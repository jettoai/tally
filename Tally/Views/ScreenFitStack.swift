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
    private static let minFlexibleHeight: CGFloat = 120

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
        heights[flexible] = max(Self.minFlexibleHeight, heights[flexible] - (total - maxHeight))
        return (width, heights)
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

    /// The cap for a surface hosted on `screen`, which is the only thing any host has to know.
    @MainActor static func maxHeight(on screen: NSScreen?) -> CGFloat {
        let usable = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return max(minSurfaceHeight, usable - screenMargin)
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
}
