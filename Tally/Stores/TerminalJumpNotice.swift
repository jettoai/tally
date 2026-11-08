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
    func jumpFailed() {
        Task { ghosttyMissing = !(await Task.detached { TerminalJump.ghosttyInstalled() }.value) }
    }

    /// The board is on screen again: drop the line if Ghostty has been installed since.
    func recheck() {
        guard ghosttyMissing, !preview else { return }
        Task { ghosttyMissing = !(await Task.detached { TerminalJump.ghosttyInstalled() }.value) }
    }
}
