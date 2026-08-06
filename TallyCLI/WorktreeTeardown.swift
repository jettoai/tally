import Darwin
import Foundation

// `tally worktree remove [name]` - the teardown counterpart of `tally claude -w`. The main-repo
// session runs it AFTER merging the worktree branch: it kills leftover agent processes rooted in
// the worktree and removes the worktree and its branch. The transcripts it wrote are KEPT unless
// `--purge-transcripts` asks for them to go.
//
// Ordering is the safety design (mirrors docs/specs/current/worktree-teardown.md): merged-check ->
// busy gate -> kill processes -> git cleanup -> transcript cleanup. Every step that finds its
// target already gone prints a note and continues, so a rerun is safe. All output goes to stderr
// (via `warn`) or /dev/tty (the menu); stdout carries nothing because this command execs nothing.
//
// Shared helpers come from GitRepoRoot.swift (`runGit`, `realpathString`), Worktree.swift
// (`parseWorktreePorcelain`, `buildMenuRows`, `WorktreeEntry`), WorktreeTree.swift
// (`resolveWorktreeListing`, `linkedWorktrees`, plus the `tally worktree` dispatch that reaches
// this file), WorktreeProcessScan.swift (the libproc walk this file's pure decisions run over) and
// Snapshot.swift (`warn`). The note it leaves for the app is WorktreeOrigins.swift, which both
// targets compile.

// MARK: - Process model

/// One live process seen by libproc, reduced to the fields the kill decision needs.
struct ProcInfo {
    let pid: pid_t
    /// Its parent, when libproc would say. 0 stands for unknown, which is what a hand-built
    /// ProcInfo in a test carries: the kill order then falls back to matching on the name.
    let ppid: pid_t
    let name: String
    let cwd: String
    /// Its controlling terminal (`/dev/ttysNNN`), nil when it has none (a daemon), or when the
    /// process belongs to another user and libproc refuses to say. Carried so teardown can hand
    /// the tab back in a usable state after killing a full-screen TUI that never got to clean up.
    let tty: String?

    init(pid: pid_t, ppid: pid_t = 0, name: String, cwd: String, tty: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.cwd = cwd
        self.tty = tty
    }
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

// The busy gate itself lives in WorktreeActivity.swift (`worktreeRemovalAllowed`), with the
// activity signal it reads: the merged check alone does not protect a running session, because a
// session that stopped at a clean intermediate commit (which the worktree protocol encourages)
// leaves a branch the main repo happily merges. Only --force waives the gate; the transcript flags
// never do, in either direction: they decide what happens to a conversation, not to a process.

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

// MARK: - Resolve the worktree to remove

/// Resolve `name` to an existing branch-backed worktree, or run the arrow-key menu when bare. Every
/// failure path exits (this is fail-closed: an ambiguous target is worse than none). The interactive
/// menu reuses WorktreeMenu.swift; its trailing "new worktree" line is a no-op here (selecting it
/// cancels with a hint) rather than invasively reshaping the shared renderer.
func resolveWorktreeForRemoval(name providedName: String?) -> RemovalTarget {
    guard let (mainRepo, entries) = resolveWorktreeListing() else {
        warn("not inside a git repository")
        exit(1)
    }
    let others = linkedWorktrees(entries).filter { $0.branch != nil }

    let name = providedName ?? pickWorktreeToRemove(others)

    guard let entry = entries.first(where: { $0.branch == name }) else {
        let available = others.compactMap { $0.branch }.joined(separator: ", ")
        warn("no worktree for branch \(name)" + (available.isEmpty ? "" : " - available: \(available)"))
        exit(1)
    }
    // Refuse the main checkout by identity (the first porcelain block), not by comparing its path:
    // a repo whose git dir is not colocated with its checkout reports that block as the git dir.
    if entries.first?.path == entry.path {
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
/// Three seams exist for tests only, all defaulting to the production behaviour: `listProcesses` so
/// the git path runs with no real killing, `transcriptHomes` so the transcript sweep can be pointed
/// at a temp tree instead of the account homes (a test must never write into, let alone delete
/// from, the user's real ~/.claude/projects, and a read-only home would fail it anyway), and
/// `originsFile` for the same reason on the other file this writes.
func performWorktreeRemove(name: String?, force: Bool, purgeTranscripts: Bool,
                          transcriptHomes: [String]? = nil,
                          originsFile: URL = WorktreeOrigins.fileURL(),
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

    // 2. The gate, then kill the agent processes rooted in the worktree before the directory
    // disappears. The agent count is the same selection `tally worktree list` reports in its live
    // agent column, so the report and the refusal can never disagree; whether those agents are
    // WORKING is read from their transcripts (WorktreeActivity.swift). Refusing returns before
    // anything is touched: no kill, no worktree removal, no branch or transcript deletion, all of
    // which are irreversible for a session still in flight. Idle agents are closed with a note
    // instead, which is the ordinary end of a finished worktree.
    let slug = worktreeTranscriptSlug(forResolvedPath: target.realPath)
    let homes = transcriptHomes ?? sharedMemoryHomes(loadSnapshot().0)
    let doomed = worktreeProcessesToKill(listProcesses(target.realPath),
                                         worktreePath: target.realPath)
    let activity = doomed.isEmpty ? .idle : worktreeActivity(slug: slug, homes: homes)
    guard worktreeRemovalAllowed(liveAgents: doomed.count, activity: activity, force: force) else {
        warn(worktreeRemovalRefusal(branch: target.branch, liveAgents: doomed.count,
                                    activity: activity))
        return 1
    }
    if !doomed.isEmpty, !force {
        warn(worktreeIdleNote(branch: target.branch, liveAgents: doomed.count,
                              purgeTranscripts: purgeTranscripts))
    }
    // 2b. Write down where this worktree came from, while the `.git` file that says so is still
    // there to be believed. Keeping the transcripts is only half of keeping the history: the app
    // rebuilds attribution from the filesystem on every full rescan (a cache version bump forces
    // one), and by then this directory is gone, so the sessions that ran here would pool into Other
    // and the repository's own recorded history would shrink anyway - the very thing keeping them
    // was for.
    //
    // `--purge-transcripts` does the opposite, and does have to act: it leaves nothing to
    // attribute, and this worktree was very likely written down when it was OPENED (`tally claude
    // -w`, or the app's scan folding it) rather than only here. That earlier note has to be taken
    // out with the conversation it was pointing at, or the ledger goes on crediting a path whose
    // transcripts are gone - to a repository that will be the wrong answer the day something else
    // takes the directory's name.
    if !purgeTranscripts {
        WorktreeOrigins.record(WorktreeOrigin(
            worktree: target.recordedPath,
            resolved: target.realPath == target.recordedPath ? nil : target.realPath,
            repository: target.mainRepo,
            removedAt: ISO8601DateFormatter().string(from: Date())), in: originsFile)
    } else {
        WorktreeOrigins.removeAll(matching: [target.recordedPath, target.realPath], in: originsFile)
    }

    // The rescan is the same selection over a fresh scan: a supervisor that got a relaunch in
    // before it died leaves a process no earlier list can name (see WorktreeKill.swift).
    let killed = killWorktreeProcesses(doomed, mainRepo: target.mainRepo, rescan: {
        worktreeProcessesToKill(listProcesses(target.realPath), worktreePath: target.realPath)
    })

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

    // 4. Transcript cleanup, which happens only when it was asked for. Keeping them is the default
    // because the app credits a worktree's usage to the repository it was cut from (the Tokens page
    // ranks one row per project, not one per parallel line), so those transcripts are part of the
    // main project's own recorded history: deleting them on the way out of a finished worktree
    // silently rewrites the numbers the user reads for the repository. `--purge-transcripts` is the
    // way to say the conversation is not worth keeping.
    var transcriptsRemoved = false
    if purgeTranscripts {
        transcriptsRemoved = removeTranscriptDirs(slug: slug, homes: homes)
    } else {
        warn("transcripts kept")
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
/// removal is guarded so nothing outside that home's transcript tree is ever touched, and the memory
/// symlink inside the dir is never followed (removeItem unlinks the link, leaving the project's
/// memory intact). Returns whether at least one directory was removed.
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

/// The `remove` flags as typed, or nil when they do not make sense (warned about here, since only
/// this function knows which word was the problem). Split from the run so the flag vocabulary can
/// be asserted without a repository to tear down.
func parseWorktreeRemoveFlags(_ args: [String])
    -> (name: String?, force: Bool, purgeTranscripts: Bool)? {
    var force = false
    var purgeTranscripts = false
    var keepTranscripts = false
    var name: String?
    for arg in args {
        switch arg {
        case "--force":
            force = true
        case "--purge-transcripts":
            purgeTranscripts = true
        case "--keep-transcripts":
            // What this flag asks for is now what happens anyway. Accepted rather than rejected so
            // a script, a habit, or a note written down when deletion was the default keeps
            // working, and answered so nobody keeps typing it for a guarantee it no longer buys.
            keepTranscripts = true
            warn("transcripts are kept by default now")
        default:
            if arg.hasPrefix("-") {
                warn("unknown flag \(arg)")
                return nil
            }
            if name == nil {
                name = arg
            } else {
                warn("unexpected argument \(arg)")
                return nil
            }
        }
    }
    // Asking for both is refused rather than resolved: the two flags name opposite fates for the
    // same conversation, and either way of picking a winner is wrong for somebody. Last-wins would
    // let an old script that still carries --keep-transcripts (written when it was the only way to
    // save a conversation, and meaning it) end up deleting one, which is not undoable. Doing
    // nothing and saying so costs one rerun.
    if keepTranscripts, purgeTranscripts {
        warn("--keep-transcripts and --purge-transcripts ask for opposite things - "
            + "pass one of them (transcripts are kept by default)")
        return nil
    }
    return (name, force, purgeTranscripts)
}

/// Parse `remove` flags and run the teardown. Returns the process exit code. Called by the
/// `tally worktree` dispatch, which lives with the read-only commands in WorktreeTree.swift.
func runWorktreeRemove(args: [String]) -> Int32 {
    guard let flags = parseWorktreeRemoveFlags(args) else { return 2 }
    return performWorktreeRemove(name: flags.name, force: flags.force,
                                 purgeTranscripts: flags.purgeTranscripts)
}
