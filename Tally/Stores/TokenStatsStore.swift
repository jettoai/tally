import Foundation
import Observation

/// Drives the Tokens tab: holds the merged samples, the selected range, and the scan state.
///
/// The scan is kicked off when the tab is opened and never on a timer. Nothing about local token
/// history changes while the user is looking at another tab, and a background sweep of several
/// gigabytes to keep a screen nobody is reading up to date would be the worst trade in the app.
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
    private(set) var isScanning = false
    /// True until the first scan of this app run has produced numbers - what separates "nothing
    /// found" from "not looked yet" for the empty state.
    private(set) var hasScanned = false

    private var samples: [TokenSample] = []

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
        isScanning = true
        TokenStatsEngine.shared.scan { scanned in
            Task { @MainActor [weak self] in
                guard let self else { return }
                samples = scanned
                isScanning = false
                hasScanned = true
                rebuild()
            }
        }
    }

    private func rebuild() {
        summary = TokenStatsSummary.make(samples: samples, range: range)
    }
}
