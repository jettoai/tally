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
            let missing = missingFromPool(members)
            // How many accounts this segment STANDS FOR - every account the provider has, not how
            // many made it into the pool. Counting only the contributors is what let a hole read as
            // a whole fleet: two accounts with one dead came back as `1`, which is no badge at all,
            // so the strip showed a healthy single account (codex review, 2026-08-12).
            let badge = members.count > 1 ? members.count : nil
            guard let summary = byProvider[providerID] else {
                // No pool at all, so the segment is a mark - and WHICH mark the ERRORS decide,
                // not the pool membership above: a provider whose accounts merely reported nothing
                // has failed at nothing, and "!" is the error mark. (One question while
                // `missingFromPool` asked about errors; two now that it asks what `FleetMath` does.)
                let allFailed = !members.isEmpty
                    && members.allSatisfy { $0.error != nil && !$0.isStale }
                return MenuBarSegment(providerID: providerID, lines: [allFailed ? "!" : "—"],
                                      dimmed: false, badge: badge)
            }
            let lines = pools(summary, focusedModel: focusedModel).map {
                // The pool's average, read the way the gauge's value column reads it: remaining by
                // default, its complement in Used mode. Both surfaces clamp where a per-account
                // meter does not - an account the provider reports at 103% used prints 103% on its
                // own segment and 100% in a pool, because `remainingPercent` floors at zero before
                // anything is averaged.
                percent(used: 100 - $0.averageRemaining, remaining: $0.averageRemaining, mode: mode)
            }
            return MenuBarSegment(
                providerID: providerID, lines: lines.isEmpty ? ["—"] : lines,
                // Either way a pooled figure stops being the whole truth dims the segment. A STALE
                // member's last-good numbers are inside the average; a member missing from the pool
                // has no numbers in it at all while the badge still counts it. A bright segment
                // would claim both away, and the badge alone cannot tell them apart - so the strip
                // says "not the whole truth" and the tooltip says which.
                dimmed: !missing.isEmpty || members.contains(where: \.isStale),
                badge: badge)
        }
    }

    /// The members whose numbers are missing from the pool ENTIRELY, each with its own name and its
    /// own reason. Typically a fetch that failed before the account ever had a good snapshot to fall
    /// back on (`AccountUsage.failure` carries no metrics), so `FleetMath` never saw it and the
    /// average is over the survivors.
    ///
    /// THE QUESTION IS THE POOL'S OWN: an account is missing exactly when it carries no metrics,
    /// the membership test `FleetMath.summaries` runs (`where !account.metrics.isEmpty`). The proxy
    /// this replaces - "has an error and is not stale" - is equivalent only while every provider
    /// reports `.failure` when it has nothing; one that reported nothing WITHOUT failing was out of
    /// the pool and unmentioned, the mirror of the hole this note exists to close (review of
    /// 266c427). It also excludes a STALE member by construction rather than by a second rule: its
    /// last-good numbers are in the average, which is the reading the panel calls "Outdated".
    ///
    /// EACH ONE BY NAME, because one count with one reason attached says something untrue as soon
    /// as two accounts are out for two reasons: "2 failed: Login expired" reads as one diagnosis
    /// for both and identifies neither. `reason` is nil for a member that never said why; the
    /// wording for that stays with the view that owns localization, the way `FleetTooltip` splits
    /// the same job.
    static func missingFromPool(
        _ members: [AccountUsage],
        label: (AccountUsage) -> String = { $0.accountLabel }
    ) -> [(label: String, reason: String?)] {
        members.filter(\.metrics.isEmpty).map { (label($0), $0.error) }
    }

    /// Those members as the hover names them: "Work (Login expired), Side (No usage data)". The
    /// count and the sentence around it are the view's (they are localized); this is the part that
    /// has to agree with `missingFromPool` about who is out and in what order, so it lives beside
    /// it and can be asserted without a status item on screen.
    ///
    /// `noData` is the caller's localized wording for a member that gave no reason of its own.
    static func missingDetail(_ missing: [(label: String, reason: String?)],
                              noData: String) -> String {
        missing.map { "\($0.label) (\($0.reason ?? noData))" }.joined(separator: ", ")
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
