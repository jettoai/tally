import Foundation

/// The config homes whose transcripts the token statistics read. The walk itself (resolved-path
/// deduplication, `projects/`, `sessions/` and `archived_sessions/`, hidden and symlinked entries)
/// is the Rust core's (rust/crates/core/src/tokenstats/sources.rs).
///
/// The homes come from the accounts Tally already discovers rather than from a fresh `~/.claude*`
/// glob: a second, looser rule would sweep in things like a `~/.claude.backup…` folder and
/// double-count a year of history. The default home is always included even when it holds no
/// login, because its transcripts are still this machine's history.
enum TokenStatsSources {
    static func homes() -> (claude: [String], codex: [String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = [home.appendingPathComponent(".claude", isDirectory: true).path]
            + ClaudeAccounts.discover().compactMap { $0.launchHome.map { URL(fileURLWithPath: $0).path } }
        let codex = [home.appendingPathComponent(".codex", isDirectory: true).path]
            + CodexAccounts.discover().compactMap { $0.launchHome.map { URL(fileURLWithPath: $0).path } }
        return (claude, codex)
    }
}
