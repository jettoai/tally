import Foundation

/// Decides which project row a session's working directory belongs to.
///
/// Attribution is an allow-list, not "the last component of the cwd". A machine that has been
/// running agents for months accumulates working directories that are not projects: a workflow's
/// throwaway worktree, a subagent's own transcript folder, one dated slug per blog post, one `src`
/// per content directory. Ranked beside real work those turned the table into a directory listing,
/// so a directory earns its own row only when it traces back to a checkout the user would name by
/// itself; everything else pools into Other, where it still counts toward the range totals.
///
/// The allow-list is the real contents of `~/workspace`, read once per scan rather than hard-coded.
/// A folder there is a project when it is a checkout; when it is only a CONTAINER of checkouts (an
/// org folder holding two products) its children are the projects instead, because collapsing them
/// would merge two different products into one unreadable row.
///
/// A git worktree is a checkout too, but not a project of its own: `tally-release` is a parallel
/// line of work on `tally`, and ranking it beside `tally` splits one product's usage across two
/// rows that nobody wants to add up by hand. So a worktree's directories are folded into the
/// repository it was cut from, which is the row it belongs to. A worktree that has been torn down
/// is folded the same way, from the note teardown wrote before deleting it (`WorktreeOrigins`):
/// its transcripts outlive it, so its row has to as well.
///
/// Attribution is baked into the cached entries, so any change to which project owns a directory
/// has to bump `TokenStatsEngine.Cache.currentVersion`; otherwise unchanged files keep the keys the
/// old rule gave them and the table mixes both rules.
struct TokenProjectMap: Sendable {
    /// The folder that holds one directory per project.
    private static let workspaceFolder = "workspace"
    /// Config-home prefixes. Multi-account setups number them (`.claude2`, `.claude3`), and all of
    /// them are the same "working on the harness itself" row.
    private static let claudeFolder = ".claude"
    private static let codexFolder = ".codex"

    /// One allow-listed project.
    private struct Root: Sendable {
        /// e.g. `tally`, or `acme/web` when `acme` is a container rather than a checkout.
        let relative: String
        /// Every absolute path this project answers to: the one under the workspace folder, plus
        /// its resolved path when the folder (or the workspace folder itself) is a symlink onto
        /// another volume. A transcript records the working directory the process really had,
        /// which is the resolved one, so a project reached through a link would otherwise be
        /// unrecognizable and pool into Other. Each of the project's worktrees contributes its
        /// own pair, which is how a parallel line of work lands on the project's row.
        let paths: [String]
        /// The same paths in Claude Code's flattened transcript-folder spelling, so an agent's own
        /// cwd can be traced back to the project it was serving.
        let munged: [String]

        /// How specifically this project claims a working directory: the length of the longest of
        /// its paths that contains it, or `nil` when none does. A length rather than a yes/no
        /// because claims nest - two projects that are siblings under the workspace folder need
        /// not have sibling targets (`monorepo -> /Volumes/work` beside `app -> /Volumes/work/app`
        /// puts one project's real directory INSIDE the other's), so the deepest claim has to win.
        func claim(cwd: String) -> Int? {
            paths.filter { cwd == $0 || cwd.hasPrefix($0 + "/") }.map(\.count).max()
        }

        /// The same for an agent's own transcript folder, where the separators have been flattened
        /// away, so a container's spelling is also a prefix of what sits below it - and `specai` is
        /// a prefix of `specai-e2e-local`, which is a different project rather than a directory in
        /// it.
        func claim(transcriptFolder folder: String) -> Int? {
            munged.filter { folder == $0 || folder.hasPrefix($0 + "-") }.map(\.count).max()
        }
    }

    private let home: String
    /// The home path already split, because every cwd is tested against it.
    private let homeComponents: [String]
    private let workspace: String
    /// The allow-list, in no particular order: which project owns a directory is decided by whose
    /// claim on it is the most specific one (`bestRoot`), not by position.
    private let roots: [Root]

    // MARK: Building

    /// The home directory is a parameter so a fixture tree can be scanned (tests/tokenprojectmap);
    /// every caller in the app uses the default.
    static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> TokenProjectMap {
        let workspace = home.appendingPathComponent(workspaceFolder, isDirectory: true)

        var relatives: [String] = []
        for child in directories(in: workspace) {
            relatives.append(child)
            let childURL = workspace.appendingPathComponent(child, isDirectory: true)
            guard !isCheckout(childURL) else { continue }
            relatives += directories(in: childURL)
                .filter { isCheckout(childURL.appendingPathComponent($0, isDirectory: true)) }
                .map { child + "/" + $0 }
        }

        var candidates = relatives.map { relative -> (relative: String, paths: [String]) in
            let absolute = workspace.path + "/" + relative
            let resolved = resolvedPath(absolute)
            return (relative, resolved == absolute ? [absolute] : [absolute, resolved])
        }
        // Which candidate a path belongs to, in either spelling, so a repository can be looked up
        // by a path recorded elsewhere (the origins file below).
        var candidateOfPath: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            for path in candidate.paths { candidateOfPath[path] = index }
        }

        // Fold every worktree into the repository it was cut from, matched on the git directory
        // both of them belong to rather than on the shape of a path: each candidate is asked which
        // common git directory it uses and whether it is a linked worktree, and a linked one joins
        // the main checkout that answers with the same directory. One hop is the whole job, since
        // the target of a fold is by definition not a linked worktree.
        let gits = candidates.map { checkoutGit(at: $0.paths[0]) }
        var mainOfCommon: [String: Int] = [:]
        for (index, git) in gits.enumerated() {
            guard let git, !git.isLinkedWorktree, mainOfCommon[git.common] == nil else { continue }
            mainOfCommon[git.common] = index
        }
        var folded = Set<Int>()
        for (index, git) in gits.enumerated() {
            guard let git, git.isLinkedWorktree,
                  let target = mainOfCommon[git.common], target != index
            else { continue }
            candidates[target].paths += candidates[index].paths
            folded.insert(index)
        }

        // A worktree that has already been torn down has no `.git` file left to match on, so the
        // note teardown wrote before removing it is the only thing that still says whose parallel
        // line it was. Records naming a repository this machine no longer has are skipped, which
        // pools their directories exactly as before.
        for origin in WorktreeOrigins.load(from: WorktreeOrigins.fileURL(home: home)) {
            guard let target = candidateOfPath[origin.repository]
                    ?? candidateOfPath[resolvedPath(origin.repository)],
                  !folded.contains(target)
            else { continue }
            let known = Set(candidates[target].paths)
            candidates[target].paths += origin.paths.filter { !known.contains($0) }
        }

        let roots = candidates.indices.filter { !folded.contains($0) }.map { index -> Root in
            let candidate = candidates[index]
            return Root(relative: candidate.relative, paths: candidate.paths,
                        munged: candidate.paths.map(munged))
        }

        return TokenProjectMap(home: home.path, homeComponents: components(home.path),
                               workspace: workspace.path, roots: roots)
    }

    private static func directories(in url: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        // Asked through `fileExists` rather than `URL.isDirectoryKey`, which does NOT follow
        // symlinks and reports a linked folder as "not a directory". A project symlinked into the
        // workspace folder (how a folder living on another volume usually gets there) has to count
        // as the directory it points at, or it never reaches the allow-list at all.
        return contents.filter(isDirectory).map(\.lastPathComponent)
    }

    /// The path a process started here would report as its working directory.
    ///
    /// `realpath(3)` rather than `URL.resolvingSymlinksInPath()`: that one strips a leading
    /// `/private`, so a folder linked to `/private/tmp/x` comes back as `/tmp/x`, which is a
    /// spelling no transcript ever contains (`getcwd` reports the `/private` form).
    private static func resolvedPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// A git checkout: a repository (`.git` directory) or a worktree of one (`.git` file).
    private static func isCheckout(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Which repository a checkout belongs to, spelled as the git directory the two of them share.
    private struct CheckoutGit {
        /// The repository's common git directory, resolved: the identity two checkouts of one
        /// repository agree on, whatever their own paths look like.
        let common: String
        /// Whether this checkout is a linked worktree (`git worktree add`) rather than the main
        /// one. Only a linked checkout is ever folded into another row.
        let isLinkedWorktree: Bool
    }

    /// The git directory a checkout belongs to, or `nil` when the directory is not a checkout, or
    /// says nothing this understands. Parsed off the filesystem rather than asked of `git`, because
    /// this runs for every entry in the workspace folder on every scan and the app must not spawn a
    /// process per directory to draw a table. (A TEST may run git, and tests/tokenprojectmap does,
    /// to build its fixtures out of the layouts git really produces; the app at runtime may not.)
    ///
    /// Three layouts, which is the whole of it:
    ///
    ///   - `.git` is a DIRECTORY: an ordinary repository, and that directory is its own identity.
    ///   - `.git` is a FILE naming `<common>/worktrees/<id>`: a linked worktree, whose repository
    ///     is `<common>`. That trailing pair is git's own layout for per-worktree bookkeeping.
    ///   - `.git` is a FILE naming anything else: a checkout whose git directory simply lives
    ///     elsewhere, which is what a submodule (`<super>/.git/modules/<name>`) and a
    ///     `--separate-git-dir` repository both are. It is a main checkout, and the file already
    ///     names its identity.
    ///
    /// Matching two checkouts on that identity is deliberately not the same as reading a path for
    /// its `.git` component. The component rule answered "the superproject" for a submodule's
    /// worktree, since `<super>/.git/modules/sub/worktrees/wt` does contain one, and had nothing to
    /// say about a git directory not named `.git` at all. Asking both sides which directory they
    /// belong to has neither problem, and never needs to know where a checkout sits relative to its
    /// git directory - which is just as well, because git records that nowhere for a
    /// `--separate-git-dir` repository: it writes no `core.worktree` there (git 2.50.1, verified
    /// 2026-08-06 against a real one, which is why the fixtures are real repositories now).
    ///
    /// Fail-open: a file that cannot be read, or a repository whose main checkout is not in the
    /// workspace folder (a bare repository has none at all), leaves the directory a project of its
    /// own - a row too many is a far smaller harm than a row of somebody else's tokens.
    ///
    /// Deliberately not `GitRepoRoot.swift`'s resolution, which the CLI shares between the worktree
    /// overview and the launch profile: that one asks git, because its answer is a directory to
    /// print and to `cd` into and must be right for every layout git allows. This one only decides
    /// which existing row a directory joins, where the cost of not knowing is a separate row.
    private static func checkoutGit(at directory: String) -> CheckoutGit? {
        let dotGit = directory + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory)
        else { return nil }
        if isDirectory.boolValue {
            return CheckoutGit(common: resolvedPath(dotGit), isLinkedWorktree: false)
        }
        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }

        let marker = "gitdir:"
        guard let line = contents.split(separator: "\n").first(where: { $0.hasPrefix(marker) })
        else { return nil }
        let recorded = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard !recorded.isEmpty else { return nil }
        // git can be configured to write the link relative to the worktree. Resolving the joined
        // path is also what makes a checkout reached through a symlink agree with the same checkout
        // reached directly: `realpath` expands the link before it interprets the `..`, so both
        // spellings land on the one git directory.
        let gitDir = recorded.hasPrefix("/") ? recorded : directory + "/" + recorded

        let parts = components(gitDir)
        guard parts.count >= 3, parts[parts.count - 2] == "worktrees" else {
            return CheckoutGit(common: resolvedPath(gitDir), isLinkedWorktree: false)
        }
        return CheckoutGit(common: resolvedPath("/" + parts.dropLast(2).joined(separator: "/")),
                           isLinkedWorktree: true)
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// Claude Code names a project's transcript folder after the project's absolute path with
    /// everything that is not a letter, digit or dash replaced by a dash.
    private static func munged(_ path: String) -> String {
        String(path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" ? $0 : "-" })
    }

    // MARK: Attribution

    /// The project key for a working directory: an absolute path (the project's own root), or
    /// `TokenProject.otherKey` for the pooled row.
    func key(forCWD cwd: String?) -> String {
        // Scratch directories are throwaway wherever they sit, including inside a project.
        guard let cwd, !cwd.isEmpty, !cwd.contains("scratchpad") else { return TokenProject.otherKey }

        if let root = bestRoot({ $0.claim(cwd: cwd) }) { return key(of: root) }

        // Nothing on the allow-list, so placement is by where the directory sits under the home
        // directory. Everything outside the home pools: that is `/tmp`, `/private/tmp`, and the
        // one-off checkouts under a temp folder, none of which is a project of the user's.
        let parts = Self.components(cwd)
        guard parts.count > homeComponents.count,
              Array(parts.prefix(homeComponents.count)) == homeComponents
        else { return unplaced(cwd) }
        let rest = Array(parts.dropFirst(homeComponents.count))
        let head = rest[0]

        if head.hasPrefix(Self.claudeFolder) {
            // Agents run with their cwd inside the transcript tree of the project they serve
            // (`projects/<munged-cwd>/…`, with `subagents/` and `workflows/` below it), so their
            // tokens are credited back to that project instead of showing up as a row named after
            // a session id. Anything else under a config home is work on the harness itself.
            if rest.count > 2, rest[1] == "projects",
               let root = bestRoot({ $0.claim(transcriptFolder: rest[2]) }) {
                return key(of: root)
            }
            return home + "/" + Self.claudeFolder
        }
        if head.hasPrefix(Self.codexFolder) { return home + "/" + Self.codexFolder }
        return unplaced(cwd)
    }

    /// The project with the most specific claim on a directory, so a project nested inside another
    /// one's tree keeps its own row instead of being counted against the tree it sits in.
    private func bestRoot(_ claim: (Root) -> Int?) -> Root? {
        roots.compactMap { root in claim(root).map { (root, $0) } }.max { $0.1 < $1.1 }?.0
    }

    /// A project's row identity is always spelled through the workspace folder, whichever of its
    /// paths the transcript happened to record.
    private func key(of root: Root) -> String {
        workspace + "/" + root.relative
    }

    /// Where a directory goes when no rule places it: the pooled row - unless this machine has no
    /// workspace folder at all, in which case there is no allow-list to be outside of and pooling
    /// everything would leave a table with one row. Those machines keep the plain behaviour of a
    /// directory being its own project.
    private func unplaced(_ cwd: String) -> String {
        roots.isEmpty ? cwd : TokenProject.otherKey
    }
}
