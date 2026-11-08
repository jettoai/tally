import Foundation
import Observation

/// Why a click on a session card did nothing, when the reason is that Ghostty is not on this Mac
/// (B-4194). `TerminalJump.jump` returns whether it landed anywhere; a click that did not, on a Mac
/// without Ghostty, sets this, and the session board says so in one line. The board asks again
/// every time it appears (`recheck`), so installing Ghostty makes the line go away on its own.
@MainActor
@Observable
final class TerminalJumpNotice {
    static let shared = TerminalJumpNotice()

    private(set) var ghosttyMissing = false
    /// `-TallyGhosttyMissingPreview YES` (Dev build or demo data): shows the line whatever this Mac has.
    private let preview: Bool
    /// The one question LaunchServices answers. Replaceable so a test can make this Mac "not have
    /// Ghostty" and drive the real `jumpFailed` and `recheck` paths; the default is the real lookup.
    @ObservationIgnored var installedProbe: @Sendable () -> Bool = { TerminalJump.ghosttyInstalled() }

    private init() {
        #if DEBUG
        preview = (DemoUsage.isActive || BuildVariant.isDev)
            && UserDefaults.standard.bool(forKey: "TallyGhosttyMissingPreview")
        #else
        preview = false
        #endif
        ghosttyMissing = preview
    }

    /// A jump found nowhere to go. The lookup goes through LaunchServices, so it is off the main thread.
    /// Returns its task so a test can wait for the answer.
    @discardableResult
    func jumpFailed() -> Task<Void, Never> { refreshMissing() }

    /// The board is on screen again: drop the line if Ghostty has been installed since.
    @discardableResult
    func recheck() -> Task<Void, Never>? {
        guard ghosttyMissing, !preview else { return nil }
        return refreshMissing()
    }

    private func refreshMissing() -> Task<Void, Never> {
        let probe = installedProbe
        return Task { ghosttyMissing = !(await Task.detached { probe() }.value) }
    }
}
