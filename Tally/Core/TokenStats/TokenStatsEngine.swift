import Foundation

/// Scans the local Claude and Codex transcripts through the Rust core
/// (rust/crates/core/src/tokenstats/engine.rs), which keeps the per-file cache
/// (`~/.tally/token-stats.json`) so only what changed is ever read twice.
///
/// Queue-confined like `UsageHistory`: every scan runs on one serial utility queue, so the main
/// actor never waits on a scan and two scans can never interleave.
final class TokenStatsEngine: @unchecked Sendable {
    static let shared = TokenStatsEngine()

    /// A dev build keeps its own file: a cache whose version differs from the installed app's is
    /// discarded and rewritten by whichever app scans next, so sharing one would have the two
    /// rescanning the whole history in turn.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(BuildVariant.isDev ? ".tally/token-stats-dev.json" : ".tally/token-stats.json")

    private let queue = DispatchQueue(label: "tally.token-stats", qos: .utility)
    private let core = TokenStatsCore()
    /// The last good result, handed back if a scan fails rather than an empty tab.
    private var last: [TokenSample] = []

    /// Bring the cache up to date and hand back the merged totals. Called on every visit to the
    /// Tokens tab; a caller that arrives while a scan is running gets its result after that one.
    func scan(completion: @escaping @Sendable ([TokenSample]) -> Void) {
        queue.async { [self] in
            // The worktree notes this scan writes carry the instant it began (TokenProjectMap).
            let host = AppTokenStatsHost(observedAt: WorktreeOrigins.timestamp(),
                                         originsFile: WorktreeOrigins.fileURL())
            let homes = TokenStatsSources.homes()
            let input = FfiScanInput(home: FileManager.default.homeDirectoryForCurrentUser.path,
                                     claudeHomes: homes.claude, codexHomes: homes.codex,
                                     zone: TimeZone.current.identifier, cachePath: Self.fileURL.path)
            if let outcome = try? core.scan(input: input, host: host) {
                last = outcome.samples.map(TokenSample.init)
            }
            completion(last)
        }
    }
}
