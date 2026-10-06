import Foundation
import Observation

/// Drives the Cost tab's two pages: holds the merged samples, the selected range, and the scan state.
///
/// The scan runs when the tab is opened, and in the background on the quota poll's cycle at most
/// every `TokenScanCadence.maxAge`, so `~/.tally/project-cost.json` (the only thing a background
/// scan is for) stays current with no surface open. Unchanged files are not reopened, so a scan
/// with nothing new costs a directory walk.
@MainActor
@Observable
final class TokenStatsStore {
    static let shared = TokenStatsStore()

    /// The window the tab is showing. A week by default: today alone is too thin to rank projects
    /// by, and the full history flattens what changed recently.
    var range: TokenStatsRange = .sevenDays {
        didSet { if range != oldValue { rebuild() } }
    }

    private(set) var summary = TokenStatsSummary()
    /// The Cost page's input for the selected range.
    private(set) var cost = CostSummary()
    private(set) var isScanning = false
    /// True until the first scan of this app run has produced numbers - what separates "nothing
    /// found" from "not looked yet" for the empty state.
    private(set) var hasScanned = false

    private var samples: [TokenSample] = []
    /// When the last scan began, for the background cadence (`refreshIfStale`). Any visit's scan
    /// counts, so opening the tab pushes the next background one back.
    private var lastScanStart: Date?

    private init() {}

    /// Incrementally rescan the transcripts. Safe to call on every tab visit: unchanged files are
    /// not reopened, so a repeat visit costs a directory walk.
    func refresh() {
        guard !isScanning else { return }
        // Demo mode must never read the machine's real transcripts: the fixtures exist so a
        // marketing screenshot shows a plausible fleet, not this laptop's projects.
        guard !DemoUsage.isActive else {
            samples = DemoUsage.tokenSamples()
            hasScanned = true
            rebuild()
            return
        }
        lastScanStart = Date()
        isScanning = true
        TokenStatsEngine.shared.scan { scanned in
            Task { @MainActor [weak self] in
                guard let self else { return }
                samples = scanned
                CostSnapshotWriter.publish(samples: scanned)
                isScanning = false
                hasScanned = true
                rebuild()
            }
        }
    }

    /// The background half: called on every quota poll (`UsageStore.refresh`), scans only when the
    /// last scan began at least `TokenScanCadence.maxAge` ago. A scan already running is left alone
    /// by `refresh`'s own guard.
    func refreshIfStale(now: Date = Date()) {
        guard TokenScanCadence.isDue(lastStart: lastScanStart, now: now) else { return }
        refresh()
    }

    /// One project's tokens per local day, every provider merged, over the whole history that is
    /// loaded. The row's activity heatmap is the only reader, and it asks once per expansion rather
    /// than on every frame: the samples are already the finest grain the app keeps, so this is a
    /// filter over a few thousand values, but it is a linear one and does not belong in a redraw.
    ///
    /// Deliberately not narrowed to the heatmap's window here. The caller owns which days it draws,
    /// and a store method that silently dropped everything older would be a second, invisible
    /// definition of "past year" sitting a layer away from the one on screen.
    func dailyTotals(forProject key: String) -> [Int: Int64] {
        let totals = tokenDailyTotals(samples: samples.map(\.ffi), project: key)
        return Dictionary(uniqueKeysWithValues: totals.map { (Int($0.key), $0.value) })
    }

    private func rebuild() {
        summary = TokenStatsSummary.make(samples: samples, range: range)
        cost = CostSummary.make(samples: samples, range: range)
    }
}
