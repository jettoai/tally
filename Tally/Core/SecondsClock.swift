import Observation
import Foundation

/// B-879: the clock the header's countdown reads when some other once-a-second redraw is already
/// running, so the two land in one pass instead of two. The countdown's own `TimelineView` ticks on
/// a phase of its own, and every tick redrew the whole panel for one changed word (measured
/// 2026-10-04: 1.31 percent of a core with a private build's panel section showing, more than that
/// section's own redraw). Nobody drives it in the public build; the countdown then keeps its `TimelineView`.
@MainActor @Observable
final class SecondsClock {
    static let shared = SecondsClock()

    /// The redraw's own time, set in the same turn as whatever else it changes.
    private(set) var now = Date()
    /// How many redraws drive it; zero hands the countdown back to its own timer.
    private(set) var drivers = 0

    func begin() { drivers += 1; now = Date() }
    func end() { drivers = max(0, drivers - 1) }
    func tick(_ date: Date) { now = date }
}
