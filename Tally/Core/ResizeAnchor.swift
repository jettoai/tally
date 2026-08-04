import CoreGraphics

/// Which corner of a surface stays put while its CONTENT changes size.
///
/// Every usage surface is sized by its content, never by a drag: switching density, column count or
/// a gauge makes the window a different size on the spot. Something has to stay still through that,
/// and which corner it is decides whether the control the user just clicked is still under the
/// pointer afterwards.
///
/// `topLeading` is the standing rule and the right one for reading: the header stays put and a
/// growing fleet runs down the screen, so the numbers do not walk upward under the eye.
/// `bottomTrailing` is for the one moment when the pointer, not the reading, is what must not move:
/// the view-options card sits at the bottom right and every control in it resizes the surface, so
/// with the top-left held the card walks out from under the pointer after each click and comparing
/// two layouts costs a re-aim every time.
///
/// Pure geometry in its own file so a test can compile it without AppKit, and so that the rule is
/// stated once for the two surfaces that follow it (the dashboard window and the pinned panel; the
/// popover's position belongs to AppKit, which anchors it to the status item).
enum ResizeAnchor {
    enum Corner: Sendable {
        case topLeading
        case bottomTrailing
    }

    /// The edges to put back, read off the surface BEFORE the resize (in practice: remembered at the
    /// last time it moved, which is the last position the user chose).
    struct Edges: Sendable, Equatable {
        /// Maximum y in AppKit's bottom-left origin space, i.e. the top edge on screen.
        var top: CGFloat
        /// Minimum y, i.e. the bottom edge on screen.
        var bottom: CGFloat
        /// Maximum x, i.e. the right edge on screen.
        var right: CGFloat

        init(frame: CGRect) {
            top = frame.maxY
            bottom = frame.minY
            right = frame.maxX
        }
    }

    /// Where the resized `frame` has to be moved to so `corner` lands where it was.
    ///
    /// Origin only: the size is whatever the content made it, and writing one back from here is the
    /// two-size-authorities crash the pinned panel already paid for once.
    static func origin(for frame: CGRect, edges: Edges, corner: Corner) -> CGPoint {
        switch corner {
        case .topLeading:
            // The left edge is already where it was (a content resize never moves origin.x), so only
            // the top has to be restored.
            return CGPoint(x: frame.origin.x, y: edges.top - frame.height)
        case .bottomTrailing:
            // The bottom edge does not move at all, so the surface grows UPWARD and the footer stays
            // under the pointer; the right edge is held by taking the width change off origin.x.
            return CGPoint(x: edges.right - frame.width, y: edges.bottom)
        }
    }

    /// Whether that move is worth making. Sub-point differences are rounding in the layout, and
    /// writing them back would trade a correction for a move notification on every pass.
    static func needsMove(from origin: CGPoint, to corrected: CGPoint) -> Bool {
        abs(origin.x - corrected.x) > 0.5 || abs(origin.y - corrected.y) > 0.5
    }
}
