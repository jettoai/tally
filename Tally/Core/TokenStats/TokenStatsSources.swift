import Foundation

/// Finds the transcript files on this machine and reports each one's identity (path, size,
/// modification time), which is what the incremental cache compares against.
enum TokenStatsSources {
    struct File: Sendable {
        var path: String
        var provider: String
        var size: Int64
        var modified: Double
    }

    /// Every transcript file, both providers.
    ///
    /// The directories come from the accounts Tally already discovers rather than from a fresh
    /// `~/.claude*` glob: a second, looser rule would sweep in things like a `~/.claude.backup…`
    /// folder and double-count a year of history. The default home is always included even when it
    /// holds no login, because its transcripts are still this machine's history.
    ///
    /// Multi-account setups routinely symlink one shared `projects/` into every config home, so
    /// roots are deduplicated by their RESOLVED path. Without that, the same 5 GB is scanned and
    /// counted once per account.
    static func all() -> [File] {
        claude() + codex()
    }

    private static func claude() -> [File] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".claude", isDirectory: true)]
        dirs += ClaudeAccounts.discover().compactMap { $0.launchHome.map(URL.init(fileURLWithPath:)) }
        return files(in: roots(dirs.map { $0.appendingPathComponent("projects", isDirectory: true) }),
                     provider: ClaudeAccounts.providerID) { $0.pathExtension == "jsonl" }
    }

    /// Archiving a Codex conversation MOVES its rollout out of `sessions/` into
    /// `archived_sessions/`, so reading only the live folder would make finished work disappear
    /// from every range and the all-time total shrink over time. Both are read; the resolved-path
    /// deduplication below covers the setups that symlink one archive into every config home.
    private static func codex() -> [File] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".codex", isDirectory: true)]
        dirs += CodexAccounts.discover().compactMap { $0.launchHome.map(URL.init(fileURLWithPath:)) }
        let folders = ["sessions", "archived_sessions"]
        return files(in: roots(dirs.flatMap { dir in
                         folders.map { dir.appendingPathComponent($0, isDirectory: true) } }),
                     provider: CodexAccounts.providerID) {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
        }
    }

    /// Existing directories, symlinks resolved, each one only once.
    private static func roots(_ candidates: [URL]) -> [URL] {
        var seen = Set<String>()
        return candidates.compactMap { url in
            let resolved = url.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  isDirectory.boolValue, seen.insert(resolved.path).inserted else { return nil }
            return resolved
        }
    }

    /// Walks a root recursively. Claude nests subagent and workflow transcripts under the session
    /// that spawned them (`<project>/<session>/subagents/**`) and Codex files sit under
    /// `YYYY/MM/DD`, so a flat listing of either root would miss most of the corpus.
    private static func files(in roots: [URL], provider: String,
                              where include: (URL) -> Bool) -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var out: [File] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                guard include(url),
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let size = values.fileSize, let modified = values.contentModificationDate
                else { continue }
                out.append(File(path: url.path, provider: provider, size: Int64(size),
                                modified: modified.timeIntervalSince1970))
            }
        }
        return out
    }
}
