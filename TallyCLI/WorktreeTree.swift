import Foundation

// The read-only half of `tally worktree`: `tree` (the human overview - which repo is the main one,
// what parallel lines exist, and which of them you are standing in), `root` (that main repo's path
// on stdout for scripts), and `list` (the tab-separated machine report), plus the subcommand
// dispatch. Split out of WorktreeTeardown.swift, which keeps only the destructive half, so neither
// file grows past the size limit.
//
// Shared helpers come from Worktree.swift (`runGit`, `realpathString`, `parseWorktreePorcelain`,
// `isMainCheckout`, `buildMenuRows`), WorktreeTeardown.swift (`defaultListProcesses`,
// `worktreeProcessesToKill`) and Snapshot.swift (`warn`). Nothing here emits ANSI: unlike the menu,
// this output is routinely piped or redirected to a file.

// MARK: - Main repo resolution

/// The main repo root implied by `git rev-parse --path-format=absolute --git-common-dir`: the
/// parent of the COMMON git dir, so a caller inside a worktree resolves back to the repo that owns
/// it (`--show-toplevel` would answer the worktree instead). Pure, so the derivation is asserted
/// without a repo.
func mainRepoPath(fromGitCommonDir dir: String) -> String {
    (dir as NSString).deletingLastPathComponent
}

/// The main repo root as a fully resolved path, or nil when git says this is not a repository.
/// Callers decide whether that is a warning (the read commands) or an exit (teardown).
func resolveMainRepo() -> String? {
    let common = runGit(["rev-parse", "--path-format=absolute", "--git-common-dir"])
    guard common.code == 0, !common.out.isEmpty else { return nil }
    return realpathString(mainRepoPath(fromGitCommonDir: common.out))
}

// MARK: - Where am I (pure)

/// Which entry of `paths` the caller is standing in: the LONGEST path that either is `cwd` or
/// contains it, or nil when the caller is somewhere else entirely. The containment test appends a
/// "/" so a sibling that merely shares a prefix (cwd `/a/repo-featx` against `/a/repo-feat`) is
/// never a false positive, and taking the longest match keeps a worktree that happens to live
/// inside the main repo attributed to the worktree rather than to its parent.
func worktreeTreeCurrentIndex(cwd: String, paths: [String]) -> Int? {
    var best: Int?
    for (index, path) in paths.enumerated() where !path.isEmpty {
        guard cwd == path || cwd.hasPrefix(path + "/") else { continue }
        if let current = best, paths[current].count >= path.count { continue }
        best = index
    }
    return best
}

// MARK: - Rendering (pure)

/// A path with the user's home collapsed to "~". The overview is the human-facing command and an
/// 80-column terminal is the target; the untouched absolute path stays one `tally worktree root`
/// (or `git worktree list`) away.
func abbreviateHomePath(_ path: String, home: String) -> String {
    guard !home.isEmpty else { return path }
    if path == home { return "~" }
    guard path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
}

/// Lay rows of cells out as columns: every cell padded to the width of the widest in its column,
/// joined by two spaces, with the trailing padding trimmed. Columns that are empty in every row are
/// dropped entirely, so a tree with nothing dirty and no live agents shows no gap where those
/// markers would have been.
func alignedColumns(_ rows: [[String]]) -> [String] {
    let columnCount = rows.map(\.count).max() ?? 0
    var widths = [Int](repeating: 0, count: columnCount)
    for row in rows {
        for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) }
    }
    let kept = (0 ..< columnCount).filter { widths[$0] > 0 }
    return rows.map { row in
        var line = kept.map { index -> String in
            let cell = index < row.count ? row[index] : ""
            return cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }
}

/// One worktree as the overview shows it: what to call it (its branch, or "[detached]"), how stale
/// it is, whether it is dirty, the live agent count from the same scan the teardown would kill, and
/// where it sits on disk.
struct WorktreeTreeRow {
    let branch: String
    let age: String
    let dirty: Bool
    let liveAgents: Int
    let path: String
}

/// The worktrees the tree draws: everything git has registered except the main checkout, INCLUDING
/// detached ones. `list` and `remove` keep filtering those out (they manage branch-backed lines and
/// a detached head is not one), but the tree answers "what exists and where am I", and a caller
/// standing in a detached worktree is exactly the one most in need of the answer: filtering it out
/// once printed an overview with no "you are here" mark anywhere on it.
func worktreeTreeEntries(_ entries: [WorktreeEntry], mainRepo: String) -> [WorktreeEntry] {
    entries.filter { !isMainCheckout($0, mainRepo: mainRepo) }
}

/// Resolve each entry's git facts for the tree. Deliberately not `buildMenuRows`: that one force
/// unwraps the branch because the menus only ever offer branch-backed worktrees, and reshaping it
/// would change what the launch menu shows. This reads the same age and dirty flag, skips the
/// commit subject the tree has no column for, and labels a detached checkout "[detached]" in the
/// same bracketed style the main repo line uses for its branch.
func worktreeTreeRows(_ entries: [WorktreeEntry], processes: [ProcInfo]) -> [WorktreeTreeRow] {
    entries.map { entry in
        let path = realpathString(entry.path)
        return WorktreeTreeRow(
            branch: entry.branch ?? "[detached]",
            age: runGit(["-C", entry.path, "log", "-1", "--format=%cr"]).out,
            dirty: !runGit(["-C", entry.path, "status", "--porcelain"]).out.isEmpty,
            liveAgents: worktreeProcessesToKill(processes, worktreePath: path).count,
            path: path)
    }
}

/// The whole overview: the main checkout first (its path and the branch it has checked out), then
/// one indented line per worktree carrying branch, age, a "*" when dirty, the live agent count and
/// the path. `currentIndex` indexes that same sequence (0 is the main repo, 1... are `rows`) and
/// earns a "*" at the start of the line plus a trailing "(you are here)"; nil marks nothing, which
/// is what a caller outside every checkout sees. ASCII only, and the marker is doubled (line start
/// AND trailing words) so it survives both a narrow terminal that wraps the line and a glance that
/// only scans the left edge.
func worktreeTreeLines(mainRepo: String, mainBranch: String?, rows: [WorktreeTreeRow],
                       currentIndex: Int?, home: String) -> [String] {
    let hereText = "(you are here)"
    func marker(_ index: Int) -> String { index == currentIndex ? "* " : "  " }
    func here(_ index: Int) -> String { index == currentIndex ? hereText : "" }

    // The main line is spelled out rather than aligned: it carries no connector and none of the
    // per-worktree columns.
    let mainSuffix = currentIndex == 0 ? "  " + hereText : ""
    let mainLine = marker(0) + abbreviateHomePath(mainRepo, home: home)
        + "  [" + (mainBranch ?? "detached") + "]" + mainSuffix

    let cells: [[String]] = rows.enumerated().map { index, row in
        // The connector carries no trailing space: the column join supplies the gap.
        let connector = index == rows.count - 1 ? "`--" : "|--"
        let agents = row.liveAgents > 0
            ? "\(row.liveAgents) agent\(row.liveAgents == 1 ? "" : "s")" : ""
        return [marker(index + 1) + connector,
                row.branch,
                row.age.isEmpty ? "no commits" : row.age,
                row.dirty ? "*" : "",
                agents,
                abbreviateHomePath(row.path, home: home),
                here(index + 1)]
    }
    return [mainLine] + alignedColumns(cells)
}

// MARK: - Tree and root

/// `tally worktree tree` (and bare `tally worktree`): print the main repo and its worktrees as one
/// indented overview on stdout, marking the one the caller stands in. Not a git repo warns and
/// exits 1; a repo with no worktrees still prints its own line, since naming the main repo is half
/// of what the command is for.
func runWorktreeTree() -> Int32 {
    guard let mainRepo = resolveMainRepo() else {
        warn("not inside a git repository")
        return 1
    }
    let entries = parseWorktreePorcelain(runGit(["worktree", "list", "--porcelain"], cwd: mainRepo).out)
    let mainBranch = entries.first { isMainCheckout($0, mainRepo: mainRepo) }?.branch
    let others = worktreeTreeEntries(entries, mainRepo: mainRepo)
    // One process scan for the whole overview (same reasoning as runWorktreeList), skipped outright
    // when there is no worktree to attribute a process to.
    let processes = others.isEmpty ? [] : defaultListProcesses(worktreePath: mainRepo)
    let rows = worktreeTreeRows(others, processes: processes)
    let paths = rows.map(\.path)
    let cwd = realpathString(FileManager.default.currentDirectoryPath)
    let home = realpathString(FileManager.default.homeDirectoryForCurrentUser.path)
    let currentIndex = worktreeTreeCurrentIndex(cwd: cwd, paths: [mainRepo] + paths)
    for line in worktreeTreeLines(mainRepo: mainRepo, mainBranch: mainBranch, rows: rows,
                                  currentIndex: currentIndex, home: home) {
        print(line)
    }
    return 0
}

/// `tally worktree root`: print the main repo's absolute path, one line on stdout, so a worktree
/// session can find its way home without the `rev-parse --path-format=absolute --git-common-dir`
/// incantation (and pipe the answer). Not a git repo warns and exits 1, like `list`.
func runWorktreeRoot() -> Int32 {
    guard let mainRepo = resolveMainRepo() else {
        warn("not inside a git repository")
        return 1
    }
    print(mainRepo)
    return 0
}

// MARK: - List

/// One report row, tab-separated so it stays greppable and pipeable. Columns, in order: branch, age
/// ("no commits" when the branch has none), a dirty marker ("*" when the working tree is dirty, ""
/// when clean), the live agent count ("N agent"/"N agents", or "-" when none are running in the
/// worktree), and the last commit subject truncated to fit. No ANSI and no layout: this is the
/// machine-readable report, an established stdout contract that must not drift (`tree` is the one
/// that may be reshaped for human eyes).
func formatWorktreeListLine(branch: String, age: String, dirty: Bool,
                            liveAgents: Int, subject: String) -> String {
    let ageText = age.isEmpty ? "no commits" : age
    let dirtyText = dirty ? "*" : ""
    let agentsText = liveAgents > 0 ? "\(liveAgents) agent\(liveAgents == 1 ? "" : "s")" : "-"
    return "\(branch)\t\(ageText)\t\(dirtyText)\t\(agentsText)\t\(truncateSubject(subject))"
}

/// Build the report lines, one per worktree. Git facts come from `buildMenuRows` (the same age/dirty/
/// subject the menu shows); the process list is passed in (a single scan, reused across worktrees)
/// so tests can assert line count and content without a real scan or stdout capture.
func worktreeListLines(_ others: [WorktreeEntry], processes: [ProcInfo]) -> [String] {
    zip(others, buildMenuRows(others)).map { entry, row in
        let realPath = realpathString(entry.path)
        let liveAgents = worktreeProcessesToKill(processes, worktreePath: realPath).count
        return formatWorktreeListLine(branch: row.branch, age: row.age, dirty: row.dirty,
                                      liveAgents: liveAgents, subject: row.subject)
    }
}

/// `tally worktree list`: print the branch-backed non-main worktrees to stdout, one greppable line
/// each. Not a git repo warns and exits 1; an empty list notes on stderr and exits 0 (stdout stays
/// clean for pipes).
func runWorktreeList() -> Int32 {
    guard let mainRepo = resolveMainRepo() else {
        warn("not inside a git repository")
        return 1
    }
    let entries = parseWorktreePorcelain(runGit(["worktree", "list", "--porcelain"], cwd: mainRepo).out)
    let others = entries.filter { $0.branch != nil && !isMainCheckout($0, mainRepo: mainRepo) }
    if others.isEmpty {
        warn("no worktrees")
        return 0
    }
    // One process scan for the whole report: defaultListProcesses returns every candidate process
    // (its worktreePath argument is not a filter), and shouldKill narrows per worktree below.
    let processes = defaultListProcesses(worktreePath: mainRepo)
    for line in worktreeListLines(others, processes: processes) {
        print(line)
    }
    return 0
}

// MARK: - CLI entry

/// `tally worktree <subcommand>`: dispatch. Bare (`tally worktree`) is the human overview, since a
/// bare command is the one someone types by hand; `list` stays the machine report. Unknown
/// subcommands print usage and exit 2.
func runWorktree(args: [String]) -> Never {
    switch args.first {
    case "remove":
        exit(runWorktreeRemove(args: Array(args.dropFirst())))
    case "tree", nil:
        exit(runWorktreeTree())
    case "root":
        exit(runWorktreeRoot())
    case "list":
        exit(runWorktreeList())
    default:
        warn("""
        usage:
          tally worktree tree       the main repo and its worktrees as one indented overview,
                                    marking where you are (bare `tally worktree` is the same)
          tally worktree root       print the main repo's absolute path, one line for scripts
          tally worktree list       one tab-separated line per worktree, for grep and pipes
                                    (branch, age, dirty, live agents, last subject)
          tally worktree remove [name] [--force] [--keep-transcripts]
                                    remove a merged worktree: kill its agents, delete the worktree,
                                    its branch, and its transcript dir (bare: pick from a menu)
        """)
        exit(2)
    }
}
