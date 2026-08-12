import Foundation

/// One readout in the menu-bar strip: a provider's brand mark, the windows stacked under it, and
/// the corner digit that tells identical marks apart. WHAT a segment stands for is the user's
/// layout choice (`MenuBarLayout`) - one account, or one provider's whole pool.
struct MenuBarSegment: Sendable {
    var providerID: String
    /// The stacked window percents, session (5h) on top and the focused weekly below; `["!"]` for
    /// an error and `["—"]` when there is nothing to read.
    var lines: [String]
    /// Stale: last-good numbers still shown after a failed refresh.
    var dimmed: Bool
    /// The corner digit, nil when there is nothing to tell apart. Per-account it is the account's
    /// 1-based number among its siblings; pooled it is how many accounts the segment sums. ONE
    /// slot, because the strip has room for one - which reading it carries follows from the layout
    /// the user picked, and the tooltip spells it out either way.
    var badge: Int?
}

/// How the strip's segments are built, in both layouts. Pure over the fetched usages and the fleet
/// pools, so the menu bar and the panel's fleet gauge run ONE calculation over one member set
/// (`FleetMath`) rather than two that can drift, and so the rules can be tested without a status
/// item on screen.
enum MenuBarSegments {

    // MARK: Which windows a segment stacks

    /// The windows one ACCOUNT's segment shows: its account-wide windows - session (5h) on top,
    /// the focused weekly below - not a single exhausted model tier (a used-up flagship at 0% would
    /// read as "the whole account is dead" while session and weekly still have room). The weekly
    /// one is the model window the gauge focus resolves to, or the account-wide weekly when no
    /// model focus applies, so the number in the menu bar is the number on the gauge. Falls back to
    /// every metric when neither window exists.
    static func metrics(_ account: AccountUsage,
                        focusedModel: (String, [String]) -> String?) -> [UsageMetric] {
        let session = account.metrics.filter { $0.kind == .session }
        let modelNames = account.metrics
            .filter { $0.kind == .weeklyModel }.map { $0.modelName ?? $0.label }
        let focused = focusedModel(account.providerID, modelNames)
        let weekly = focused.flatMap { name in
            account.metrics.first { $0.kind == .weeklyModel && ($0.modelName ?? $0.label) == name }
        } ?? account.metrics.first { $0.kind == .weeklyAll }
        let picked = session + [weekly].compactMap { $0 }
        return picked.isEmpty ? account.metrics : picked
    }

    /// The same choice one level up: the POOLS one provider's pooled segment stacks. Deliberately
    /// the same shape as `metrics` above - session pool on top, focus-resolved weekly pool below,
    /// everything the provider has when neither exists - so switching layouts changes what each
    /// number sums, never which windows are on screen.
    static func pools(_ summary: FleetSummary,
                      focusedModel: (String, [String]) -> String?) -> [FleetPool] {
        let session = summary.pools.filter { $0.kind == .session }
        let focused = focusedModel(summary.providerID, summary.modelPoolNames)
        let weekly = focused.flatMap { name in
            summary.pools.first { $0.kind == .weeklyModel && ($0.modelName ?? $0.label) == name }
        } ?? summary.pools.first { $0.kind == .weeklyAll }
        let picked = session + [weekly].compactMap { $0 }
        return picked.isEmpty ? summary.pools : picked
    }

    // MARK: The two layouts

    /// One segment per account, in the accounts' display order. The caller passes the accounts the
    /// strip may show (the per-account menu-bar switches are its filter).
    static func perAccount(_ accounts: [AccountUsage], mode: DisplayMode,
                           focusedModel: (String, [String]) -> String?) -> [MenuBarSegment] {
        // Same-provider accounts are visually identical marks, so number them (1, 2, …) - the one
        // piece of identity the strip needs. A lone account gets no badge.
        let providerCounts = Dictionary(grouping: accounts, by: \.providerID).mapValues(\.count)
        var runningIndex: [String: Int] = [:]
        return accounts.map { account in
            let badge: Int? = (providerCounts[account.providerID] ?? 0) > 1
                ? { runningIndex[account.providerID, default: 0] += 1
                    return runningIndex[account.providerID] }()
                : nil
            if account.error != nil && !account.isStale {
                return MenuBarSegment(providerID: account.providerID, lines: ["!"],
                                      dimmed: false, badge: badge)
            }
            let lines = metrics(account, focusedModel: focusedModel).map {
                percent(used: $0.usedPercent, remaining: $0.remainingPercent, mode: mode)
            }
            return MenuBarSegment(providerID: account.providerID,
                                  lines: lines.isEmpty ? ["—"] : lines,
                                  dimmed: account.isStale, badge: badge)
        }
    }

    /// One segment per provider, each summing that provider's accounts - the strip read as budgets
    /// rather than as accounts, for a fleet whose per-account strip has outgrown the bar.
    ///
    /// `summaries` are the pools, built by `FleetMath` over the accounts the PANEL's gauge reads
    /// (with `minMembers: 1`, so a single-account provider still gets its own pool of one). Passing
    /// them in rather than deriving them here is what makes "the strip and the gauge agree" a fact
    /// about one calculation instead of a promise: every pool of two or more is the very pool the
    /// gauge draws, member for member.
    ///
    /// A provider with no pool at all is one whose accounts have no metrics to pool - a first fetch
    /// that failed, or a provider that reported nothing - and reads the same way a lone account's
    /// segment does in that state.
    static func pooled(_ accounts: [AccountUsage], summaries: [FleetSummary], mode: DisplayMode,
                       focusedModel: (String, [String]) -> String?) -> [MenuBarSegment] {
        let byProvider = Dictionary(summaries.map { ($0.providerID, $0) },
                                    uniquingKeysWith: { first, _ in first })
        return providerGroups(accounts).map { providerID, members in
            guard let summary = byProvider[providerID] else {
                let failed = members.allSatisfy { $0.error != nil && !$0.isStale }
                return MenuBarSegment(providerID: providerID, lines: [failed ? "!" : "—"],
                                      dimmed: false,
                                      badge: members.count > 1 ? members.count : nil)
            }
            let lines = pools(summary, focusedModel: focusedModel).map {
                // The pool's average, exactly as the gauge's value column reads it: remaining by
                // default, and in Used mode the complement of the same average - never a second
                // arithmetic that could round the other way.
                percent(used: 100 - $0.averageRemaining, remaining: $0.averageRemaining, mode: mode)
            }
            return MenuBarSegment(
                providerID: providerID, lines: lines.isEmpty ? ["—"] : lines,
                // ANY member stale dims the segment: the pooled figure has that account's
                // last-good numbers inside it, and a bright segment would claim they are fresh.
                dimmed: members.contains(where: \.isStale),
                // The fleet size the gauge's own label states (×N), so the two surfaces cannot
                // count the same fleet two ways.
                badge: summary.accountCount > 1 ? summary.accountCount : nil)
        }
    }

    /// The providers present in these accounts, each with its own accounts, in the accounts'
    /// display order. Shared with the tooltip, so the strip and its hover walk one list.
    static func providerGroups(
        _ accounts: [AccountUsage]
    ) -> [(providerID: String, accounts: [AccountUsage])] {
        var order: [String] = []
        var grouped: [String: [AccountUsage]] = [:]
        for account in accounts {
            if grouped[account.providerID] == nil { order.append(account.providerID) }
            grouped[account.providerID, default: []].append(account)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// The strip's one numeric form, following the Used/Left toggle.
    private static func percent(used: Double, remaining: Double, mode: DisplayMode) -> String {
        "\(Int((mode == .used ? used : remaining).rounded()))%"
    }
}
