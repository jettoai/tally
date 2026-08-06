import AppKit
import SwiftUI

/// A borderless, non-activating floating panel - the pinned form of the usage view. It hosts the same
/// `PopoverRootView` as the transient popover; only one is on screen at a time.
final class PinnedUsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The pinned panel's window-move handle: an AppKit view that hands its mouse-down to
/// `NSWindow.performDrag`, giving the header strip (and nothing else) window-moving duty. This is the
/// counterpart to `isMovableByWindowBackground = false` - an explicit drag region can never collide
/// with the cards' reorder gesture. Inert inside the transient popover (that window must stay anchored).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        // Titled windows get background-drag for free; a borderless panel's custom drag region must
        // accept the first mouse, or a click while the panel is unfocused is consumed by focus
        // handling and the user needs a wake-up click before the header will drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if window is PinnedUsagePanel {
                window?.performDrag(with: event)
            } else {
                super.mouseDown(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// The same window-move duty for a spot that is ALREADY a control: the tab switch and the refresh
/// button, the two things sitting in the middle of the header's grab strip. `WindowDragArea` cannot
/// be laid over them, because a view that hands every mouse-down to `performDrag` eats the click as
/// well - so this one keeps the press to itself only long enough to find out which it was, and then
/// commits to exactly one (`PointerIntent`).
///
/// The two outcomes are exclusive BY STRUCTURE, not by a flag: the loop below returns on the pass
/// that decides, so there is no path on which a window moves and the tab under it also changes.
///
/// Inert everywhere but the pinned panel, by the same rule `WindowDragArea` follows and for the same
/// reason: nothing about the transient popover may change, and a window that is anchored to a status
/// item cannot be moved anyway. `hitTest` answering nil there leaves the control underneath with the
/// plain SwiftUI behaviour it has always had, pointer tracking included.
struct DragOrTapArea: NSViewRepresentable {
    /// What a press that never travelled should do: the control's own action, stated by the caller
    /// so this view knows nothing about tabs or refreshing.
    let onTap: () -> Void

    final class HandleView: NSView {
        var onTap: () -> Void = {}

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
                    panel.performDrag(with: event)
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
    /// Let this control move the pinned panel when the press travels, and do `onTap` when it does
    /// not. An overlay rather than a background: the press has to be intercepted before the control
    /// under it sees it, which is the opposite of what `WindowDragArea` is for.
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
private struct PanelBackdrop: View {
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
        // `bringToFront()`: raising a panel already on screen must keep focus a keyboard user placed.
        panel.makeFirstResponder(nil)
    }

    func bringToFront() { panel?.makeKeyAndOrderFront(nil) }

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
        // Moving the panel is the header strip's job instead (`WindowDragArea`).
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
                                hostScreen: sizer.screen,
                                hostTopEdge: sizer.topEdge,
                                tabState: surfaceTab, host: sizer.host)
                    .background(PanelBackdrop(settings: .shared))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        }
        return panel
    }
}
