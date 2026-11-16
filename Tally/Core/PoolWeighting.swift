import Foundation

/// How a pool's plan weighting is shown, decided here and worded by the views (so the choices can
/// be tested without a window). `FleetMath` decides the weights (`FleetPool.Member.weight`); this
/// decides what a reader is told about them:
///
///  - `equal`: every member weighs the same (one plan, or plans of equal multiple). Nothing to say;
///    the pool reads exactly as it always has.
///  - `weighted`: plans of different published multiples are pooled. The pool is named as weighted
///    and its hover lists each seat's multiple and the unit the pool is counted in.
///  - `unknown`: a plan in the pool has no published multiple. No combined figure exists, so the ring
///    is empty, no pace is claimed, and the hover lists what each plan has left on its own.
struct PoolWeighting: Equatable {
    enum Kind: Equatable { case equal, weighted, unknown }

    /// One account's place in the pool.
    struct Seat: Equatable {
        let account: String
        let plan: String
        /// The published multiple, nil when the vendor publishes none.
        let multiple: Double?
        /// The multiple is the vendor's announcement rather than a figure read off its pricing page.
        let announced: Bool
    }

    /// One plan's own reading (its accounts' average), for a pool that cannot be combined.
    struct PlanShare: Equatable {
        let plan: String
        let remaining: Double
        let published: Bool
    }

    let kind: Kind
    let seats: [Seat]
    let planShares: [PlanShare]
    /// Left and total, in lowest-plan weeks (one lowest-plan account's window = 1).
    let weeksLeft: Double
    let weeksTotal: Double

    /// The em dash the panel already uses for "no figure" (`UsageFormat.noResetGlyph`).
    static let noFigure = "\u{2014}"

    static func kind(of pool: FleetPool) -> Kind {
        pool.weightUnknown ? .unknown : (Set(pool.members.map(\.weight)).count > 1 ? .weighted : .equal)
    }

    /// `unknownPlan` names a seat whose plan this machine cannot name.
    init(_ pool: FleetPool, unknownPlan: String) {
        kind = Self.kind(of: pool)
        seats = pool.members.map {
            Seat(account: $0.accountLabel, plan: $0.plan ?? unknownPlan, multiple: $0.multiple,
                 announced: $0.multipleSource == .announced)
        }
        var order: [String] = []
        var byPlan: [String: [FleetPool.Member]] = [:]
        for member in pool.members {
            let plan = member.plan ?? unknownPlan
            if byPlan[plan] == nil { order.append(plan) }
            byPlan[plan, default: []].append(member)
        }
        planShares = order.map { plan in
            let members = byPlan[plan]!
            return PlanShare(plan: plan,
                             remaining: members.map(\.remaining).reduce(0, +) / Double(members.count),
                             published: members.allSatisfy { $0.multiple != nil })
        }
        weeksLeft = pool.totalRemaining / 100
        weeksTotal = pool.capacity / 100
    }

    /// The plans without a published multiple, in pool order.
    var unpublishedPlans: [String] { planShares.filter { !$0.published }.map(\.plan) }

    /// "x10", with the multiplication sign; a fractional multiple keeps one decimal.
    static func multipleText(_ value: Double) -> String {
        "\u{00D7}" + (value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value))
    }

    /// "codex1 Pro 200 x10 announced, codex2 Team x1", the seats and their multiples in pool order.
    /// `announcedWord` follows the multiple of a seat whose figure is the vendor's announcement.
    func seatsText(announcedWord: String) -> String {
        seats.map { seat in
            var text = seat.account + " " + seat.plan
            if let multiple = seat.multiple {
                text += " " + Self.multipleText(multiple)
                if seat.announced { text += " " + announcedWord }
            }
            return text
        }.joined(separator: " \u{00B7} ")
    }

    /// What the card head's ring shows: the pool's share in the Used/Left mode, or nil when the pool
    /// has no combined figure (the ring is then drawn empty, never from the placeholder average).
    static func ringShare(_ pool: FleetPool, used: Bool) -> Double? {
        pool.combinedAverage.map { used ? 100 - $0 : $0 }
    }
}
