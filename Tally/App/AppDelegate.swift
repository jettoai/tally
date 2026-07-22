import AppKit

/// Set at the first moment of app termination, before AppKit tears the windows down, so
/// quit-time willClose notifications can be told apart from the user actually closing a window.
@MainActor
enum AppTermination {
    private(set) static var inProgress = false
    static func begin() { inProgress = true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar accessory app: install the status item, then start the refresh loop.
        statusItemController.install()
        // Updater before the window restores: a restored Settings window renders update rows,
        // and they must see a live updater (plus the observable mirror, for any later render).
        UpdaterController.shared.start()   // dormant unless the build carries a feed URL + ED key
        // Whatever was on screen at the last quit comes back: an update relaunch is just
        // quit + launch, and losing the window you were reading mid-update is disorienting.
        // (The pinned panel restores itself inside install(); the transient popover is always
        // closed by the time an update runs, so there is nothing of it to restore.)
        // Settings second so it lands on top when both were open: the update button lives
        // there, making it the window the user most likely had focused.
        MainWindowController.shared.restoreAtLaunchIfNeeded()
        SettingsWindowController.shared.restoreAtLaunchIfNeeded()
        // Design-preview hook (demo/dev only): -TallyUpdateChip 0.15.0 renders the header's
        // update chip without a live feed (-TallyUpdateChipReady YES for the downloaded state),
        // so the nudge can be reviewed and screenshotted.
        if DemoUsage.isActive || BuildVariant.isDev,
           let fake = UserDefaults.standard.string(forKey: "TallyUpdateChip") {
            UpdateAvailability.shared.version = fake
            UpdateAvailability.shared.isDownloaded = UserDefaults.standard.bool(forKey: "TallyUpdateChipReady")
        }
        UsageStore.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Snapshot restore state HERE, the first termination hook, while the windows are still
        // on screen. By applicationWillTerminate AppKit has already closed them - their
        // willClose fired and read as the user dismissing each window, which is exactly how a
        // Sparkle update relaunch lost every flag (verified via scripted quit, 2026-07-21).
        // The latch keeps the willClose observers quiet through the tear-down.
        AppTermination.begin()
        MainWindowController.shared.persistRestoreState()
        SettingsWindowController.shared.persistRestoreState()
        return .terminateNow
    }

    /// Escape hatch for a hidden status item: macOS silently hides menu bar icons that
    /// no longer fit (notch or a crowded bar), and this app has no Dock icon, so
    /// relaunching from Spotlight or Finder is the only door left. Surface the main
    /// window instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowController.shared.show() }
        return true
    }
}
