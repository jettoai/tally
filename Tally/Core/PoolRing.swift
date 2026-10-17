import Foundation

/// What one pool's ring in the menu bar shows (B-2045). Pure, so the whole state table can be
/// asserted without a status item on screen.
struct PoolRing: Equatable {
    /// A pool turns red when less than this share is left. 20 itself is still ink: only below it.
    static let lowBelow = 20

    /// The arc's length as a share of the full ring; nil draws a dashed empty ring, because a pool
    /// with no readable figure must not pretend to know how much is left.
    var fraction: Double?
    /// The ring and the mark inside it are red, as one unit.
    var isLow: Bool
    /// Faded to 40%: the figure is the last one known (stale) or there is none (offline).
    var isFaded: Bool

    init(fraction: Double?, isLow: Bool, isFaded: Bool) {
        self.fraction = fraction
        self.isLow = isLow
        self.isFaded = isFaded
    }

    init(_ segment: MenuBarSegment) {
        // Always the REMAINING share, whatever the Used/Left toggle prints on the hover and panel.
        if let remaining = segment.remaining {
            fraction = Double(remaining) / 100
            isLow = remaining < Self.lowBelow
            isFaded = segment.dimmed
        } else {
            fraction = nil
            isLow = false
            isFaded = true
        }
    }
}
