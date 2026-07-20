import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar accessory app: install the status item, then start the refresh loop.
        statusItemController.install()
        // Whatever was on screen at the last quit comes back: an update relaunch is just
        // quit + launch, and losing the window you were reading mid-update is disorienting.
        // (The pinned panel restores itself inside install(); the transient popover is always
        // closed by the time an update runs, so there is nothing of it to restore.)
        // Settings second so it lands on top when both were open: the update button lives
        // there, making it the window the user most likely had focused.
        MainWindowController.shared.restoreAtLaunchIfNeeded()
        SettingsWindowController.shared.restoreAtLaunchIfNeeded()
        UsageStore.shared.start()
        UpdaterController.shared.start()   // dormant unless the build carries a feed URL + ED key
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quit-time window tear-down must not register as the user closing anything:
        // snapshot the real on-screen state so the next launch restores it faithfully.
        MainWindowController.shared.persistRestoreState()
        SettingsWindowController.shared.persistRestoreState()
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
