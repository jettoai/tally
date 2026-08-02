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

    /// Per-account segments for the menu-bar strip. Each account shows its account-wide windows -
    /// session (5h) on top, weekly below - not a single exhausted model tier (a used-up Fable at 0%
    /// would read as "the whole account is dead" when session/weekly still have room). Every account
    /// gets its own segment/mark, so N accounts read as N marks. Model-tier detail stays in the popover.
    /// Accounts in the user's custom drag-reordered order (falls back to discovery order).
    var orderedAccounts: [AccountUsage] {
        let order = SettingsStore.shared.orderedAccountIDs(accounts.map(\.id))
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    var menuBarSegments: [MenuBarSegment] {
        let shown = orderedAccounts.filter { SettingsStore.shared.isShownInMenuBar($0.id) }
        let mode = SettingsStore.shared.displayMode
        // Same-provider accounts are visually identical marks, so number them (1, 2, …) - the one
        // piece of identity the strip needs. A lone account gets no badge.
        let providerCounts = Dictionary(grouping: shown, by: \.providerID).mapValues(\.count)
        var runningIndex: [String: Int] = [:]
        return shown.map { account in
            let index: Int? = (providerCounts[account.providerID] ?? 0) > 1
                ? { runningIndex[account.providerID, default: 0] += 1
                    return runningIndex[account.providerID] }()
                : nil
            if account.error != nil && !account.isStale {
                return MenuBarSegment(providerID: account.providerID, lines: ["!"],
                                      dimmed: false, accountIndex: index)
            }
            let lines = Self.menuBarMetrics(account).map { metric -> String in
                let value = mode == .used ? metric.usedPercent : metric.remainingPercent
                return "\(Int(value.rounded()))%"
            }
            return MenuBarSegment(providerID: account.providerID,
                                  lines: lines.isEmpty ? ["—"] : lines,
                                  dimmed: account.isStale, accountIndex: index)
        }
    }

    /// Hovering the status item names every account with its numbers - the identity that can't fit in
    /// the strip itself. Doubles as the strip image's VoiceOver description.
    var menuBarTooltip: String {
        let shown = orderedAccounts.filter { SettingsStore.shared.isShownInMenuBar($0.id) }
        let mode = SettingsStore.shared.displayMode
        return shown.map { account in
            let label = SettingsStore.shared.displayLabel(accountID: account.id,
                                                          fallback: account.accountLabel)
            if let error = account.error, !account.isStale { return "\(label): \(error)" }
            let parts = Self.menuBarMetrics(account).map { metric in
                let value = mode == .used ? metric.usedPercent : metric.remainingPercent
                return "\(L(metric.label)) \(Int(value.rounded()))%"
            }
            let stale = account.isStale ? " (\(L("Outdated")))" : ""
            return "\(label): \(parts.joined(separator: " · "))\(stale)"
        }.joined(separator: "\n")
    }

    /// The strip's stacked numbers: session (5h) first, then the FOCUSED weekly window - the
    /// model window the gauge focus resolves to (e.g. Fable), or the account-wide weekly when no
    /// model focus applies. Same resolution as the fleet gauge, so the number in the menu bar is
    /// the number on the gauge. Falls back to all metrics when neither window exists.
    private static func menuBarMetrics(_ account: AccountUsage) -> [UsageMetric] {
        let session = account.metrics.filter { $0.kind == .session }
        let modelNames = account.metrics
            .filter { $0.kind == .weeklyModel }.map { $0.modelName ?? $0.label }
        let focused = focusedModel(providerID: account.providerID, available: modelNames)
        let weekly = focused.flatMap { name in
            account.metrics.first { $0.kind == .weeklyModel && ($0.modelName ?? $0.label) == name }
        } ?? account.metrics.first { $0.kind == .weeklyAll }
        let picked = session + [weekly].compactMap { $0 }
        return picked.isEmpty ? account.metrics : picked
    }
}
