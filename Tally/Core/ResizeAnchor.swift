import CoreGraphics

/// WHICH CORNER OF A SURFACE STAYS PUT WHILE ITS CONTENT CHANGES SIZE. There is one answer, and that
/// it is one is the whole design: the TOP LEFT.
///
/// Every usage surface is sized by its content, never by a drag: switching density, column count or
/// a gauge makes the window a different size on the spot. Something has to stay still through that,
/// and the top left is the corner a reader placed: the header stays where the eye left it and a
/// growing fleet runs down the screen, so the numbers never walk upward under it.
///
/// THE RULE USED TO HAVE AN EXCEPTION, and why it no longer does is the part worth keeping. The
/// view-options card hung off the footer, so every control in it resized the surface out from under
/// the pointer. The answer then was to hold the BOTTOM RIGHT while the pointer was on the card,
/// which kept the control still by walking the panel's top left away instead - measured at 333pt
/// down the display for a single column-count click - and then jumping it back when the card closed.
/// Both halves were the panel moving, and being equal and opposite made them cancel on paper and not
/// on screen (Albert, 2026-08-17). The card is a window of its own now, put where the screen says
/// when it opens and left there (`ViewOptionsCardPlacement`), so nothing has to move for its
/// controls to stay under the pointer and every surface holds one corner for everything.
///
/// Pure geometry in its own file so a test can compile it without AppKit, and so that the rule is
/// stated once for the three surfaces that follow it (the dashboard window and the pinned panel
/// through the shared sizing contract, the pick panel through its own `setFrame`; the popover's
/// position belongs to AppKit, which anchors it to the status item).
enum ResizeAnchor {
    /// Where a resized `frame` has to be moved to so that its top edge lands back on `topEdge`.
    ///
    /// - Parameter topEdge: the surface's maximum y BEFORE the resize. AppKit's origin is the bottom
    ///   left, so a content resize leaves that origin alone and the top edge is what travels; this
    ///   is the number that puts it back. The left edge takes no argument because a content resize
    ///   never moves origin.x - it is already where it was.
    ///
    /// Origin only: the size is whatever the content made it, and writing one back from here is the
    /// two-size-authorities crash the pinned panel already paid for once.
    static func origin(for frame: CGRect, topEdge: CGFloat) -> CGPoint {
        CGPoint(x: frame.origin.x, y: topEdge - frame.height)
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

    /// THE HEIGHT A REPORTED CONTENT HEIGHT LANDS ON, ON A NAMED DISPLAY.
    ///
    /// The settings window fits its tallest pane whole - a workhorse pane must never need a
    /// scrollbar (Albert's call, 2026-07-19) - and the display is the only thing that overrules
    /// that. Which display therefore has to be an ARGUMENT rather than something read at the moment
    /// a report happens to arrive: the same content is a different window height on a 1440pt display
    /// than on a 1152pt one, and a window summoned from the first to the second has to be told the
    /// new answer without any report arriving at all (the content did not change, so none will).
    ///
    /// Pure so the enumeration can be asserted: fits / capped / floored / unchanged.
    static func fittedWindowHeight(reported: CGFloat, chrome: CGFloat,
                                   visibleHeight: CGFloat) -> CGFloat {
        max(minimumWindowHeight, min(reported + chrome, visibleHeight - screenMargin))
    }

    /// The breathing room left under a window that had to be capped, so a capped window still reads
    /// as a window on a desktop rather than as one wedged between two edges.
    static let screenMargin: CGFloat = 40

    /// And the floor, for a display too short for even the margin to make sense.
    static let minimumWindowHeight: CGFloat = 200
}
