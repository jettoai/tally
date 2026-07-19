import AppKit
import Sparkle

/// Owns the Sparkle updater. Dormant unless the build carries BOTH a feed URL and an EdDSA public
/// key (release builds only - Debug substitutes an empty SUFeedURL), so dev builds never poll a
/// feed and the Settings row hides itself.
///
/// Dockless (LSUIElement) apps need two extra dances:
/// Sparkle's update window opens behind other apps unless the activation policy is temporarily
/// promoted to `.regular`, and scheduled checks should use gentle reminders instead of stealing
/// focus.
@MainActor
final class UpdaterController: NSObject {
    static let shared = UpdaterController()

    private var controller: SPUStandardUpdaterController?

    /// False in dev builds / until the ship pipeline bakes the key - callers hide their UI.
    var isActive: Bool { controller != nil }

    func start() {
        let info = Bundle.main.infoDictionary
        guard let feed = info?["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info?["SUPublicEDKey"] as? String, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Sparkle's own persisted preference, surfaced as a Settings toggle.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Sparkle's second, separate consent: silently download + install when an update is found
    /// (the checkbox in the update dialog), surfaced as a Settings toggle so it isn't reachable
    /// only through a dialog that stops appearing once you enable it.
    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    /// User-initiated check from Settings: promote to a regular app so Sparkle's window fronts.
    func checkForUpdates() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

extension UpdaterController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState) {
        // Sparkle centres its window on the MAIN display; the user may be working on another.
        // Move it to the screen the pointer is on (the same rule the redeem alert follows) -
        // a beat after Sparkle has actually put it on screen.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            Self.centerSparkleWindowOnPointerScreen()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        // Update UI done - drop back to the menu-bar accessory policy.
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
    }

    /// Find Sparkle's update window (its classes are the only SU*/SPU* windows in the process)
    /// and centre it on the screen containing the pointer. No-op when nothing matches.
    @MainActor private static func centerSparkleWindowOnPointerScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main else { return }
        for window in NSApp.windows where window.isVisible {
            let className = String(describing: type(of: window))
            guard className.hasPrefix("SU") || className.hasPrefix("SPU") else { continue }
            let frame = window.frame
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                          y: visible.midY - frame.height / 2))
        }
    }
}
