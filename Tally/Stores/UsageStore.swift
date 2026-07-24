import Foundation
import Observation

/// Owns the live usage snapshots and the periodic refresh loop. Shared singleton.
///
/// Refresh model: fetch every enabled account concurrently, on a
/// user-configurable interval. `onChange` lets the AppKit status item update its title without SwiftUI
/// observation. Claude's usage endpoint rate-limits aggressively, so the default interval is
/// conservative and manual refresh is available on demand.
@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var accounts: [AccountUsage] = []
    /// Every account that EXISTS on this machine (all providers, including disabled ones) - the
    /// Settings list renders from this, so a switched-off account stays visible and can be
    /// switched back on. Refreshed on every poll; discovery is local and cheap.
    private(set) var discoveredAccounts: [ProviderAccount] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshedAt: Date?
    /// Set only when a refresh produced at least one non-error account - drives the "updated …" header
    /// so it never reads fresh while everything actually failed.
    private(set) var lastSuccessfulRefreshAt: Date?

    /// Called on the main actor after every refresh.
    var onChange: (() -> Void)?

    /// Burn rate per pooled weekly-cycle window (keyed by `FleetForecast.rateKey`), recomputed from the usage history after each
    /// refresh - what the fleet strip's "lasts about …" forecast runs on.
    private(set) var fleetRates: [String: FleetRate] = [:]

    /// The usage advisor's per-provider "do I need another account?" verdict, recomputed from the
    /// 28-day burn history after each refresh - what the advisor strip renders. Empty until the
    /// first history read completes, and stays empty in demo mode (its refresh returns before this
    /// read is ever reached).
    private(set) var advisorReadings: [UsageAdvisor.Reading] = []

    private let providers = ProviderCatalog.all
    private var timer: DispatchSourceTimer?

    /// When the next automatic poll fires (main timer or an earlier failure retry) - drives the
    /// header's "updates in Xs" countdown.
    var nextRefreshAt: Date? {
        [mainTimerNextFire, retryFireAt].compactMap { $0 }.min()
    }
    private var mainTimerNextFire: Date?

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
            Task { @MainActor in
                self?.mainTimerNextFire = Date().addingTimeInterval(interval)
                await self?.refresh(userInitiated: false)
            }
        }
        timer.resume()
        self.timer = timer
        mainTimerNextFire = Date().addingTimeInterval(interval)
    }

    // MARK: Fast retry after a failed poll

    /// Backoff ladder for retrying after a failure, so a transient miss (the seconds-long window
    /// while the CLI rotates a token, a network blip) heals in ~1 minute instead of sitting on
    /// screen until the next full 5-minute tick. Doubles per consecutive failure so a real outage
    /// (e.g. a 429 spell) is probed gently, and never exceeds the regular interval.
    private var retryTimer: DispatchSourceTimer?
    private var retryDelay: TimeInterval = 60
    private var retryFireAt: Date?

    private func scheduleRetryIfNeeded(anyFailure: Bool) {
        retryTimer?.cancel()
        retryTimer = nil
        retryFireAt = nil
        guard anyFailure else {
            retryDelay = 60   // healthy again - reset the ladder
            return
        }
        let interval = TimeInterval(max(1, SettingsStore.shared.refreshIntervalMinutes) * 60)
        let delay = min(retryDelay, interval)
        retryDelay = min(retryDelay * 2, interval)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.retryFireAt = nil
                await self?.refresh(userInitiated: false)
            }
        }
        timer.resume()
        retryTimer = timer
        retryFireAt = Date().addingTimeInterval(delay)
    }

    /// Optimistically drop rows the user just switched off (an account or a whole provider) so
    /// every surface reacts instantly; the refresh right behind converges the snapshot too.
    func hideAccounts(where predicate: (AccountUsage) -> Bool) {
        let filtered = accounts.filter { !predicate($0) }
        guard filtered.count != accounts.count else { return }
        accounts = filtered
        onChange?()
    }

    /// Instantly restore the last-good rows of a just re-enabled provider, so Settings doesn't sit
    /// on a blank group while the CLIs re-fetch (10-20s). The refresh right behind this call
    /// overwrites them with live data.
    func showCachedAccounts(providerID: String) {
        let cached = lastGood.values.filter { usage in
            usage.providerID == providerID
                && SettingsStore.shared.isAccountEnabled(usage.id)
                && !accounts.contains { $0.id == usage.id }
        }
        guard !cached.isEmpty else { return }
        accounts = (accounts + cached).sorted {
            ($0.providerID, $0.accountLabel) < ($1.providerID, $1.accountLabel)
        }
        onChange?()
    }

    /// A refresh requested while one is in flight runs right after it (coalesced to one). Without
    /// this, rapidly re-enabling a provider lost its follow-up fetch: the in-flight refresh (started
    /// while the provider was still off) finished, wiped the provider's rows, and nothing re-fetched
    /// until the next timer tick.
    private var refreshQueued = false

    func refresh(userInitiated: Bool = false) async {
        guard !isRefreshing else { refreshQueued = true; return }
        // Screenshot fixtures replace the whole poll: no CLI runs, no snapshot write (so a demo
        // instance can't steer the `tally` CLI), no retry ladder.
        if DemoUsage.isActive {
            accounts = DemoUsage.accounts()
            fleetRates = DemoUsage.fleetRates
            lastRefreshedAt = Date()
            lastSuccessfulRefreshAt = lastRefreshedAt
            onChange?()
            return
        }
        isRefreshing = true
        onChange?()

        let enabled = SettingsStore.shared.enabledProviders
        var results: [AccountUsage] = []
        var allDiscovered: [ProviderAccount] = []
        var launchHomes: [String: String] = [:]   // account id → CLI config home, for the snapshot
        for provider in providers {
            let found = provider.discoverAccounts()
            allDiscovered.append(contentsOf: found)
            guard enabled.contains(provider.id) else { continue }
            // Disabled accounts are discovered (Settings shows them) but never polled - and never
            // reach the snapshot, so the `tally` CLI skips them too.
            let active = found.filter { SettingsStore.shared.isAccountEnabled($0.id) }
            for account in active {
                if let home = account.launchHome { launchHomes[account.id] = home }
            }
            await withTaskGroup(of: AccountUsage.self) { group in
                for account in active {
                    group.addTask { await provider.fetchUsage(for: account, userInitiated: userInitiated) }
                }
                for await usage in group { results.append(usage) }
            }
        }
        discoveredAccounts = allDiscovered

        let merged = results.map(applyLastGood)
        // The enablement set may have changed while the CLIs ran: keep rows of providers enabled
        // NOW that this round didn't fetch (the queued follow-up replaces them with live data),
        // and drop rows of providers disabled mid-flight.
        let enabledNow = SettingsStore.shared.enabledProviders
        let fetchedIDs = Set(merged.map(\.id))
        let carried = accounts.filter {
            enabledNow.contains($0.providerID) && !fetchedIDs.contains($0.id)
        }
        accounts = (merged + carried)
            .filter { enabledNow.contains($0.providerID) && SettingsStore.shared.isAccountEnabled($0.id) }
            .sorted { ($0.providerID, $0.accountLabel) < ($1.providerID, $1.accountLabel) }
        isRefreshing = false
        lastRefreshedAt = Date()
        if results.contains(where: { $0.error == nil }) {
            lastSuccessfulRefreshAt = Date()
        }
        onChange?()
        // Publish the non-secret snapshot the `tally` CLI reads to pick a launch account.
        // Publish DISPLAY labels (the user's nicknames, default names as fallback) so the CLI
        // side - status line, pick messages, tally status - speaks the same names as the panel.
        let labeled = accounts.map { usage in
            var copy = usage
            copy.accountLabel = SettingsStore.shared.displayLabel(accountID: usage.id,
                                                                  fallback: usage.accountLabel)
            return copy
        }
        // The dev variant (side-by-side testing) never publishes: one poller owns the shared
        // ~/.tally files, and it is the installed release app.
        if !BuildVariant.isDev {
            lastPublishedAccounts = labeled
            lastLaunchHomes = launchHomes
            republishSnapshot()
            // Sample fresh results into the burn-rate history (change-only, off-main-queue).
            UsageHistory.shared.record(results)
        }
        let now = Date()
        UsageHistory.shared.samples(
            since: now.addingTimeInterval(-FleetForecast.lookbackHours * 3_600)) { samples in
            let rates = FleetForecast.weeklyRates(samples: samples, now: now)
            Task { @MainActor in
                UsageStore.shared.fleetRates = rates
                // The snapshot's fleet forecast is computed from these rates - refresh it.
                UsageStore.shared.republishSnapshot()
            }
        }
        // The advisor needs a wider window than the pace forecast (weekly demand needs weeks, not
        // hours), so it reads the history separately. Same off-main queue, mapped into the pure
        // advisor's own sample type.
        UsageHistory.shared.samples(
            since: now.addingTimeInterval(-UsageAdvisor.lookbackDays * 86_400)) { samples in
            let advisorSamples = samples.map {
                UsageAdvisor.Sample(ts: $0.ts, account: $0.account, provider: $0.provider,
                                    window: $0.window, model: $0.model, used: $0.used,
                                    resetAt: $0.resetAt)
            }
            let readings = UsageAdvisor.readings(samples: advisorSamples, now: now)
            Task { @MainActor in UsageStore.shared.advisorReadings = readings }
        }
        // Any failed account → probe again soon (backoff) instead of waiting the full interval.
        scheduleRetryIfNeeded(anyFailure: results.contains { $0.error != nil })

        if refreshQueued {
            refreshQueued = false
            Task { await refresh(userInitiated: false) }
        }
    }

    /// Inputs of the last published snapshot, so a settings flip (display mode, status line
    /// options) can rewrite ~/.tally/snapshot.json immediately WITHOUT refetching usage.
    private var lastPublishedAccounts: [AccountUsage] = []
    private var lastLaunchHomes: [String: String] = [:]

    /// Rewrite the snapshot from the cached accounts + current settings. No-op for the dev
    /// variant and demo mode (neither may publish), or before the first successful refresh.
    func republishSnapshot() {
        guard !BuildVariant.isDev, !DemoUsage.isActive, !lastPublishedAccounts.isEmpty else { return }
        let (fleet, fleetPools) = fleetForSnapshot()
        UsageSnapshot.make(accounts: lastPublishedAccounts, launchHomes: lastLaunchHomes,
                           statuslineFullQuota: SettingsStore.shared.statuslineFullQuota,
                           displayMode: SettingsStore.shared.displayMode.rawValue,
                           fleet: fleet, fleetPools: fleetPools).write()
    }

    /// The model name the display leads with for `providerID`, given the available model window
    /// names - the glue between the pure resolver and the app's stores. One resolution shared by
    /// the fleet gauge, the menu-bar strip and the status line's fleet.
    static func focusedModel(providerID: String, available: [String]) -> String? {
        FleetFocus.focusedModel(SettingsStore.shared.gaugeFocus,
                                primaryModel: LaunchPolicyStore.shared.policy(providerID).model,
                                available: available,
                                flagshipOrder: ModelCatalog.claudeAliases)
    }

    /// The status line's fleet piece follows the SAME switch as the panel's gauge: published
    /// only while the gauge is on, and only for providers with a real pool (2+ accounts with a
    /// weekly window). Launch mode is deliberately irrelevant - one toggle, one meaning.
    ///
    /// Two shapes from one pass: `fleet` keeps the single headline pool (the pre-0.17 contract
    /// older CLIs render) and `fleetPools` carries the panel's ordered pool list (gauge focus
    /// applied, session pools excluded) for CLIs that render every pool the gauge shows.
    private func fleetForSnapshot() -> ([String: UsageSnapshot.Fleet]?,
                                        [String: [UsageSnapshot.Fleet]]?) {
        guard SettingsStore.shared.showFleetGauge else { return (nil, nil) }
        var fleet: [String: UsageSnapshot.Fleet] = [:]
        var fleetPools: [String: [UsageSnapshot.Fleet]] = [:]
        let now = Date()
        for summary in FleetMath.summaries(accounts: lastPublishedAccounts,
                                           label: { $0.accountLabel }) {
            let focused = Self.focusedModel(providerID: summary.providerID,
                                            available: summary.modelPoolNames)
            func published(_ pool: FleetPool) -> UsageSnapshot.Fleet {
                var dryAt: Date?
                var sustainable = false
                if let rate = fleetRates[FleetForecast.rateKey(
                    provider: summary.providerID, window: pool.kind.rawValue,
                    model: pool.modelName)] {
                    dryAt = FleetForecast.depletion(
                        remaining: pool.totalRemaining,
                        refills: pool.refills.map { ($0.at, $0.gain) },
                        perHour: rate.perHour,
                        steadyRefillPerHour: pool.steadyRefillPerHour(windowHours: 168),
                        now: now)
                    sustainable = dryAt == nil
                }
                return UsageSnapshot.Fleet(
                    remaining: pool.totalRemaining,
                    capacity: Double(pool.members.count) * 100,
                    dryAt: dryAt, sustainable: sustainable,
                    poolName: pool.kind == .weeklyModel ? (pool.modelName ?? pool.label) : nil)
            }
            if let pool = summary.headline(focusedModel: focused), pool.kind != .session {
                fleet[summary.providerID] = published(pool)
            }
            // Mirrors FleetStripView.displayedPools, so the status line shows the same pools
            // as the panel: "all" renders every weekly-cycle pool in display order, the
            // single-pool modes just the focus-resolved headline.
            let ordered: [FleetPool]
            switch SettingsStore.shared.gaugeFocus {
            case .all: ordered = summary.displayPools(focusedModel: focused)
            case .primary, .weekly:
                ordered = summary.headline(focusedModel: focused).map { [$0] } ?? []
            }
            let pools = ordered.filter { $0.kind != .session }
            if !pools.isEmpty { fleetPools[summary.providerID] = pools.map(published) }
        }
        return (fleet.isEmpty ? nil : fleet, fleetPools.isEmpty ? nil : fleetPools)
    }

    /// Last successful snapshot per account, so a failed refresh can keep showing the numbers.
    private var lastGood: [String: AccountUsage] = [:]
    /// Consecutive failed polls per account, so a single transient failure doesn't flip the badge.
    private var failureStreak: [String: Int] = [:]

    /// Only flag "Outdated" after this many consecutive failures. A single miss - e.g. the brief window
    /// while the CLI rotates the OAuth token, which 1-minute polling reliably catches - keeps showing the
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
