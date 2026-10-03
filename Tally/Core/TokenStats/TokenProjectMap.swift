import Foundation

/// Decides which project row a session's working directory belongs to: an allow-list read from
/// `~/workspace`, with git worktrees folded into the repository they were cut from (live ones by
/// their `.git` file, torn-down ones by the note `WorktreeOrigins` keeps), and everything else
/// pooled into Other. The rules live in the Rust core, whose header explains them
/// (rust/crates/core/src/tokenstats/project_map.rs); this wrapper is what tests/tokenprojectmap
/// and the reconciliation drivers call.
struct TokenProjectMap: Sendable {
    let core: TokenProjectMapCore

    /// The home directory is a parameter so a fixture tree can be scanned (tests/tokenprojectmap);
    /// every caller in the app uses the default.
    static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> TokenProjectMap {
        // When this scan looked, taken before it looks at anything and carried by every note it
        // writes at the end, so a teardown that stamped a removal in between knows something newer.
        let observedAt = WorktreeOrigins.timestamp()
        let host = AppTokenStatsHost(observedAt: observedAt, originsFile: WorktreeOrigins.fileURL(home: home))
        return TokenProjectMap(core: TokenProjectMapCore.build(home: home.path, host: host))
    }

    /// The project key for a working directory: an absolute path (the project's own root), or
    /// `TokenProject.otherKey` for the pooled row.
    func key(forCWD cwd: String?) -> String {
        core.keyForCwd(cwd: cwd)
    }
}
