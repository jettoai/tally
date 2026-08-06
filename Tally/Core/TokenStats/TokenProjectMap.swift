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
/// repository it was cut from, which is the row it belongs to.
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
        // Which candidate a path belongs to, in either spelling, so a worktree's main repository
        // can be looked up by the path its `.git` file points at.
        var candidateOfPath: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            for path in candidate.paths { candidateOfPath[path] = index }
        }
        // Fold every worktree into the repository it was cut from. One hop is the whole job: what
        // a worktree's `.git` file leads to is always the repository's MAIN checkout, never
        // another linked worktree, so the target of a fold is never itself folded and folds cannot
        // chain.
        var folded = Set<Int>()
        for (index, candidate) in candidates.enumerated() {
            guard let main = mainRepository(ofWorktreeAt: candidate.paths[0]),
                  let target = candidateOfPath[main] ?? candidateOfPath[resolvedPath(main)],
                  target != index
            else { continue }
            candidates[target].paths += candidate.paths
            folded.insert(index)
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

    /// The repository a worktree belongs to, or `nil` when the directory is not a worktree.
    ///
    /// Read out of the `.git` FILE a worktree has in place of a directory, which holds one
    /// `gitdir:` line naming the bookkeeping git keeps for THIS worktree inside the repository's
    /// common git directory: `<common>/worktrees/<id>`. Parsed rather than asked of `git`, because
    /// this runs for every entry in the workspace folder on every scan and the app must not spawn a
    /// process per directory to draw a table.
    ///
    /// That trailing `worktrees/<id>` is the whole identification, and it is what a `.git` file
    /// naming anything else is measured against: a submodule's checkout points straight at
    /// `<super>/.git/modules/<name>` and is not a worktree of anybody, so it keeps its own row.
    ///
    /// From the common directory the checkout is found two ways, config first:
    ///
    ///   - `core.worktree` in `<common>/config`, which git writes exactly when the git directory is
    ///     not the checkout's own `.git`: a submodule's `<super>/.git/modules/<name>`, or a
    ///     repository created with `--separate-git-dir`. git-config documents the value as absolute
    ///     or relative to the git directory, so both spellings are resolved. Asked FIRST because a
    ///     common directory can be named `.git` and still not sit in its checkout
    ///     (`--separate-git-dir=.../x/.git`), where the folder holding it is the wrong answer; an
    ///     ordinary colocated repository has no such key, so this costs it nothing but the read.
    ///   - otherwise the folder holding a common directory literally named `.git`, which is the
    ///     ordinary layout.
    ///
    /// Fail-open: a file that cannot be read, a shape this does not recognize, or a common
    /// directory with no checkout at all (a bare repository) leaves the directory a project of its
    /// own - a row too many is a far smaller harm than a row of somebody else's tokens.
    ///
    /// Deliberately not `GitRepoRoot.swift`'s resolution, which the CLI shares between the worktree
    /// overview and the launch profile: that one asks git, because its answer is a directory to
    /// print and to `cd` into and must be right for every layout git allows. This one only decides
    /// which existing row a directory joins, where the cost of not knowing is a separate row.
    private static func mainRepository(ofWorktreeAt directory: String) -> String? {
        guard let gitDir = worktreeGitDir(at: directory) else { return nil }

        // The answer can still be an unresolved spelling (a relative link leaves `..` in it, and so
        // can a relative `core.worktree`); the caller looks it up both as written and resolved.
        let parts = components(gitDir)
        guard parts.count >= 3, parts[parts.count - 2] == "worktrees" else { return nil }
        let commonParts = parts.dropLast(2)
        let common = "/" + commonParts.joined(separator: "/")

        if let checkout = configuredWorktree(inGitDir: common) { return checkout }
        // The ordinary layout: the folder holding a common directory literally named `.git`.
        guard commonParts.count >= 2, commonParts.last == ".git" else { return nil }
        return "/" + commonParts.dropLast().joined(separator: "/")
    }

    /// The path a directory's `.git` FILE points at, absolute (git can be configured to write the
    /// link relative to the worktree). `nil` when there is no such file, when it is a directory
    /// instead, or when nothing in it is a `gitdir:` line.
    private static func worktreeGitDir(at directory: String) -> String? {
        let dotGit = directory + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let contents = try? String(contentsOfFile: dotGit, encoding: .utf8)
        else { return nil }

        let marker = "gitdir:"
        guard let line = contents.split(separator: "\n").first(where: { $0.hasPrefix(marker) })
        else { return nil }
        let gitDir = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard !gitDir.isEmpty else { return nil }
        return gitDir.hasPrefix("/") ? gitDir : directory + "/" + gitDir
    }

    /// `core.worktree` as written in a git directory's own `config`, resolved against that
    /// directory when the value is relative. `nil` when the file cannot be read or names no
    /// worktree, which is the ordinary case: a repository whose checkout holds its `.git` never
    /// carries the key, and neither does a bare one.
    private static func configuredWorktree(inGitDir gitDir: String) -> String? {
        guard let config = try? String(contentsOfFile: gitDir + "/config", encoding: .utf8)
        else { return nil }
        var inCore = false
        for rawLine in config.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                // Section names are case insensitive, and a subsection (`[core "x"]`) is a
                // different section that holds no key this reads.
                inCore = line.dropFirst().lowercased().hasPrefix("core]")
                continue
            }
            guard inCore, let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "worktree"
            else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { return nil }
            return value.hasPrefix("/") ? value : gitDir + "/" + value
        }
        return nil
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
