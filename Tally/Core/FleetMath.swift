import Foundation

/// Cross-account "fleet" aggregation: for each provider with two or more visible accounts, pool
/// the same window class across the accounts to answer "how much does the whole fleet have left,
/// and when does it get quota back". Pure math over the already-fetched usages; no I/O, so the
/// test harness can compile it standalone.
///
/// Percentages pool with equal weights. That is exact when sibling accounts share a plan tier
/// (the common multi-account setup); plan-weighted pooling can layer on once plan detection is
/// reliable enough to trust.
struct FleetPool: Hashable {
    var kind: MetricKind
    /// Representative window label (a localization key such as "Weekly", or a model name).
    var label: String
    /// Equal-weight mean of the accounts' remaining percent.
    var averageRemaining: Double
    /// The account with the least room, by display label - the fleet's weak spot.
    var minAccountLabel: String
    var minRemaining: Double
    /// Soonest upcoming reset in the pool: the next moment the pool gets quota back. Staggered
    /// resets are the multi-account superpower, so the strip surfaces the nearest refill.
    var nextReset: Date?
    var nextResetAccountLabel: String?
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
        let average = entries.map { $0.1.remainingPercent }.reduce(0, +) / Double(entries.count)
        let weakest = entries.min { $0.1.remainingPercent < $1.1.remainingPercent }!
        let upcoming = entries
            .compactMap { entry in entry.1.resetsAt.map { (entry.0, $0) } }
            .filter { $0.1 > now }
            .min { $0.1 < $1.1 }
        return FleetPool(kind: kind,
                         label: entries[0].1.label,
                         averageRemaining: average,
                         minAccountLabel: label(weakest.0),
                         minRemaining: weakest.1.remainingPercent,
                         nextReset: upcoming?.1,
                         nextResetAccountLabel: upcoming.map { label($0.0) })
    }
}
