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
    /// THE ANCHOR THIS POPOVER ACTUALLY HANGS FROM, and the whole of the fix.
    ///
    /// NSPopover places itself against a positioning view and keeps its own model of where that is,
    /// re-placing the surface whenever that view's window moves. The status item's window is moved by
    /// the system, not by this app: into the strip above the display when the bar hides, and onto
    /// another display entirely when the bar it was summoned on goes away (measured 2026-08-12, four
    /// separate ways). Three rounds of this file tried to correct the placement afterwards, and every
    /// one of them lost, because the model is resident and unwritable: it re-placed the surface 1.2s
    /// after a correct put-back, moved it with no size report at all, and when finally held by force
    /// it produced 25 put-backs in one session with the arrow pointing at a display the user was not
    /// looking at.
    ///
    /// So the anchor is replaced instead of the placement. This is an invisible window we own, put
    /// where the status item is, and the popover is shown against IT. Nothing outside this app can
    /// move it, so the model never has cause to re-place anything: the surface's position has exactly
    /// one writer (AppKit, as designed), and the anchor's position has exactly one writer (this file).
    /// The arrow, the transient dismissal and the placement arithmetic all stay native, which is what
    /// the previous rounds were spending correction code to fake.
    ///
    /// Verified before it was built (probe v7, 2026-08-12): a popover shows against an alpha-0 window
    /// of our own, is placed on it with its arrow chrome, and sees ZERO moves while the real status
    /// window is dragged across displays.
    private var decoyAnchor: NSWindow?

    /// The view inside it, which is what `show(relativeTo:of:)` is actually given.
    private var decoyAnchorView: NSView?

    /// The moment the popover last closed itself, for the toggle (see `handleClick`).
    private var lastPopoverClose: Date?

    /// Feeding the decoy is watched from the real anchor's own moves.
    private var anchorObserver: NSObjectProtocol?


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
                                      // The screen the content has to fit inside, which is the one
                                      // the surface is actually on (see `contentHostScreen`).
                                      hostScreen: { [weak self] in self?.contentHostScreen() },
                                      tabState: popoverTab, host: .popover))
        host.sizingOptions = []
        popoverHost = host
        popover.contentViewController = host

        // A transient popover is dismissed by clicking outside it, which never passes through this
        // file, so the close notification is where the decoy is put away and the moment is written
        // down for the toggle (`dismissedThisClick`).
        _ = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification,
                                                   object: popover, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastPopoverClose = Date()
                self?.retireDecoyAnchor()
            }
        }

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
        } else if dismissedThisClick {
            // THE CLICK THAT CLOSED IT IS NOT A CLICK THAT OPENS IT. The popover hangs off a decoy
            // now, so the status item is OUTSIDE it and a transient popover dismisses itself on the
            // mouse-down; the action below arrives on the mouse-up and would open it straight back,
            // which reads as a flicker and an item that cannot be toggled shut. While the anchor was
            // the item's own window, NSPopover exempted clicks in it and this could not happen.
        } else {
            NSApp.activate(ignoringOtherApps: true)
            guard let anchorView = decoyAnchorViewForShow(button: button) else { return }
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            // The real anchor is watched only to feed the decoy from it.
            watchRealAnchor()
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
    /// Whether the click being handled right now is the one that just dismissed the popover.
    ///
    /// A quarter of a second is the window: a mouse-down that dismisses and the mouse-up that fires
    /// this action are the same physical click and land within a few milliseconds of each other,
    /// while a deliberate reopen is a second trip to the menu bar.
    private var dismissedThisClick: Bool {
        guard let lastPopoverClose else { return false }
        return Date().timeIntervalSince(lastPopoverClose) < 0.25
    }

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
            // Nothing else needs saying here any more. A resize is a placement, and this one is
            // made against the decoy, which is exactly where the surface belongs: the write below is
            // the whole of it.
            guard ResizeAnchor.needsResize(from: self.popover.contentSize, to: size) else {
                return
            }
            // NSPopover animates contentSize changes with a springy bounce; for in-place content
            // changes (collapsing a provider's cards) the bounce reads as the popover "jumping".
            // Suppress the animation just for the resize - show/close keep theirs.
            let animated = self.popover.animates
            self.popover.animates = false
            self.popover.contentSize = size
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
    /// Against the DECOY, which is the anchor this popover was shown on and the only one it ever
    /// sees. Three rounds of conditions lived here - is the anchor on screen, is it on this display,
    /// is a placement owed - and all of them were asking whether it was safe to hand the anchor back
    /// to AppKit. With an anchor nothing outside this app can move, it always is.
        private func fitShownPopoverToScreen() {
        guard popover.isShown, let anchorView = decoyAnchorView else { return }
        // No condition left to check. The decoy is on the display the popover is being read on by
        // construction - it is only ever moved to an anchor that is there - so handing it back is
        // always a correct placement. The guard that used to stand here existed because the rect
        // being handed back could be somewhere the surface must not go.
        popover.positioningRect = anchorView.bounds
    }

    /// Put the decoy where the status item is, and show the popover against it.
    ///
    /// Reused rather than rebuilt: a window per showing would be a new positioning view each time,
    /// and the point of this one is that it is ours and stable. `ignoresMouseEvents` because it sits
    /// over the menu bar and must never eat a click meant for the item underneath; the status bar
    /// level and `canJoinAllSpaces` so it is where the item is, on whichever Space the user is on.
    private func decoyAnchorViewForShow(button: NSStatusBarButton) -> NSView? {
        guard let anchorRect = anchorScreenRect(button: button) else { return nil }
        if decoyAnchor == nil {
            let window = NSWindow(contentRect: anchorRect, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.alphaValue = 0
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
            window.collectionBehavior = [.canJoinAllSpaces]
            let view = NSView(frame: NSRect(origin: .zero, size: anchorRect.size))
            window.contentView = view
            decoyAnchor = window
            decoyAnchorView = view
        }
        decoyAnchor?.setFrame(anchorRect, display: false)
        decoyAnchor?.orderFrontRegardless()
        return decoyAnchorView
    }

    /// The status item's own rectangle in screen coordinates, which is where the decoy belongs.
    private func anchorScreenRect(button: NSStatusBarButton) -> CGRect? {
        guard let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// FOLLOW THE REAL ANCHOR WHILE IT IS SOMEWHERE THE SURFACE MAY GO, AND FREEZE WHEN IT IS NOT.
    ///
    /// This is the whole of the open-popover behaviour, and it replaces three rounds of correction
    /// code. Moving the decoy is a placement AppKit makes for us, correctly and natively: the bar
    /// sliding 24pt as it hides takes the popover with it and the arrow stays glued, exactly as it
    /// does today. Freezing is equally passive - nothing moves the decoy, so nothing moves the
    /// popover, and the surface simply stays where the user is reading it.
    ///
    /// The question is the one this file has asked since the third round: is the status item on the
    /// display the popover is on? An anchor in the strip above the display, or parked on another
    /// display by the system, is not somewhere this surface may follow it to.
    private func feedDecoyAnchor() {
        guard popover.isShown, let button = statusItem?.button else { return }
        guard anchorMayBeFollowed, let anchorRect = anchorScreenRect(button: button) else {
            return
        }
        guard decoyAnchor?.frame != anchorRect else { return }
        decoyAnchor?.setFrame(anchorRect, display: false)
    }

    /// Watch the REAL anchor while the popover is up, because following it is the only thing this
    /// file still does about placement. Torn down with the popover.
    private func watchRealAnchor() {
        if let anchorObserver {
            NotificationCenter.default.removeObserver(anchorObserver)
            self.anchorObserver = nil
        }
        guard popover.isShown, let window = statusItem?.button?.window else { return }
        anchorObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.feedDecoyAnchor() }
        }
    }

    /// Put the decoy away with the popover, so nothing of ours is left over the menu bar.
    private func retireDecoyAnchor() {
        if let anchorObserver {
            NotificationCenter.default.removeObserver(anchorObserver)
            self.anchorObserver = nil
        }
        decoyAnchor?.orderOut(nil)
    }

    /// Whether the real anchor is somewhere the surface may follow it to: on the display the popover
    /// is being read on.
    ///
    /// The question survives from the third round, but what it decides has changed completely. It
    /// used to gate whether AppKit was allowed to place the surface, which meant fighting a model
    /// that placed it anyway. Now it gates whether the DECOY follows the real anchor, and both
    /// answers are passive: follow, and AppKit slides the popover along natively; freeze, and nothing
    /// moves the popover because nothing is moving its anchor.
    ///
    /// Asked of the popover's own display rather than the anchor's, which is the trap the third round
    /// found: `menuBarScreen` is derived from the anchor window, so asking it whether the anchor is
    /// on it is asking whether the anchor is where the anchor is. It answered yes for a window the
    /// system had parked on another display.
    private var anchorMayBeFollowed: Bool {
        guard let anchor = statusItem?.button?.window?.frame, let screen = popoverScreenFrame()
        else { return false }
        return StatusAnchor.isOnScreen(buttonWindow: anchor, screen: screen)
    }

    /// The display the popover is standing on right now, by its own frame. Nil when it is not shown
    /// or is standing on no display at all.
    private func popoverScreenFrame() -> CGRect? {
        guard popover.isShown, let frame = popoverWindow?.frame else { return nil }
        return StatusAnchor.screenFrame(containing: frame, among: NSScreen.screens.map(\.frame))
    }

    /// The display the CONTENT sizes itself to fit (`ScreenFitStack`).
    ///
    /// While the popover is up that is the display it is standing on, not the one the anchor is on:
    /// those are the same display until the system parks the anchor somewhere else, and then a
    /// surface open on a 2560x1440 display would shrink itself to fit a 2048x1152 one it is nowhere
    /// near - and the shrink is a resize, which is another placement. Before it is shown there is no
    /// surface to ask, and the anchor is the best answer available: that is where it is about to
    /// open.
    private func contentHostScreen() -> NSScreen? {
        guard let standing = popoverScreenFrame() else { return menuBarScreen() }
        return NSScreen.screens.first { $0.frame == standing } ?? menuBarScreen()
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
