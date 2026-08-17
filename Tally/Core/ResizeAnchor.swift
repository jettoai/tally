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

    /// THE CORNER A FRAME WRITE IS MADE WITH, AND HOW LONG IT ANSWERS FOR.
    ///
    /// The corner has three consumers a run-loop turn apart - where the content places itself, the
    /// frame write, and the correction the resize notification triggers - and the rule they follow
    /// is only a rule while all three read the same answer (`ScreenFitStack.HostAnchored`: "the
    /// transition and its destination are never different anchors"). So the corner travels with the
    /// measurement, and this is how long that reading is allowed to speak for.
    ///
    /// A state machine rather than an optional in the host, because "how long" is exactly the part
    /// that was wrong and exactly the part a source reading cannot check: a corner held past the
    /// resize it was taken for answers for a resize nobody measured (a display going away), and the
    /// host has no way to notice.
    struct Hold: Sendable {
        private var pending: Corner?

        init() {}

        /// A measurement arrived, carrying the corner its content was laid out against.
        mutating func reported(_ corner: Corner) { pending = corner }

        /// Which corner to hold right now: the one that came with the measurement being acted on,
        /// and the host's own live answer whenever no measurement is in flight.
        func corner(live: Corner) -> Corner { pending ?? live }

        /// The measurement has been acted on, and `wroteFrame` says whether that produced a
        /// resize. One that did leaves the corner standing for the notification it is about to
        /// cause; one that did not - a report whose size differs from the frame by less than the
        /// half-point tolerance, which this repo has measured down to 6e-14 - causes no
        /// notification at all, so there is nothing left for the corner to answer for and holding
        /// it would hand it to the next resize instead.
        mutating func applied(wroteFrame: Bool) { if !wroteFrame { pending = nil } }

        /// The resize a written frame produced has finished.
        mutating func finished() { pending = nil }
    }

    /// WHAT CLOSING THE VIEW-OPTIONS CARD HAS TO DO TO THE SURFACE: where to put it, and whether to
    /// go on and put it back on a screen.
    struct Restitution: Sendable, Equatable {
        /// Where the surface has to be moved to, or nil when there is nothing to pay back (no card
        /// was recorded, or the surface is already where the card found it).
        var origin: CGPoint?
        /// Whether to follow the move with `clampOnScreen()`.
        var clampsOnScreen: Bool
    }

    /// The put-back, decided rather than performed, so that WHEN IT IS SKIPPED can be asserted
    /// (`tests/windowanchor`) instead of only read.
    ///
    /// A SURFACE NOBODY CAN SEE STILL PAYS. Visibility gates the clamp and nothing else: the frame
    /// is what AppKit's autosave records, so a window that goes away with the card still open (Cmd-Q,
    /// an update relaunch - neither of which any press can precede) has to have its origin written
    /// anyway or it comes back next launch exactly where the card pushed it. Clamping is the part
    /// that is meaningless for it: a hidden window has no screen to be put back on, and the one it
    /// is shown on next is decided when it is shown.
    static func restitution(for frame: CGRect, to edges: Edges?, isVisible: Bool) -> Restitution {
        guard let edges else { return Restitution(origin: nil, clampsOnScreen: false) }
        let corrected = restoredOrigin(for: frame, to: edges)
        guard needsMove(from: frame.origin, to: corrected) else {
            return Restitution(origin: nil, clampsOnScreen: false)
        }
        return Restitution(origin: corrected, clampsOnScreen: isVisible)
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
        /// Minimum x, i.e. the left edge on screen. Read for the same reason the other three are,
        /// one interaction later: a resize under the bottom-right rule moves this edge, and putting
        /// the surface back afterwards means knowing where it started (see `restoredOrigin`).
        var left: CGFloat

        init(frame: CGRect) {
            top = frame.maxY
            bottom = frame.minY
            right = frame.maxX
            left = frame.minX
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

    /// WHERE THE SURFACE GOES BACK TO WHEN THE CARD THAT WAS MOVING IT CLOSES: the top left it had
    /// when the card was opened, with whatever size the content has now hanging off it.
    ///
    /// The bottom-right rule is a loan, not a gift. It holds the bottom and right edges so the
    /// control under the pointer stays under it (`origin(for:edges:corner:)`), and pays for that in
    /// the two edges it does NOT hold: a board that lost 333pt of height dropped the surface's top
    /// edge - and its header - 333pt down the screen, where nothing gave it back and the panel had
    /// to be dragged home by hand (Albert, 2026-08-17, measured on screen). This is the repayment,
    /// made once, when the card stops being what the pointer is aiming at.
    ///
    /// BOTH edges, not just the top. The card's rule holds the right edge, so a width change comes
    /// off origin.x too - the Usage page's density and column tiles walk the surface sideways by the
    /// same mechanism the session board's count walks it downward.
    ///
    /// Origin only, for the reason everything else here is: the size belongs to the content, and a
    /// second authority writing one back is the crash this file's neighbour already paid for.
    static func restoredOrigin(for frame: CGRect, to edges: Edges) -> CGPoint {
        CGPoint(x: edges.left, y: edges.top - frame.height)
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
