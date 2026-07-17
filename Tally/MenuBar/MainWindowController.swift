import AppKit
import SwiftUI

/// Manages the main dashboard window (a menu-bar app has no window by default). Lazily created,
/// reused, and never released so its frame autosaves across opens.
///
/// The window hosts the SAME view as the popover and the pinned panel (PopoverRootView), so card
/// order, drag-to-reorder, the countdown header and the footer behave identically in all three
/// surfaces. The titlebar shows only the traffic lights: the view carries its own branding row, and
/// a second "Tally" in the frame would double it.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: PopoverRootView(store: .shared, settings: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Tally"          // Mission Control / Window menu name
            window.titleVisibility = .hidden
            // Not resizable: the content is fixed-width by design, and the hosting controller is
            // the single size authority (adding setContentSize/setFrame here recursed the layout
            // engine to a stack overflow on the pinned panel; see PinnedPanelController).
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("TallyMainWindow.v3")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
