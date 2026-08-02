import Foundation

/// The severity band a flagship fleet pool sits in. "Armed" (a notification-worthy band, low or
/// dry) exists only when two or more accounts back the pool: a lone account sitting at zero is the
/// ordinary single-subscription state, not the third-account tripwire this feature watches for.
enum DryTier: String, Codable {
    case normal
    case low
    case dry
}

/// Which notification an evaluation should emit, if any.
enum DryNotification: String, Codable, Equatable {
    case low
    case dry
}

/// Per-pool dedup memory, persisted (UserDefaults) so an app restart or auto-update does not
/// re-fire an alert already delivered this reset cycle. `resetKey` identifies the cycle: when the
/// pool's reset time moves far enough to name a different one (`namesSameCycle`), the whole thing
/// re-arms.
struct DryPoolState: Codable, Equatable {
    var resetKey: String?
    var firedLow: Bool
    var firedDry: Bool

    init(resetKey: String? = nil, firedLow: Bool = false, firedDry: Bool = false) {
        self.resetKey = resetKey
        self.firedLow = firedLow
        self.firedDry = firedDry
    }
}

/// Pure tier and transition logic for the dual-dry flagship pool alert. Foundation only (no AppKit,
/// no UserNotifications) so the CLI test harness compiles it standalone.
enum DryPoolLogic {
    /// Low fires at or below this fraction of capacity remaining (5%).
    static let lowFraction = 0.05
    /// A recovery back above this fraction (10%) re-arms both tiers within the same cycle. The band
    /// between 5% and 10% is deliberate hysteresis, so a pool hovering at the threshold does not
    /// re-fire on every refresh.
    static let rearmFraction = 0.10

    /// The band the pool sits in. Armed (low or dry) only when two or more accounts back it.
    static func tier(remaining: Double, capacity: Double, accountCount: Int) -> DryTier {
        guard accountCount >= 2, capacity > 0 else { return .normal }
        if remaining <= 0 { return .dry }
        if remaining <= capacity * lowFraction { return .low }
        return .normal
    }

    /// Fold one evaluation into the dedup state, returning the next state and the notification to
    /// emit (nil when this reading is a duplicate or below threshold). Semantics:
    /// - each of low and dry fires at most once per reset cycle;
    /// - a reset time that names a different cycle re-arms everything, while one that has only
    ///   drifted within the parser's own resolution does not;
    /// - a recovery above `rearmFraction` re-arms both tiers within the same cycle.
    static func advance(state: DryPoolState, remaining: Double, capacity: Double,
                        accountCount: Int, resetAt: Date?) -> (DryPoolState, DryNotification?) {
        let key = resetKey(resetAt)
        // The remembered key wins when the two name the same cycle, so a window whose reported
        // reset drifts by a minute keeps the identity it was first seen under instead of walking
        // forward a minute at a time until it has crossed the tolerance from where it started.
        var next = namesSameCycle(state.resetKey, key) ? state : DryPoolState(resetKey: key)

        // A recovery above the re-arm line clears both fired flags for this cycle.
        if accountCount >= 2, capacity > 0, remaining > capacity * rearmFraction {
            next.firedLow = false
            next.firedDry = false
        }

        switch tier(remaining: remaining, capacity: capacity, accountCount: accountCount) {
        case .dry where !next.firedDry:
            next.firedDry = true
            return (next, .dry)
        case .low where !next.firedLow:
            next.firedLow = true
            return (next, .low)
        default:
            return (next, nil)
        }
    }

    /// How far a reported reset time may move and still name the SAME cycle. Reset times are parsed
    /// out of what the providers report in human text, whose finest unit is the minute, so one
    /// unbroken window is reported up to a minute apart between polls as the underlying instant
    /// rounds one way or the other. Five minutes clears that comfortably while staying far below
    /// the shortest window a genuine new cycle can arrive on (the 5h session window), so no real
    /// reset is ever mistaken for jitter.
    ///
    /// The CLI's rebalance claim keeps its own copy of this rule (`rebalanceCycleTolerance` and
    /// `namesSameDrought` in TallyCLI/Rebalance.swift) because the two live in different targets;
    /// they are the same tolerance for the same reason, and should move together.
    static let cycleTolerance: TimeInterval = 5 * 60

    /// Whether two cycle keys name the same window: the same reported reset, or one that has moved
    /// no further than the source's own resolution can move it. Anything that is not an epoch falls
    /// back to equality, which covers both an absent key (an unknown reset is one unknown cycle
    /// rather than a new one each round) and a key nothing writes.
    static func namesSameCycle(_ one: String?, _ other: String?) -> Bool {
        guard let a = one.flatMap({ Double($0) }), let b = other.flatMap({ Double($0) }) else {
            return one == other
        }
        return abs(a - b) <= cycleTolerance
    }

    /// Stable per-cycle identity from a reset time, in whole seconds. The key is only half of the
    /// answer: the jitter this source actually produces is a whole minute, so the tolerance lives
    /// in the comparison (`namesSameCycle`) rather than in the key.
    static func resetKey(_ resetAt: Date?) -> String? {
        resetAt.map { String(Int($0.timeIntervalSince1970.rounded())) }
    }
}
