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
///
/// It also sizes itself the same way they do: `sizingOptions = []` on the hosting view, the
/// content's MEASURED size in (`PopoverRootView.onContentSize`), one frame write out. It used to be
/// the odd one out - the hosting controller's Auto Layout constraints were the size authority - and
/// that difference cost it both halves of the transition fix the other two got. `HostAnchored`
/// cannot apply to a constraint-sized host (reporting whatever size is proposed makes every size a
/// fixpoint, so such a window keeps the degenerate size it is born with and never grows: measured
/// 1x32), so this window alone kept `NSHostingView`'s centring of a root view that is momentarily a
/// different height than its window - the whole page, header and all, lifting by half the growth
/// and dropping back when the window caught up. Measured on 2026-08-05: 114pt on a density switch,
/// 245-302pt sideways on a column-count click, 41 of 54 scripted triggers moving something.
///
/// Deliberately still NOT `.resizable`, and that is what makes one size authority possible at all:
/// a drag would be a second one, and the next content report - a card folding, fresh data, the
/// countdown ticking - would write the dragged size straight back out. The two things a user could
/// want from a drag are already theirs by other means: the width is a column count they choose in
/// the view-options card, and the height gives way to the screen through `ScreenFitStack` (content
/// past the cap scrolls rather than running off the display). The zoom button follows the same
/// mask, so it is inert for the same reason.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?
    /// The window's own Usage / Tokens selection, kept here so the pin hand-off can read it.
    let surfaceTab = SurfaceTabState()
    /// Owns how big this window is and where a resize leaves it - the same object the pinned panel
    /// uses, which is the point (see `SurfaceSizer`).
    private var sizer: SurfaceSizer?

    /// Whether the window should come back on the next launch. An update relaunch is just
    /// quit + launch, so without this the dashboard the user was reading silently vanishes.
    /// True while the window is up, false once the user closes it; at quit the last value
    /// stands, which is exactly "restore what was open".
    private nonisolated static let restoreKey = "restoreMainWindow"

    var isWindowVisible: Bool { window?.isVisible == true }

    /// Reopen the window at launch if it was up when the app last quit (see `restoreKey`).
    ///
    /// `activating` is the launch's one answer about taking the foreground, passed in rather than
    /// assumed: a restore is not a click, and on a launch that must stay in the background this is
    /// the path that would otherwise pull the app forward on nothing but "the window happened to be
    /// open last time" (CaptureLaunch.mayTakeForeground).
    func restoreAtLaunchIfNeeded(activating: Bool = true) {
        if UserDefaults.standard.bool(forKey: Self.restoreKey) {
            show(restoring: true, activating: activating)
        }
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
        return window.contentTopLeft
    }

    func close() {
        window?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Self.restoreKey)
        ActivationPolicy.refresh()
    }

    /// `restoring` = a launch-time restore: keep the autosaved frame (the window reappears where
    /// it was before the quit) instead of re-deriving the position from the pointer.
    ///
    /// Nothing here decides which view the window lands on any more: the surface keeps that in its
    /// own state, so a window reopened during a session shows what its header was last switched to,
    /// exactly like the panel and the popover do.
    /// `activating` = take the foreground, which every ordinary summon does because it is a click.
    /// Only the launch-time restore passes false, and only on a launch that must leave the
    /// foreground to however the app was started (see `restoreAtLaunchIfNeeded`).
    func show(restoring: Bool = false, activating: Bool = true) {
        StatusItemController.shared?.closePopover()
        // The pinned panel gives way too, and for a harder reason than tidiness: it is THIS view in
        // its always-on-top form, so leaving it up stacks two identical surfaces and the floating
        // one silently eats every click on the part of this window it covers (see
        // StatusItemController.unpin). Pinning already closes this window; this is its reverse.
        // Being the reverse, it carries the same hand-off: the panel gives up the view it was showing,
        // so opening the dashboard off a panel reading token history does not drop the user back on
        // the quota cards - the mirror of pinning handing this window's tab to the panel (see
        // StatusItemController.setPinned). Nil while the panel is off screen, which leaves this
        // window's own last selection alone. The hand-off carries the panel's POSITION too, read
        // here while the panel is still up: the window takes over in place rather than reappearing
        // wherever the pointer happens to be, so the view the user was reading does not teleport
        // mid-glance. Both halves are read before `unpin`, which puts the panel off screen and with
        // it the answers to both questions.
        let fromPanel = PinnedPanelController.shared.visibleContentTopLeft
        if let tab = PinnedPanelController.shared.visibleTab { surfaceTab.tab = tab }
        StatusItemController.unpin()
        if window == nil {
            // Built without a contentViewController: what goes in a window under this contract is
            // a hosting VIEW with no sizing constraints, and that is `SurfaceSizer`'s job for both
            // surfaces. A contentViewController would also size the window from its view's fitting
            // size, which is the second authority all over again.
            let window = NSWindow(contentRect: .zero,
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = BuildVariant.isDev ? "Tally Dev" : "Tally"   // Mission Control / Window menu name
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            // Opaque window: its cards stay solid. Glass cards belong to the hosts that put glass
            // behind them (the popover's vibrancy, the pinned panel's behind-window blur).
            //
            // Everything about the size is the sizer's, including the autosaved frame: restoring
            // one IS a resize, so the anchor edges have to be read after it and not before.
            sizer = SurfaceSizer(window: window, host: .window,
                                 autosaveName: "TallyMainWindow.v3") { sizer in
                PopoverRootView(store: .shared, settings: .shared,
                                onContentSize: sizer.onContentSize,
                                hostDrawsGlass: false,
                                // Summoned windows follow the user, so the display to fit is the
                                // one this window was last put on.
                                hostScreen: sizer.screen,
                                // Same growth rule as the pinned panel (it holds its top left and
                                // clamps after every resize), so it takes the same position-aware
                                // cap: the content stops at the bottom of the display instead of
                                // pushing the window up from under the pointer.
                                hostTopEdge: sizer.topEdge,
                                tokens: .shared, tabState: surfaceTab, host: sizer.host)
            }
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
            self.window = window
        }
        // Summoned windows follow the user: place on the pointer's screen whenever the window
        // isn't already up (an open window stays put - yanking it mid-use would be worse). Taking
        // over a pinned panel is the exception: that surface was already where the user put it, so
        // the window inherits its spot - the mirror of pinning handing this window's position to
        // the panel (see StatusItemController.setPinned).
        if window?.isVisible != true {
            if !restoring {
                // Centring reads the window's size, so it has to wait for the size the content is
                // about to report: a window placed around the placeholder would then grow AWAY from
                // where it was centred (measured, before there was a queue: the window landed a full
                // content-height off).
                sizer?.whenSized { window in
                    if let fromPanel { window.setContentTopLeft(fromPanel) } else { window.centerOnPointerScreen() }
                    // The one move made here that is not an anchor correction, so the one that can
                    // put a surface somewhere it does not fit.
                    window.clampOnScreen()
                }
            }
            // And appearing waits for the same thing, for the same reason: a window ordered front
            // before it has been measured shows its placeholder (or, restoring, whatever frame the
            // last quit saved) and jumps to its real size and place a run-loop turn later. It comes
            // up transparent instead and is revealed by the pass that sizes it.
            //
            // It is still ORDERED front below rather than held back, and that is load-bearing: an
            // unordered window is not laid out, and the measurement being waited for is a product
            // of that layout - waiting to order it would be waiting for something that only
            // ordering it can produce.
            window?.alphaValue = 0
            sizer?.whenSized { $0.alphaValue = 1 }
            // `layoutIfNeeded` runs the SwiftUI pass that produces the measurement and `sizeNow`
            // applies it here rather than a run-loop turn later, so in the ordinary case the window
            // is its real size, in its real place and fully opaque before anyone sees it. When the
            // report is genuinely a turn behind, the queue above is what keeps that invisible.
            window?.layoutIfNeeded()
            sizer?.sizeNow()
        }
        UserDefaults.standard.set(true, forKey: Self.restoreKey)
        ActivationPolicy.promote()   // a visible dashboard earns a Dock / Cmd-Tab presence
        // The promotion above stays unconditional: being reachable through Cmd-Tab is how a window
        // is found again, and is not the same act as taking the screen from whoever is using it.
        // Only the second is the caller's to withhold.
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
        // Nothing should start focused, the same clear `PinnedPanelController.show` makes on its way
        // in. This window outlives its closes, so focus left on the tab switch is still there when it
        // is summoned again. A close reads from inside the view as this surface going quiet, the one
        // thing the row keeps focus through, so without this a reopen wears a ring nobody asked for.
        window?.makeFirstResponder(nil)
    }
}
