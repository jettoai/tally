import CoreGraphics

/// The geometry of one in-view drag-to-reorder, shared by every list that reorders by hand: the
/// panel's account cards and rows (CardReorder.swift) and the Settings account rows. Pure
/// CoreGraphics so the hit-testing rule can be tested outside SwiftUI (tests/accountrow).

/// The item lifted by an in-flight drag: its source frame and where inside it the drag started, so
/// the floating copy tracks the pointer 1:1 from the exact grab point.
struct ReorderLift: Equatable {
    let id: String
    let sourceFrame: CGRect
    let touchOffset: CGPoint
    var location: CGPoint

    /// Locks in the item under the drag's START point, exactly once: later frames must not re-hit-test
    /// it, or a mid-drag layout shift could silently swap which item is being dragged. Nil when the
    /// drag began on a gap between items.
    init?(grabbing start: CGPoint, at location: CGPoint, frames: [String: CGRect]) {
        guard let grabbed = frames.first(where: { $0.value.contains(start) }) else { return nil }
        id = grabbed.key
        sourceFrame = grabbed.value
        touchOffset = CGPoint(x: start.x - grabbed.value.minX, y: start.y - grabbed.value.minY)
        self.location = location
    }

    /// Where the floating copy's centre currently sits. The single source for BOTH the copy's
    /// rendered position and the reorder hit-test probe: the two must never diverge, or reordering
    /// silently stops matching what the user sees. Probing with the pointer instead is the B-1388
    /// bug: a full-width row grabbed by its handle keeps the pointer in every target's side dead
    /// zone for the whole drag, so the order never moves.
    var previewCentre: CGPoint {
        CGPoint(x: location.x - touchOffset.x + sourceFrame.width / 2,
                y: location.y - touchOffset.y + sourceFrame.height / 2)
    }
}

/// The item the drag should displace, or nil. The probe point (the lifted copy's centre) must reach
/// the target's core (inset 20% per side) rather than merely graze its edge - the grid has horizontal
/// *and* vertical neighbors, and edge-triggered reordering feels jumpy in both directions.
func reorderTarget(at location: CGPoint, frames: [String: CGRect],
                   excluding draggedID: String, orderedIDs: [String]) -> String? {
    for id in orderedIDs where id != draggedID {
        guard let frame = frames[id] else { continue }
        let core = frame.insetBy(dx: frame.width * 0.2, dy: frame.height * 0.2)
        if core.contains(location) { return id }
    }
    return nil
}
