import AppKit
import SwiftUI

/// Manages the main dashboard window (a menu-bar app has no window by default). Lazily created,
/// reused, and never released so its frame autosaves across opens.
///
/// The window hosts the SAME view as the popover and the pinned panel (PopoverRootView) and nothing
/// else, so card order, drag-to-reorder, the countdown header, the footer and the switch to token
/// history behave identically in all three surfaces. It wrapped that view in a tab bar of its own
/// until the switch moved into the header, at which point the wrapper was two tabs for one selection
/// and went away. The titlebar shows only the traffic lights: the view carries its own branding row,
/// and a second "Tally" in the frame would double it.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?
    /// The window's own Usage / Tokens selection, kept here so the pin hand-off can read it.
    let surfaceTab = SurfaceTabState()

    /// Whether the window should come back on the next launch. An update relaunch is just
    /// quit + launch, so without this the dashboard the user was reading silently vanishes.
    /// True while the window is up, false once the user closes it; at quit the last value
    /// stands, which is exactly "restore what was open".
    private nonisolated static let restoreKey = "restoreMainWindow"

    var isWindowVisible: Bool { window?.isVisible == true }

    /// Reopen the window at launch if it was up when the app last quit (see `restoreKey`).
    func restoreAtLaunchIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.restoreKey) { show(restoring: true) }
    }

    /// Called at termination: tear-down closes must not read as the user dismissing the
    /// window, so re-record what is actually on screen for the next launch to restore.
    func persistRestoreState() {
        UserDefaults.standard.set(isWindowVisible, forKey: Self.restoreKey)
    }

    /// Screen-space top-left of the window content while visible, for the pin handoff (the pinned
    /// panel opens exactly where the window was, mirroring the popover-to-panel handoff).
    var contentTopLeft: CGPoint? {
        guard let window, window.isVisible else { return nil }
        let onScreen = window.convertToScreen(window.contentLayoutRect)
        return CGPoint(x: onScreen.minX, y: onScreen.maxY)
    }

    func close() {
        window?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Self.restoreKey)
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

    /// `restoring` = a launch-time restore: keep the autosaved frame (the window reappears where
    /// it was before the quit) instead of re-deriving the position from the pointer.
    ///
    /// Nothing here decides which view the window lands on any more: the surface keeps that in its
    /// own state, so a window reopened during a session shows what its header was last switched to,
    /// exactly like the panel and the popover do.
    func show(restoring: Bool = false) {
        StatusItemController.shared?.closePopover()
        // The pinned panel gives way too, and for a harder reason than tidiness: it is THIS view in
        // its always-on-top form, so leaving it up stacks two identical surfaces and the floating
        // one silently eats every click on the part of this window it covers (see
        // StatusItemController.unpin). Pinning already closes this window; this is its reverse.
        // Being the reverse, it carries the same hand-off: the panel gives up the view it was showing,
        // so opening the dashboard off a panel reading token history does not drop the user back on
        // the quota cards - the mirror of pinning handing this window's tab to the panel (see
        // StatusItemController.setPinned). Nil while the panel is off screen, which leaves this
        // window's own last selection alone.
        if let tab = PinnedPanelController.shared.visibleTab { surfaceTab.tab = tab }
        StatusItemController.unpin()
        if window == nil {
            // Opaque window: its cards stay solid. Glass cards belong to the hosts that put glass
            // behind them (the popover's vibrancy, the pinned panel's behind-window blur).
            let hosting = NSHostingController(
                rootView: PopoverRootView(store: .shared, settings: .shared, hostDrawsGlass: false,
                                          tokens: .shared, tabState: surfaceTab))
            let window = NSWindow(contentViewController: hosting)
            window.title = BuildVariant.isDev ? "Tally Dev" : "Tally"   // Mission Control / Window menu name
            window.titleVisibility = .hidden
            // Not resizable: the content is fixed-width by design, and the hosting controller is
            // the single size authority (adding setContentSize/setFrame here recursed the layout
            // engine to a stack overflow on the pinned panel; see PinnedPanelController).
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("TallyMainWindow.v3")
            ActivationPolicy.track(window)
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                // Quit-time tear-down also closes the window; only a close while the app keeps
                // running is the user dismissing it (Sparkle-relaunch lesson, see AppDelegate).
                Task { @MainActor in
                    if !AppTermination.inProgress {
                        UserDefaults.standard.set(false, forKey: Self.restoreKey)
                    }
                }
            }
            keepTopEdgeThroughResizes(window)
            self.window = window
        }
        // Summoned windows follow the user: place on the pointer's screen whenever the window
        // isn't already up (an open window stays put - yanking it mid-use would be worse).
        if window?.isVisible != true, !restoring { window?.centerOnPointerScreen() }
        UserDefaults.standard.set(true, forKey: Self.restoreKey)
        ActivationPolicy.promote()   // a visible dashboard earns a Dock / Cmd-Tab presence
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
