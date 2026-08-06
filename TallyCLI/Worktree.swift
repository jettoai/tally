import Darwin
import Foundation

// `tally claude -w [name]` support: resolve or create a git worktree, share the project's
// Claude memory into it, run the repo's per-worktree setup hook, and chdir so the supervisor
// and the exec'd CLI inherit the worktree as their working directory.
//
// Split of responsibility with main.swift: this file owns all worktree logic and depends only on
// Foundation/Darwin plus a few symbols from Snapshot.swift (`warn`, `loadSnapshot`, `projectSlug`,
// the `Snapshot` type), GitRepoRoot.swift (`runGit`, `realpathString`, `resolveMainRepo` - the
// repo identity a per-project launch profile is keyed by too) and WorktreeOrigins.swift (the note
// this writes for the app, which teardown writes too), so tests can compile it standalone.
// The launch resolution itself is fail-closed (the user explicitly asked for a worktree, so a wrong
// directory is worse than none), while the memory link and setup hook are fail-open enhancements
// that only ever warn.

struct WorktreeLaunch {
    let mainRepo: String      // main repo root (realpath)
    let path: String          // worktree directory (realpath)
    let name: String          // branch name (verbatim, may contain "/")
    let created: Bool         // whether this invocation created it
}

/// One line of `git worktree list --porcelain`, reduced to what the menu and reuse check need.
struct WorktreeEntry {
    let path: String
    let branch: String?       // short name (refs/heads/ stripped); nil when detached or bare
}

// MARK: - Flag extraction

/// Pull `-w`/`--worktree` out of the passthrough args. Its value is optional: when the next arg
/// starts with "-" (another flag) or is absent, it is a bare `-w` whose name is resolved
/// interactively. Returns whether the flag was present and its name; `args` has the flag and its
/// consumed value removed in place.
func extractWorktreeFlag(_ args: inout [String]) -> (found: Bool, name: String?) {
    // Options only: `-w` inside a prompt is a word, and consuming it would also swallow the word
    // after it. An index into the options prefix is an index into `args` (Snapshot.swift).
    guard let index = optionsOnly(args).firstIndex(where: { $0 == "-w" || $0 == "--worktree" })
    else {
        return (false, nil)
    }
    let next = index + 1 < args.count ? args[index + 1] : nil
    if let next, !next.hasPrefix("-") {
        args.removeSubrange(index ... index + 1)
        return (true, next)
    }
    args.remove(at: index)
    return (true, nil)
}

// MARK: - Porcelain parsing and path derivation

/// Parse `git worktree list --porcelain` into entries. Blocks are separated by blank lines; each
/// starts with a `worktree <path>` line and may carry a `branch refs/heads/<name>` line (absent
/// when detached or bare).
func parseWorktreePorcelain(_ text: String) -> [WorktreeEntry] {
    var entries: [WorktreeEntry] = []
    var path: String?
    var branch: String?
    func flush() {
        if let path { entries.append(WorktreeEntry(path: path, branch: branch)) }
        path = nil
        branch = nil
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("worktree ") {
            flush()
            path = String(line.dropFirst("worktree ".count))
        } else if line.hasPrefix("branch ") {
            let ref = String(line.dropFirst("branch ".count))
            branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
    }
    flush()
    return entries
}

/// A branch name sanitized for a directory suffix: only "/" is replaced (the branch itself keeps
/// its verbatim name, e.g. `feat/x` lives on branch `feat/x` in `<repo>-feat-x`).
func sanitizeWorktreeName(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "-")
}

/// Landing directory for a new worktree: a sibling of the main repo named `<repo>-<sanitized>`.
func worktreePath(mainRepo: String, name: String) -> String {
    let parent = (mainRepo as NSString).deletingLastPathComponent
    let repoName = (mainRepo as NSString).lastPathComponent
    return "\(parent)/\(repoName)-\(sanitizeWorktreeName(name))"
}

// MARK: - Resolve / create

/// Resolve an existing worktree by branch, or create one, for `name`. When `name` is nil the
/// bare-`-w` menu prompts for a choice (existing worktrees or a new branch). Every failure path
/// warns and exits non-zero: `-w` was an explicit request, so silently falling back to a plain
/// launch would land the user in the wrong tree.
func resolveWorktree(name providedName: String?) -> WorktreeLaunch {
    // Resolution is shared with the read-only commands (WorktreeTree.swift): running `-w` from
    // inside a worktree resolves back to the same main repo, and a repo whose git dir is not
    // colocated with its checkout (submodule, --separate-git-dir) is asked rather than computed.
    // Only the failure path differs: `-w` was an explicit request, so this one exits.
    guard let (mainRepo, entries) = resolveWorktreeListing() else {
        warn("not inside a git repository")
        exit(1)
    }

    let name = providedName ?? promptWorktreeName(mainRepo: mainRepo, entries: entries)

    // A branch already checked out in a worktree is reused at ITS recorded path (respecting an
    // existing checkout even if it doesn't follow our `<repo>-<name>` naming). Matching the main
    // checkout is refused rather than silently resolving `-w <trunk-branch>` to "no worktree";
    // that check is by POSITION (the first porcelain block is the main worktree) because a path
    // comparison never matches it when git reports that block as the git dir.
    if let existing = entries.first(where: { $0.branch == name }) {
        if entries.first?.path == existing.path {
            warn("branch \(name) is the main checkout, not a worktree")
            exit(1)
        }
        return WorktreeLaunch(mainRepo: mainRepo, path: realpathString(existing.path),
                              name: name, created: false)
    }

    let path = worktreePath(mainRepo: mainRepo, name: name)
    // Never clobber: a directory that exists but isn't a registered worktree for this branch is
    // left untouched (the user removes it or picks another name).
    if pathExists(path) {
        warn("\(path) already exists but is not a registered worktree - remove it or pick another name")
        exit(1)
    }

    // Reuse an existing branch, otherwise create it with the worktree.
    let branchExists = runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], cwd: mainRepo).code == 0
    let addArgs = branchExists
        ? ["worktree", "add", path, name]
        : ["worktree", "add", path, "-b", name]
    let add = runGit(addArgs, cwd: mainRepo)
    guard add.code == 0 else {
        warn(add.err.isEmpty ? "git worktree add failed" : add.err)
        exit(1)
    }
    return WorktreeLaunch(mainRepo: mainRepo, path: realpathString(path), name: name, created: true)
}

/// Bare `-w`: choose a worktree. With no existing worktrees, skip straight to naming a new one.
/// Otherwise try the arrow-key menu (WorktreeMenu.swift); a non-interactive session (no tty, dumb
/// terminal, or raw mode unavailable) falls back to the numbered stderr prompt. Either way stdout
/// stays a clean pipe for the exec that follows and stdin belongs to the CLI. `n` prompts for a new
/// branch name; a cancel, empty input, or EOF exits non-zero rather than guessing.
private func promptWorktreeName(mainRepo: String, entries: [WorktreeEntry]) -> String {
    let others = linkedWorktrees(entries).filter { $0.branch != nil }
    if others.isEmpty {
        return promptNewBranchViaTTY()
    }
    if let selection = selectWorktree(rows: buildMenuRows(others)) {
        switch selection {
        case .existing(let index): return others[index].branch!
        case .newWorktree: return promptNewBranchViaTTY()
        case .cancelled: exit(1)
        }
    }
    return promptNumberedMenu(others: others)
}

/// Resolve the git facts each menu row shows: relative age (`%cr`), a dirty flag, and the last
/// commit subject (`%s`), which the renderer clips. Shared with WorktreeTeardown.swift's remove menu.
func buildMenuRows(_ others: [WorktreeEntry]) -> [MenuRow] {
    others.map { entry in
        let age = runGit(["-C", entry.path, "log", "-1", "--format=%cr"]).out
        let dirty = !runGit(["-C", entry.path, "status", "--porcelain"]).out.isEmpty
        let subject = runGit(["-C", entry.path, "log", "-1", "--format=%s"]).out
        return MenuRow(branch: entry.branch!, age: age, dirty: dirty, subject: subject)
    }
}

/// The numbered stderr prompt kept for non-interactive sessions: prints the list on stderr and
/// reads one line from /dev/tty. A number reuses that worktree's branch; `n` names a new one.
private func promptNumberedMenu(others: [WorktreeEntry]) -> String {
    guard let tty = fopen("/dev/tty", "r") else {
        warn("pass a name: tally claude -w <name>")
        exit(1)
    }
    defer { fclose(tty) }
    var menu = "existing worktrees:\n"
    for (i, entry) in others.enumerated() {
        let age = runGit(["-C", entry.path, "log", "-1", "--format=%cr"]).out
        let dirty = runGit(["-C", entry.path, "status", "--porcelain"]).out.isEmpty ? "" : "  dirty"
        menu += "  \(i + 1)) \(entry.branch!)  (\(age.isEmpty ? "no commits" : age))\(dirty)\n"
    }
    menu += "  n) new worktree\nchoose: "
    FileHandle.standardError.write(Data(menu.utf8))

    guard let choice = readLine(from: tty), !choice.isEmpty else { exit(1) }
    if choice == "n" || choice == "N" {
        return promptNewBranch(tty)
    }
    if let index = Int(choice), index >= 1, index <= others.count {
        return others[index - 1].branch!
    }
    warn("not a valid choice")
    exit(1)
}

/// Open /dev/tty for a single line of new-branch input, used after the menu picks "new worktree".
private func promptNewBranchViaTTY() -> String {
    guard let tty = fopen("/dev/tty", "r") else {
        warn("pass a name: tally claude -w <name>")
        exit(1)
    }
    defer { fclose(tty) }
    return promptNewBranch(tty)
}

private func promptNewBranch(_ tty: UnsafeMutablePointer<FILE>) -> String {
    FileHandle.standardError.write(Data("new worktree name: ".utf8))
    guard let name = readLine(from: tty), !name.isEmpty else { exit(1) }
    return name
}

// MARK: - Shared memory

/// The Claude config homes whose `projects/` tree should carry the shared-memory link: the default
/// `~/.claude` plus every claude account's launch home. Deduped later by realpath (a machine that
/// symlinks projects across accounts sees the same tree, and the link op is idempotent anyway).
func sharedMemoryHomes(_ snapshot: Snapshot?) -> [String] {
    let defaultHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude").path
    var homes = [defaultHome]
    for account in snapshot?.accounts ?? [] where account.provider == "claude" {
        if let home = account.launchHome { homes.append(home) }
    }
    return homes
}

/// For each home, link `<home>/projects/<wtSlug>/memory` to the main repo's memory directory so a
/// fresh worktree inherits the project's accumulated notes. Never clobbers an existing path (a
/// real local memory dir, or a link already in place), and every step is fail-open: memory is an
/// enhancement, not a reason to block the launch.
func ensureSharedMemory(_ wt: WorktreeLaunch, homes: [String]) {
    let fm = FileManager.default
    let wtSlug = projectSlug(forCwd: wt.path)
    let mainSlug = projectSlug(forCwd: wt.mainRepo)
    var seen = Set<String>()
    for rawHome in homes {
        let home = realpathString(rawHome)
        guard seen.insert(home).inserted else { continue }
        let projects = "\(home)/projects"
        let mainMemory = "\(projects)/\(mainSlug)/memory"
        let wtDir = "\(projects)/\(wtSlug)"
        let wtMemory = "\(wtDir)/memory"
        do {
            // Ensure the link TARGET exists first so a relative symlink never dangles, then the
            // worktree's own projects dir.
            try fm.createDirectory(atPath: mainMemory, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: wtDir, withIntermediateDirectories: true)
        } catch {
            warn("shared memory (\(home)): \(error.localizedDescription)")
            continue
        }
        if pathExists(wtMemory) { continue }   // never clobber, whatever is already there
        do {
            try fm.createSymbolicLink(atPath: wtMemory, withDestinationPath: "../\(mainSlug)/memory")
        } catch {
            warn("shared memory (\(home)): \(error.localizedDescription)")
        }
    }
}

// MARK: - Origin note

/// Write down which repository this worktree belongs to, now, while it is being opened.
///
/// The app credits a worktree's tokens to its repository by reading the `.git` file that says so,
/// and `WorktreeOrigins` is the note that answers once that file is gone. Teardown writes one, but
/// teardown is not the only way a parallel line ends: a bare `git worktree remove`, or an `rm -rf`
/// on the directory, leaves nothing behind at all and the transcripts (which outlive the directory
/// either way) pool into Other. Writing the note at the START costs one file write per launch and
/// covers every ending. The file is a parameter for the same reason it is one in
/// `performWorktreeRemove`: a test must never write into the ledger the running app reads.
///
/// Written only when it would say something new (`recordNew`), so re-entering a worktree every day
/// does not rewrite the ledger every time, and a note teardown has already stamped with a removal
/// time is left where it is.
func recordWorktreeOrigin(_ wt: WorktreeLaunch, in url: URL = WorktreeOrigins.fileURL()) {
    WorktreeOrigins.recordNew([WorktreeOrigin(worktree: wt.path, resolved: nil,
                                              repository: wt.mainRepo, removedAt: nil)], in: url)
}

// MARK: - Setup hook

/// Run the repo's `.tally/worktree-setup.sh` (if present) with the worktree as cwd, passing the
/// launch context through the environment. Runs on EVERY entry (the script must be idempotent),
/// and a non-zero exit only warns: tally must never be the reason a session can't start.
func runSetupHook(_ wt: WorktreeLaunch) {
    let script = "\(wt.mainRepo)/.tally/worktree-setup.sh"
    guard FileManager.default.fileExists(atPath: script) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script]
    process.currentDirectoryURL = URL(fileURLWithPath: wt.path)
    var env = ProcessInfo.processInfo.environment
    env["TALLY_MAIN_REPO"] = wt.mainRepo
    env["TALLY_WORKTREE_NAME"] = wt.name
    env["TALLY_WORKTREE_PATH"] = wt.path
    env["TALLY_WORKTREE_CREATED"] = wt.created ? "1" : "0"
    process.environment = env
    // stdout/stderr inherit the terminal so the script's output is visible.
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            warn("setup hook failed (exit \(process.terminationStatus)) - continuing")
        }
    } catch {
        warn("setup hook could not run: \(error.localizedDescription) - continuing")
    }
}

// MARK: - Orchestration

/// Resolve/create the worktree, run its setup hook, wire shared memory, then chdir into it so the
/// supervisor and the exec'd CLI both inherit the worktree. Returns whether there is NO conversation
/// to continue (freshly created, OR an existing worktree - e.g. one made by hand - whose project
/// slug has no transcript in any home): the caller then suppresses a "continue by default" and
/// strips a hand-typed --continue/--resume so claude doesn't error out continuing nothing.
func enterWorktree(name: String?) -> Bool {
    let wt = resolveWorktree(name: name)
    recordWorktreeOrigin(wt)
    runSetupHook(wt)
    let (snapshot, _) = loadSnapshot()
    let homes = sharedMemoryHomes(snapshot)
    ensureSharedMemory(wt, homes: homes)
    let hasConversation = worktreeHasTranscript(slug: projectSlug(forCwd: wt.path), homes: homes)
    if chdir(wt.path) != 0 {
        warn("cannot enter worktree \(wt.path): \(String(cString: strerror(errno)))")
        exit(1)
    }
    warn("→ worktree \(wt.name)\(wt.created ? " (created)" : "")")
    return wt.created || !hasConversation
}

/// True when any home already holds a *.jsonl transcript for this project slug (a conversation
/// exists to continue). A fresh worktree, or a hand-made one with no session yet, has none.
func worktreeHasTranscript(slug: String, homes: [String]) -> Bool {
    let fm = FileManager.default
    for home in homes {
        let files = (try? fm.contentsOfDirectory(atPath: "\(home)/projects/\(slug)")) ?? []
        if files.contains(where: { $0.hasSuffix(".jsonl") }) { return true }
    }
    return false
}

/// Strip a hand-typed --continue/-c and --resume/-r (with its session-id value, i.e. the next arg
/// unless it looks like another flag) from the args. Returns whether anything was removed (the
/// caller then warns). Used for a worktree with no conversation yet.
func stripContinueResume(_ args: inout [String]) -> Bool {
    var removed = false
    var i = 0
    // Only the options are stripped; `end` tracks the shrinking prefix so everything from the user's
    // `--` onward is left exactly as typed (Snapshot.swift).
    var end = optionsOnly(args).count
    while i < end {
        switch args[i] {
        case "--continue", "-c":
            args.remove(at: i)
            end -= 1
            removed = true
        case "--resume", "-r":
            args.remove(at: i)
            end -= 1
            removed = true
            if i < end, !args[i].hasPrefix("-") { args.remove(at: i); end -= 1 }
        default:
            i += 1
        }
    }
    return removed
}

// MARK: - Helpers

/// True when a path exists as anything, INCLUDING a dangling symlink (lstat does not follow the
/// final link) - so the never-clobber checks refuse to overwrite an existing link too.
private func pathExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

/// Read one trimmed line from an open FILE stream; nil on EOF.
private func readLine(from stream: UnsafeMutablePointer<FILE>) -> String? {
    // A crashed or killed full-screen program (a Claude session dying to SIGTERM, say) can leave
    // the tty raw with ICRNL off, so Enter yields a bare CR that never ends the line and echoes as
    // ^M. Force a sane line-input mode for the duration of this read, then put back whatever was
    // there before; the shell owns the terminal's long-term state, not us.
    let fd = fileno(stream)
    var saved = termios()
    let sane = isatty(fd) == 1 && tcgetattr(fd, &saved) == 0
    if sane {
        var line = saved
        line.c_iflag |= tcflag_t(ICRNL)
        line.c_lflag |= tcflag_t(ICANON) | tcflag_t(ECHO)
        tcsetattr(fd, TCSANOW, &line)
    }
    defer { if sane { var restore = saved; tcsetattr(fd, TCSANOW, &restore) } }
    var buffer = [CChar](repeating: 0, count: 4096)
    guard fgets(&buffer, Int32(buffer.count), stream) != nil else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
