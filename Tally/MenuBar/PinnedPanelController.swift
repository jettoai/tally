import AppKit
import SwiftUI

/// A borderless, non-activating floating panel - the pinned form of the usage view. It hosts the same
/// `PopoverRootView` as the transient popover; only one is on screen at a time.
final class PinnedUsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Whether a panel is being carried by hand right this moment, and the moment it is set down.
///
/// The surface re-reads its own height cap on every move notification, because that cap depends on
/// where its top edge is (`PopoverRootView.refreshScreenCap`) - which is the right answer to ask,
/// at the wrong rate: `performDrag` posts a move for every frame of the gesture, so a panel carried
/// down its display, or across to one of another size, was resized under the hand dozens of times
/// on the way (measured 2026-08-07: 532 -> 476 -> 417 -> 347 -> 320 in a single downward drag). The
/// window server is moving the window while the layout is changing its size, and what a hand feels
/// is the two of them arguing.
///
/// So the cap is not re-read during the carry, and is re-read once when it ends. `performDrag` runs
/// its own event loop and returns when the mouse comes up, which is what makes "the carry" a span
/// this code can name at all - no timer, no guessing, and no notification AppKit does not have.
@MainActor
enum PanelDrag {
    /// Whether the panel is being carried RIGHT NOW. Both halves are load-bearing: the flag says a
    /// drag was started, and the button says the hand has not let go yet. The second one is what
    /// makes this safe to read - if the watcher below were ever lost, the cap would resume the
    /// moment the button came up rather than staying frozen for the life of the process.
    static var isActive: Bool {
        PanelCarry.inProgress(started: carrying, buttonsDown: NSEvent.pressedMouseButtons)
    }

    /// Posted once, when the hand lets go.
    static let ended = Notification.Name("TallyPanelDragEnded")

    private static var carrying = false
    private static var release: Timer?

    /// Runs a drag, with everything that watches window moves told to wait until it is over.
    ///
    /// `performDrag` RETURNS AT ONCE - it hands the window to AppKit, which carries it from there
    /// (measured 2026-08-07: the call's entry and exit share a timestamp, which is why a span
    /// written around the call alone covered none of the drag). AppKit posts no notification for
    /// the moment a hand lets go either, so the release is watched for directly, at a rate that is
    /// nothing beside the drag it runs during and that stops the moment it answers.
    static func carry(_ drag: () -> Void) {
        carrying = true
        drag()
        release?.invalidate()
        release = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                release?.invalidate()
                release = nil
                carrying = false
                NotificationCenter.default.post(name: ended, object: nil)
            }
        }
    }
}

/// The pinned panel's window-move handle: an AppKit view that hands a press to `NSWindow.performDrag`
/// so a borderless panel can be moved by the parts of itself that are not controls. This is the
/// counterpart to `isMovableByWindowBackground = false` - an explicit drag region can never collide
/// with the cards' reorder gesture. Inert inside the transient popover (that window must stay
/// anchored).
///
/// LAID OVER THE CONTENT, NEVER BEHIND IT, and that is the whole lesson of 2026-08-07: mounted as a
/// `.background` this view is never sent a mouse-down at all. The hosting view answers the hit test
/// for its own SwiftUI content and nothing below it is consulted, so a wordmark, a clock and a whole
/// panel background that all "had" a drag layer behind them were dead to the pointer (measured on the dev
/// instance: four such regions, zero movement; the one region with this view on TOP moved every
/// time). Reading the code, or the docs, said the opposite.
///
/// Two shapes, one class:
///
/// - `onTap == nil` - the region has no click of its own (the wordmark, the clock, the empty run
///   beside a strip). A press moves the window at once, which is the whole of the feel: nothing is
///   waiting to find out what the press meant.
/// - `onTap != nil` - the region IS a control (a tab, the refresh, the update badge). The press is
///   held just long enough to tell a click from a move, and then commits to exactly one
///   (`PointerIntent`). The two outcomes are exclusive BY STRUCTURE, not by a flag: the loop returns
///   on the pass that decides, so no press can move the window and also fire the control under it.
///
/// Inert everywhere but the pinned panel: nothing about the transient popover may change, and a
/// window anchored to a status item cannot be moved anyway. `hitTest` answering nil there leaves
/// whatever is underneath with the plain SwiftUI behaviour it has always had, pointer tracking
/// included.
struct DragOrTapArea: NSViewRepresentable {
    /// What a press that never travelled should do, or nil when this region has no click to protect.
    /// Stated by the caller, so this view knows nothing about tabs, refreshing or wordmarks.
    let onTap: (() -> Void)?

    final class HandleView: NSView {
        var onTap: (() -> Void)?

        // As on the plain drag area: a borderless panel that is not focused would otherwise spend
        // the first click on focus handling, and this one sits on controls that people click.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Transparent to the pointer on any window that is not the pinned panel, which is what
        /// makes this safe to leave on a control that also lives in the popover.
        override func hitTest(_ point: NSPoint) -> NSView? {
            window is PinnedUsagePanel ? super.hitTest(point) : nil
        }

        override func mouseDown(with event: NSEvent) {
            guard let panel = window as? PinnedUsagePanel else {
                return super.mouseDown(with: event)
            }
            // Nothing here to click, so nothing to wait for: the press is a move from its first
            // frame. A region that had to prove itself over a few points first would feel like a
            // window that starts late, which is what every titlebar in the system does not do.
            guard let onTap else { return PanelDrag.carry { panel.performDrag(with: event) } }
            let start = event.locationInWindow
            // Peek at the press as it unfolds. No deadline and no timer: the loop only ever waits
            // for the pointer to move or the button to come up, so a press that does neither is
            // still sitting on a control that has not decided anything yet.
            while let next = panel.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                let intent = PointerIntent.dragOrTap(from: start, to: next.locationInWindow)
                if next.type == .leftMouseUp {
                    if intent == .tap { onTap() }
                    return
                }

                if intent == .drag {
                    // Handed the MOUSE-DOWN, which is what `performDrag` is documented to take: it
                    // reads the gesture's origin off that event and tracks the pointer from there.
                    // Passing the drag event that happened to cross the threshold instead does move
                    // the window on this system, but on an undocumented reading of an event type
                    // the contract does not name - and the price of the documented one is only that
                    // the panel takes up the slop travelled so far on the first frame, a few points
                    // at the moment a hand has already committed to moving something.
                    PanelDrag.carry { panel.performDrag(with: event) }
                    return
                }
            }
        }
    }

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onTap = onTap
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) { nsView.onTap = onTap }
}

extension View {
    /// This region moves the pinned panel, from the first frame of the press. For the parts of the
    /// surface that are not controls: the wordmark and its badges, the clock, the empty run beside a
    /// strip. An OVERLAY, because a drag layer mounted behind SwiftUI content is never sent the
    /// press at all (see `DragOrTapArea`) - which is exactly how four regions came to be advertised
    /// as draggable while being dead to the pointer.
    func windowDragSurface() -> some View {
        overlay(DragOrTapArea(onTap: nil))
    }

    /// This control moves the pinned panel when the press travels, and does `onTap` when it does
    /// not. For the regions that have a click worth protecting: the tab switch, the refresh, the
    /// update badge.
    ///
    /// - Parameter enabled: off leaves the view exactly as it was, for the copies of a shared
    ///   control that are not sitting in a drag strip.
    func windowDragOrTap(enabled: Bool = true, _ onTap: @escaping () -> Void) -> some View {
        overlay { if enabled { DragOrTapArea(onTap: onTap) } }
    }
}

/// The pinned panel's base surface. Glass mode shows the desktop through behind-window vibrancy -
/// SwiftUI's `Material` only samples in-app content, so this must be an `NSVisualEffectView` with
/// `.behindWindow`, and it carries its own rounded mask because the window server composites the blur
/// without honoring the SwiftUI clip shape. Accessibility's Reduce Transparency is a need, not a
/// preference: it clamps the surface to solid regardless of the user's glass setting.
/// The surface a borderless panel draws under its content: the glass the user asked for, or a
/// plain window background when they did not (or when the system says no to transparency). Shared
/// with the pick panel, which is borderless for the same reason and must not invent a second look.
struct PanelBackdrop: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        if settings.isPanelTranslucent,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            GlassBackdrop()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct GlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.roundedMask(cornerRadius: 12)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded-corner mask (9-slice) so the blur region itself gets rounded corners.
    private static func roundedMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                       bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}

/// Owns the pinned floating panel. Separate from the popover so the transient popover keeps working
/// untouched; pinning just hands its content off to this always-on-top window.
///
/// Its size comes from its content and nowhere else - `sizingOptions = []`, the measured size in,
/// one anchored frame write out. That whole contract lives in `SurfaceSizer`, which the dashboard
/// window follows too; what is left here is what is actually this panel's own (floating, borderless,
/// drag-by-header, glass backdrop).
@MainActor
final class PinnedPanelController {
    static let shared = PinnedPanelController()

    private var panel: PinnedUsagePanel?
    /// The panel's own Usage / Tokens selection, seeded by the pin hand-off (see `show`).
    private let surfaceTab = SurfaceTabState()
    /// Owns everything about how big this panel is and where a resize leaves it (`SurfaceSizer`).
    private var sizer: SurfaceSizer?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The view the panel is showing, for the hand-off back out of the panel: the dashboard window
    /// reads it as it retires the panel (see `MainWindowController.show`). Nil while the panel is off
    /// screen, the same shape as the position half of this hand-off (`MainWindowController
    /// .contentTopLeft`), so a caller cannot accidentally seed itself from a surface nobody is looking
    /// at. Read-only: `show(atTopLeft:showing:)` stays the only seam that writes this selection.
    var visibleTab: SurfaceTab? { isVisible ? surfaceTab.tab : nil }

    /// Where the panel is on screen, the position half of that same hand-off back out of the panel:
    /// the dashboard window opens exactly where the panel stood instead of jumping to the pointer's
    /// screen (see `MainWindowController.show`). Nil while the panel is off screen, so a caller
    /// cannot inherit a position nobody is looking at. Read-only, like `visibleTab`: the panel's own
    /// placement stays owned by `show(atTopLeft:showing:)` and the user's drags.
    var visibleContentTopLeft: CGPoint? { isVisible ? panel?.contentTopLeft : nil }

    /// Show the panel. When `topLeft` is given (the pin hand-off from the popover or the window),
    /// open there and on the view that surface was showing; otherwise reuse the autosaved frame and
    /// whatever the panel was last left on (launch restore / re-show). The size is driven by the
    /// content's measured size (`SurfaceSizer`), so placing by TOP LEFT is safe before it arrives:
    /// that is the corner a content-driven resize holds anyway.
    func show(atTopLeft topLeft: CGPoint?, showing tab: SurfaceTab? = nil) {
        if let tab { surfaceTab.tab = tab }
        let panel = panel ?? makePanel()
        self.panel = panel
        if let topLeft { panel.setFrameTopLeftPoint(topLeft) }
        panel.clampOnScreen()
        panel.makeKeyAndOrderFront(nil)
        // Nothing should start focused, the same rule `SettingsWindowController.bringToFrontIfVisible`
        // enforces: SwiftUI seeds focus into the first focusable view as the window becomes key, so a
        // panel the user merely pinned came up wearing a focus ring nobody asked for (and Tab, starting
        // from there, could only walk away from the tab switch). Only on the way in, not in
        // `summon(onScreenOf:)`: raising a panel already on screen must keep focus a keyboard user placed.
        panel.makeFirstResponder(nil)
    }

    /// SUMMON THE PANEL TO THE DISPLAY THE CLICK CAME FROM, then raise it.
    ///
    /// The status item is the panel's only summon while it is pinned, and raising alone was not an
    /// answer to it: on several displays the panel sat wherever it was last dropped, so a click on
    /// one screen surfaced it on another (reported 2026-08-15). `anchor` is the item's own rectangle,
    /// which is what says which display that is; nil (an item with no window yet) leaves the panel
    /// where it is rather than guessing.
    ///
    /// Three things go wrong on this path and all three are fixed by it being one path: a panel that
    /// does not exist yet is SHOWN rather than silently doing nothing (`panel?.` was an optional
    /// chain, so a click on the item was a no-op with no feedback at all); a panel left on a display
    /// that has since been unplugged or resized is put back on screen, which raising alone never did;
    /// and the move itself writes an ORIGIN and nothing else - the size of this surface has exactly
    /// one authority and it is not this file (`SurfaceSizer`).
    ///
    /// First responder is deliberately left alone, unlike `show`: raising a panel already on screen
    /// must keep the focus a keyboard user placed in it.
    func summon(onScreenOf anchor: CGRect?) {
        guard let panel else { return show(atTopLeft: nil) }
        if let topLeft = StatusAnchor.summonTopLeft(panel: panel.frame, towards: anchor,
                                                    displays: NSScreen.displays) {
            panel.setFrameTopLeftPoint(topLeft)
        }
        panel.clampOnScreen()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> PinnedUsagePanel {
        let panel = PinnedUsagePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating                                    // above normal app windows, below system UI
        panel.hidesOnDeactivate = false                            // stay put when Tally isn't frontmost
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // visible across Spaces + over full-screen apps
        panel.isMovable = true
        // NOT movable-by-background: SwiftUI drag gestures don't opt a region out of AppKit's
        // background window drag, so dragging a card to reorder also dragged the whole panel.
        // Moving the panel is the named grab areas' job instead (`DragOrTapArea`).
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        // Borderless panels have no chrome, so the content supplies its own rounded surface (the
        // popover got this from NSPopover). Same PopoverRootView, same shared stores - and the same
        // sizing contract as the dashboard window, which is why none of it is written here: how big
        // this panel gets, which corner a resize holds, and putting it back on a screen afterwards
        // all belong to `SurfaceSizer`. The panel is a fixture the user placed, so the display it
        // fits is its own (not the menu bar's), and it grows downward from where it was dragged, so
        // its cap depends on its own top edge - both of those the sizer answers from the panel.
        sizer = SurfaceSizer(window: panel, host: .panel,
                             autosaveName: "TallyPinnedUsagePanel",
                             acceptsFirstMouse: true) { sizer in
            AnyView(
                PopoverRootView(store: .shared, settings: .shared,
                                onContentSize: sizer.onContentSize,
                                onViewOptionsPresented: sizer.onViewOptionsPresented,
                                hostScreen: sizer.screen,
                                hostTopEdge: sizer.topEdge,
                                tabState: surfaceTab, host: sizer.host)
                    .background(PanelBackdrop(settings: .shared))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        }
        return panel
    }
}
