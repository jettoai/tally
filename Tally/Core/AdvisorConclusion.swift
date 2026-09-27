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

    /// A pool the fleet gauge forecasts running dry, reduced to what the join needs.
    struct DryPool: Equatable {
        /// False when the gauge draws the provider as one pool, not split by plan. That pool is
        /// every plan's at once, so it runs every tier dry, whatever plans the history names.
        var byPlan: Bool
        /// The pool's plan when `byPlan`; nil there is a plan this machine cannot name.
        var plan: String?
        var accountCount: Int
    }

    /// The tiers worth splitting the figure into: none unless the provider's accounts actually sit
    /// on two or more NAMED plans. One plan (or none the app can name) means the accounts really
    /// are interchangeable, and the pooled figure is then both exact and the shorter read.
    static func splitTiers(_ tiers: [UsageAdvisor.TierDemand]) -> [UsageAdvisor.TierDemand] {
        guard Set(tiers.compactMap(\.plan)).count >= 2 else { return [] }
        return tiers
    }

    /// The advisor's tiers joined with the gauge's dry pools by plan key (case-insensitive, "?"
    /// for an unnamed plan, the rule `FleetSummary.Tier.key` uses), then decided. The two sides
    /// can split differently: the history names the plan of an account that has failed since
    /// launch, the gauge only splits on accounts with metrics. So an unsplit dry pool marks every
    /// tier dry, and a plan the gauge shows but the history has not seen still counts, with no
    /// demand, so a short pool is never dropped for lack of a matching tier.
    static func join(verdict: UsageAdvisor.Verdict, daysOfData: Double, pooledDemandPerWeek: Double,
                     tierDemands: [UsageAdvisor.TierDemand], ownedAccounts: Int,
                     dryPools: [DryPool]) -> AdvisorConclusion {
        func key(_ plan: String?) -> String { plan?.lowercased() ?? "?" }
        let planPools = dryPools.filter(\.byPlan)
        let wholeProviderDry = planPools.count < dryPools.count
        let dryKeys = Set(planPools.map { key($0.plan) })
        var tiers = splitTiers(tierDemands).map { tier in
            Tier(plan: tier.plan, demandPerWeek: tier.demandPerWeek, accountCount: tier.accountCount,
                 runsDry: wholeProviderDry || dryKeys.contains(key(tier.plan)))
        }
        if tiers.isEmpty {
            // Unsplit: one tier for the whole provider, dry when any of its pools is.
            tiers = [Tier(plan: nil, demandPerWeek: pooledDemandPerWeek,
                          accountCount: max(1, ownedAccounts), runsDry: !dryPools.isEmpty)]
        } else {
            for pool in planPools where !tiers.contains(where: { key($0.plan) == key(pool.plan) }) {
                tiers.append(Tier(plan: pool.plan, demandPerWeek: 0, accountCount: pool.accountCount,
                                  runsDry: true))
            }
        }
        let split = Set(tiers.compactMap(\.plan)).count >= 2
            || Set(planPools.compactMap(\.plan)).count >= 2
        return decide(verdict: verdict, daysOfData: daysOfData, tiers: tiers, split: split)
    }

    private static func ratio(_ tier: Tier) -> Double {
        tier.demandPerWeek / Double(max(1, tier.accountCount))
    }
}
