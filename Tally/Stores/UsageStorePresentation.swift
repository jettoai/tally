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
        FleetMath.summaries(accounts: orderedAccounts, minMembers: 1) { usage in
            SettingsStore.shared.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
        }
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
                // No pool means no metrics to pool; the accounts' own error is the answer.
                return "\(head): \(members.compactMap(\.error).first ?? "—")"
            }
            let parts = MenuBarSegments.pools(summary, focusedModel: Self.focusedModel).map { pool in
                let value = mode == .used ? 100 - pool.averageRemaining : pool.averageRemaining
                return "\(L(pool.label)) \(Int(value.rounded()))%"
            }
            let stale = members.contains(where: \.isStale) ? " (\(L("Outdated")))" : ""
            return "\(head): \(parts.joined(separator: " · "))\(stale)\(Self.missingNote(members))"
        }.joined(separator: "\n")
    }

    /// " · 1 failed: <reason>" for the accounts that contributed nothing to the pool, empty when
    /// every member is in. Without it the ×N counts an account the figures do not, and the only
    /// other sign is a dimmed segment that could equally mean "outdated".
    private static func missingNote(_ members: [AccountUsage]) -> String {
        guard let missing = MenuBarSegments.missingFromPool(members) else { return "" }
        // The count interpolated as a String on purpose: an Int makes the catalog key "%lld …",
        // which matches no entry and silently renders the English source in every other language
        // (the fleet tooltip's capacity line states the whole trap, FleetStripView.swift).
        return " · " + String(localized: "\(String(missing.count)) failed: \(missing.reason)",
                              bundle: AppLocale.bundle)
    }
}
