import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar accessory app: install the status item, then start the refresh loop.
        statusItemController.install()
        UsageStore.shared.start()
        UpdaterController.shared.start()   // dormant unless the build carries a feed URL + ED key
    }
}
