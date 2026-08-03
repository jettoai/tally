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
    /// first history read completes; demo mode fills it from fixtures instead, since a demo launch
    /// has no history to read.
    private(set) var advisorReadings: [UsageAdvisor.Reading] = []

    private let providers = ProviderCatalog.all
    private var timer: DispatchSourceTimer?
    /// Held for the app's lifetime: the watcher tears its stream down when it is released.
    private var accountWatcher: AccountDirWatcher?

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
        startAccountWatcher()
    }

    /// Watches the provider config dirs so an account that finishes logging in shows up now rather
    /// than on the next tick (AccountDirWatcher.swift). Only a change in the SET of discoverable
    /// accounts reaches `refresh`; the discovery pass in between is local and cheap, which is what
    /// keeps a busy `.claude.json` from turning into usage-API traffic.
    private func startAccountWatcher() {
        let watcher = AccountDirWatcher(
            discoverChanged: { [weak self] in
                guard let self else { return false }
                let found = providers.flatMap { $0.discoverAccounts() }
                // A signed-out account is not discoverable - that is what being signed out means
                // here - so the dormant ones are merged back in BEFORE anything compares sets.
                // Without this every event on a machine with one would read as "an account
                // disappeared" and buy a refresh, which is the exact traffic this filter exists
                // to keep away.
                let all = KnownAccountsStore.shared.reconcile(discovered: found).all
                guard accountSetChanged(from: self.discoveredAccounts, to: all) else { return false }
                // Adopt it here so the Settings list is right even if the refresh below is queued
                // behind one already running, and so a second event does not report the same news.
                self.discoveredAccounts = all
                self.onChange?()
                return true
            },
            onChange: { [weak self] in Task { await self?.refresh(userInitiated: false) } })
        watcher.start()
        accountWatcher = watcher
    }

    /// Every account on this machine, discovered on the spot while the first refresh has not
    /// filled the list yet. For the launch flags, which fire from `applicationDidFinishLaunching`
    /// with that refresh only just queued: reading the empty list there is how the expiry flag's
    /// sample alert ended up naming no account at all. Discovery is local and cheap - the same
    /// pass the config-dir watcher runs on every event.
    func discoveredAccountsNow() -> [ProviderAccount] {
        guard discoveredAccounts.isEmpty else { return discoveredAccounts }
        return KnownAccountsStore.shared
            .reconcile(discovered: providers.flatMap { $0.discoverAccounts() }).all
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
            advisorReadings = DemoUsage.advisorReadings
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
        // An account that signed OUT stops being discoverable at all - Claude's logout deletes the
        // Keychain item, Codex's deletes auth.json - so discovery alone drops it from the app at
        // the exact moment the expiry alert is about it. The remembered accounts whose home is
        // still on disk come back here as dormant ones: listed, probed, renewable. A home that is
        // GONE is a removal instead, and is forgotten (KnownAccounts.swift).
        let (known, dormant) = KnownAccountsStore.shared.reconcile(discovered: allDiscovered)
        discoveredAccounts = known

        // The enablement set may have changed while the CLIs ran: keep rows of providers enabled
        // NOW that this round didn't fetch (the queued follow-up replaces them with live data),
        // and drop rows of providers disabled mid-flight.
        let enabledNow = SettingsStore.shared.enabledProviders
        // A dormant account gets a row rather than a fetch: there is no credential left to fetch
        // with, and a card is where its "Login expired" chip lives. Kept out of `results` so an
        // account that stays signed out cannot hold the failure-retry ladder open for as long as
        // it does.
        let dormantRows = dormant
            .filter { enabledNow.contains($0.providerID) && SettingsStore.shared.isAccountEnabled($0.id) }
            .map { AccountUsage.failure(account: $0, providerID: $0.providerID,
                                        message: L("Login expired")) }
        let merged = (results + dormantRows).map(applyLastGood)
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
            // Alert when the claude flagship fleet pool crosses the low/dry tripwire. Release
            // variant only: the dev variant never owns the shared surfaces, so it never alerts.
            notifyFlagshipDryness(accounts: labeled)
            // And when a banked reset is worth spending: the user has to REMEMBER to look at a
            // credit otherwise. Same rule as every other surface here - it names the account, it
            // never redeems.
            ResetHintNotifier.shared.evaluate(accounts: labeled)
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
        // advisor's own sample type. Demo mode never reaches this read (its refresh returned
        // above); the guard below keeps the fixture readings the only ones a demo panel can show
        // even if that early return ever moves.
        UsageHistory.shared.samples(
            since: now.addingTimeInterval(-UsageAdvisor.lookbackDays * 86_400)) { samples in
            let advisorSamples = samples.map {
                UsageAdvisor.Sample(ts: $0.ts, account: $0.account, provider: $0.provider,
                                    window: $0.window, model: $0.model, used: $0.used,
                                    resetAt: $0.resetAt)
            }
            let readings = UsageAdvisor.readings(samples: advisorSamples, now: now)
            Task { @MainActor in
                guard !DemoUsage.isActive else { return }
                UsageStore.shared.advisorReadings = readings
            }
        }
        // Ask the provider CLIs whether each account is still signed in. Detached rather than
        // awaited: it throttles itself to its own (much longer) interval, and a refresh must not
        // hold the snapshot behind a question about credentials. Only the accounts actually being
        // polled are asked - a switched-off account is not one the user wants processes spawned for.
        // `known` (every account that EXISTS, dormant ones included) goes along separately because
        // the dedup state is pruned against it and must not shrink when an account is switched off
        // - see `LoginStatusStore.announce`.
        let polled = known.filter {
            enabledNow.contains($0.providerID) && SettingsStore.shared.isAccountEnabled($0.id)
        }
        Task { await LoginStatusStore.shared.evaluate(accounts: polled,
                                                      known: Set(known.map(\.id)),
                                                      userInitiated: userInitiated) }
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

    /// Feed the claude flagship weekly pool to the dry-pool notifier. The flagship window is chosen
    /// by tier order (not the gauge's display focus), so the tripwire watches the top model pool
    /// regardless of what the panel currently shows. No pool (fewer than two accounts share the
    /// flagship window) means nothing to arm.
    private func notifyFlagshipDryness(accounts labeled: [AccountUsage]) {
        let now = Date()
        let summaries = FleetMath.summaries(accounts: labeled, now: now) { $0.accountLabel }
        guard let summary = summaries.first(where: { $0.providerID == "claude" }),
              let flagship = FleetFocus.flagship(summary.modelPoolNames,
                                                 order: ModelCatalog.claudeAliases),
              let pool = summary.pools.first(where: {
                  $0.kind == .weeklyModel && ($0.modelName ?? $0.label) == flagship
              }),
              // No known upcoming reset means stale or partial data (e.g. wake-from-sleep with
              // fetches still failing): a nil reset would read as a new cycle and re-fire a stale
              // alert. Skip this round; the next successful fetch recovers naturally.
              pool.nextReset != nil else { return }
        DryPoolNotifier.shared.evaluate(
            remaining: pool.totalRemaining,
            capacity: Double(pool.members.count) * 100,
            accountCount: pool.members.count,
            resetAt: pool.nextReset,
            windowName: pool.modelName ?? pool.label)
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
        // The numbers are stale; the identity need not be. Whatever this round established without
        // the poll (Claude reads plan and email from a local config file) replaces the last-good
        // copy, so a config dir signed in as somebody else stops showing the previous account's
        // email. Nil means this round could not tell, not that there is no identity, so it leaves
        // the known value alone.
        if let plan = usage.planName { previous.planName = plan }
        if let email = usage.accountEmail { previous.accountEmail = email }
        if streak >= Self.staleAfterFailures {
            previous.isStale = true
            previous.error = usage.error  // reason, shown as an "Outdated" tooltip
        }
        return previous
    }
}
