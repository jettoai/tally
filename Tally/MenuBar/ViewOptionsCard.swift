import AppKit
import SwiftUI

/// THE VIEW-OPTIONS CARD AS A WINDOW OF ITS OWN, put where the screen says when it opens and left
/// there until it goes.
///
/// It was an `NSPopover` attached to the footer button, and an attached presentation cannot hold
/// still: every control on the card resizes the surface behind it, and a surface that holds its top
/// left moves its own footer by the whole height change - so the card, and the tile under the
/// pointer, travelled on every click. Holding the surface's bottom right instead kept the tile still
/// by walking the panel away and jumping it back when the card closed, which is the movement that
/// was actually being reported (Albert, 2026-08-17 / 08-18). Owning the window is what makes "the
/// card does not move" expressible at all: it is placed once from where the button was, in screen
/// space, and nothing observes the surface afterwards.
///
/// WHAT MAKES IT STILL FEEL LIKE A POPOVER is here rather than free: a press anywhere else puts it
/// away, Escape puts it away, and the surface going away takes it with it. The first of those is
/// also the one behaviour that is deliberately MORE than a popover's - a press on one of the panel's
/// drag regions dismisses the card and carries the window from the same press, because the card is
/// beside those regions rather than over them and waiting for a second press would read as a stuck
/// window.
///
/// NOT DISMISSED ON LOSING KEY, which is how a popover does it and how this one must not: an
/// accessory app's panel is handed the key window and can have it taken straight back while the
/// activation request settles, so that reading fires before anybody has seen anything
/// (~/.claude/docs/patterns/swiftui-appkit.md, paid for by the pick panel in 2026-08-09). The press
/// monitors below answer the same question by watching for the press itself, which is an event that
/// only happens when somebody makes it happen.
@MainActor
final class ViewOptionsCard {
    static let shared = ViewOptionsCard()

    /// Everything a card that is up consists of, in ONE optional rather than four fields that have
    /// to be cleared together - which is the shape of bookkeeping this change exists to retire.
    private struct Presentation {
        let panel: ViewOptionsCardPanel
        /// Whose card this is, so a second surface opening one closes the first and a host tearing
        /// down cannot dismiss the card belonging to the other window on screen.
        let host: SurfaceHost
        /// Where the button that opened it is RIGHT NOW, asked at every press: the surface resizes
        /// while the card is up, and the footer the button sits in moves with it.
        let toggle: () -> CGRect?
        /// Told to the surface when the card goes by any route other than its own toggle, so the
        /// button it came from stops reading as lit.
        let onDismiss: () -> Void
        var monitors: [Any] = []
    }

    private var presentation: Presentation?

    /// Put the card up for `host`, standing on the button `anchor` describes.
    ///
    /// - Parameter content: built fresh here rather than handed a rendered view, and evaluated
    ///   inside a body (`CardBody`) rather than at the call: the card's own controls change what the
    ///   card shows (the density switch changes how many column tiles there are, the gauge switch
    ///   greys the rows under it), and only reads made during a body pass are observed.
    func present(host: SurfaceHost, anchor: ViewOptionsAnchor,
                 content: @escaping () -> AnyView, onDismiss: @escaping () -> Void) {
        dismiss()
        guard let hostWindow = anchor.hostWindow, let anchorRect = anchor.screenRect else { return }
        let panel = ViewOptionsCardPanel(contentRect: .zero,
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Just above the surface it belongs to, rather than at a level of its own: the pinned panel
        // floats and the dashboard window does not, and a card that picked one absolute level would
        // be under its own surface in one case or over every other app's windows in the other.
        panel.level = NSWindow.Level(rawValue: hostWindow.level.rawValue + 1)
        // And on the same Spaces, for the same reason: the pinned panel joins them all, so a card
        // that did not would be left behind the moment its surface was looked at somewhere else.
        panel.collectionBehavior = hostWindow.collectionBehavior
        panel.onCancel = { [weak self] in self?.dismissAndReport() }
        let hosting = CardHostingView(rootView: CardBody(content: content))
        // ONE SIZE AUTHORITY, and it is this one: the card is the size its content lays out at, and
        // the frame written below is placement only (~/.claude/docs/patterns/swiftui-appkit.md - a
        // second authority is the stack overflow the pinned panel already paid for). Reading
        // `fittingSize` is what needs `.intrinsicContentSize` rather than `[]`, which answers zero.
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let visible = (hostWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        panel.setFrame(ViewOptionsCardPlacement.frame(size: hosting.fittingSize, anchor: anchorRect,
                                                      visible: visible),
                       display: false)
        // FROM HERE THE BOTTOM EDGE IS THE ONE THAT STAYS (`ViewOptionsCardPanel.setFrame`), armed
        // after the placement for the reason the pick panel arms its own after one: everything
        // before this line is the panel getting its first size at all.
        panel.holdsBottomEdge = true
        panel.makeKeyAndOrderFront(nil)
        presentation = Presentation(panel: panel, host: host,
                                    toggle: { [weak anchor] in anchor?.screenRect },
                                    onDismiss: onDismiss)
        presentation?.monitors = watchForPresses()
    }

    /// Take the card down on behalf of the surface that put it up. A no-op for any other host, so
    /// the popover closing behind its own footer cannot take away the panel's card.
    func dismiss(host: SurfaceHost) {
        guard presentation?.host == host else { return }
        dismiss()
    }

    /// Take it down whoever it belongs to. Private, so `dismiss(host:)` above is the only way in
    /// from outside: an unguarded take-down is exactly how one surface would close the other's card.
    private func dismiss() {
        guard let card = presentation else { return }
        presentation = nil
        for monitor in card.monitors { NSEvent.removeMonitor(monitor) }
        card.panel.orderOut(nil)
    }

    private func dismissAndReport() {
        let report = presentation?.onDismiss
        dismiss()
        report?()
    }

    /// The two monitors that make a press elsewhere put the card away, and Escape with them.
    ///
    /// THE PRESS IS PASSED ON UNCHANGED, which is the whole of the drag behaviour: the monitor runs
    /// before the event reaches the window, so the card is gone by the time the panel's drag region
    /// receives the very same press and starts carrying the window from it. Swallowing it would cost
    /// a click, and dismissing afterwards would let the press through to a card that was still up.
    private func watchForPresses() -> [Any] {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let local = NSEvent.addLocalMonitorForEvents(matching: mouse.union(.keyDown),
                                                     handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                // 53 is Escape. Swallowed, because a key that closed the card must not also reach
                // whatever is behind it.
                guard event.keyCode == 53 else { return event }
                self.dismissAndReport()
                return nil
            }
            if self.dismisses(pressAt: NSEvent.mouseLocation) { self.dismissAndReport() }
            return event
        })
        // And a press in another app, which the local monitor never sees. Nothing to return: an
        // event belonging to somebody else is only ever observed here.
        let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.dismisses(pressAt: NSEvent.mouseLocation) { self.dismissAndReport() }
            }
        })
        return [local, global].compactMap { $0 }
    }

    private func dismisses(pressAt point: CGPoint) -> Bool {
        guard let card = presentation else { return false }
        return ViewOptionsCardPlacement.dismisses(press: point, card: card.panel.frame,
                                                  toggle: card.toggle())
    }
}

/// The card's window. Key, because the controls on it are clicked and typed at; never main, like
/// every other panel here.
final class ViewOptionsCardPanel: NSPanel {
    var onCancel: (() -> Void)?

    /// Whether a change of SIZE keeps the bottom edge where it is. Off until the card has been
    /// placed, because before that its frame is the zero rect it was created with.
    var holdsBottomEdge = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// THE BOTTOM EDGE IS WHAT STAYS when the card's own content changes size - switching density
    /// changes how many column tiles the picker offers - so the card grows UPWARD, away from the
    /// button it stands on and away from the pointer that is on it. AppKit's own answer is the
    /// opposite (a constraint-driven resize holds the top left, measured on the pick panel,
    /// 2026-08-11), which would push the card down over the control that opened it.
    ///
    /// ORIGIN ONLY, so the size authority is still `sizingOptions` alone: the size in this write is
    /// AppKit's, passed through byte for byte (~/.claude/docs/patterns/swiftui-appkit.md).
    override func setFrame(_ frameRect: NSRect, display displays: Bool) {
        guard holdsBottomEdge, frameRect.size != frame.size else {
            super.setFrame(frameRect, display: displays)
            return
        }
        var held = frameRect
        held.origin = frame.origin
        super.setFrame(held, display: displays)
    }

    /// Escape, at the AppKit level as well as through the press monitor, for the case where this
    /// panel has the keyboard and the key event never reaches a monitor.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The hosting view the card is built on. Both overrides are the pinned panel's, for its reason: a
/// non-activating panel's first click would otherwise be spent on focus, and SwiftUI only tracks a
/// gesture in the KEY window.
private final class CardHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let window, !window.isKeyWindow { window.makeKey() }
        super.mouseDown(with: event)
    }
}

/// The card's content, built inside a body so that everything it reads is observed. Handed a closure
/// rather than a view because the card is assembled from the surface it belongs to
/// (`PopoverRootView.viewOptions`), whose computed properties would otherwise be read once, at the
/// moment the card opened, and never again.
///
/// AND THE SURFACE IT IS DRAWN ON, which a popover used to supply: an `NSPopover` brings its own
/// material, border and corner, and a borderless panel brings nothing at all - measured on the dev
/// instance, the card came up as white text on the desktop with no background behind it. It is the
/// backdrop the pinned panel and the pick panel already draw, for the reason they share it: three
/// borderless surfaces of the same app must not invent three looks.
private struct CardBody: View {
    let content: () -> AnyView

    var body: some View {
        content()
            .background(PanelBackdrop(settings: .shared))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// WHERE THE BUTTON THAT OPENS THE CARD IS, ON SCREEN, ASKED WHEN IT IS ASKED.
///
/// A box rather than a piece of view state: the answer is read at moments SwiftUI is not driving
/// (the press monitor above), and writing a rect into `@State` from an AppKit layout pass is the
/// re-entrancy this app does not need. Held weakly, so a footer that has gone leaves this answering
/// nil rather than pointing at a view nobody is drawing.
@MainActor
final class ViewOptionsAnchor {
    fileprivate weak var view: NSView?

    var hostWindow: NSWindow? { view?.window }

    var screenRect: CGRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// Mounts that box on the button. A BACKGROUND, which is exactly where a view that must never take
/// a press belongs: the hosting view answers the hit test for its own SwiftUI content and never
/// consults what is below it (`DragOrTapArea`, measured 2026-08-07), and `hitTest` says so anyway.
private struct ViewOptionsAnchorProbe: NSViewRepresentable {
    let anchor: ViewOptionsAnchor

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Marks this view as the thing the view-options card stands on and comes back to.
    func viewOptionsAnchor(_ anchor: ViewOptionsAnchor) -> some View {
        background(ViewOptionsAnchorProbe(anchor: anchor))
    }
}
