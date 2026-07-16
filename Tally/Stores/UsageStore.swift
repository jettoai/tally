import Foundation
import Observation

/// Owns the live usage snapshots and the periodic refresh loop. Shared singleton.
///
/// Refresh model (adapted from OpenUsage): fetch every enabled account concurrently, on a
/// user-configurable interval. `onChange` lets the AppKit status item update its title without SwiftUI
/// observation. Claude's usage endpoint rate-limits aggressively, so the default interval is
/// conservative and manual refresh is available on demand.
@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var accounts: [AccountUsage] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshedAt: Date?
    /// Set only when a refresh produced at least one non-error account — drives the "updated …" header
    /// so it never reads fresh while everything actually failed.
    private(set) var lastSuccessfulRefreshAt: Date?

    /// Called on the main actor after every refresh.
    var onChange: (() -> Void)?

    private let providers = ProviderCatalog.all
    private var timer: DispatchSourceTimer?

    private init() {}

    func start() {
        // First launch counts as user-initiated: the app was just opened, so the one-time credential
        // prompt is expected here rather than on a later silent background tick.
        Task { await refresh(userInitiated: true) }
        scheduleTimer()
    }

    /// Rebuild the background timer from the current interval setting.
    func rescheduleRefresh() {
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.cancel()
        let interval = TimeInterval(max(1, SettingsStore.shared.refreshIntervalMinutes) * 60)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in await self?.refresh(userInitiated: false) }
        }
        timer.resume()
        self.timer = timer
    }

    func refresh(userInitiated: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?()

        let enabled = SettingsStore.shared.enabledProviders
        var results: [AccountUsage] = []
        var launchHomes: [String: String] = [:]   // account id → CLI config home, for the snapshot
        for provider in providers where enabled.contains(provider.id) {
            let discovered = provider.discoverAccounts()
            for account in discovered {
                if let home = account.launchHome { launchHomes[account.id] = home }
            }
            await withTaskGroup(of: AccountUsage.self) { group in
                for account in discovered {
                    group.addTask { await provider.fetchUsage(for: account, userInitiated: userInitiated) }
                }
                for await usage in group { results.append(usage) }
            }
        }

        let merged = results.map(applyLastGood)
        accounts = merged.sorted {
            ($0.providerID, $0.accountLabel) < ($1.providerID, $1.accountLabel)
        }
        isRefreshing = false
        lastRefreshedAt = Date()
        if results.contains(where: { $0.error == nil }) {
            lastSuccessfulRefreshAt = Date()
        }
        onChange?()
        // Publish the non-secret snapshot the `tally` CLI reads to pick a launch account.
        UsageSnapshot.make(accounts: accounts, launchHomes: launchHomes).write()
    }

    /// Last successful snapshot per account, so a failed refresh can keep showing the numbers.
    private var lastGood: [String: AccountUsage] = [:]
    /// Consecutive failed polls per account, so a single transient failure doesn't flip the badge.
    private var failureStreak: [String: Int] = [:]

    /// Only flag "Outdated" after this many consecutive failures. A single miss — e.g. the brief window
    /// while the CLI rotates the OAuth token, which 1-minute polling reliably catches — keeps showing the
    /// last-good numbers unbadged, so the badge stops flickering on every token refresh.
    private static let staleAfterFailures = 2

    /// On success, record the snapshot. On a transient failure keep the last-good numbers as-is; only a
    /// sustained failure (≥ staleAfterFailures in a row) marks them stale with the error tooltip. An
    /// account that never succeeded still shows a bare error immediately.
    private func applyLastGood(_ usage: AccountUsage) -> AccountUsage {
        if usage.error == nil {
            failureStreak[usage.id] = 0
            lastGood[usage.id] = usage
            return usage
        }
        let streak = (failureStreak[usage.id] ?? 0) + 1
        failureStreak[usage.id] = streak
        guard var previous = lastGood[usage.id] else { return usage }
        if streak >= Self.staleAfterFailures {
            previous.isStale = true
            previous.error = usage.error  // reason, shown as an "Outdated" tooltip
        }
        return previous
    }

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

    /// Per-account segments for the menu-bar strip. Each account shows its account-wide windows —
    /// session (5h) on top, weekly below — not a single exhausted model tier (a used-up Fable at 0%
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
        // Same-provider accounts are visually identical marks, so number them (1, 2, …) — the one
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

    /// Hovering the status item names every account with its numbers — the identity that can't fit in
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

    /// Account-wide windows only, ordered session → weekly; fall back to all metrics if none.
    private static func menuBarMetrics(_ account: AccountUsage) -> [UsageMetric] {
        let accountWide = account.metrics.filter { !$0.isModelScoped }
        return (accountWide.isEmpty ? account.metrics : accountWide)
            .sorted { menuBarOrder($0.kind) < menuBarOrder($1.kind) }
    }

    /// Menu-bar stacking order: session (5h) first, then weekly, then anything else.
    private static func menuBarOrder(_ kind: MetricKind) -> Int {
        switch kind {
        case .session: return 0
        case .weeklyAll: return 1
        default: return 2
        }
    }
}
