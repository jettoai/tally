import Foundation

/// Cross-account "fleet" aggregation: for each provider with two or more visible accounts, pool
/// the same window class across the accounts to answer "how much does the whole fleet have left,
/// and when does it get quota back". Pure math over the already-fetched usages; no I/O, so the
/// test harness can compile it standalone.
///
/// Percentages pool with equal weights inside a plan: one account's full window is 100 units, so a
/// five-account pool holds 500 units ("5 accounts' worth"). A pool whose accounts sit on different
/// plans weighs every member by its plan's multiple of the vendor's lowest paid plan (`PlanWeight`),
/// so the unit becomes one lowest-plan account's window ("Plus weeks"): a Pro 200 account counts ten
/// of them. Vendors publish those multiples for overall usage, not per window, so applying them to
/// the weekly window is an assumption. A mixed pool with a plan whose multiple is not published
/// carries `weightUnknown` and no combined figure, never a weight of 1. Pools of ONE plan (or of
/// plans with equal multiples) keep weight 1 on every member, so their numbers do not move.
struct FleetPool: Hashable {
    /// One account's contribution to the pool, in the accounts' display order - the segments of
    /// the combined bar.
    struct Member: Hashable {
        var accountLabel: String
        var remaining: Double
        var severity: MetricSeverity
        var resetsAt: Date?
        /// This account's capacity in the pool's unit (`FleetMath.memberWeights`); 1 for a pool of
        /// one plan.
        var weight: Double = 1
        /// The account's plan as shown, and its PUBLISHED multiple (nil = the vendor publishes none)
        /// with how sure that multiple is. `weight` holds the placeholder 1 for an unpublished one;
        /// these say what the pool's weighting rests on (`PoolWeighting`).
        var plan: String? = nil
        var multiple: Double? = nil
        var multipleSource: PlanWeight.Source? = nil
    }

    /// A scheduled quota refill: when a member's window rolls over, the pool gets back what that
    /// member has used so far. Staggered resets are the multi-account superpower, so they are
    /// first-class here.
    struct Refill: Hashable {
        var at: Date
        var accountLabel: String
        /// Units the pool gains at `at`: the member's weight x its current used percent.
        var gain: Double
        /// Accounts in the pool this refill belongs to.
        var poolSize: Int
        /// The member's own used percent, before weighting; nil reads as `gain` (weight 1).
        var ownGain: Double? = nil
        /// Sum of the pool's member weights (capacity = poolWeight x 100 units); nil reads as
        /// `poolSize` (every weight 1).
        var poolWeight: Double? = nil

        /// `gain` as a share of the whole pool's capacity, in percent (gain / (poolWeight x 100) x 100).
        var poolShare: Double {
            let total = poolWeight ?? Double(poolSize)
            return total > 0 ? gain / total : 0
        }
        var poolShareText: String { Self.percentText(poolShare) }
        /// The one account's own gain ("100%"), for the hover that spells out both readings.
        var gainText: String { Self.percentText(ownGain ?? gain) }

        /// One decimal, trailing ".0" dropped: 12.5%, 8%, 24%. Non-finite reads as 0%.
        static func percentText(_ v: Double) -> String {
            let r = ((v.isFinite ? v : 0) * 10).rounded() / 10
            return r == r.rounded() ? "\(Int(r))%" : String(format: "%.1f%%", r)
        }
    }

    var kind: MetricKind
    /// Representative window label (a localization key such as "Weekly", or a model name).
    var label: String
    /// The model this pool is scoped to (weeklyModel pools only) - the focus resolver's handle.
    var modelName: String?
    var members: [Member]
    /// Upcoming refills, soonest first (past resets excluded).
    var refills: [Refill]
    /// The pool mixes plans and at least one has no published multiple, so its members' weights
    /// are not known. `totalRemaining`/`averageRemaining` then hold the unweighted placeholder
    /// (never NaN, so a view cannot crash on it); a surface must read `combinedAverage` instead.
    var weightUnknown: Bool = false

    /// Sum of the members' weights: how many lowest-plan accounts' windows the pool spans.
    var totalWeight: Double { members.map(\.weight).reduce(0, +) }
    /// The pool's size in units (one lowest-plan account's window = 100).
    var capacity: Double { totalWeight * 100 }
    /// Total units left across the pool (0...capacity), each member weighted.
    var totalRemaining: Double { members.map { $0.weight * $0.remaining }.reduce(0, +) }
    var averageRemaining: Double { totalRemaining / totalWeight }
    /// `averageRemaining`, or nil when the weights are unknown and no honest figure exists.
    var combinedAverage: Double? { weightUnknown ? nil : averageRemaining }
    /// The account with the least room - the fleet's weak spot.
    var minMember: Member { members.min { $0.remaining < $1.remaining }! }
    var minAccountLabel: String { minMember.accountLabel }
    var minRemaining: Double { minMember.remaining }
    /// Soonest upcoming reset: the next moment the pool gets quota back.
    var nextReset: Date? { refills.first?.at }
    var nextResetAccountLabel: String? { refills.first?.accountLabel }
    /// Steady-state refill speed (units per hour) once every member's window cycles - the
    /// long-run budget the fleet's burn rate is measured against.
    func steadyRefillPerHour(windowHours: Double) -> Double {
        capacity / windowHours
    }
}

struct FleetSummary: Hashable {
    var providerID: String
    var accountCount: Int
    /// Ordered session → weekly → model pools; only classes that two or more accounts share.
    var pools: [FleetPool]
    /// Which plan this summary covers when the provider's accounts sit on two or more named plans
    /// (`FleetMath.summaries(byPlan: true)`); nil when the summary is the whole provider.
    var planTier: Tier? = nil

    /// One plan's slice of a provider. `name` nil = the accounts whose plan this machine cannot name,
    /// grouped together once a split happens (the advisor's "Unknown plan" tier, same rule).
    struct Tier: Hashable {
        var name: String?
        /// Stable identity for rate keys and view ids.
        var key: String { name?.lowercased() ?? "?" }
    }

    /// View identity: the provider alone when unsplit, provider plus plan when split.
    var id: String { planTier.map { "\(providerID)|plan=\($0.key)" } ?? providerID }

    /// The pool the strip headlines when no model focus resolves: the weekly budget when present,
    /// else the session window.
    var headline: FleetPool? { pools.first { $0.kind == .weeklyAll } ?? pools.first }

    /// Names of the model-scoped pools, the candidates the focus resolver picks from.
    var modelPoolNames: [String] {
        pools.filter { $0.kind == .weeklyModel }.map { $0.modelName ?? $0.label }
    }

    /// Headline honoring a resolved model focus: the named model pool when it exists, else the
    /// plain headline - so a missing window (schema drift, non-flagship plan) degrades to the
    /// weekly budget instead of an empty gauge.
    func headline(focusedModel: String?) -> FleetPool? {
        if let name = focusedModel,
           let pool = pools.first(where: { $0.kind == .weeklyModel && ($0.modelName ?? $0.label) == name }) {
            return pool
        }
        return headline
    }

    /// The pools "All pools" renders, in display order: every window the fleet has a pool for, one
    /// row each (B-1544, owner ruling 2026-10-12: the mode is named "all", so it draws all). The
    /// focused model's pool leads, the account-wide weekly follows, any other model pool after it,
    /// and the 5-hour session pool closes. The leading pool is the same one the old rule led with
    /// for every input, so the menu-bar number and the advisor's next-refill line, which both follow
    /// the leading pool, do not move; the session pool goes last because it paces work rather than
    /// capping it. This replaces the 2026-09-28 rule that hid a model pool unless it was the focus.
    func displayPools(focusedModel: String?) -> [FleetPool] {
        func isFocus(_ pool: FleetPool) -> Bool {
            pool.kind == .weeklyModel && (pool.modelName ?? pool.label) == focusedModel
        }
        let focus = pools.filter(isFocus)
        let weekly = pools.filter { $0.kind == .weeklyAll }
        let otherModels = pools.filter { $0.kind == .weeklyModel && !isFocus($0) }
        let session = pools.filter { $0.kind == .session }
        return focus + weekly + otherModels + session
    }
}

/// Model-window name helpers. Pure so the test harness compiles it standalone.
enum FleetFocus {
    /// The highest-tier name by the given order; names matching nothing rank last.
    static func flagship(_ names: [String], order: [String]) -> String? {
        names.min { rank($0, order) < rank($1, order) }
    }

    private static func rank(_ name: String, _ order: [String]) -> Int {
        order.firstIndex { matches(name, $0) } ?? order.count
    }

    /// "Fable" matches "fable"; a versioned window name and its alias match by containment.
    static func matches(_ windowName: String, _ model: String) -> Bool {
        let window = windowName.lowercased(), model = model.lowercased()
        return window == model || window.contains(model) || model.contains(window)
    }
}

enum FleetMath {
    /// Summaries in the accounts' display order. `label` maps an account to its display name
    /// (the user's nickname), injected so this stays free of store dependencies.
    ///
    /// `minMembers` is how many accounts a window needs before it is worth pooling. Two on the
    /// panel, where a pool of one is just that account's own card standing right below it. The
    /// menu bar's pooled strip asks for ONE, because there a pool is the only reading a
    /// single-account provider gets. It changes nothing about the arithmetic or about who is in a
    /// pool - the members of a class are every account reporting it either way - so every pool the
    /// panel draws comes back from a `minMembers: 1` pass identical, member for member.
    ///
    /// `byPlan`: when a provider's pooled accounts sit on two or more NAMED plans, return one
    /// summary per plan instead of one per provider (unknown-plan accounts form their own, last).
    /// The provider still needs `minMembers` pooled accounts to appear at all; inside a split every
    /// plan pools from ONE account, because a plan of one is still that plan's whole budget and the
    /// alternative drops the provider's strip (and its fold header) entirely. Off by default, so a
    /// caller that does not ask gets the unsplit summaries bit for bit.
    static func summaries(accounts: [AccountUsage], now: Date = Date(), minMembers: Int = 2,
                          byPlan: Bool = false,
                          label: (AccountUsage) -> String) -> [FleetSummary] {
        var providerOrder: [String] = []
        var groups: [String: [AccountUsage]] = [:]
        for account in accounts where !account.metrics.isEmpty {
            if groups[account.providerID] == nil { providerOrder.append(account.providerID) }
            groups[account.providerID, default: []].append(account)
        }
        let tiers = byPlan ? planTiers(accounts: accounts) : [:]
        return providerOrder.flatMap { providerID -> [FleetSummary] in
            guard let members = groups[providerID], members.count >= minMembers else { return [] }
            guard members.contains(where: { tiers[$0.id] != nil }) else {
                return summary(providerID, members, tier: nil, minMembers: minMembers, now: now,
                               label: label).map { [$0] } ?? []
            }
            return planGroups(members).compactMap { tier, group in
                summary(providerID, group, tier: tier, minMembers: 1, now: now, label: label)
            }
        }
    }

    /// `members` grouped by plan: named plans in display order, the unknown one last (it is the
    /// least informative row). Shared with the menu bar's pooled strip, so both split in one order.
    static func planGroups(_ members: [AccountUsage])
        -> [(tier: FleetSummary.Tier, members: [AccountUsage])] {
        var order: [FleetSummary.Tier] = []
        var byTier: [FleetSummary.Tier: [AccountUsage]] = [:]
        for member in members {
            let tier = FleetSummary.Tier(name: member.planName)
            if byTier[tier] == nil { order.append(tier) }
            byTier[tier, default: []].append(member)
        }
        let ordered = order.filter { $0.name != nil } + order.filter { $0.name == nil }
        return ordered.map { ($0, byTier[$0]!) }
    }

    /// The plan tier of every pooled account whose provider splits (two or more named plans among
    /// its pooled accounts), keyed by account id. Accounts of providers that do not split are
    /// absent. Shared by `summaries(byPlan:)` and the burn-rate pass, so the gauge and its pace
    /// forecast cannot disagree about who is on which plan.
    static func planTiers(accounts: [AccountUsage]) -> [String: FleetSummary.Tier] {
        let pooled = accounts.filter { !$0.metrics.isEmpty }
        var tiers: [String: FleetSummary.Tier] = [:]
        for (_, members) in Dictionary(grouping: pooled, by: \.providerID)
        where Set(members.compactMap(\.planName)).count >= 2 {
            for member in members { tiers[member.id] = FleetSummary.Tier(name: member.planName) }
        }
        return tiers
    }

    /// Each account's weight in a pool of `accounts` (one provider's), and whether the pool's
    /// weights cannot be established. One plan (every account the same key, unknown included) or
    /// plans of equal multiple: all 1, so a single-plan pool is exactly the equal-weight pool it has
    /// always been. Different plans, every multiple published: the multiples. Different plans with
    /// any multiple unpublished: unknown, and the weights hold the placeholder 1.
    static func memberWeights(_ accounts: [AccountUsage]) -> (weights: [Double], unknown: Bool) {
        let ones = [Double](repeating: 1, count: accounts.count)
        guard Set(accounts.map(PlanWeight.key(of:))).count > 1 else { return (ones, false) }
        let found = accounts.map { PlanWeight.weight(providerID: $0.providerID, plan: PlanWeight.key(of: $0)) }
        guard !found.contains(where: { $0 == nil }) else { return (ones, true) }
        let values = found.compactMap { $0?.value }
        return Set(values).count == 1 ? (ones, false) : (values, false)
    }

    /// Per-account weights for the burn-rate pass, looked up by the account ids behind one rate key
    /// (`FleetForecast.rateKey`: provider|window[|model]): nil when that pool's weights are unknown
    /// (no honest combined pace exists), else id -> weight. The weights come from the pool's whole
    /// membership (every account of the provider holding that window), NOT from the ids, which only
    /// cover accounts with recent samples: a mixed pool whose heavy plan has samples and whose light
    /// plan has none must still weigh the heavy one by its multiple. An id this machine no longer
    /// lists weighs 1.
    static func weightLookup(accounts: [AccountUsage]) -> @Sendable ([String], String) -> [String: Double]? {
        return { ids, rateKey in
            let parts = rateKey.split(separator: "|").map(String.init)
            let provider = parts.first ?? ""
            let window = parts.count > 1 ? parts[1] : ""
            let model = parts.count > 2 ? parts[2] : nil
            var members = accounts.filter { account in
                account.providerID == provider && account.metrics.contains {
                    $0.kind.rawValue == window && (model == nil || $0.modelName?.lowercased() == model)
                }
            }
            if members.isEmpty { members = accounts.filter { ids.contains($0.id) } }
            let (weights, unknown) = memberWeights(members)
            guard !unknown else { return nil }
            var result = Dictionary(ids.map { ($0, 1.0) }, uniquingKeysWith: { first, _ in first })
            for (account, weight) in zip(members, weights) where result[account.id] != nil {
                result[account.id] = weight
            }
            return result
        }
    }

    /// One summary over `members`, pooled at `minMembers` and stamped with `tier`.
    private static func summary(_ providerID: String, _ members: [AccountUsage],
                                tier: FleetSummary.Tier?, minMembers: Int, now: Date,
                                label: (AccountUsage) -> String) -> FleetSummary? {
        var pools: [FleetPool] = []
        for kind in [MetricKind.session, .weeklyAll] {
            let entries = members.compactMap { account in
                account.metrics.first { $0.kind == kind }.map { (account, $0) }
            }
            if let pool = pool(kind: kind, entries: entries, now: now, minMembers: minMembers,
                               label: label) {
                pools.append(pool)
            }
        }
        // Model-scoped windows pool per model name: two accounts' Fable windows are one
        // budget, but a Fable window and an Opus window are not.
        let modelEntries = members.flatMap { account in
            account.metrics.filter { $0.kind == .weeklyModel }.map { (account, $0) }
        }
        let byModel = Dictionary(grouping: modelEntries) { $0.1.modelName ?? $0.1.label }
        for name in byModel.keys.sorted() {
            if let pool = pool(kind: .weeklyModel, entries: byModel[name]!, now: now,
                               minMembers: minMembers, label: label) {
                pools.append(pool)
            }
        }
        guard !pools.isEmpty else { return nil }
        return FleetSummary(providerID: providerID, accountCount: members.count, pools: pools,
                            planTier: tier)
    }

    /// One pooled window class, or nil when fewer than `minMembers` accounts share it (on the
    /// panel, a "pool" of one is just that account's own meter, already on its card).
    private static func pool(kind: MetricKind, entries: [(AccountUsage, UsageMetric)], now: Date,
                             minMembers: Int,
                             label: (AccountUsage) -> String) -> FleetPool? {
        guard entries.count >= minMembers, !entries.isEmpty else { return nil }
        let (weights, unknown) = memberWeights(entries.map(\.0))
        let poolWeight = weights.reduce(0, +)
        let members = zip(entries, weights).map { entry, weight in
            let published = PlanWeight.weight(providerID: entry.0.providerID,
                                              plan: PlanWeight.key(of: entry.0))
            return FleetPool.Member(accountLabel: label(entry.0), remaining: entry.1.remainingPercent,
                                    severity: entry.1.severity, resetsAt: entry.1.resetsAt,
                                    weight: weight, plan: entry.0.planName,
                                    multiple: published?.value, multipleSource: published?.source)
        }
        let refills = zip(entries, weights)
            .compactMap { entry, weight in
                entry.1.resetsAt.map {
                    FleetPool.Refill(at: $0, accountLabel: label(entry.0),
                                     gain: weight * entry.1.usedPercent, poolSize: entries.count,
                                     ownGain: entry.1.usedPercent, poolWeight: poolWeight)
                }
            }
            .filter { $0.at > now }
            .sorted { $0.at < $1.at }
        return FleetPool(kind: kind, label: entries[0].1.label,
                         modelName: entries[0].1.modelName, members: members, refills: refills,
                         weightUnknown: unknown)
    }
}

/// One account's capacity relative to its vendor's lowest paid plan (Claude Pro = 1, ChatGPT
/// Plus = 1), keyed by the plan code, and how sure that multiple is. A plan the table does not
/// list has NO multiple: callers must treat nil as unknown, never as 1.
///
/// Sources of the multiples (checked 2026-11-16):
///  - Claude: claude.com/pricing, "5x Pro usage every 5 hours and every week" (Max), "10x Pro usage
///    every week" (Ultra). Official.
///  - Codex Plus/Team/Business/Edu: developers.openai.com/codex/pricing lists Business standard
///    seats and non-flexible Enterprise/Edu seats at Plus's allowance. Official.
///  - Codex Pro 100 / 200 / 500 (`prolite` / `pro` / `promax`): the 5x, 10x (since 2026-10-30,
///    down from 20x) and 25x multiples OpenAI announced for them, as reported by the press; the
///    help-center pages are not readable here. Announced, less sure.
///  The vendors publish the multiples for overall usage, so applying them to the weekly window is
///  an assumption.
enum PlanWeight {
    /// When the table above was last checked against the vendors' pages; the hover says so.
    static let checkedOn = "2026-11-16"

    enum Source: String, Hashable {
        /// Read off the vendor's own pricing page.
        case detected
        /// A multiple the vendor announced but this build could not read from an official page.
        case announced
        /// No multiple: a pool of one unlisted plan, weighted 1 only because every member is alike.
        case assumed
    }

    /// The table's key for an account: Claude's plan name, Codex's raw `planType`. "Max 20x",
    /// "max_20x" and "MAX 20X" name the same plan.
    static func key(of account: AccountUsage) -> String? {
        key(account.providerID == "codex" ? account.planKey : account.planName)
    }

    static func key(_ plan: String?) -> String? {
        let key = (plan ?? "").lowercased().filter { !$0.isWhitespace && $0 != "_" }
        return key.isEmpty ? nil : key
    }

    /// The plan's multiple, or nil when the table does not list it. `plan` may be raw: it is keyed here.
    static func weight(providerID: String, plan: String?) -> (value: Double, source: Source)? {
        switch (providerID, key(plan) ?? "") {
        // Anthropic renamed Max 20x to Ultra (2026-10-31); both are 10x Pro per week.
        case ("claude", "max20x"), ("claude", "ultra"), ("claude", "claudeultra"):
            return (10, .detected)
        // Max ($100) is the old 5x tier under its current name.
        case ("claude", "max5x"), ("claude", "max"): return (5, .detected)
        case ("claude", "pro"): return (1, .detected)
        // Business (formerly Team) and non-flexible Edu carry the same Codex allowance as Plus.
        case ("codex", "plus"), ("codex", "team"), ("codex", "business"), ("codex", "edu"):
            return (1, .detected)
        case ("codex", "prolite"): return (5, .announced)
        case ("codex", "pro"): return (10, .announced)
        case ("codex", "promax"): return (25, .announced)
        default: return nil
        }
    }

    /// A pooled figure is only as sure as its least sure member.
    static func combined(_ sources: Set<Source>) -> Source {
        if sources.contains(.assumed) { return .assumed }
        if sources.contains(.announced) { return .announced }
        return .detected
    }
}

/// One provider's weekly remaining across every plan it holds, weighted by plan capacity.
struct FleetWeighted: Hashable {
    /// 0...100, rounded to a whole percent.
    var remainingPercent: Double
    var source: PlanWeight.Source
}

extension FleetMath {
    /// Whether any account of the provider reports a 5-hour window. Ultra has none (claude.com/pricing:
    /// "No 5-hour limit"), so a fleet of those is a two-bar fleet and 5-hour UI has nothing to say.
    static func hasSessionWindow(_ accounts: [AccountUsage], provider: String) -> Bool {
        accounts.contains { $0.providerID == provider && $0.metrics.contains { $0.kind == .session } }
    }

    /// Whether the settings for a 5-hour window (relay, auto reset) have anything to act on. Shown
    /// while no reading of the provider exists yet (so they do not flash away on launch), while an
    /// account has a 5-hour window, and while the switch is already on (it must stay reachable to
    /// be turned off).
    static func showsSessionSettings(_ accounts: [AccountUsage], provider: String,
                                     alreadyOn: Bool = false) -> Bool {
        alreadyOn
            || !accounts.contains { $0.providerID == provider && !$0.metrics.isEmpty }
            || hasSessionWindow(accounts, provider: provider)
    }

    /// Per provider: sum(weight x weekly remaining) / sum(weight). An account without a weekly
    /// reading, or whose reading is stale, stays out of both sums; a provider left with none is
    /// absent. One account is enough, so a single-account provider reads its own remaining. A
    /// provider whose plans cannot all be weighed (`memberWeights`) is absent too: no figure beats
    /// a figure that treats an unknown plan as 1.
    static func weighted(accounts: [AccountUsage]) -> [String: FleetWeighted] {
        var result: [String: FleetWeighted] = [:]
        let fresh = accounts.filter { !$0.isStale && $0.metrics.contains { $0.kind == .weeklyAll } }
        for (providerID, members) in Dictionary(grouping: fresh, by: \.providerID) {
            let (weights, unknown) = memberWeights(members)
            let remaining = members.map { $0.metrics.first { $0.kind == .weeklyAll }!.remainingPercent }
            let total = weights.reduce(0, +)
            guard !unknown, total > 0 else { continue }
            let sources = Set(members.map {
                PlanWeight.weight(providerID: providerID, plan: PlanWeight.key(of: $0))?.source
                    ?? .assumed
            })
            let sum = zip(weights, remaining).map { $0 * $1 }.reduce(0, +)
            result[providerID] = FleetWeighted(remainingPercent: (sum / total).rounded(),
                                               source: PlanWeight.combined(sources))
        }
        return result
    }

    /// The multiple of the one plan a summary's pools cover, nil when its accounts span plans or the
    /// plan has no published multiple.
    static func planWeight(of summary: FleetSummary, accounts: [AccountUsage])
        -> (value: Double, source: PlanWeight.Source)? {
        let covered = accounts.filter { account in
            account.providerID == summary.providerID && !account.metrics.isEmpty
                && (summary.planTier.map { $0.name == account.planName } ?? true)
        }
        let keys = Set(covered.map(PlanWeight.key(of:)))
        guard keys.count == 1, let key = keys.first else { return nil }
        return PlanWeight.weight(providerID: summary.providerID, plan: key)
    }

    /// The plan a summary's pools cover: the split tier's name, or the plan every pooled account
    /// of an unsplit provider shares. nil when they do not all name one plan, which weighs as an
    /// unknown plan.
    static func planName(of summary: FleetSummary, accounts: [AccountUsage]) -> String? {
        if let tier = summary.planTier { return tier.name }
        let plans = Set(accounts
            .filter { $0.providerID == summary.providerID && !$0.metrics.isEmpty }
            .map(\.planName))
        return plans.count == 1 ? plans.first ?? nil : nil
    }
}
