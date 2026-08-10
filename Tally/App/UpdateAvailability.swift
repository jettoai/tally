import Foundation

/// Observable "an update is waiting" state, fed by `UpdaterController` and rendered by the panel
/// header. Separate tiny class because UpdaterController is an NSObject delegate (the @Observable
/// macro and NSObject don't mix), and its own file because that controller is at the size a file
/// gets split at.
///
/// A mirror, not a second copy of the truth: every field here is written from `UpdateState`, only
/// when the value has actually moved, in the one place that reduces an event.
@MainActor
@Observable
final class UpdateAvailability {
    static let shared = UpdateAvailability()
    var version: String?
    /// True once Sparkle has the update downloaded (auto-download on): a click now finishes
    /// in one restart instead of walking the download dialog.
    var isDownloaded = false
    /// Which step of an install is under way, or nil when none is. The chip renders it as a spinner
    /// and stops taking presses while it is set.
    var busy: UpdateBusy?
    /// Observable mirror of UpdaterController.isActive, so views rendered before start() (a
    /// Settings window restored at launch) correct themselves once the updater comes up.
    var updaterActive = false

    func clear() {
        version = nil
        isDownloaded = false
        busy = nil
    }
}
