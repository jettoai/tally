import Darwin
import Foundation

// `tally worktree remove [name]` - the teardown counterpart of `tally claude -w`. The main-repo
// session runs it AFTER merging the worktree branch: it kills leftover agent processes rooted in
// the worktree, removes the worktree and its branch, and deletes the orphaned transcript directory.
//
// Ordering is the safety design (mirrors docs/specs/current/worktree-teardown.md): merged-check ->
// liveness gate -> kill processes -> git cleanup -> transcript cleanup. Every step that finds its
// target already gone prints a note and continues, so a rerun is safe. All output goes to stderr
// (via `warn`) or /dev/tty (the menu); stdout carries nothing because this command execs nothing.
//
// Shared helpers come from Worktree.swift (`runGit`, `realpathString`, `parseWorktreePorcelain`,
// `isMainCheckout`, `buildMenuRows`, `WorktreeEntry`), WorktreeTree.swift (`resolveMainRepo`, plus
// the `tally worktree` dispatch that reaches this file) and Snapshot.swift (`warn`).

// MARK: - Process model

/// One live process seen by libproc, reduced to the fields the kill decision needs.
struct ProcInfo {
    let pid: pid_t
    let name: String
    let cwd: String
}

/// The worktree we resolved to tear down. `recordedPath` is the exact string git stored (fed back
/// to `git worktree remove`); `realPath` is the fully-resolved path used for cwd matching and the
/// transcript slug (both must resolve /tmp -> /private/tmp to line up with what Claude Code wrote).
struct RemovalTarget {
    let mainRepo: String
    let recordedPath: String
    let realPath: String
    let branch: String
}

// MARK: - Pure decisions (unit-tested without root or real processes)

/// Whether a process should be signalled: its name must be in the allowlist AND its cwd must be the
/// worktree itself or nested under it. The nested check appends a trailing "/" so a sibling whose
/// path merely shares a prefix (e.g. cwd `/a/bc` against worktree `/a/b`) is never a false positive.
/// Shells (zsh/bash) are absent from the allowlist on purpose: killing one would close a user's
/// terminal tab, and a tab left in a removed directory is harmless.
func shouldKill(name: String, cwd: String, worktreePath: String) -> Bool {
    let allowlist: Set<String> = ["claude", "tally", "fswatch"]
    guard allowlist.contains(name) else { return false }
    return cwd == worktreePath || cwd.hasPrefix(worktreePath + "/")
}

/// The processes a scan hands to the killer, and the same selection the list report counts as live
/// agents. Shared by both callers so an injected scan can exercise it: `shouldKill` was never the
/// failure, the scan feeding it was (see `defaultListProcesses`).
func worktreeProcessesToKill(_ processes: [ProcInfo], worktreePath: String) -> [ProcInfo] {
    processes.filter { shouldKill(name: $0.name, cwd: $0.cwd, worktreePath: worktreePath) }
}

/// The liveness gate: whether teardown may proceed while agents are still running in the worktree.
/// The merged check alone does not protect them - a session that stopped at a clean intermediate
/// commit (which the worktree protocol encourages) leaves a branch the main repo happily merges, so
/// "merged" says nothing about whether anyone is still working there. Only --force waives it, and
/// --keep-transcripts deliberately does not: it spares the transcripts, not the processes.
func worktreeRemovalAllowed(liveAgents: Int, force: Bool) -> Bool {
    liveAgents == 0 || force
}

/// Whether teardown may delete the worktree directory itself. Only true once git has let go of the
/// path, so the normal path (where `git worktree remove` deletes the files) never reaches it.
/// Refuses the main repo and any ancestor of it: deleting one would take the repository along.
func worktreeDirRemovalAllowed(path: String, mainRepo: String, registered: Bool) -> Bool {
    guard !registered, path.hasPrefix("/"), path != "/", path != mainRepo else { return false }
    return !mainRepo.hasPrefix(path + "/")
}

/// The transcript-directory slug for a worktree: "/" and "." become "-" on the already-resolved
/// path. Matches `projectSlug` applied to the same realpath, but stays a pure string op so it works
/// even after the worktree directory has been removed.
func worktreeTranscriptSlug(forResolvedPath path: String) -> String {
    path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
}

/// Guard before deleting a transcript directory: the target must sit strictly under this account
/// home's `<home>/projects/` (where `home` is a config home such as ~/.claude or ~/.claude2) and not
/// be that directory itself. Combined with a non-empty slug (a resolved path with no remaining
/// slashes cannot escape the prefix), this refuses any path outside the transcript tree.
func transcriptGuardPasses(target: String, home: String) -> Bool {
    let prefix = "\(home)/projects/"
    return target.hasPrefix(prefix) && target != prefix
}

// MARK: - libproc enumeration (production only; tests inject a process list)

/// Every live process (except this one and its ancestors) whose cwd libproc will report. Only
/// processes we can inspect and signal surface here, which is exactly the set we could kill anyway.
/// How far the pid buffer may be walked comes from `scannedPidCount` (ReloadRequest.swift, same
/// target), which documents why the second `proc_listallpids` return must not be divided by the pid
/// size. Doing so once ended the walk a quarter of the way through the machine, blinding both users
/// of this scan: teardown reported "killed 0" over live agents, and `tally worktree list`
/// undercounted the same processes in its live agent column.
func defaultListProcesses(worktreePath: String) -> [ProcInfo] {
    let excluded = ancestorPids(of: getpid())
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity))
    let returned = proc_listallpids(&pids, Int32(Int(capacity) * MemoryLayout<pid_t>.size))
    var result: [ProcInfo] = []
    for pid in pids.prefix(scannedPidCount(returned, capacity: pids.count)) {
        if pid <= 0 || excluded.contains(pid) { continue }
        guard let cwd = processCwd(pid), !cwd.isEmpty else { continue }
        result.append(ProcInfo(pid: pid, name: processName(pid), cwd: cwd))
    }
    return result
}

/// The current working directory of a process via proc_pidvnodepathinfo, or nil when it cannot be
/// read (the process is gone, or belongs to another user).
private func processCwd(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
    return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
        raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
    }
}

/// A process's short name: the last path component of its executable (proc_pidpath), falling back to
/// the accounting name (proc_name) when the path is unavailable.
private func processName(_ pid: pid_t) -> String {
    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not imported into Swift; use its literal value.
    var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)
    if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
        let path = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if !path.isEmpty { return (path as NSString).lastPathComponent }
    }
    var nameBuffer = [CChar](repeating: 0, count: 256)
    if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
        return nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
    return ""
}

/// The set of a process's own pid plus every ancestor, walked via proc_bsdinfo's parent pid. Used to
/// keep the teardown from signalling the session that launched it.
private func ancestorPids(of start: pid_t) -> Set<pid_t> {
    var chain: Set<pid_t> = [start]
    var pid = start
    while let parent = parentPid(pid), parent > 0, !chain.contains(parent) {
        chain.insert(parent)
        pid = parent
    }
    return chain
}

private func parentPid(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

/// SIGTERM the matched processes, poll up to 2 seconds for a graceful exit, then SIGKILL the
/// survivors. Prints "terminated <pid> <name>" for those that exited on the TERM and
/// "killed <pid> <name>" for those that needed the KILL. Returns the number targeted.
func killWorktreeProcesses(_ targets: [ProcInfo]) -> Int {
    guard !targets.isEmpty else { return 0 }
    for target in targets { kill(target.pid, SIGTERM) }
    var remaining = targets
    let deadline = Date().addingTimeInterval(2)
    while !remaining.isEmpty, Date() < deadline {
        usleep(100_000)
        var stillAlive: [ProcInfo] = []
        for target in remaining {
            if kill(target.pid, 0) == 0 {
                stillAlive.append(target)
            } else {
                warn("terminated \(target.pid) \(target.name)")
            }
        }
        remaining = stillAlive
    }
    for target in remaining {
        kill(target.pid, SIGKILL)
        warn("killed \(target.pid) \(target.name)")
    }
    return targets.count
}

// MARK: - Resolve the worktree to remove

/// Resolve `name` to an existing branch-backed worktree, or run the arrow-key menu when bare. Every
/// failure path exits (this is fail-closed: an ambiguous target is worse than none). The interactive
/// menu reuses WorktreeMenu.swift; its trailing "new worktree" line is a no-op here (selecting it
/// cancels with a hint) rather than invasively reshaping the shared renderer.
func resolveWorktreeForRemoval(name providedName: String?) -> RemovalTarget {
    guard let mainRepo = resolveMainRepo() else {
        warn("not inside a git repository")
        exit(1)
    }
    let entries = parseWorktreePorcelain(runGit(["worktree", "list", "--porcelain"], cwd: mainRepo).out)
    let others = entries.filter { $0.branch != nil && !isMainCheckout($0, mainRepo: mainRepo) }

    let name = providedName ?? pickWorktreeToRemove(others)

    guard let entry = entries.first(where: { $0.branch == name }) else {
        let available = others.compactMap { $0.branch }.joined(separator: ", ")
        warn("no worktree for branch \(name)" + (available.isEmpty ? "" : " - available: \(available)"))
        exit(1)
    }
    if isMainCheckout(entry, mainRepo: mainRepo) {
        warn("branch \(name) is the main checkout, not a worktree")
        exit(1)
    }
    guard let branch = entry.branch else {
        warn("worktree \(name) has no branch to remove")
        exit(1)
    }
    return RemovalTarget(mainRepo: mainRepo, recordedPath: entry.path,
                         realPath: realpathString(entry.path), branch: branch)
}

/// Bare `tally worktree remove`: present the same menu as launch, minus the create affordance.
private func pickWorktreeToRemove(_ others: [WorktreeEntry]) -> String {
    if others.isEmpty {
        warn("no worktrees to remove")
        exit(1)
    }
    guard let selection = selectWorktree(rows: buildMenuRows(others)) else {
        warn("pass a name: tally worktree remove <name>")
        exit(1)
    }
    switch selection {
    case .existing(let index): return others[index].branch!
    case .newWorktree:
        warn("nothing to create here; pass a name to tally claude -w")
        exit(1)
    case .cancelled:
        exit(1)
    }
}

// MARK: - Orchestration

/// Run the full teardown for a resolved target. Returns a process exit code (0 success, 1 refusal).
/// Two seams exist for tests only, both defaulting to the production behaviour: `listProcesses` so
/// the git path runs with no real killing, and `transcriptHomes` so the transcript sweep can be
/// pointed at a temp tree instead of the account homes (a test must never write into, let alone
/// delete from, the user's real ~/.claude/projects, and a read-only home would fail it anyway).
func performWorktreeRemove(name: String?, force: Bool, keepTranscripts: Bool,
                          transcriptHomes: [String]? = nil,
                          listProcesses: (String) -> [ProcInfo] = defaultListProcesses) -> Int32 {
    let target = resolveWorktreeForRemoval(name: name)

    // 0. Never saw off the branch we are sitting on: a caller whose own cwd is inside the target
    // worktree (a session run from the worktree by mistake) would otherwise be left in a deleted
    // directory with its transcripts removed mid-session; git itself does not refuse because the
    // git subprocess runs with mainRepo as its cwd. Refuse cleanly before anything is torn down.
    let callerCwd = realpathString(FileManager.default.currentDirectoryPath)
    if callerCwd == target.realPath || callerCwd.hasPrefix(target.realPath + "/") {
        warn("refusing: the current directory is inside worktree \(target.branch); "
            + "run this from the main repo")
        return 1
    }

    // 1. Merged check: refuse an unmerged branch unless forced, naming the unmerged commit count.
    // refs/heads/ is spelled out because a tag with the branch's name would otherwise shadow it in
    // rev-parse (gitrevisions resolves tags before heads) and could waive the merged gate.
    let head = runGit(["rev-parse", "refs/heads/\(target.branch)"], cwd: target.mainRepo)
    let sha = head.out
    if !force {
        let merged = runGit(["merge-base", "--is-ancestor", sha, "HEAD"], cwd: target.mainRepo).code == 0
        if !merged {
            let count = runGit(["rev-list", "--count", "HEAD..\(sha)"], cwd: target.mainRepo).out
            let plural = count == "1" ? "" : "s"
            warn("branch \(target.branch) is not merged into HEAD (\(count) commit\(plural) ahead) - "
                + "merge first or pass --force")
            return 1
        }
    }

    // 2. Liveness gate, then kill the agent processes rooted in the worktree before the directory
    // disappears. The count is the same selection `tally worktree list` reports in its live agent
    // column, so what the report shows and what the gate refuses can never disagree. Refusing
    // returns before anything is touched: no kill, no worktree removal, no branch or transcript
    // deletion, all of which are irreversible for a session still in flight.
    let doomed = worktreeProcessesToKill(listProcesses(target.realPath),
                                         worktreePath: target.realPath)
    guard worktreeRemovalAllowed(liveAgents: doomed.count, force: force) else {
        // Both ways out are named: someone stopped here next wants to know how to take the worktree
        // down WITHOUT losing the conversation, and that flag combination is right there.
        let plural = doomed.count == 1 ? "" : "s"
        warn("worktree \(target.branch) still has \(doomed.count) live agent\(plural) - "
            + "let them finish, or --force to kill them and delete their transcripts, "
            + "or --force --keep-transcripts to kill them and keep the conversation")
        return 1
    }
    let killed = killWorktreeProcesses(doomed)

    // 3. git cleanup: remove the worktree, then delete its branch. Idempotent: an already-gone
    // target just notes and continues.
    let removeArgs = force ? ["worktree", "remove", "--force", target.recordedPath]
                           : ["worktree", "remove", target.recordedPath]
    let removed = runGit(removeArgs, cwd: target.mainRepo)
    if removed.code != 0 {
        // A registration whose checkout no longer validates (its .git file gone, which git reports
        // as "prunable") fails remove while leaving the directory behind. Prune, then ask again:
        // pruning only drops entries git already considers broken, so a healthy worktree that
        // refused removal for a real reason (uncommitted work) still stops the teardown here.
        _ = runGit(["worktree", "prune"], cwd: target.mainRepo)
        if worktreeStillRegistered(target) {
            warn(removed.err.isEmpty ? "git worktree remove failed" : removed.err)
            return 1
        }
        warn("worktree already removed")
    }

    // 3b. The directory outlives the registration whenever git stopped owning the path without
    // deleting the files (the half-removed state seen 2026-07-26: every step reported success and
    // a directory shell stayed on disk with nobody responsible for it).
    removeOrphanedWorktreeDirectory(target)

    let deleteArgs = force ? ["branch", "-D", target.branch] : ["branch", "-d", target.branch]
    let branchDelete = runGit(deleteArgs, cwd: target.mainRepo)
    let branchDeleted = runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(target.branch)"],
                               cwd: target.mainRepo).code != 0
    if !branchDeleted {
        warn(branchDelete.err.isEmpty ? "could not delete branch \(target.branch)" : branchDelete.err)
    } else if branchDelete.code != 0 {
        warn("branch \(target.branch) already deleted")
    }

    // 4. Transcript cleanup: delete the orphaned per-worktree projects dir in EVERY account home the
    // launch side seeds (never following the memory symlink inside it - removeItem unlinks the link,
    // leaving the project's memory intact).
    var transcriptsRemoved = false
    if keepTranscripts {
        warn("transcripts kept")
    } else {
        transcriptsRemoved = removeTranscriptDirs(
            slug: worktreeTranscriptSlug(forResolvedPath: target.realPath),
            homes: transcriptHomes ?? sharedMemoryHomes(loadSnapshot().0))
    }

    warn("worktree \(target.branch) removed (killed \(killed), "
        + "branch \(branchDeleted ? "deleted" : "kept"), "
        + "transcripts \(transcriptsRemoved ? "removed" : "kept"))")
    return 0
}

/// Whether git still lists the target path among this repo's worktrees. Asked again after a failed
/// removal (and before deleting anything ourselves) since a prune in between can change the answer.
private func worktreeStillRegistered(_ target: RemovalTarget) -> Bool {
    parseWorktreePorcelain(runGit(["worktree", "list", "--porcelain"], cwd: target.mainRepo).out)
        .contains { realpathString($0.path) == target.realPath }
}

/// Delete the worktree directory git left behind, guarded by `worktreeDirRemovalAllowed`. A removal
/// that failed the guard, or the deletion itself failing, only warns: the remaining teardown steps
/// (branch, transcripts) are still worth running.
private func removeOrphanedWorktreeDirectory(_ target: RemovalTarget) {
    guard FileManager.default.fileExists(atPath: target.realPath) else { return }
    guard worktreeDirRemovalAllowed(path: target.realPath, mainRepo: target.mainRepo,
                                    registered: worktreeStillRegistered(target)) else {
        warn("worktree directory kept (path guard): \(target.realPath)")
        return
    }
    do {
        try FileManager.default.removeItem(atPath: target.realPath)
        warn("worktree directory removed: \(target.realPath)")
    } catch {
        warn("could not remove worktree directory (\(target.realPath)): "
            + error.localizedDescription)
    }
}

/// Delete `<home>/projects/<slug>` in each account home. The launch side (`ensureSharedMemory`)
/// seeds this dir in every home `sharedMemoryHomes` returns (default ~/.claude plus each account's
/// launch home), so teardown must sweep the same set or leave orphan dirs and dangling memory
/// symlinks behind in secondary homes. Homes that resolve to one physical projects tree (e.g.
/// ~/.claude2/projects symlinked to ~/.claude/projects) are acted on once; a home whose dir is
/// already gone (removed via a shared tree, or never created) prints a note and continues. Each
/// removal is guarded so nothing outside that home's transcript tree is ever touched. Returns
/// whether at least one directory was removed.
func removeTranscriptDirs(slug: String, homes: [String]) -> Bool {
    guard !slug.isEmpty else {
        warn("transcripts kept (empty slug)")
        return false
    }
    var removedAny = false
    var seenTrees = Set<String>()
    for home in homes {
        guard seenTrees.insert(realpathString("\(home)/projects")).inserted else { continue }
        let target = "\(home)/projects/\(slug)"
        guard transcriptGuardPasses(target: target, home: home) else {
            warn("transcripts kept (path guard): \(target)")
            continue
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
            warn("transcripts already gone: \(target)")
            continue
        }
        do {
            try FileManager.default.removeItem(atPath: target)
            warn("transcripts removed: \(target)")
            removedAny = true
        } catch {
            warn("could not remove transcripts (\(target)): \(error.localizedDescription)")
        }
    }
    return removedAny
}

// MARK: - Remove flags

/// Parse `remove` flags and run the teardown. Returns the process exit code. Called by the
/// `tally worktree` dispatch, which lives with the read-only commands in WorktreeTree.swift.
func runWorktreeRemove(args: [String]) -> Int32 {
    var force = false
    var keepTranscripts = false
    var name: String?
    for arg in args {
        switch arg {
        case "--force":
            force = true
        case "--keep-transcripts":
            keepTranscripts = true
        default:
            if arg.hasPrefix("-") {
                warn("unknown flag \(arg)")
                return 2
            }
            if name == nil {
                name = arg
            } else {
                warn("unexpected argument \(arg)")
                return 2
            }
        }
    }
    return performWorktreeRemove(name: name, force: force, keepTranscripts: keepTranscripts)
}
