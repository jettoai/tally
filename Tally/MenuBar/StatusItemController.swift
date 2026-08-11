import AppKit
import SwiftUI

/// Owns the `NSStatusItem` and its popover.
///
/// Uses raw `NSStatusItem` rather than SwiftUI `MenuBarExtra`: MenuBarExtra's label does not redraw
/// on `@Observable` changes (Apple FB13683957), so the at-a-glance percentage wouldn't update.
/// The button title is refreshed imperatively via `UsageStore.onChange`.
///
/// Left-click toggles the popover; right/control-click drops a small menu (Settings / Quit).
@MainActor
final class StatusItemController: NSObject {
    static private(set) weak var shared: StatusItemController?

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var popoverHost: NSHostingController<PopoverRootView>?
    /// The popover's own Usage / Tokens selection, kept here so the pin hand-off can read it.
    private let popoverTab = SurfaceTabState()
    /// A RE-PLACEMENT THIS POPOVER STILL OWES. A resize that lands while the menu bar is hidden
    /// applies the new size and skips the placement (`fitShownPopoverToScreen` has nothing on screen
    /// to place against), so the surface is now a size that was never fitted to the display: wider
    /// than the anchor it kept, possibly off the right of it.
    ///
    /// It has to be REMEMBERED rather than left to the next report, which is what the comment here
    /// used to promise: the next report is usually the same size, the guard below returns on it, and
    /// nothing would ever call the placement again - the popover stayed off screen until it was
    /// resized once more or closed and reopened (codex review of 06d734f). With the debt written
    /// down, the same report that used to be the end of it is what pays it.
    private var repositionOwed = false

    private static let symbolCandidates = ["gauge.medium", "gauge", "chart.bar.fill"]

    /// Whether the transient popover is on screen. Read by the updater before it restarts the app
    /// into a new version: the popover is a surface the user opened to read something, and taking
    /// it away mid-read is the interruption the idle bar exists to avoid.
    var isPopoverShown: Bool { popover.isShown }

    func install() {
        Self.shared = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        statusItem = item

        popover.behavior = .transient
        // Show instantly instead of playing NSPopover's expand/scale animation - that animation (not
        // the content) is the "laggy on expand" feel; other menu-bar apps just appear.
        popover.animates = false
        // `sizingOptions = []` (not `.preferredContentSize`, not the default `.standardBounds`) so the
        // host installs NO Auto Layout constraints - we set the popover's contentSize manually via
        // `sizeThatFits`. Two size authorities (SwiftUI constraints + manual sizing) recurse the layout
        // engine into a stack-overflow crash.
        let host = NSHostingController(
            rootView: PopoverRootView(store: UsageStore.shared, settings: SettingsStore.shared,
                                      onContentSize: { [weak self] size in self?.applyPopoverSize(size) },
                                      // The popover hangs off the status item, so it has to fit the
                                      // screen the menu bar is on, whichever display that is today.
                                      hostScreen: { [weak self] in self?.menuBarScreen() },
                                      tabState: popoverTab, host: .popover))
        host.sizingOptions = []
        popoverHost = host
        popover.contentViewController = host

        UsageStore.shared.onChange = { [weak self] in self?.updateButton() }
        updateButton()

        // Restore the pinned floating panel if it was pinned when the app last quit.
        if SettingsStore.shared.isUsagePanelPinned {
            PinnedPanelController.shared.show(atTopLeft: nil)
        }
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let segments = UsageStore.shared.menuBarSegments
        button.attributedTitle = NSAttributedString(string: "")
        if segments.isEmpty {
            // No visible accounts - fall back to the app glyph.
            button.image = Self.symbolImage()
            button.toolTip = nil
        } else {
            // The whole strip is rendered as one template image (brand marks + stacked numbers).
            // Hover / VoiceOver carry the full per-account identity the compact strip can't.
            let tooltip = UsageStore.shared.menuBarTooltip
            button.image = MenuBarStripRenderer.stripImage(segments)
            button.image?.accessibilityDescription = tooltip
            button.toolTip = tooltip
            // README screenshot hook: demo mode + -TallyStripSnapshot <path> writes the strip
            // as a standalone PNG (idempotent - demo data never changes between refreshes).
            if DemoUsage.isActive,
               let path = UserDefaults.standard.string(forKey: "TallyStripSnapshot") {
                MenuBarStripRenderer.writeSnapshot(segments, to: path)
            }
        }
        button.imagePosition = .imageOnly
        // Surface resizing is handled by PopoverRootView.onContentSize (it reports the real content
        // size on every layout change), so nothing to do here.
    }

    private static func symbolImage() -> NSImage? {
        for name in symbolCandidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tally") {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    @objc private func handleClick() {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showMenu(from: button)
        } else {
            togglePopover(button: button)
        }
    }

    private func togglePopover(button: NSStatusBarButton) {
        // While pinned, the floating panel is the usage view; a status-item click just surfaces it
        // rather than opening a competing popover.
        if SettingsStore.shared.isUsagePanelPinned {
            PinnedPanelController.shared.bringToFront()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            let window = popoverWindow
            window?.makeKey()
            // Nothing should start focused, the same clear `PinnedPanelController.show` makes on its
            // way in. The tab switch keeps focus through a surface going quiet so a keyboard user
            // comes back to it, and from inside a reused view a close looks exactly like that:
            // without this, the ring and the arrow keys come back with a popover merely reopened.
            window?.makeFirstResponder(nil)
        }
    }

    /// Dismiss the popover when another Tally window takes the stage: that window steals key and
    /// promotes the activation policy, which defeats the transient popover's own click-outside
    /// dismissal and leaves it stuck on screen. No-op when closed, so callers need no condition.
    func closePopover() {
        popover.performClose(nil)
    }

    /// Size the popover to the content's measured size (reported by `PopoverRootView.onContentSize`),
    /// deferred a run-loop turn so it never resizes from inside the SwiftUI update that reported it.
    ///
    /// The measured size goes through verbatim, and that is load-bearing. NSPopover re-derives its
    /// anchor from whatever contentSize it is handed, while the window it draws is sized by SwiftUI's
    /// own layout: a cap never shrinks the popover, it only anchors it as if it were smaller, and the
    /// surface jumps a frame after the content changed. Both old caps fired on layouts the user can
    /// pick (four columns is 1108pt wide by design; one column with a full fleet is taller than the
    /// screen), which is why the jump appeared only after a column change. Fitting the screen belongs
    /// to the content that reports the size, never to a size reported back wrong - the content does
    /// it one layout pass earlier, in `ScreenFitStack`, so what arrives here already fits.
    private func applyPopoverSize(_ size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self, size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1
            else { return }
            // A report that is the size the popover already is has nothing to apply, and applying it
            // anyway would hand the anchor back to AppKit for a resize that isn't one. Layout reports
            // the same size on plenty of changes that are not resizes at all - switching the gauges
            // between used and remaining is one - so this is where most reposition requests stop.
            //
            // UNLESS A PLACEMENT IS OWED, which is the one thing this return may not swallow: the
            // size it is comparing against was applied while the anchor was off screen, so the
            // popover is standing at a position that fits an older, smaller surface. This is the
            // report that pays that debt - it arrives on every layout the content measures again,
            // including all the ones that change nothing this guard can see.
            guard ResizeAnchor.needsResize(from: self.popover.contentSize, to: size) else {
                if self.repositionOwed { self.fitShownPopoverToScreen() }
                return
            }
            // NSPopover animates contentSize changes with a springy bounce; for in-place content
            // changes (collapsing a provider's cards) the bounce reads as the popover "jumping".
            // Suppress the animation just for the resize - show/close keep theirs.
            let animated = self.popover.animates
            self.popover.animates = false
            // WRITING THE SIZE IS ITSELF A PLACEMENT, so declining the one below cannot be the whole
            // answer: this is the resize the guard let through, and handing NSPopover a contentSize
            // is what throws the surface at the corner (`StatusAnchor.heldOrigin` has the measured
            // numbers). The frame it is standing at has to be read BEFORE that write, because after
            // it there is nothing left to read - AppKit has already moved it.
            let held = self.popover.isShown && !self.anchorIsPlaceable ? self.popoverWindow?.frame : nil
            self.popover.contentSize = size
            if let held, let window = self.popoverWindow, let screen = self.menuBarScreen() {
                // Origin only, put back against the bar's own display. The arrow keeps whatever
                // offset AppKit drew it at until the bar comes back and the owed placement re-places
                // the surface properly: a triangle a few points out, against a jump to another
                // display, and only for as long as the bar it points at is invisible anyway.
                window.setFrameOrigin(StatusAnchor.heldOrigin(previous: held, size: window.frame.size,
                                                             within: screen.visibleFrame))
            }
            self.fitShownPopoverToScreen()
            self.popover.animates = animated
        }
    }

    /// Ask AppKit to place the popover again, now that it knows how big it is.
    ///
    /// Fitting the popover to its display is a ONE-SHOT: NSPopover works out where it goes when it
    /// is shown, from the size it has at that moment, and every later size change resizes the window
    /// in place from the origin that fit the OLD size. This surface changes width while it is open -
    /// the card that changes the column count and the density is inside the popover itself - so a
    /// panel widened from two columns to four kept the left edge it had and walked off the right of
    /// the display, taking the last column with it, and stayed there until it was closed (measured:
    /// a status item near the right of a 2048pt display, 406pt panel at x=1471, still x=1471 once it
    /// was 1134pt wide, i.e. 557pt past the edge).
    ///
    /// Handing the positioning rect back is what makes it place itself again; it is the same rect
    /// `show(relativeTo:)` was given, so nothing about where it points changes - only whether the
    /// screen it points on can hold it. The content's own fit (`ScreenFitStack`, `PanelGeometry`)
    /// keeps it small enough for that to succeed; this is what makes the two meet.
    ///
    /// Only while the anchor is ON SCREEN, though. With "Automatically hide and show the menu bar"
    /// on and the bar hidden, the status item's window sits in the strip above the display and
    /// placing a surface against it puts the popover in the display's top-left corner, arrow
    /// pointing back at the corner (reported 2026-08-11, from switching the gauges between used and
    /// remaining while the bar was hidden). A popover already open is already placed correctly, so
    /// the safe answer for an anchor nobody can see is to leave it where it is and resize in place.
    ///
    /// AND TO WRITE DOWN THAT IT IS OWED ONE. The size was applied either way, so declining the
    /// placement leaves a surface standing where a smaller one fitted; the debt is what makes the
    /// next report pay it (`repositionOwed`, and `applyPopoverSize` is where it is collected). The
    /// earlier version of this comment claimed the next report would re-place the popover on its
    /// own, and it could not: that report is the same size, and the guard up there returns before
    /// this is ever reached (codex review of 06d734f).
    ///
    /// A CLOSED POPOVER OWES NOTHING: NSPopover works its position out when it is shown, from the
    /// size it has then, so the debt cannot outlive the surface that incurred it.
    private func fitShownPopoverToScreen() {
        guard popover.isShown else {
            repositionOwed = false
            return
        }
        guard anchorIsPlaceable, let button = statusItem?.button else {
            repositionOwed = true
            return
        }
        popover.positioningRect = button.bounds
        repositionOwed = false
    }

    /// Whether the status item is somewhere a popover can be placed against right now.
    ///
    /// Stated ONCE, because two callers need the same answer for opposite reasons: the placement
    /// above declines to make one, and the sizing pass has to undo one AppKit made anyway. Asked
    /// twice, the two would drift apart invisibly - each half would still read correctly on its own,
    /// while the surface was being put back to fit a question the guard no longer agreed with.
    private var anchorIsPlaceable: Bool {
        guard let window = statusItem?.button?.window, let screen = menuBarScreen() else { return false }
        return StatusAnchor.isOnScreen(buttonWindow: window.frame, screen: screen.frame)
    }

    /// The window AppKit draws the popover in. Meaningful only while it is shown: after a close the
    /// content view keeps an off-screen window attached (see `popoverContentTopLeft`).
    private var popoverWindow: NSWindow? { popover.contentViewController?.view.window }

    /// The display the popover opens on, which is the one the menu bar is on.
    ///
    /// Deliberately not `button.window?.screen`: with "Automatically hide and show the menu bar"
    /// on, the status item's window sits in the strip just ABOVE its display while the bar is
    /// hidden, and AppKit then answers either nil (nothing there) or - when another display is
    /// stacked above this one - THAT display, whose size the surface has no business fitting. The
    /// popover still hangs off the bar's own screen, so read it off the point it hangs from.
    private func menuBarScreen() -> NSScreen? {
        guard let window = statusItem?.button?.window else { return NSScreen.main }
        let anchor = CGPoint(x: window.frame.midX, y: window.frame.minY - 1)
        return NSScreen.screens.first { $0.frame.contains(anchor) } ?? window.screen ?? NSScreen.main
    }

    /// Toggle the pinned floating panel (called from the popover/panel footer's pin button).
    static func togglePin() {
        shared?.setPinned(!SettingsStore.shared.isUsagePanelPinned)
    }

    /// Retire the pinned panel, the other half of the transformation below - called by the dashboard
    /// window as it takes the stage.
    ///
    /// The two are one surface in two forms, and the panel floats above every normal window, so
    /// leaving it up while the dashboard opens stacks two IDENTICAL views with the floating one on
    /// top: every click on the covered part of the dashboard is silently eaten by the panel. It
    /// looks like a dead region rather than an overlap precisely because both surfaces render the
    /// same view, and which part is covered changes as the window resizes - switching the dashboard
    /// to Tokens shrinks it (top-anchored), pulling its footer up into the panel's band, so the
    /// whole footer stops responding while the header above the panel still works.
    ///
    /// Unpinning rather than merely hiding keeps the state honest: the window's footer button reads
    /// "Pin on top" again, which is exactly what it now does.
    static func unpin() {
        guard SettingsStore.shared.isUsagePanelPinned else { return }
        SettingsStore.shared.isUsagePanelPinned = false
        PinnedPanelController.shared.hide()
    }

    private func setPinned(_ pinned: Bool) {
        guard pinned else { return Self.unpin() }
        SettingsStore.shared.isUsagePanelPinned = true
        // Pinning is a transformation, not a copy: whichever surface the pin was clicked in
        // (popover or main window) hands its on-screen position AND the view it is showing to
        // the panel and closes, so the panel visibly takes over in place. Handing over only the
        // position would have made pinning the Tokens tab a way to leave it.
        let fromPopover = popoverContentTopLeft()
        let source = fromPopover != nil ? popoverTab : MainWindowController.shared.surfaceTab
        let topLeft = fromPopover ?? MainWindowController.shared.contentTopLeft
        popover.performClose(nil)
        MainWindowController.shared.close()
        PinnedPanelController.shared.show(atTopLeft: topLeft, showing: source.tab)
    }

    /// The screen-space top-left of the popover's content, so the panel can open exactly where the
    /// popover was (its own window frame includes the arrow, so measure the content view instead).
    /// Returns nil unless the popover is actually on screen: after `performClose` AppKit keeps the
    /// content view attached to an off-screen window, so a `view.window` check alone stays non-nil
    /// forever once the popover has been shown, and callers using this as "the pin came from the
    /// popover" would misread every later pin from the main window.
    private func popoverContentTopLeft() -> CGPoint? {
        guard popover.isShown else { return nil }
        guard let view = popover.contentViewController?.view, let window = popoverWindow else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        return CGPoint(x: onScreen.minX, y: onScreen.maxY)
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let open = NSMenuItem(title: String(localized: "Open Tally", bundle: AppLocale.bundle),
                              action: #selector(openMainWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: String(localized: "Settings…", bundle: AppLocale.bundle),
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Tally", bundle: AppLocale.bundle),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openSettings() {
        StatusItemController.openSettingsWindow()
    }

    @objc private func openMainWindow() {
        MainWindowController.shared.show()
    }

    /// Opens the settings window (a reliable custom NSWindow, not the flaky `Settings` scene action).
    static func openSettingsWindow() {
        SettingsWindowController.shared.show()
    }
}
