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
        /// unrecognizable and pool into Other.
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
        /// away, so a container's spelling is also a prefix of what sits below it - and `tally` is
        /// a prefix of `tally-release`, which is a different project rather than a directory in it.
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

    static func current() -> TokenProjectMap {
        let home = FileManager.default.homeDirectoryForCurrentUser
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
        let roots = relatives.map { relative -> Root in
            let absolute = workspace.path + "/" + relative
            let resolved = resolvedPath(absolute)
            let paths = resolved == absolute ? [absolute] : [absolute, resolved]
            return Root(relative: relative, paths: paths, munged: paths.map(munged))
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
