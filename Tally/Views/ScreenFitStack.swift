import SwiftUI

/// The vertical stack the usage surface is built from, with the one rule a plain `VStack` cannot
/// express: it never grows taller than the screen its host opens on. Children keep their ideal
/// heights until the stack would overflow, at which point the single child marked
/// `.screenFitFlexible()` gives up exactly the excess - it owns a scroll view, so the rows that no
/// longer fit stay reachable instead of falling off the bottom of the display.
///
/// Fitting the screen belongs HERE, in the content, and not in the hosts that resize themselves to
/// what this reports. A host that caps the size it is handed shrinks nothing (the layout, not the
/// window, decides how tall the view is): it only writes back a frame that disagrees with the
/// content, which is exactly what jumped the popover a frame after every column change (see
/// `StatusItemController.applyPopoverSize`).
///
/// It also stays a single sizing pass, which is what keeps the surface off the "two clocks" stutter
/// that rules a measured `ScrollView` out of `PopoverRootView` (open at one size, resize to fit,
/// AppKit's frame animation fighting SwiftUI's layout). The screen's usable height is known before
/// the surface opens, so no measurement round-trip is needed to apply it. Two properties make that
/// hold: children are measured with the height proposal UNSPECIFIED, so the reported height is a
/// function of the content and the screen alone, and the flexible child is given a definite height
/// rather than left to absorb whatever it is offered. Were the host's current size to feed back
/// into the reported size, a single small frame - the placeholder a panel opens with - would
/// collapse the surface and it would never grow back.
struct ScreenFitStack: Layout {
    /// The tallest the whole stack may become, margins already taken off (see `maxHeight(on:)`).
    var maxHeight: CGFloat

    /// The flexible child never drops below this: on a display too short for even the fixed rows,
    /// the surface overflows a little rather than scrolling a slit.
    static let minFlexibleHeight: CGFloat = 120

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = resolve(proposal: proposal, subviews: subviews)
        return CGSize(width: layout.width, height: layout.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let layout = resolve(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let height = layout.heights[index]
            // Centred like the `VStack` this replaces, and handed the height it was measured at, so
            // a stack that fits lays out exactly as it did before there was a cap.
            subview.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    /// Every child's ideal height, with the excess taken off the flexible one when there is one.
    private func resolve(proposal: ProposedViewSize,
                         subviews: Subviews) -> (width: CGFloat, heights: [CGFloat]) {
        // Height unspecified on purpose: each child reports what it WANTS to be, never what the
        // host currently offers (see the type's note on feedback).
        let ideals = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let width = proposal.width ?? ideals.map(\.width).max() ?? 0
        var heights = ideals.map(\.height)
        let total = heights.reduce(0, +)
        guard maxHeight.isFinite, total > maxHeight,
              let flexible = subviews.indices.first(where: { subviews[$0][ScreenFitFlexibleKey.self] })
        else { return (width, heights) }
        heights[flexible] = Self.flexibleHeight(others: total - heights[flexible],
                                                maxHeight: maxHeight)
        return (width, heights)
    }

    /// What the flexible child gets when the stack has to fit: whatever is left under the cap, in
    /// WHOLE points, and never below the floor.
    ///
    /// The rounding is the load-bearing part, and it is not cosmetic. Taking the excess off the
    /// child's own height (`h - (total - maxHeight)`) is the same arithmetic on paper but not in
    /// binary: summing a dozen fractional child heights and subtracting leaves a residue, measured
    /// at 480.00000000000006 for a cap of exactly 480. A surface reports that number as its size,
    /// AppKit rounds a window frame up to whole points, and the surface is suddenly one point
    /// taller than the room it was capped to - which moves its top edge up by a point, which raises
    /// the cap (it is measured from that edge), which produces the same residue again on the next
    /// resize. That is a ratchet: the pinned panel crept upward a point per expand, which is what
    /// "the whole panel jumps up, about every third time" was (2026-08-05).
    ///
    /// Subtracting from the cap instead of from the child, and flooring, makes the answer land at
    /// or just BELOW the cap. Below is safe (AppKit rounds up into the space that is there); above
    /// is the ratchet.
    /// Not private, and taking its inputs rather than reading them off the layout, so the rule can
    /// be asserted directly (`tests/run-screenfit-tests.sh`) instead of restated by a test.
    static func flexibleHeight(others: CGFloat, maxHeight: CGFloat) -> CGFloat {
        max(minFlexibleHeight, (maxHeight - others).rounded(.down))
    }
}

extension ScreenFitStack {
    /// How much of a screen a surface may take before its scroll region starts giving way: the
    /// usable height (menu bar and Dock already out of `visibleFrame`) less what the content cannot
    /// see of its own host. Sized for the tightest of the three - the popover, which hangs off the
    /// status item, so it starts a menu bar below the top of the screen AND adds its arrow on top
    /// of the size the content reports (measured: 26pt each on a machine whose auto-hidden menu bar
    /// leaves it inside `visibleFrame`). The window gives up a titlebar, the panel nothing at all;
    /// both keep the remainder as breathing room.
    static let screenMargin: CGFloat = 64
    /// Below this a capped surface is a slit, so a display that short gets an overflowing surface
    /// instead. Nothing on sale has a screen this small; the floor is here so the arithmetic cannot
    /// produce an absurd cap.
    static let minSurfaceHeight: CGFloat = 320

    /// Same floor, the other axis: nothing narrower than a single comfortable column.
    static let minSurfaceWidth: CGFloat = 480

    /// The cap for a surface hosted on `screen`, and - for the hosts that grow downward from a
    /// position the user placed - on where that surface's content starts.
    ///
    /// - Parameter topEdge: the screen-space y of the content's TOP edge (AppKit coordinates, so
    ///   `window.contentTopLeft.y`). The pinned panel and the dashboard window keep their top left
    ///   as they grow, so the room a surface actually has is the room BELOW its own top edge, not
    ///   the height of the display. Pass nil for a host that does not grow this way (the popover
    ///   moves itself to stay attached to the status item), which leaves the screen rule alone.
    ///
    ///   THAT PREMISE IS NOW UNCONDITIONAL, which it was not while the view-options card could make
    ///   a surface hold its bottom right instead: under that rule the top edge moved with the
    ///   content, so a shorter surface lowered its own top edge, which lowered this cap, which
    ///   shortened the surface again - a ratchet that stalled at a fixed point for a panel already
    ///   sitting on the bottom of its display. One anchor for every resize removes the input that
    ///   fed it (`ResizeAnchor`).
    @MainActor static func maxHeight(on screen: NSScreen?, topEdge: CGFloat? = nil) -> CGFloat {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else {
            return max(minSurfaceHeight, 900 - screenMargin)
        }
        return cap(visible: visible, topEdge: topEdge)
    }

    /// The arithmetic behind `maxHeight(on:topEdge:)`, on a plain rect so it can be asserted
    /// (`tests/run-screenfit-tests.sh`) rather than only observed on a display.
    ///
    /// Both rules apply and the smaller wins: a surface is never taller than the display's rule of
    /// thumb, and never taller than the gap between its own top edge and the bottom of the visible
    /// area. Without the second one a surface that grows keeps its top left, runs past the bottom
    /// of the screen, and gets pushed back up bodily by `clampOnScreen()` - which is a row moving
    /// out from under the pointer that just clicked it (pinned panel, 2026-08-05).
    ///
    /// Known and accepted: a surface dragged very low is capped hard, so opening something inside
    /// it scrolls rather than grows, and below `minSurfaceHeight` the floor wins and the overflow
    /// (with the clamp that follows it) comes back. Keeping the footer reachable is the same call
    /// `makePanel` states for the panel: the footer is the way to unpin.
    /// Whole points, because a window frame is whole points: a cap of 479.6 can only be honoured by
    /// a surface that is 479 or 480 tall, and 480 is a point past the room it was supposed to fit
    /// in (see `flexibleHeight`, which is where that point turns into a ratchet).
    static func cap(visible: CGRect, topEdge: CGFloat?) -> CGFloat {
        var cap = visible.height - screenMargin
        if let topEdge { cap = min(cap, topEdge - visible.minY) }
        return max(minSurfaceHeight, cap).rounded(.down)
    }

    /// The width twin, for the one layout whose column count depends on the display rather than on
    /// the content: the compact list, whose rows are wide enough that how many fit side by side is a
    /// question about the screen (see `PopoverRootView.listColumnCount`). Nothing CAPS a surface's
    /// width - an explicitly chosen column count is honoured whatever the display - so this only
    /// ever answers "how many would fit".
    @MainActor static func maxWidth(on screen: NSScreen?) -> CGFloat {
        let usable = (screen ?? NSScreen.main)?.visibleFrame.width ?? 1_440
        return max(minSurfaceWidth, usable - screenMargin)
    }

    /// What a scrolling region has to leave beside its content for the scroller itself. Zero under
    /// the default overlay scrollers, which float over the content and cost no width; 17pt (asked of
    /// AppKit, not assumed) once "Show scroll bars: Always" puts them back in the layout, where a
    /// scroll view reports its content's width PLUS the scroller and the surface is a fixed width,
    /// so the excess hangs off the sides and half the scroller lands outside the window.
    ///
    /// Deliberately not conditional on whether the region currently scrolls: the width would then
    /// depend on the height, which is measured at that width, and a fleet sitting on the cap would
    /// oscillate between the two answers. The gutter costs a scroller's width whenever the user has
    /// asked for permanent scrollers, which is what asking for them means.
    @MainActor static var scrollerGutter: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// Takes exactly the size it is offered and puts its content against the top left, which is the
/// corner its host holds still through every resize (`ResizeAnchor`).
///
/// A surface reports the height it WANTS and its host window follows a beat later - there is no way
/// to make a window resize and a SwiftUI layout pass the same event - so for a handful of frames
/// after anything opens or closes, the content is a different height than the window it is inside.
/// `NSHostingView` CENTRES a root view whose size differs from its bounds, and centring content that
/// is taller lifts the top of the page (the header, the wordmark, the whole reading column) by half
/// the difference, then drops it back when the window catches up.
///
/// Measured on the pinned panel (2026-08-05): opening a project's activity graph moved the header
/// up 45pt and held it there for the length of the 0.2s animation, on every single toggle, while
/// the window's own frame never moved by so much as a point - which is why every measurement taken
/// outside the process said the panel was standing perfectly still. That is the "the whole page
/// including the header jumps up" report.
///
/// Sizing to the proposal is what removes the centring: the root view is then exactly the window's
/// size, so there is nothing to centre, and the difference goes where it cannot be seen - off the
/// edge the window is a frame away from growing past.
///
/// WHICH edge is the load-bearing part. The host holds one corner still through a resize
/// (`ResizeAnchor`), so that corner is the only place the content can be put without the intervening
/// frames moving something: waiting against an edge the window is NOT about to hold leaves whatever
/// hangs off it a whole growth step out of place until the window lands. So the two answers are
/// derived from one rule rather than stated twice, which is why this file's assertions compute the
/// window's held edges from `ResizeAnchor.origin` instead of restating them (`tests/screenfit`).
///
/// The corner was once an input to this layout, because the view-options card made it conditional on
/// where the pointer was; the card is a window of its own now and the surface has one anchor for
/// everything (`ViewOptionsCardPlacement`), so this is the top left, always.
///
/// Nothing about what the surface REPORTS changes: the size the hosts follow is measured inside
/// this, on the content itself (`PopoverRootView.sizeReporter`), so the host still resizes to the
/// content's ideal height and this only decides where that content sits until it does.
struct HostAnchored: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(proposal) ?? .zero
        // An unspecified proposal is answered with the content's own size: a host that asks how big
        // this wants to be must not be told "as big as you like".
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let (point, anchor) = Self.placement(in: bounds)
        for subview in subviews { subview.place(at: point, anchor: anchor, proposal: proposal) }
    }

    /// Where the content goes: the corner the host is holding. Taking its bounds rather than reading
    /// them off a layout pass, so the rule can be asserted directly
    /// (`tests/run-screenfit-tests.sh`) instead of only being seen on a display.
    ///
    /// It names the two edges the WINDOW keeps still (`ResizeAnchor.origin`), and the content waits
    /// against those same two. BOTH of them: a rule that held only the vertical would hold the wrong
    /// side of a width change and throw the surface sideways when the window caught up (found by
    /// review, 2026-08-05, on the bottom-right rule that has since been retired).
    static func placement(in bounds: CGRect) -> (CGPoint, UnitPoint) {
        (CGPoint(x: bounds.minX, y: bounds.minY), .topLeading)
    }
}

extension View {
    /// Puts this view against the corner its host holds still, and leaves it there while the host
    /// resizes itself to fit (see `HostAnchored`).
    ///
    /// - Parameter enabled: whether the host sizes itself from what this view REPORTS (it passes an
    ///   `onContentSize` and sets `sizingOptions = []`). A host that instead takes its size from
    ///   this view's own layout constraints must not have this: reporting whatever size is proposed
    ///   makes every size a fixpoint, so such a window keeps the degenerate one it starts with and
    ///   never grows into its content (measured: the dashboard window opened 1x32 instead of
    ///   504x548). The condition is the `onContentSize` itself rather than a list of hosts, so a
    ///   host that does not size from the report cannot accidentally opt in.
    @ViewBuilder func anchoredInHost(enabled: Bool) -> some View {
        if enabled { HostAnchored { self } } else { self }
    }
}

/// Marks the child of a `ScreenFitStack` that absorbs the overflow. Exactly one child should carry
/// it: the first one marked wins, and with none the stack simply reports its full height.
private struct ScreenFitFlexibleKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Inside a `ScreenFitStack`, the region that gives up height when the surface would outgrow the
    /// screen. It has to be able to lose height without losing content, i.e. it scrolls.
    func screenFitFlexible() -> some View {
        layoutValue(key: ScreenFitFlexibleKey.self, value: true)
    }

    /// Keeps a surface's own copy of `ScreenFitStack.scrollerGutter` current. AppKit reconfigures
    /// every scroller the moment the preferred style changes - the user flips "Show scroll bars", or
    /// plugs a mouse into a machine set to Automatic - but nothing about that reaches SwiftUI, so a
    /// width computed from the gutter keeps the answer the old style gave until something unrelated
    /// happens to redraw it: content clipped by a scroller that has just appeared, or a scroller's
    /// width of nothing where one has just left. Read on the notification, so what is laid out is
    /// what AppKit has already switched to.
    ///
    /// Per surface rather than shared: the popover, the pinned panel and the dashboard window can
    /// all be up at once, and each one hears this for itself.
    func trackingScrollerGutter(_ gutter: Binding<CGFloat>) -> some View {
        onReceive(NotificationCenter.default.publisher(
            for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            gutter.wrappedValue = ScreenFitStack.scrollerGutter
        }
    }
}
