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
struct TokenProjectMap: Sendable {
    /// The folder that holds one directory per project.
    private static let workspaceFolder = "workspace"
    /// Config-home prefixes. Multi-account setups number them (`.claude2`, `.claude3`), and all of
    /// them are the same "working on the harness itself" row.
    private static let claudeFolder = ".claude"
    private static let codexFolder = ".codex"

    /// One allow-listed project, by its path relative to the workspace folder.
    private struct Root: Sendable {
        /// e.g. `tally`, or `acme/web` when `acme` is a container rather than a checkout.
        let relative: String
        /// The same path in Claude Code's flattened transcript-folder spelling, so an agent's own
        /// cwd can be traced back to the project it was serving.
        let munged: String
    }

    private let home: String
    /// The home path already split, because every cwd is tested against it.
    private let homeComponents: [String]
    private let workspace: String
    /// Deepest first, then longest first: the match walks this in order, so the most specific root
    /// wins over its container, and `tally-release` is never mistaken for `tally` once the
    /// separators have been flattened away.
    private let roots: [Root]
    /// What every project's transcript folder starts with on this machine.
    private let mungedWorkspacePrefix: String

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
        let ordered = relatives
            .sorted { (depth($0), $0.count) > (depth($1), $1.count) }
            .map { Root(relative: $0, munged: munged($0)) }

        return TokenProjectMap(home: home.path, homeComponents: components(home.path),
                               workspace: workspace.path, roots: ordered,
                               mungedWorkspacePrefix: munged(workspace.path) + "-")
    }

    private static func directories(in url: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        // Resource values follow symlinks, so a project symlinked into the workspace folder (the
        // usual way a client folder on another volume gets there) still reads as a directory.
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
    }

    /// A git checkout: a repository (`.git` directory) or a worktree of one (`.git` file).
    private static func isCheckout(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    private static func depth(_ path: String) -> Int {
        path.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
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

        // Everything outside the home directory pools: that is `/tmp`, `/private/tmp`, and the
        // one-off checkouts under a temp folder, none of which is a project of the user's.
        let parts = Self.components(cwd)
        guard parts.count > homeComponents.count,
              Array(parts.prefix(homeComponents.count)) == homeComponents
        else { return unplaced(cwd) }
        let rest = Array(parts.dropFirst(homeComponents.count))
        let head = rest[0]

        if head == Self.workspaceFolder {
            let tail = rest.dropFirst().joined(separator: "/")
            guard let root = roots.first(where: { tail == $0.relative || tail.hasPrefix($0.relative + "/") })
            else { return unplaced(cwd) }
            return workspace + "/" + root.relative
        }
        if head.hasPrefix(Self.claudeFolder) {
            // Agents run with their cwd inside the transcript tree of the project they serve
            // (`projects/<munged-cwd>/…`, with `subagents/` and `workflows/` below it), so their
            // tokens are credited back to that project instead of showing up as a row named after
            // a session id. Anything else under a config home is work on the harness itself.
            if rest.count > 2, rest[1] == "projects", let root = root(munged: rest[2]) {
                return workspace + "/" + root
            }
            return home + "/" + Self.claudeFolder
        }
        if head.hasPrefix(Self.codexFolder) { return home + "/" + Self.codexFolder }
        return unplaced(cwd)
    }

    private func root(munged: String) -> String? {
        guard munged.hasPrefix(mungedWorkspacePrefix) else { return nil }
        let tail = munged.dropFirst(mungedWorkspacePrefix.count)
        return roots.first { tail == $0.munged || tail.hasPrefix($0.munged + "-") }?.relative
    }

    /// Where a directory goes when no rule places it: the pooled row - unless this machine has no
    /// workspace folder at all, in which case there is no allow-list to be outside of and pooling
    /// everything would leave a table with one row. Those machines keep the plain behaviour of a
    /// directory being its own project.
    private func unplaced(_ cwd: String) -> String {
        roots.isEmpty ? cwd : TokenProject.otherKey
    }
}
