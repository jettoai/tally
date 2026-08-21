import Foundation

/// THE RULES THE RESERVE STRIP RUNS ON, which is everything about it except the drawing
/// (`Tally/Views/ReserveMark.swift` holds the strip itself and the water line it matches).
///
/// HERE RATHER THAN IN THE VIEW because every one of them is a decision with a right answer - which
/// cell a point is in, how much of a cell a value covers, what a press means, where an arrow key
/// lands - and a decision with a right answer should not need a pointer, a screenshot and somebody's
/// desktop to check. What stays in the view is what only it can do: pixels, gestures, focus.
///
/// Foundation-only for that reason, the way the other rule files under Core are
/// (AccountSignIn, AccountListState): the test harness compiles it directly.
enum ReserveStrip {
    /// How many cells the scale divides into. Ten, and DERIVED: `AccountRoles.reserveStep` says
    /// what one is worth, and a step that ever changes redraws this strip rather than quietly
    /// mismatching it.
    static var cells: Int { AccountRoles.reserveBounds.upperBound / AccountRoles.reserveStep }

    /// The percentage cell `index` (1-based) stands for.
    static func percent(cell index: Int) -> Int { index * AccountRoles.reserveStep }

    /// Which cell a point at `x` falls in, 1-based and CLAMPED TO THE STRIP: a press that runs off
    /// either end belongs to the end it ran off, which is what lets a sweep dragged past the left
    /// edge settle on the first cell rather than on nothing.
    static func cell(atX x: Double, cellWidth: Double, gap: Double) -> Int {
        min(max(Int(x / (cellWidth + gap)) + 1, 1), cells)
    }

    /// How much of cell `index` a value covers, 0...1.
    ///
    /// A value off the step covers part of one - 35 is three full cells and half of the fourth -
    /// because the bounds have always allowed such a value (the 5-point stepper this strip replaced
    /// could write one, and so can a hand-edited state file). It is drawn as what it is; the first
    /// click snaps it, and nothing on disk is rewritten for the sake of the control.
    static func fill(_ value: Int, cell index: Int) -> Double {
        min(max(Double(value) / Double(AccountRoles.reserveStep) - Double(index - 1), 0), 1)
    }

    /// What a press ending on `cell` sets, given the value it STARTED on and whether it moved.
    ///
    /// A STILL PRESS ON THE CELL THE VALUE ALREADY SAT ON CLEARS IT. Every cell sets at least its
    /// own step, so without this, zero is the one setting on the scale the strip cannot reach - the
    /// way a star rating gives its first star a way back. A sweep sets what it ends on instead:
    /// somebody dragging across the strip is choosing a number, and having the drag land on the
    /// number it started from would erase the setting rather than leave it alone.
    ///
    /// Asked about the START value rather than the current one because the strip follows the
    /// pointer live, so by the time a press ends the value already IS what the press is over.
    static func pressed(cell index: Int, from start: Int, swept: Bool) -> Int {
        let target = percent(cell: index)
        return !swept && start == target ? AccountRoles.reserveBounds.lowerBound : target
    }

    /// One arrow key, or one VoiceOver adjustment: the next cell boundary in the direction asked
    /// for, held inside the bounds.
    ///
    /// SNAPPED IN THE DIRECTION OF TRAVEL rather than snapped and then stepped, which is the
    /// difference between 35 going up to 40 and 35 going up to 50. An off-step value moves to the
    /// cell edge it is heading for; a value already on the scale moves a whole cell, so no press
    /// ever does nothing.
    static func nudged(_ value: Int, up: Bool) -> Int {
        let scaled = Double(value) / Double(AccountRoles.reserveStep)
        let next = up ? Int(scaled.rounded(.down)) + 1 : Int(scaled.rounded(.up)) - 1
        return min(max(next * AccountRoles.reserveStep, AccountRoles.reserveBounds.lowerBound),
                   AccountRoles.reserveBounds.upperBound)
    }
}
