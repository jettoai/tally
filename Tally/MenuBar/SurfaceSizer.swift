import AppKit
import SwiftUI

/// The measured-sizing contract for a window whose SwiftUI content decides how big it is, stated
/// once for every host that follows it.
///
/// The contract has five parts and they only work together:
///
/// 1. `sizingOptions = []` on the hosting view, so SwiftUI installs NO Auto Layout constraints.
///    Two size authorities (constraints AND a manual frame write) recurse the layout engine into a
///    stack overflow, which this app has already paid for once (2026-07-16, the pinned panel).
/// 2. The content reports the size it actually laid out at (`PopoverRootView.onContentSize`).
///    Measuring the rendered size beats asking `sizeThatFits`, which answers an unbounded proposal
///    with a screen-tall height.
/// 3. That size is written back one run-loop turn later, so a window is never resized from inside
///    the SwiftUI update that measured it.
/// 4. The write holds a corner still (`ResizeAnchor`, `SettingsStore.resizeAnchor(for:)`) rather
///    than letting AppKit keep the bottom edge, which would drop the whole view - and the row just
///    clicked - by the height difference.
/// 5. Whatever the resize ends up as, the surface is put back on a screen (`clampOnScreen`) and the
///    edges the NEXT resize anchors against are re-read. A size change posts no move notification,
///    so nothing else refreshes them.
///
/// It lives in one object because it now has two users, and this battle's repeated lesson is that
/// an invariant produced by two separately maintained copies of the same code drifts: the two cards
/// whose number columns were "aligned" by two `HStack`s with different spacings (2pt apart), and
/// the anchor rule that enumerated the reading region's controls and missed three of them. A second
/// user is the moment to share the implementation, not the moment to copy it.
///
/// Its owner has to be the controller. Everything this hands out - the three callbacks, both
/// notification observers - captures it weakly, so nothing else keeps it alive, and a surface whose
/// sizer was released would simply stop following its content.
///
/// Not the popover. `NSPopover` is placed by AppKit against the status item's arrow and has no
/// frame of its own to write, so `StatusItemController.applyPopoverSize` writes a content SIZE and
/// nothing else. It shares what is genuinely common (the `sizingOptions = []` rule, and
/// `ResizeAnchor.needsResize` through the same store answer) and none of what is not.
@MainActor
final class SurfaceSizer {
    /// Which surface this is, for the questions whose answer depends on it (the resize anchor).
    let host: SurfaceHost

    /// Held weakly: the window owns its content view, the content view owns this object through
    /// the callbacks below, and a strong reference back would close that loop. The controllers
    /// keep their windows alive for the life of the app anyway.
    private weak var window: NSWindow?

    /// The last size the content reported, applied by `sizeNow()` a run-loop turn later. Kept
    /// rather than passed through so that a host being opened can apply the pending measurement on
    /// the spot (see `MainWindowController.show`).
    private var reported: CGSize?

    /// The edges a content-driven resize puts back, refreshed after every resize AND every move: a
    /// move is the last position the user chose, a resize is the shape they now have to be put
    /// back to, and only the pair covers it.
    private var anchorEdges: ResizeAnchor.Edges?

    /// The corner that came with the last measurement, and how long it answers for
    /// (`ResizeAnchor.Hold`). Read rather than asked again, because asking again is asking a
    /// question whose answer can have changed in between: one click both switches a tab and
    /// dismisses the card, and the two readings a run-loop turn apart then place the content
    /// against one corner and write the frame to the other.
    private var hold = ResizeAnchor.Hold()

    /// The surface's edges at the moment the view-options card was opened here, and nil whenever
    /// there is no card up to give anything back.
    ///
    /// NOT INVALIDATED BY A MOVE, and that is a statement about the card rather than an oversight:
    /// it is a transient popover, so a press anywhere else on the surface dismisses it, and the
    /// dismissal is what runs first. A hand cannot carry a panel that still has this card open, and
    /// a press that did both would settle the debt and then be carried from wherever the put-back
    /// left it - which is the same place the hand grabbed.
    private var cardEdges: ResizeAnchor.Edges?

    /// Work that cannot be done until this surface has a real size: placing a window being opened,
    /// and revealing it. Both read the size, and under this contract the size arrives a run-loop
    /// turn after the surface is built, so doing either on the spot works off the placeholder - a
    /// window centred around it and then grown away from where it was centred, or shown at it and
    /// then jumped (see `MainWindowController.show`).
    private var awaitingSize: [(NSWindow) -> Void] = []

    /// What a surface is born with, replaced by the first measurement a run-loop turn later. A
    /// window with no constraints and no frame of its own would otherwise open at nothing at all.
    private static let placeholderSize = CGSize(width: 500, height: 400)

    /// Take over `window`'s size: install `content` as its only content, with no sizing
    /// constraints, and start following what that content reports.
    ///
    /// - Parameter autosaveName: the frame this surface comes back to (position across launches;
    ///   the size is re-derived from the content). Applied here rather than by the caller because
    ///   restoring a frame IS a resize, and the anchor edges read below have to be the restored
    ///   ones, not the placeholder's.
    /// - Parameter acceptsFirstMouse: for a surface that is not the active window and must react to
    ///   the very first click anyway (the floating panel: macOS utility panels are expected to, and
    ///   without it dragging a card needed a wake-up click). Off for ordinary windows, where a
    ///   first click legitimately just activates.
    /// - Parameter content: built here, given this object, so the three questions the surface asks
    ///   its host are answered from the one place that knows them.
    init<Content: View>(window: NSWindow, host: SurfaceHost, autosaveName: String,
                        acceptsFirstMouse: Bool = false,
                        content: (SurfaceSizer) -> Content) {
        self.window = window
        self.host = host
        let view = MeasuredHostingView(rootView: content(self))
        view.wantsFirstMouse = acceptsFirstMouse
        // The single statement of part 1. Not `.preferredContentSize`, not the default
        // `.standardBounds`: both install constraints that would fight every frame written below.
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.setContentSize(Self.placeholderSize)
        window.setFrameAutosaveName(autosaveName)
        anchorEdges = window.resizeEdges
        observe(window)
    }

    /// Which corner has to stay still through the resize being applied: the one the content told us
    /// it laid itself out against, and the store's live answer only before any content has spoken.
    ///
    /// ONE READING PER RESIZE, and how long that reading lasts is `ResizeAnchor.Hold`'s to say:
    /// this object only supplies the live answer for the passes where no measurement is in flight.
    var corner: ResizeAnchor.Corner {
        hold.corner(live: SettingsStore.shared.resizeAnchor(for: host))
    }

    // MARK: - What the surface asks its host

    /// Part 2 of the contract, wired for `PopoverRootView.onContentSize`. The corner travels with
    /// the size because it was read in the same body pass that produced it (see `corner`).
    var onContentSize: (CGSize, ResizeAnchor.Corner) -> Void {
        { [weak self] size, corner in self?.contentReported(size, corner: corner) }
    }

    /// The view-options card being presented or dismissed on this surface
    /// (`PopoverFooterView.viewOptions`). Wired per host rather than broadcast, because it is the
    /// host's own window that has something to give back: while the card is up the surface holds
    /// its bottom right and walks its top left away with every click, and the debt is settled here
    /// when the card goes (`ResizeAnchor.restoredOrigin`).
    var onViewOptionsPresented: (Bool) -> Void {
        { [weak self] open in self?.viewOptionsPresented(open) }
    }

    /// The display this surface is on, asked of the window rather than assumed: a panel sits
    /// wherever it was dragged and a window on whichever display it was summoned to, and the cap
    /// the content applies has to be that screen's.
    var screen: () -> NSScreen? { { [weak self] in self?.window?.screen } }

    /// Where this surface's content starts on screen, for the position-aware half of that cap
    /// (`ScreenFitStack.maxHeight(on:topEdge:)`). Both surfaces here keep their top left as they
    /// grow, so the room they actually have is the room below their own top edge.
    ///
    /// The CONTENT's top edge, not the frame's: a titled window's chrome is above it, and counting
    /// the titlebar as room the content can grow into is a titlebar's worth of overflow.
    var topEdge: () -> CGFloat? { { [weak self] in self?.window?.contentTopLeft.y } }

    // MARK: - Writing the frame

    private func contentReported(_ size: CGSize, corner: ResizeAnchor.Corner) {
        reported = size
        hold.reported(corner)
        // Part 3: out of the SwiftUI update that produced this number before touching the window.
        DispatchQueue.main.async { [weak self] in self?.sizeNow() }
    }

    /// Remember where the card found this surface, and put it back when the card goes.
    ///
    /// The record is taken at OPENING rather than at the first click inside the card: opening it
    /// resizes nothing, so that moment is the last one the user is unambiguously still looking at
    /// the surface they arranged. Closing settles whatever the clicks in between spent, in one move
    /// - the individual resizes must keep holding the bottom right, which is the only reason the
    /// controls stay under the pointer.
    ///
    /// The height is NOT put back: what the card changed is what the surface is now showing, and a
    /// surface that sprang back to its old height would have thrown the change away. Only the top
    /// left goes home, which is where the reading was (`ResizeAnchor.restoredOrigin`).
    private func viewOptionsPresented(_ open: Bool) {
        guard let window else { return }
        if open {
            cardEdges = window.resizeEdges
            return
        }
        // Cleared whatever happens below, so a card that closed with nothing to give back cannot
        // leave a position behind for the next one to be put back to.
        defer { cardEdges = nil }
        let plan = ResizeAnchor.restitution(for: window.frame, to: cardEdges,
                                            isVisible: window.isVisible)
        guard let origin = plan.origin else { return }
        window.setFrameOrigin(origin)
        // The put-back can land a surface that grew while the card was open off the display it was
        // on, so it ends the way every other frame write here does.
        if plan.clampsOnScreen { window.clampOnScreen() }
        anchorEdges = window.resizeEdges
    }

    /// Apply the last reported size, and any placement waiting on one. Public so a host that is
    /// being opened can flush the measurement it just forced (a window is placed and ordered front
    /// in one call, and both need the real size); a no-op when nothing has been reported yet or
    /// the size is already right.
    func sizeNow() {
        guard let window else { return }
        // Whatever this call decides, the measurement that scheduled it has now been acted on. A
        // corner that outlives that is a corner answering for a resize nobody is going to see.
        var wroteFrame = false
        defer { hold.applied(wroteFrame: wroteFrame) }
        guard let content = reported,
              content.width.isFinite, content.height.isFinite,
              content.width > 1, content.height > 1 else { return }
        // What the content reports is a CONTENT size; what a window owns is a frame. For the
        // borderless panel those are the same rectangle, and for the titled window they differ by
        // the chrome - a constant offset, which is what lets everything below stay frame
        // arithmetic: holding the frame's top edge holds the content's top edge with it, and the
        // bottom and right edges are shared outright.
        let target = window.frameRect(forContentRect: CGRect(origin: .zero, size: content)).size
        // Not `!=`: a size that differs by a rounding residue is the same size, and writing a
        // frame for it is what let the panel ratchet upward a point per expand
        // (`ResizeAnchor.needsResize`, and `ScreenFitStack.flexibleHeight` where the residue was
        // produced).
        if ResizeAnchor.needsResize(from: window.frame.size, to: target) {
            var frame = window.frame
            // Read before the size is changed: these are the edges the resize has to put back.
            let edges = window.resizeEdges
            frame.size = target
            // Origin only. Writing a size back from an anchor is the second authority again.
            frame.origin = ResizeAnchor.origin(for: frame, edges: edges, corner: corner)
            window.setFrame(frame, display: false)
            wroteFrame = true
        }
        // Drained after the write, never before: what these were waiting for is a surface that is
        // already the size it is going to be.
        let waiting = awaitingSize
        awaitingSize = []
        for action in waiting { action(window) }
    }

    /// Run `action` once this surface has been sized by its content (see `awaitingSize`), which is
    /// usually the same turn: a caller that has just forced a layout calls `sizeNow()` straight
    /// after queueing, and the action runs there. A surface positioned by its TOP LEFT does not
    /// need this at all: that corner is the one a content-driven resize keeps anyway, so it can be
    /// set before any size arrives (which is why the pinned panel never queues anything).
    func whenSized(_ action: @escaping (NSWindow) -> Void) {
        awaitingSize.append(action)
    }

    // MARK: - Bookkeeping

    private func observe(_ window: NSWindow) {
        // DELIBERATELY NOT GUARDED BY `PanelDrag.isActive`, unlike the other per-move work in this
        // app (`PopoverRootView.refreshScreenCap`). That guard is not about the notification storm,
        // it is about what the work DOES: the cap feeds SwiftUI state, which re-lays the surface out
        // and resizes the window, so a carried panel was resized dozens of times on the way. The
        // whole of this closure is one struct store, and `resizeEdges` is three reads off
        // `window.frame` (`ResizeAnchor.Edges.init`) - no frame write, no layout, no observable
        // state, nothing posted. Falsifiable exactly there: a statement in here that touches the
        // window or any @Observable has to bring the guard with it.
        //
        // The value cannot go stale either, in either direction: each move overwrites the last (no
        // accumulation), so a carry ends with the position it ended at. Guarding it would be the
        // bug, not the fix - a resize arriving mid-carry (fresh data, a folded provider) would then
        // anchor the panel to where the hand PICKED IT UP and yank it back mid-drag.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.anchorEdges = window.resizeEdges
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                // Only the bottom-right case corrects here. A top-leading resize is already at the
                // origin this correction would compute - `sizeNow()` wrote it there - so the
                // correction is a no-op, and leaving it out keeps a resize this object did not
                // make (AppKit adjusting a window to a display that changed under it) from being
                // yanked back to an edge the user can no longer see.
                if self.corner == .bottomTrailing, let edges = self.anchorEdges {
                    window.restoreAnchor(edges, corner: .bottomTrailing)
                }
                // Holding an edge is what lets a growing view run off the display: the footer
                // first under the top anchor, the leading edge under the bottom-right one. So the
                // same growth that needs the anchor also needs the surface put back on screen. The
                // content stops growing at the screen's edge one layout pass earlier
                // (`ScreenFitStack`); this catches what is left, including the display that went
                // away under a panel left on it.
                window.clampOnScreen()
                // AND THE CORNER IS SPENT HERE, on the resize it was written for. Kept any longer
                // it would answer for a resize it was not taken for: a display going away under a
                // panel resizes it without any report at all. The other end of that lifetime is in
                // `sizeNow`, because a measurement that resized nothing produces no notification
                // and this line would never run for it (`ResizeAnchor.Hold`).
                self.hold.finished()
                // Whatever shape this resize ended in IS what the next one has to put back. The
                // move observer cannot be the only refresher: a size change through `setFrame`
                // posts no MOVE notification, so the ordinary top-left resizes (a provider folded,
                // a tab switched, fresh data arriving) would leave the remembered bottom and right
                // at the last drag, and the first bottom-trailing correction after that would
                // anchor to a frame several shapes old.
                self.anchorEdges = window.resizeEdges
            }
        }
        // AND WHEN THE DISPLAYS THEMSELVES CHANGE, directly rather than through a resize.
        //
        // Putting a surface back on screen used to be reachable only from the branch above, which
        // made it conditional on something nothing guarantees: a display going away under a panel
        // changes the surface's screen, not its content, so it produces a resize only if the height
        // cap the content reads happens to come out different (`PopoverRootView.refreshScreenCap`,
        // `ScreenFitStack`). Two displays of the same height - a matched pair, or unplugging the
        // second of three - report the same cap, so nothing resized and the panel stayed on a
        // display that was no longer there. The clamp is what this event is for; asking for it via
        // a resize was asking a question that has a right to answer no.
        //
        // A turn later, because AppKit rearranges windows onto the surviving displays itself when
        // this posts: clamping in the same turn would correct a frame that is about to be moved
        // again, and the second write would be the one nobody checked.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self, weak window] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let window, window.isVisible else { return }
                    window.clampOnScreen()
                    self.anchorEdges = window.resizeEdges
                }
            }
        }
    }
}

/// The hosting view every measured surface is built on: no sizing constraints (set by
/// `SurfaceSizer`, which is the only thing that makes one), and optionally answering the first
/// mouse for a surface that is not the active window.
private final class MeasuredHostingView<Content: View>: NSHostingView<Content> {
    /// Off by default: in an ordinary window a click on an inactive surface should activate it and
    /// stop there, which is what the rest of macOS does.
    var wantsFirstMouse = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { wantsFirstMouse }

    // SwiftUI only tracks gestures in the KEY window, so accepting the first mouse is not enough:
    // make the window key synchronously as the click lands (a non-activating panel may become key
    // without stealing the active app), THEN route the event so the drag tracks immediately.
    override func mouseDown(with event: NSEvent) {
        if wantsFirstMouse, let window, !window.isKeyWindow { window.makeKey() }
        super.mouseDown(with: event)
    }
}
