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

    /// Which corner has to stay still through the next resize. One statement for both surfaces,
    /// and it is the store's answer rather than this object's: whether the view-options card holds
    /// the bottom right is a question about what is on screen (see `SettingsStore.resizeAnchor`).
    var corner: ResizeAnchor.Corner { SettingsStore.shared.resizeAnchor(for: host) }

    // MARK: - What the surface asks its host

    /// Part 2 of the contract, wired for `PopoverRootView.onContentSize`.
    var onContentSize: (CGSize) -> Void { { [weak self] size in self?.contentReported(size) } }

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

    private func contentReported(_ size: CGSize) {
        reported = size
        // Part 3: out of the SwiftUI update that produced this number before touching the window.
        DispatchQueue.main.async { [weak self] in self?.sizeNow() }
    }

    /// Apply the last reported size, and any placement waiting on one. Public so a host that is
    /// being opened can flush the measurement it just forced (a window is placed and ordered front
    /// in one call, and both need the real size); a no-op when nothing has been reported yet or
    /// the size is already right.
    func sizeNow() {
        guard let window, let content = reported,
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
                // Whatever shape this resize ended in IS what the next one has to put back. The
                // move observer cannot be the only refresher: a size change through `setFrame`
                // posts no MOVE notification, so the ordinary top-left resizes (a provider folded,
                // a tab switched, fresh data arriving) would leave the remembered bottom and right
                // at the last drag, and the first bottom-trailing correction after that would
                // anchor to a frame several shapes old.
                self.anchorEdges = window.resizeEdges
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
