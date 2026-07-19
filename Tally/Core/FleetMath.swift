import Foundation

/// Cross-account "fleet" aggregation: for each provider with two or more visible accounts, pool
/// the same window class across the accounts to answer "how much does the whole fleet have left,
/// and when does it get quota back". Pure math over the already-fetched usages; no I/O, so the
/// test harness can compile it standalone.
///
/// Percentages pool with equal weights: one account's full window is 100 units, so a five-account
/// pool holds 500 units ("5 accounts' worth"). That is exact when sibling accounts share a plan
/// tier (the common multi-account setup); plan-weighted pooling can layer on once plan detection
/// is reliable enough to trust.
struct FleetPool: Hashable {
    /// One account's contribution to the pool, in the accounts' display order - the segments of
    /// the combined bar.
    struct Member: Hashable {
        var accountLabel: String
        var remaining: Double
        var severity: MetricSeverity
        var resetsAt: Date?
    }

    /// A scheduled quota refill: when a member's window rolls over, the pool gets back what that
    /// member has used so far. Staggered resets are the multi-account superpower, so they are
    /// first-class here.
    struct Refill: Hashable {
        var at: Date
        var accountLabel: String
        /// Units the pool gains at `at` (the member's current used percent).
        var gain: Double
    }

    var kind: MetricKind
    /// Representative window label (a localization key such as "Weekly", or a model name).
    var label: String
    var members: [Member]
    /// Upcoming refills, soonest first (past resets excluded).
    var refills: [Refill]

    /// Total units left across the pool (0...members×100).
    var totalRemaining: Double { members.map(\.remaining).reduce(0, +) }
    var averageRemaining: Double { totalRemaining / Double(members.count) }
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
        Double(members.count) * 100 / windowHours
    }
}

struct FleetSummary: Hashable {
    var providerID: String
    var accountCount: Int
    /// Ordered session → weekly → model pools; only classes that two or more accounts share.
    var pools: [FleetPool]

    /// The pool the strip headlines: the weekly budget when present (the scarce resource a
    /// multi-account user actually rations), else the session window.
    var headline: FleetPool? { pools.first { $0.kind == .weeklyAll } ?? pools.first }
}

enum FleetMath {
    /// Summaries in the accounts' display order. `label` maps an account to its display name
    /// (the user's nickname), injected so this stays free of store dependencies.
    static func summaries(accounts: [AccountUsage], now: Date = Date(),
                          label: (AccountUsage) -> String) -> [FleetSummary] {
        var providerOrder: [String] = []
        var groups: [String: [AccountUsage]] = [:]
        for account in accounts where !account.metrics.isEmpty {
            if groups[account.providerID] == nil { providerOrder.append(account.providerID) }
            groups[account.providerID, default: []].append(account)
        }
        return providerOrder.compactMap { providerID in
            guard let members = groups[providerID], members.count >= 2 else { return nil }
            var pools: [FleetPool] = []
            for kind in [MetricKind.session, .weeklyAll] {
                let entries = members.compactMap { account in
                    account.metrics.first { $0.kind == kind }.map { (account, $0) }
                }
                if let pool = pool(kind: kind, entries: entries, now: now, label: label) {
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
                                   label: label) {
                    pools.append(pool)
                }
            }
            guard !pools.isEmpty else { return nil }
            return FleetSummary(providerID: providerID, accountCount: members.count, pools: pools)
        }
    }

    /// One pooled window class, or nil when fewer than two accounts share it (a "pool" of one is
    /// just that account's own meter, already on its card).
    private static func pool(kind: MetricKind, entries: [(AccountUsage, UsageMetric)], now: Date,
                             label: (AccountUsage) -> String) -> FleetPool? {
        guard entries.count >= 2 else { return nil }
        let members = entries.map { account, metric in
            FleetPool.Member(accountLabel: label(account), remaining: metric.remainingPercent,
                             severity: metric.severity, resetsAt: metric.resetsAt)
        }
        let refills = entries
            .compactMap { account, metric in
                metric.resetsAt.map {
                    FleetPool.Refill(at: $0, accountLabel: label(account), gain: metric.usedPercent)
                }
            }
            .filter { $0.at > now }
            .sorted { $0.at < $1.at }
        return FleetPool(kind: kind, label: entries[0].1.label, members: members, refills: refills)
    }
}
