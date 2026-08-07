import CoreGraphics

/// What a press on a control turned out to be once the pointer stopped: a click on the control, or
/// the beginning of a window move.
///
/// The pinned panel is a borderless window with no titlebar, so every point of it that a user can
/// grab has to be given by hand (`DragOrTapArea`), and the controls standing in those runs were
/// the holes: a panel whose grab area is interrupted by a tab switch in its exact centre is one the
/// hand has to aim at. Making those controls draggable too means one press has to answer two
/// questions, and this is the whole of that decision.
///
/// DISTANCE ONLY, NEVER TIME. A press-and-hold reading of the same gesture (drag after N
/// milliseconds) makes every click on the tab switch wait to find out whether it was one, and a
/// control that answers late reads as a control that is broken. Distance costs nothing: a click is
/// a press that did not travel, which is already true of every click anyone makes.
///
/// Pure geometry in its own file so the rule can be tested without a window, an event queue or a
/// pointer (`tests/run-dragortap-tests.sh`) - the surrounding event loop is the part that cannot be
/// driven from a test, and it is deliberately left with no arithmetic of its own to get wrong.
enum PointerIntent: Sendable, Equatable {
    /// The pointer stayed put: the control does what it is for.
    case tap
    /// The pointer travelled: the window moves and the control does nothing at all.
    case drag

    /// How far the pointer may travel and still have been a click, in points.
    ///
    /// Four is the slop the system's own controls allow, and the range either side of it is narrow:
    /// much less and a hand that shakes by a point loses the click it made, much more and a short
    /// deliberate nudge of the panel is swallowed as a click on whatever it started over.
    static let slop: CGFloat = 4

    /// Which of the two a press became, given where it went down and where the pointer is now.
    ///
    /// Radial rather than per-axis: a threshold measured on x and y separately would let a diagonal
    /// travel almost half again as far before it counted, so a panel nudged corner-wise would answer
    /// differently from one nudged sideways by the same distance.
    ///
    /// AT the threshold is still a tap. The boundary has to fall on one side and this is the side
    /// that cannot surprise anyone: the gesture that did the smallest thing the caller was willing
    /// to call movement still does what the control it was aimed at is for.
    static func dragOrTap(from origin: CGPoint, to point: CGPoint,
                          threshold: CGFloat = slop) -> PointerIntent {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        // Squared on both sides: same answer as a distance, without a square root that would make
        // the boundary case above depend on rounding.
        return dx * dx + dy * dy > threshold * threshold ? .drag : .tap
    }
}


/// Whether a drag that was started is still under way.
///
/// Its own answer rather than a stored flag, because the flag alone cannot be trusted: the drag is
/// carried by AppKit after `performDrag` returns (it returns at once), so the code that started it
/// is not told when it ends and has to watch for the release. If that watcher were ever lost, a
/// bare flag would say "still dragging" for the life of the process and the surface would stop
/// re-reading its own height cap forever. Asking the button as well makes the wrong answer expire:
/// the moment the hand is off, this is false whatever the flag says.
///
/// Pure so the truth table can be asserted without a window, a pointer or a drag
/// (`tests/run-dragortap-tests.sh`).
enum PanelCarry {
    /// - Parameters:
    ///   - started: a drag was handed to AppKit and the release has not been seen yet.
    ///   - buttonsDown: `NSEvent.pressedMouseButtons`, a bitmask whose low bit is the left button.
    static func inProgress(started: Bool, buttonsDown: Int) -> Bool {
        started && buttonsDown & 1 != 0
    }
}
