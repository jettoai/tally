import Foundation

/// What the advisor row says, decided in one place from two readings that answer different
/// questions. The advisor's verdict looks at the last four weeks, pooled across every account of
/// the provider: "do these accounts cover the average week, or should another one be bought?".
/// The fleet gauge's forecast looks at the last 72 hours, per plan, starting from what is left
/// right now and adding each scheduled refill back: "does this pool outlast this week's pace?".
///
/// Shown side by side as raw figures, the two disagreed on screen (a Team seat read "1.0" under
/// a gauge saying it runs out in two days) and the reader had to do the conversion. The row now
/// states a conclusion, and one rule keeps it honest against the gauge above it: while any plan's
/// pool is forecast to run dry, this never says "enough". The dry signal is the gauge's own
/// predicate (`FleetForecast.depletion` returning a date), passed in, never recomputed here.
enum AdvisorConclusion: Equatable {
    /// History is shorter than the verdict's gate; advice arrives in this many whole days.
    case collecting(daysLeft: Int)
    /// Four-week demand is inside the fleet and no pool runs dry at the current pace.
    case enough
    /// The four-week verdict asks for more accounts. `plan` names the tier to buy when the
    /// provider is split across plans, nil when its accounts are interchangeable.
    case add(count: Int, plan: String?)
    /// At least one pool runs dry at this week's pace. `plans` names the tiers that do when only
    /// some of a split provider's tiers are short; empty means the whole provider.
    /// A nil entry is a tier whose plan this machine cannot name.
    case shortAtPace(plans: [String?])

    /// One plan tier as the row needs it. For an unsplit provider this is a single tier whose
    /// `plan` is nil and whose numbers are the provider's.
    struct Tier: Equatable {
        var plan: String?
        var demandPerWeek: Double
        var accountCount: Int
        /// The fleet gauge forecasts at least one of this tier's pools running dry.
        var runsDry: Bool
    }

    /// Accounts short of a weekly demand, never fewer than one: the verdict can also fire on a
    /// flagship window or on starved hours, where the weekly figure alone says nothing is missing
    /// yet the advice still stands. Same arithmetic the pips used, so the count does not move.
    static func shortfall(demandPerWeek: Double, owned: Int) -> Int {
        let asked = Int(min(99, max(0, demandPerWeek)).rounded(.up))
        return max(1, asked - max(1, owned))
    }

    /// `split` is true when the tiers carry two or more named plans; the row then names the plan.
    static func decide(verdict: UsageAdvisor.Verdict, daysOfData: Double, tiers: [Tier],
                       split: Bool) -> AdvisorConclusion {
        let dry = tiers.filter(\.runsDry)
        if verdict == .addAccount {
            // The advisor always reports at least one tier; an empty list still gets the
            // verdict's own advice rather than a crash.
            guard split, !tiers.isEmpty else {
                let demand = tiers.reduce(0) { $0 + $1.demandPerWeek }
                let owned = tiers.reduce(0) { $0 + $1.accountCount }
                return .add(count: shortfall(demandPerWeek: demand, owned: owned), plan: nil)
            }
            // Prefer a tier the gauge already shows running dry, so the row names the plan the
            // reader can see is short; among those, the one most over its own capacity. Ties keep
            // the tier order, which is largest demand first.
            let candidates = dry.isEmpty ? tiers : dry
            var pick = candidates[0]
            for tier in candidates.dropFirst() where ratio(tier) > ratio(pick) { pick = tier }
            return .add(count: shortfall(demandPerWeek: pick.demandPerWeek, owned: pick.accountCount),
                        plan: pick.plan)
        }
        if !dry.isEmpty {
            // Named only when some tiers are fine: "Codex Team" when Pro still lasts, plain
            // "Codex" when every tier is short, since naming them all says nothing extra.
            let named = split && dry.count < tiers.count
            return .shortAtPace(plans: named ? dry.map(\.plan) : [])
        }
        if verdict == .collecting {
            let left = Int((UsageAdvisor.minimumDays - daysOfData).rounded(.up))
            return .collecting(daysLeft: max(1, left))
        }
        return .enough
    }

    private static func ratio(_ tier: Tier) -> Double {
        tier.demandPerWeek / Double(max(1, tier.accountCount))
    }
}
