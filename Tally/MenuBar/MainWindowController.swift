import AppKit
import SwiftUI

/// Manages the main dashboard window (a menu-bar app has no window by default). Lazily created,
/// reused, and never released so its frame autosaves across opens.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: DashboardView(store: .shared, settings: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Tally"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 440, height: 640))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("TallyMainWindow")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
