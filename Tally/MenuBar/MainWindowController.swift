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

    var isWindowVisible: Bool { window?.isVisible == true }

    /// Screen-space top-left of the window content while visible, for the pin handoff (the pinned
    /// panel opens exactly where the window was, mirroring the popover-to-panel handoff).
    var contentTopLeft: CGPoint? {
        guard let window, window.isVisible else { return nil }
        let onScreen = window.convertToScreen(window.contentLayoutRect)
        return CGPoint(x: onScreen.minX, y: onScreen.maxY)
    }

    func close() {
        window?.orderOut(nil)
        ActivationPolicy.refresh()
    }

    /// Content-driven resizes (the hosting controller is the size authority here) keep the
    /// window's BOTTOM edge by AppKit default, so collapsing cards made the whole view, and the
    /// row just clicked, drop by the height difference. Re-anchor the TOP edge instead: position
    /// is corrected after each resize (origin-only, never a size write, so the layout engine's
    /// single size authority stays untouched; see the pinned panel's recursion lesson). The
    /// window has no .resizable mask, so every resize here is content-driven.
    private var topAnchor: CGFloat?

    private func keepTopEdgeThroughResizes(_ window: NSWindow) {
        topAnchor = window.frame.maxY
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window else { return }
                self.topAnchor = window.frame.maxY
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, let top = self.topAnchor else { return }
                let frame = window.frame
                if abs(frame.maxY - top) > 0.5 {
                    window.setFrameOrigin(NSPoint(x: frame.origin.x, y: top - frame.height))
                }
            }
        }
    }

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
            ActivationPolicy.track(window)
            keepTopEdgeThroughResizes(window)
            self.window = window
        }
        // Summoned windows follow the user: place on the pointer's screen whenever the window
        // isn't already up (an open window stays put - yanking it mid-use would be worse).
        if window?.isVisible != true { window?.centerOnPointerScreen() }
        ActivationPolicy.promote()   // a visible dashboard earns a Dock / Cmd-Tab presence
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
