import AppKit
import SwiftUI

/// Owns the `NSStatusItem` and its popover.
///
/// Uses raw `NSStatusItem` rather than SwiftUI `MenuBarExtra`: MenuBarExtra's label does not redraw
/// on `@Observable` changes (Apple FB13683957), so the at-a-glance percentage wouldn't update.
/// The button title is refreshed imperatively via `UsageStore.onChange`.
///
/// Left-click toggles the popover; right/control-click drops a small menu (Settings / Quit).
///
/// What is left HERE is the summoning path: the click, the popover, and the decoy anchor it hangs
/// from. What the button draws is in `StatusItemButton`, and the commands the item offers besides
/// its popover (the secondary-click menu, the pin transformation) are in `StatusItemCommands` -
/// both moved out verbatim on 2026-08-15, when this file went past the 500-line limit. The window
/// anchor suite reads all three as ONE source, because every "and nowhere else" it asserts is a
/// claim about the controller rather than about a file (tests/windowanchor/popover.swift).
@MainActor
final class StatusItemController: NSObject {
    static private(set) weak var shared: StatusItemController?

    var statusItem: NSStatusItem?
    let popover = NSPopover()
    private var popoverHost: NSHostingController<PopoverRootView>?
    /// The popover's own Usage / Tokens selection, kept here so the pin hand-off can read it.
    let popoverTab = SurfaceTabState()
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

    /// WHAT THE LAST DISMISSAL SAW, kept until the click that caused it arrives and spends it.
    ///
    /// A press on the status item dismisses the popover on the mouse-down and delivers the item's
    /// action on the mouse-up, so the two halves are one click and the second has to know about the
    /// first. Spent rather than timed out: a window expires under a press that is merely HELD, and
    /// the release then reopened the popover the press had just shut (codex review of ca32b61).
    /// `TogglePress` states which of these facts decides what.
    private var lastDismissal: (at: Date, pointerOnItem: Bool, buttonDown: Bool)?

    /// Feeding the decoy is watched from the real anchor's own moves AND its own resizes. Two
    /// observers rather than one because they are two notifications, and the second one is not
    /// decoration: the item's width changes under the app's own hand - the waiting dot appears, a
    /// percentage goes from two digits to three - and a strip that grows to the LEFT of a right-hand
    /// edge posts a resize whose move notification may never come.
    private var anchorObservers: [NSObjectProtocol] = []

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
        // down for the toggle (`noteDismissal`).
        _ = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification,
                                                   object: popover, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteDismissal()
                self?.retireDecoyAnchor()
            }
        }

        UsageStore.shared.onChange = { [weak self] in self?.updateButton() }
        // The blocked dot is the one thing on this button that does not come from the quota
        // snapshot, so it needs its own reason to redraw: a session that starts waiting while
        // every window is closed is exactly the case the dot exists for (SessionRosterStore.swift
        // states how it hears about that with nothing open).
        SessionRosterStore.shared.onChange = { [weak self] in self?.updateButton() }
        // Which order the board is in is the user's switch, and the roster READS it rather than
        // holding a copy: the setting is the one answer (`SettingsStore.sessionBoardSortsByState`),
        // and the store is compiled into an assertion harness that has no settings around it.
        SessionRosterStore.shared.sortsByState = { SettingsStore.shared.sessionBoardSortsByState }
        SessionRosterStore.shared.install()
        updateButton()

        // Restore the pinned floating panel if it was pinned when the app last quit.
        if SettingsStore.shared.isUsagePanelPinned {
            PinnedPanelController.shared.show(atTopLeft: nil)
        }
    }

    @objc private func handleClick() {
        guard let button = statusItem?.button else { return }
        // Spent here, once, for whatever kind of click this turns out to be: a dismissal left
        // unspent by a right-click would still be sitting there for the next left one.
        let dismissedByThisClick = consumeDismissalOfThisClick()
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showMenu(from: button)
        } else {
            togglePopover(button: button, afterDismissal: dismissedByThisClick)
        }
    }

    private func togglePopover(button: NSStatusBarButton, afterDismissal: Bool) {
        // While pinned, the floating panel is the usage view; a status-item click just surfaces it
        // rather than opening a competing popover.
        if SettingsStore.shared.isUsagePanelPinned {
            // TO THE DISPLAY THIS CLICK CAME FROM, which the item's own rectangle is what states.
            // Raising it where it was left is not an answer to a summon made from another screen.
            PinnedPanelController.shared.summon(onScreenOf: anchorScreenRect(button: button))
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if afterDismissal {
            // THE CLICK THAT CLOSED IT IS NOT A CLICK THAT OPENS IT. The popover hangs off a decoy
            // now, so the status item is OUTSIDE it and a transient popover dismisses itself on the
            // mouse-down; the action below arrives on the mouse-up and would open it straight back,
            // which reads as a flicker and an item that cannot be toggled shut. While the anchor was
            // the item's own window, NSPopover exempted clicks in it and this could not happen.
        } else {
            // ANCHOR FIRST, FOREGROUND SECOND, and the order is the fix. The anchor has to be the
            // fact the click carried - which display the user pressed the item on - and coming
            // forward is a thing that can CHANGE that fact: activating an app moves the key window
            // to the front, and with a Tally window open on another display the menu bar (and the
            // status item's own window with it) can follow it there. Read afterwards, the item's
            // rectangle is then the one on the display nobody clicked on.
            guard let anchorView = decoyAnchorViewForShow(button: button) else { return }
            takeForegroundForPopover()
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

    /// COME FORWARD FOR THE POPOVER ONLY WHEN NOTHING OF OURS COMES WITH IT.
    ///
    /// Activating is what a popover needs to be typed into - Esc closes it, an account rename has a
    /// text field - and for a menu-bar app with nothing else on screen it costs nothing: there is no
    /// other window of ours for the window server to raise. With a Settings or dashboard window open
    /// it costs exactly the symptom reported on 2026-08-15: glancing at the menu bar dragged a window
    /// the user had left on another display, behind another app, back over the top of it (measured
    /// off the window server's own front-to-back order: Settings went from behind the terminal to in
    /// front of it on one press, and back to leaving it alone once this path stopped activating).
    ///
    /// SO THE CONDITION IS THE PRICE, not a manner. A cheaper-looking fix was tried first and is
    /// recorded here because it looks right: make our own invisible anchor the key window and let
    /// activation raise THAT. It does not work - with the decoy made key first, the same press still
    /// pulled Settings in front of the terminal (measured the same day, same probe) - so "activation
    /// only fronts the key window" is not a lever this app can pull, whatever the reason.
    ///
    /// The case that gives up the foreground is the one where the user has a Tally window open, and
    /// what it gives up is real: the popover opens without the app becoming active, so a keystroke
    /// goes to whatever they were typing in until they click the popover (which activates the app
    /// the ordinary way). That is the right side of the trade - the popover is a thing you look at,
    /// and the window it was moving belongs to something the user was doing.
    private func takeForegroundForPopover() {
        guard !SettingsWindowController.shared.isWindowVisible,
              !MainWindowController.shared.isWindowVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether the click being handled right now is the one that dismissed the popover, SPENDING the
    /// dismissal either way: it can be answered yes at most once, so nothing left over can swallow a
    /// later click.
    private func consumeDismissalOfThisClick() -> Bool {
        guard let dismissal = lastDismissal else { return false }
        lastDismissal = nil
        return TogglePress.suppressesOpen(pointerWasOnItem: dismissal.pointerOnItem,
                                          buttonWasDown: dismissal.buttonDown,
                                          elapsed: Date().timeIntervalSince(dismissal.at))
    }

    /// Record what the dismissal happening right now looks like. Read AT THE CLOSE because that is
    /// when the click is still in flight: a moment later the button may be up and the pointer moved,
    /// and neither fact can be recovered afterwards.
    private func noteDismissal() {
        let onItem = statusItem?.button
            .flatMap { anchorScreenRect(button: $0) }?
            .contains(NSEvent.mouseLocation) ?? false
        lastDismissal = (Date(), onItem, NSEvent.pressedMouseButtons & 1 == 1)
    }

    /// Dismiss the popover when another Tally window takes the stage: that window steals key and
    /// promotes the activation policy, which defeats the transient popover's own click-outside
    /// dismissal and leaves it stuck on screen. No-op when closed, so callers need no condition.
    /// (Its callers are the two window controllers' `show`, which is where the stage is taken.)
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
            // `.fullScreenAuxiliary` for the same reason the pinned panel carries it: without it
            // this window cannot join a full-screen Space, so a popover opened from the menu bar
            // of a full-screen app would have no anchor to be shown against at all.
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
    ///
    /// Moves AND resizes, through the one handler: both are ways the rectangle the decoy stands in
    /// for stops being the rectangle the decoy is at, and `feedDecoyAnchor` compares the whole rect
    /// either way. Watching only moves was an assumption that one event always brings the other -
    /// true for a menu bar laid out from the right, and this file's own history is a list of times
    /// "always" was a display arrangement away from being false.
    private func watchRealAnchor() {
        stopWatchingRealAnchor()
        guard popover.isShown, let window = statusItem?.button?.window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            anchorObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.feedDecoyAnchor() }
            })
        }
    }

    private func stopWatchingRealAnchor() {
        for observer in anchorObservers { NotificationCenter.default.removeObserver(observer) }
        anchorObservers = []
    }

    /// Put the decoy away with the popover, so nothing of ours is left over the menu bar.
    private func retireDecoyAnchor() {
        stopWatchingRealAnchor()
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
    var popoverWindow: NSWindow? { popover.contentViewController?.view.window }

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
}
