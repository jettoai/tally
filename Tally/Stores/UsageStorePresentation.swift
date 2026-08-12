import Foundation

// What the panel, the popover and the menu-bar strip read off the store: derived views over
// `accounts`, holding no state of their own and never fetching. Lifted out of UsageStore.swift
// (past the repo's 500-line cap) along the seam the callers already use - the refresh loop, the
// retry ladder and the snapshot publishing that stayed there are reached from timers and settings
// writes, while everything here is reached from a view body or the status item's redraw.

extension UsageStore {
    enum ContentState {
        case loading            // first fetch in flight
        case allProvidersOff    // every provider disabled in settings
        case noAccounts         // providers on, but no signed-in accounts found
        case hasAccounts
    }

    /// Which empty/populated state the popover and dashboard should show.
    var contentState: ContentState {
        if !accounts.isEmpty { return .hasAccounts }
        if SettingsStore.shared.enabledProviders.isEmpty { return .allProvidersOff }
        if lastRefreshedAt == nil { return .loading }
        return .noAccounts
    }

    /// Accounts in the user's custom drag-reordered order (falls back to discovery order).
    var orderedAccounts: [AccountUsage] {
        let order = SettingsStore.shared.orderedAccountIDs(accounts.map(\.id))
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    /// The accounts the PER-ACCOUNT strip may show: the display order minus the ones switched off
    /// in the Settings list's menu-bar column. That switch picks which marks stand in the bar, a
    /// question the pooled layout does not ask - there the segment is the provider's whole budget,
    /// and quietly leaving a member out would print a figure no other surface shows.
    private var menuBarAccounts: [AccountUsage] {
        orderedAccounts.filter { SettingsStore.shared.isShownInMenuBar($0.id) }
    }

    /// The pools the POOLED strip sums: `FleetMath` over the same accounts the panel's fleet gauge
    /// reads, in the same order, differing only in `minMembers: 1` - which adds pools of one (a
    /// single-account provider, whose segment would otherwise have nothing to show) without
    /// touching any pool the gauge itself draws.
    private var menuBarPools: [FleetSummary] {
        FleetMath.summaries(accounts: orderedAccounts, minMembers: 1, label: Self.displayName)
    }

    /// The name every fleet reading calls an account by: the user's own. ONE function for the pools
    /// and for both hover notes, because `FleetPool.Member` records a LABEL rather than an id - a
    /// note that labels accounts differently from the pools it compares them against cannot match
    /// them up at all (`MenuBarSegments.windowGaps` states what that would look like).
    private static func displayName(_ usage: AccountUsage) -> String {
        SettingsStore.shared.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
    }

    /// The strip's segments, in whichever layout the user picked (`MenuBarLayout`). Both are built
    /// in `MenuBarSegments`; this is only the wiring that hands them the stores' answers.
    var menuBarSegments: [MenuBarSegment] {
        let mode = SettingsStore.shared.displayMode
        switch SettingsStore.shared.menuBarLayout {
        case .perAccount:
            return MenuBarSegments.perAccount(menuBarAccounts, mode: mode,
                                              focusedModel: Self.focusedModel)
        case .pooled:
            return MenuBarSegments.pooled(orderedAccounts, summaries: menuBarPools, mode: mode,
                                          focusedModel: Self.focusedModel)
        }
    }

    /// Hovering the status item spells out what the marks cannot - which accounts, and what each
    /// number sums. Doubles as the strip image's VoiceOver description.
    var menuBarTooltip: String {
        switch SettingsStore.shared.menuBarLayout {
        case .perAccount: return perAccountTooltip
        case .pooled: return pooledTooltip
        }
    }

    /// One line per account: its name and its windows.
    private var perAccountTooltip: String {
        let mode = SettingsStore.shared.displayMode
        return menuBarAccounts.map { account in
            let label = SettingsStore.shared.displayLabel(accountID: account.id,
                                                          fallback: account.accountLabel)
            if let error = account.error, !account.isStale { return "\(label): \(error)" }
            let parts = MenuBarSegments.metrics(account, focusedModel: Self.focusedModel)
                .map { metric in
                    let value = mode == .used ? metric.usedPercent : metric.remainingPercent
                    return "\(L(metric.label)) \(Int(value.rounded()))%"
                }
            let stale = account.isStale ? " (\(L("Outdated")))" : ""
            return "\(label): \(parts.joined(separator: " · "))\(stale)"
        }.joined(separator: "\n")
    }

    /// One line per provider: the fleet and its pooled windows ("Claude ×5: Session 41% · …"). The
    /// ×N counts every account the segment stands for (the badge's own count, not the pool's), and
    /// the pools come from the same selection the segments are built from, so the hover can never
    /// name a window the strip is not showing. Whoever is missing from those figures is named at
    /// the end - the strip can only say that something is off by dimming.
    private var pooledTooltip: String {
        let mode = SettingsStore.shared.displayMode
        let byProvider = Dictionary(menuBarPools.map { ($0.providerID, $0) },
                                    uniquingKeysWith: { first, _ in first })
        return MenuBarSegments.providerGroups(orderedAccounts).map { providerID, members in
            let head = "\(ProviderCatalog.displayName(for: providerID)) ×\(members.count)"
            guard let summary = byProvider[providerID] else {
                // No pool means no metrics to pool, so EVERY member is a missing one and the same
                // naming applies: one account's error was standing in for all of them here too.
                let named = Self.missingNamed(members)
                return "\(head): \(named.isEmpty ? "—" : named)"
            }
            // The same pools the segment draws, held so the note below can say which of them is
            // short of members (MenuBarSegments.windowGaps).
            let drawn = MenuBarSegments.pools(summary, focusedModel: Self.focusedModel)
            let parts = drawn.map { pool in
                let value = mode == .used ? 100 - pool.averageRemaining : pool.averageRemaining
                return "\(L(pool.label)) \(Int(value.rounded()))%"
            }
            let stale = members.contains(where: \.isStale) ? " (\(L("Outdated")))" : ""
            return "\(head): \(parts.joined(separator: " · "))\(stale)"
                + Self.missingNote(members) + Self.windowGapNote(members, pools: drawn)
        }.joined(separator: "\n")
    }

    /// " · 2 failed: Work (Login expired), Side (No usage data)" for the accounts that contributed
    /// nothing to the pool, empty when every member is in. Without it the ×N counts accounts the
    /// figures do not, and the only other sign is a dimmed segment that could equally mean
    /// "outdated".
    ///
    /// EVERY ONE OF THEM BY NAME AND BY ITS OWN REASON: a count with one reason attached applied
    /// the first account's diagnosis to all of them and identified none, which the per-account
    /// hover never does (it prints "label: error" per row). Renames are honoured here for the same
    /// reason - this is the name the user reads everywhere else.
    private static func missingNote(_ members: [AccountUsage]) -> String {
        let missing = missingFromPool(members)
        guard !missing.isEmpty else { return "" }
        let named = MenuBarSegments.missingDetail(missing, noData: L("No usage data"))
        // The count interpolated as a String on purpose: an Int makes the catalog key "%lld …",
        // which matches no entry and silently renders the English source in every other language
        // (the fleet tooltip's capacity line states the whole trap, FleetStripView.swift).
        return " · " + String(localized: "\(String(missing.count)) failed: \(named)",
                              bundle: AppLocale.bundle)
    }

    /// " · incomplete: Weekly (Side)" for a member that reported SOME windows and so sits in one
    /// of the drawn lines and not another. A DIFFERENT SENTENCE from the one above, deliberately:
    /// that account has not failed at anything and is not absent from the segment, so counting it
    /// among the failures would say something untrue about it. The window comes first because it
    /// names the row whose figure is short.
    ///
    /// No count in the key, so there is no `%lld` trap to sidestep here (the note above explains
    /// the one it does sidestep).
    private static func windowGapNote(_ members: [AccountUsage], pools: [FleetPool]) -> String {
        let gaps = MenuBarSegments.windowGaps(members, pools: pools, label: displayName)
        guard !gaps.isEmpty else { return "" }
        let named = MenuBarSegments.windowGapDetail(gaps) { L($0) }
        return " · " + String(localized: "incomplete: \(named)", bundle: AppLocale.bundle)
    }

    /// Who is out of the pool, under the names the user reads everywhere else - one resolution for
    /// both places the hover asks, so a rename cannot reach one branch and not the other.
    private static func missingFromPool(_ members: [AccountUsage]) -> [(label: String, reason: String?)] {
        MenuBarSegments.missingFromPool(members, label: displayName)
    }

    /// Those members, worded. Empty when nothing is missing, which the no-pool branch reads as
    /// "nothing to say" and prints as the no-data glyph.
    private static func missingNamed(_ members: [AccountUsage]) -> String {
        MenuBarSegments.missingDetail(missingFromPool(members), noData: L("No usage data"))
    }
}
