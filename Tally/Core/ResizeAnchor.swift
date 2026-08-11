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
        abs(origin.x - corrected.x) > tolerance || abs(origin.y - corrected.y) > tolerance
    }

    /// The same question for a size: is this content really a different size, or is it the same
    /// size with a rounding residue on it?
    ///
    /// A surface that rewrites its frame for a difference of 6e-14 gets that residue rounded up to
    /// a whole point by AppKit, and on a surface whose cap is measured from its own top edge that
    /// point comes back as a bigger cap and a bigger residue: the pinned panel climbed a point per
    /// expand until it had walked out from under the pointer (2026-08-05). The layout side of that
    /// is fixed where the residue is produced (`ScreenFitStack.flexibleHeight`); this is the same
    /// rule the move already follows, so no future residue can move a window either.
    static func needsResize(from size: CGSize, to reported: CGSize) -> Bool {
        abs(size.width - reported.width) > tolerance || abs(size.height - reported.height) > tolerance
    }

    /// The same question again for the vertical alone, which is what a surface holding its TOP edge
    /// has to separate: a frame write that only MOVES the window is the user dragging it, and
    /// correcting the origin of a drag would pin the window in place. Height is the axis because the
    /// edge being held is horizontal (the pick panel's, `PickPanel.setFrame`).
    static func changesHeight(from size: CGSize, to reported: CGSize) -> Bool {
        abs(size.height - reported.height) > tolerance
    }

    /// Half a point: below this, two numbers are the same place on a screen that can only draw
    /// whole points, and acting on the difference is acting on noise.
    private static let tolerance: CGFloat = 0.5
}
