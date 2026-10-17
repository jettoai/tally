import Foundation

/// What one pool's ring in the menu bar shows (B-2045). Pure, so the whole state table can be
/// asserted without a status item on screen.
struct PoolRing: Equatable {
    /// The arc's length as a share of the full ring; nil draws a dashed empty ring, because a pool
    /// with no readable figure must not pretend to know how much is left.
    var fraction: Double?
    /// The ring and the mark inside it wear this severity's colour (`MetricSeverity.color`, the
    /// panel bar's own), as one unit; `.unknown` leaves them ink.
    var severity: MetricSeverity
    /// Faded to 40%: the figure is the last one known (stale) or there is none (offline).
    var isFaded: Bool
    /// The optional inner ring (5-hour window): same rules as `fraction` / `severity`; nil draws a
    /// dashed inner track when the inner ring is switched on.
    var innerFraction: Double? = nil
    var innerSeverity: MetricSeverity = .unknown
}

// In an extension so the memberwise initializer stays synthesized.
extension PoolRing {
    init(_ segment: MenuBarSegment) {
        // Always the REMAINING share, whatever the Used/Left toggle prints on the hover and panel.
        if let remaining = segment.remaining {
            fraction = Double(remaining) / 100
            severity = segment.severity
            isFaded = segment.dimmed
        } else {
            fraction = nil
            severity = .unknown
            isFaded = true
        }
        innerFraction = segment.sessionRemaining.map { Double($0) / 100 }
        innerSeverity = segment.sessionRemaining == nil ? .unknown : segment.sessionSeverity
    }
}
