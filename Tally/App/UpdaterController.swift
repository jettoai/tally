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
    /// Whatever result window Sparkle opens (update found, up to date, error) follows the
    /// pointer's screen: it isn't ours to create, so sweep for windows that appeared after the
    /// check started - swept twice because the feed fetch time varies.
    func checkForUpdates() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // The window this check was clicked in comes along - only the key window fronts on
        // activation, and Settings vanishing under other apps read as "the app lost my click".
        SettingsWindowController.shared.bringToFrontIfVisible()
        let before = Set(NSApp.windows.map(\.windowNumber))
        controller?.checkForUpdates(nil)
        for delay: UInt64 in [400_000_000, 1_500_000_000, 4_000_000_000] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: delay)
                Self.centerOnPointerScreen(NSApp.windows.filter {
                    $0.isVisible && !before.contains($0.windowNumber)
                })
            }
        }
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
        centerOnPointerScreen(NSApp.windows.filter {
            let className = String(describing: type(of: $0))
            return $0.isVisible && (className.hasPrefix("SU") || className.hasPrefix("SPU"))
        })
    }

    /// See NSWindow.centerOnPointerScreen (Core/WindowPlacement.swift) - the shared house rule.
    @MainActor private static func centerOnPointerScreen(_ windows: [NSWindow]) {
        windows.forEach { $0.centerOnPointerScreen() }
    }
}
