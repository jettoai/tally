import Foundation

// The read-only half of `tally worktree`: `tree` (the human overview - which repo is the main one,
// what parallel lines exist, and which of them you are standing in), `root` (that main repo's path
// on stdout for scripts), and `list` (the tab-separated machine report), plus the subcommand
// dispatch. Split out of WorktreeTeardown.swift, which keeps only the destructive half, so neither
// file grows past the size limit.
//
// Shared helpers come from Worktree.swift (`runGit`, `realpathString`, `parseWorktreePorcelain`,
// `buildMenuRows`), WorktreeTeardown.swift (`defaultListProcesses`, `worktreeProcessesToKill`),
// WorktreeMenu.swift (`displayColumns`, so the tree and the menu agree on how wide a CJK or emoji
// line is) and Snapshot.swift (`warn`). Nothing here emits ANSI: unlike the menu, this output is
// routinely piped or redirected to a file.

// MARK: - Main repo resolution

/// The main worktree of the ORDINARY layout, where the common git dir sits at `<checkout>/.git`:
/// strip that suffix, which is the rule git applies internally. nil when the common dir lives
/// somewhere else (a submodule keeps it at `<super>/.git/modules/<name>`, `--separate-git-dir` puts
/// it anywhere, a bare repo is the dir), because its parent is then not a checkout at all and the
/// answer has to be asked for rather than computed.
func colocatedMainRepoPath(gitCommonDir dir: String) -> String? {
    let suffix = "/.git"
    guard dir.hasSuffix(suffix) else { return nil }
    return String(dir.dropLast(suffix.count))
}

/// Whether `candidate` really is a working tree of the repo whose common git dir is `commonDir`.
/// Every guess below is put through this: a computed path that looks like a checkout but is not one
/// (or belongs to a different repo) is worse than admitting we do not know, because everything
/// downstream treats the answer as a directory to print, to cd into, and to run git in.
private func isWorkingTree(_ candidate: String, ofCommonDir commonDir: String) -> Bool {
    guard !candidate.isEmpty else { return false }
    let probe = runGit(["-C", candidate, "rev-parse", "--path-format=absolute", "--git-common-dir"])
    return probe.code == 0 && realpathString(probe.out) == realpathString(commonDir)
}

/// The main repo's working tree, fully resolved, or nil when git says this is not a repository.
///
/// Four ways to the answer, each verified before it is trusted:
///
///  1. The caller is standing IN the main worktree (its git dir is the common one, true for every
///     plain repo, submodule and separate-git-dir repo entered at its own checkout): git names it
///     outright with `--show-toplevel`. `--show-toplevel` alone is not enough, because from a
///     LINKED worktree it names that worktree rather than the main one.
///  2. The colocated layout, common dir at `<checkout>/.git`: strip the suffix.
///  3. `core.worktree`, which is how a submodule points back at its checkout from a linked worktree
///     of that submodule (relative to the common dir).
///  4. Nothing verified: the common dir, which is the answer `git worktree list` itself prints, and
///     a warning that it is a git dir rather than a checkout.
///
/// Case 4 is reachable and is not an oversight: a repo made with `git init --separate-git-dir`
/// records its working tree NOWHERE (measured 2026-07-27 on git 2.50.1: `core.worktree` unset, no
/// path in the git dir's config, and the `.git` file in the checkout points one way only, into the
/// git dir). Asked from a linked worktree of such a repo, git cannot answer either:
/// `git -C <common dir> rev-parse --show-toplevel` fails with "this operation must be run in a work
/// tree", and `--git-dir=<common dir>` resolves the toplevel from the caller's own cwd. So the
/// information genuinely does not exist, and inventing a path would be the worse failure.
func resolveMainRepo() -> String? {
    let common = runGit(["rev-parse", "--path-format=absolute", "--git-common-dir"])
    guard common.code == 0, !common.out.isEmpty else { return nil }
    if runGit(["rev-parse", "--path-format=absolute", "--absolute-git-dir"]).out == common.out {
        let top = runGit(["rev-parse", "--path-format=absolute", "--show-toplevel"]).out
        if !top.isEmpty { return realpathString(top) }   // empty in a bare repo
    }
    if let colocated = colocatedMainRepoPath(gitCommonDir: common.out),
       isWorkingTree(colocated, ofCommonDir: common.out) {
        return realpathString(colocated)
    }
    let recorded = runGit(["config", "--get", "core.worktree"]).out
    let absolute = recorded.hasPrefix("/") ? recorded : "\(common.out)/\(recorded)"
    if !recorded.isEmpty, isWorkingTree(absolute, ofCommonDir: common.out) {
        return realpathString(absolute)
    }
    warn("this repository records no main working tree; using its git dir \(common.out)")
    return realpathString(common.out)
}

/// The main repo path plus every worktree git has registered. nil when git says this is not a
/// repository; callers decide whether that is a warning (the read commands) or an exit (teardown).
func resolveWorktreeListing() -> (mainRepo: String, entries: [WorktreeEntry])? {
    guard let mainRepo = resolveMainRepo() else { return nil }
    let listing = runGit(["worktree", "list", "--porcelain"], cwd: mainRepo)
    return (mainRepo, parseWorktreePorcelain(listing.out))
}

/// The linked worktrees: every porcelain block after the FIRST, which git documents as always being
/// the main worktree. Dropped by POSITION rather than by comparing paths to the main repo, because
/// a repo whose git dir is not colocated with its checkout (submodule, `--separate-git-dir`) has
/// git reporting that first block AS the git dir: a path comparison never matches it, and the main
/// checkout would be drawn as one of its own worktrees.
func linkedWorktrees(_ entries: [WorktreeEntry]) -> [WorktreeEntry] {
    Array(entries.dropFirst())
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

/// One cell widened to `columns` terminal columns, measured with `displayColumns`
/// (WorktreeMenu.swift, shared with the menu clipper) so a CJK or emoji cell is padded to what a
/// terminal actually draws.
///
/// Padding only ever APPENDS spaces. `padding(toLength:)` did both jobs wrong at once: it counts
/// UTF-16 units, so a branch name with an emoji was measured as shorter than it is and then cut in
/// half, emitting a lone surrogate; and a CJK name measured by grapheme count came out a column
/// short per character. Content is never truncated here, so the worst a mis-measured exotic scalar
/// can now do is misalign a column by one.
private func padToColumns(_ cell: String, _ columns: Int) -> String {
    cell + String(repeating: " ", count: max(0, columns - displayColumns(cell)))
}

/// Lay rows of cells out as columns: every cell padded to the width of the widest in its column,
/// joined by two spaces, with the trailing padding trimmed. Columns that are empty in every row are
/// dropped entirely, so a tree with nothing dirty and no live agents shows no gap where those
/// markers would have been.
func alignedColumns(_ rows: [[String]]) -> [String] {
    let columnCount = rows.map(\.count).max() ?? 0
    var widths = [Int](repeating: 0, count: columnCount)
    for row in rows {
        for (index, cell) in row.enumerated() {
            widths[index] = max(widths[index], displayColumns(cell))
        }
    }
    let kept = (0 ..< columnCount).filter { widths[$0] > 0 }
    return rows.map { row in
        var line = kept.map { index in
            padToColumns(index < row.count ? row[index] : "", widths[index])
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
    guard let (mainRepo, entries) = resolveWorktreeListing() else {
        warn("not inside a git repository")
        return 1
    }
    let mainBranch = entries.first?.branch
    // Every linked worktree, INCLUDING detached ones (`list` and `remove` keep filtering those
    // out: they manage branch-backed lines and a detached head is not one). The tree answers
    // "what exists and where am I", and a caller standing in a detached worktree is exactly the one
    // most in need of the answer: filtering it out once printed an overview with no "you are here"
    // mark anywhere on it.
    let others = linkedWorktrees(entries)
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
/// session can find its way home without hand-rolling the `rev-parse` incantation (and pipe the
/// answer). Not a git repo warns and exits 1, like `list`.
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
    guard let (mainRepo, entries) = resolveWorktreeListing() else {
        warn("not inside a git repository")
        return 1
    }
    let others = linkedWorktrees(entries).filter { $0.branch != nil }
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
