import Foundation

/// What the Rust token statistics core (rust/crates/ffi/src/uniffi_tokenstats.rs) asks of the app:
/// the zone offset at an instant, from Foundation's own time zone database so day boundaries are
/// exactly the ones the Swift engine cut, and the worktree ledger the app shares with the CLI.
///
/// `observedAt` is taken by the caller before the core looks at anything, and every note this
/// writes carries it (see `WorktreeOrigin.observedAt` for why the instant has to be the start).
final class AppTokenStatsHost: TokenStatsHost {
    private let observedAt: String
    private let originsFile: URL
    /// Read once per scan, so one scan never mixes two zones.
    private let zone = TimeZone.current

    init(observedAt: String, originsFile: URL) {
        self.observedAt = observedAt
        self.originsFile = originsFile
    }

    func secondsFromGmt(epochSeconds: Int64) -> Int32 {
        Int32(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epochSeconds))))
    }

    func loadWorktreeOrigins() -> [FfiOrigin] {
        WorktreeOrigins.load(from: originsFile).map {
            FfiOrigin(repository: $0.repository, paths: $0.paths, purged: $0.purged == true)
        }
    }

    func recordLiveWorktrees(folds: [FfiLiveFold]) {
        WorktreeOrigins.recordNew(folds.map {
            WorktreeOrigins.liveNote(worktree: $0.worktree, repository: $0.repository, observedAt: observedAt)
        }, in: originsFile)
    }
}

extension TokenTotals {
    init(_ ffi: FfiTotals) {
        self.init(input: ffi.input, cacheWrite: ffi.cacheWrite, cacheRead: ffi.cacheRead, output: ffi.output,
                  cacheWrite1h: ffi.cacheWrite1h)
    }

    var ffi: FfiTotals {
        FfiTotals(input: input, cacheWrite: cacheWrite, cacheRead: cacheRead, output: output, cacheWrite1h: cacheWrite1h)
    }
}

extension TokenSample {
    init(_ ffi: FfiSample) {
        self.init(day: Int(ffi.day), project: ffi.project, providerID: ffi.providerId, totals: TokenTotals(ffi.totals),
                  model: ffi.model, subagent: ffi.subagent, turns: ffi.turns)
    }

    var ffi: FfiSample {
        FfiSample(day: Int64(day), project: project, providerId: providerID, totals: totals.ffi,
                  model: model, subagent: subagent, turns: turns)
    }
}
