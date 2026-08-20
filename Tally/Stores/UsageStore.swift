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
    /// Whether a discovery pass has finished at least once this launch - a different question from
    /// whether it found anything, and the one a surface has to ask before it renders "no accounts"
    /// (AccountListState.swift). The pass lands at the END of a refresh round, behind every provider
    /// CLI that round polls, so on the cold start every self-update performs, an empty
    /// `discoveredAccounts` means "not asked yet" for as long as that takes.
    private(set) var hasDiscovered = false
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
                self.adoptDiscovered(all)
                self.onChange?()
                return true
            },
            onChange: { [weak self] in Task { await self?.refresh(userInitiated: false) } })
        watcher.start()
        accountWatcher = watcher
    }

    /// Adopt a freshly discovered account set as what this store knows, from either of the two
    /// passes that produce one (the watcher above and the refresh below).
    ///
    /// An account that was dormant and is discoverable again has a credential on disk once more,
    /// and discovery is credential-shaped: that is stronger evidence than the verdict the card's
    /// "Login expired" chip is read off, which was written by a probe that ran BEFORE the login
    /// landed. Saying so here is what takes the chip down the moment the credential appears, rather
    /// than at the probe's own five-minute interval - the tail of the Terminal-handoff path, where
    /// Tally cannot see the login finish at all (codex review, 2026-08-03).
    private func adoptDiscovered(_ accounts: [ProviderAccount]) {
        let dormantBefore = Set(discoveredAccounts.filter(\.isDormant).map(\.id))
        discoveredAccounts = accounts
        // Every route that produces a set passes through here, so this is the one place that can
        // say the question has been asked - including when the answer is "none".
        hasDiscovered = true
        guard !dormantBefore.isEmpty else { return }
        LoginStatusStore.shared.loginLanded(
            dormantBefore.intersection(accounts.lazy.filter { !$0.isDormant }.map(\.id)))
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

    /// …and the same pass ADOPTED, for a surface that opens before the first refresh has produced
    /// one: the Settings account list, which draws from nothing else. Without it that list waits
    /// out every provider CLI the first round polls (10-20s on the relaunch an update performs)
    /// before it can show a single account.
    ///
    /// Once per launch (the flag it sets is what stops the second caller), and never on a demo
    /// instance: a screenshot run does not discover at all - its refresh returns before the pass -
    /// and must not start reading this machine's real config homes because a pane opened.
    func ensureDiscovered() {
        guard !hasDiscovered, !DemoUsage.isActive else { return }
        adoptDiscovered(discoveredAccountsNow())
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
    /// …and the coalesced refresh inherits the strongest reason any of the merged ones had. A
    /// renewal that lands while a poll is running asks for a USER-INITIATED refresh, which is what
    /// makes the login probe skip its five-minute throttle; dropping the flag here left a
    /// just-renewed account wearing its red "Login expired" chip for the rest of that interval.
    private var queuedUserInitiated = false

    func refresh(userInitiated: Bool = false) async {
        guard !isRefreshing else {
            refreshQueued = true
            queuedUserInitiated = queuedUserInitiated || userInitiated
            return
        }
        // Screenshot fixtures replace the whole poll: no CLI runs, no snapshot write (so a demo
        // instance can't steer the `tally` CLI), no retry ladder.
        if DemoUsage.isActive {
            accounts = DemoUsage.accounts()
            fleetRates = DemoUsage.fleetRates
            advisorReadings = DemoUsage.advisorReadings
            // This branch REPLACES the discovery pass, so a demo run's answer about which accounts
            // exist is as final as it will ever get. Saying so keeps the Settings list from sitting
            // on a "still looking" placeholder that nothing is ever going to resolve - and the
            // fixtures answer it, rather than an empty list, because the Settings account list draws
            // from existence rather than from usage and would otherwise be the one pane a capture
            // cannot photograph. Assigned rather than adopted: `adoptDiscovered` is the real pass's
            // bookkeeping (dormancy notices, removal rounds), and none of it is about fixtures.
            discoveredAccounts = DemoUsage.discoveredAccounts()
            hasDiscovered = true
            lastRefreshedAt = Date()
            lastSuccessfulRefreshAt = lastRefreshedAt
            onChange?()
            return
        }
        isRefreshing = true
        // Everything below is captured BEFORE the awaits, so a removal landing mid-round has to be
        // filtered back out at the commit (AccountRemovals.swift).
        let round = removals.beginRound()
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
                // The LAUNCHABLE home: this map is what the `tally` CLI picks and execs from, so a
                // signed-out account must not reach it even if it kept a home to be renewed at.
                if let home = account.launchableHome { launchHomes[account.id] = home }
            }
            await withTaskGroup(of: AccountUsage.self) { group in
                for account in active {
                    group.addTask { await provider.fetchUsage(for: account, userInitiated: userInitiated) }
                }
                for await usage in group { results.append(usage) }
            }
        }
        // An account the user removed while this round was out fetching: its home went to the Trash
        // after the discovery above read it, so everything this round holds about it is an echo.
        let removed = removals.removedIDs(inRound: round)
        if !removed.isEmpty {
            allDiscovered.removeAll { removed.contains($0.id) }
            results.removeAll { removed.contains($0.id) }
            launchHomes = launchHomes.filter { !removed.contains($0.key) }
        }
        // An account that signed OUT stops being discoverable at all - Claude's logout deletes the
        // Keychain item, Codex's deletes auth.json - so discovery alone drops it from the app at
        // the exact moment the expiry alert is about it. The remembered accounts whose home is
        // still on disk come back here as dormant ones: listed, probed, renewable. A home that is
        // GONE is a removal instead, and is forgotten (KnownAccounts.swift).
        let (known, dormant) = KnownAccountsStore.shared.reconcile(discovered: allDiscovered)
        adoptDiscovered(known)
        // A pin on an account that has signed out must stop steering launches: the launch home is
        // denormalized into the policy file the `tally` CLI reads, and nothing there asks whether
        // the login is still good. Every dormant account, not just the enabled ones - a switched-off
        // account is not a launchable one either.
        let dormantIDs = Set(dormant.map(\.id))
        LaunchPolicyStore.shared.releasePinnedHome(dormant: dormantIDs)
        // Discovery is the witness a settling renewal is waiting for: an account that is no longer
        // dormant is signed in again, so the "renewing" it is still showing everywhere ends here
        // rather than running out its deadline (RenewLoginStore.discoveryReported).
        RenewLoginStore.shared.discoveryReported(dormant: dormantIDs)

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
        let carried = carriedAccountRows(previous: accounts, fetched: Set(merged.map(\.id)),
                                         known: Set(known.map(\.id)), enabledProviders: enabledNow)
        accounts = (merged + carried)
            .filter { enabledNow.contains($0.providerID) && SettingsStore.shared.isAccountEnabled($0.id) }
            .sorted { ($0.providerID, $0.accountLabel) < ($1.providerID, $1.accountLabel) }
        // Who each polled account turned out to be, written down before the filter above can make
        // it unaskable: only enabled accounts are polled, so this round is the only chance to learn
        // an address that a switched-off row will still want to show (AccountIdentity.swift).
        LoginStatusStore.shared.rememberIdentities(merged)
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
        // A build nobody installed never publishes: one poller owns the shared ~/.tally files, and
        // it is the installed release app. The dev variant is the obvious case; a locally built
        // Release is the one that hurt, because it wears the release bundle id and so wrote a second,
        // older set of numbers into the same snapshot the CLI picks accounts from (`isUnshipped`).
        if !BuildVariant.isUnshipped {
            lastPublishedAccounts = labeled
            lastLaunchHomes = launchHomes
            republishSnapshot()
            // Sample fresh results into the burn-rate history (change-only, off-main-queue).
            UsageHistory.shared.record(results)
            // Alert when the claude flagship fleet pool crosses the low/dry tripwire. Installed
            // app only: a build nobody installed never owns the shared surfaces, so it never alerts.
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
        // Which plan each account is on, for the advisor's tier split. Taken from the live rows
        // here on the main actor rather than inside the read below, which runs on the history
        // queue; a plain [String: String] is what can cross to it.
        let plans = Dictionary(accounts.compactMap { usage in usage.planName.map { (usage.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        UsageHistory.shared.samples(
            since: now.addingTimeInterval(-UsageAdvisor.lookbackDays * 86_400)) { samples in
            let advisorSamples = samples.map {
                UsageAdvisor.Sample(ts: $0.ts, account: $0.account, provider: $0.provider,
                                    window: $0.window, model: $0.model, used: $0.used,
                                    resetAt: $0.resetAt)
            }
            let readings = UsageAdvisor.readings(samples: advisorSamples, now: now) { plans[$0] }
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
        // This round has now published a world without the removed accounts, so the tombstones that
        // predate it are spent - and a config home recreated under the same name is a new account
        // again rather than one this store refuses to show.
        removals.endRound(round)

        if refreshQueued {
            refreshQueued = false
            let inherited = queuedUserInitiated
            queuedUserInitiated = false
            Task { await refresh(userInitiated: inherited) }
        }
    }

    /// Inputs of the last published snapshot, so a settings flip (display mode, status line
    /// options) can rewrite ~/.tally/snapshot.json immediately WITHOUT refetching usage. Read by
    /// the publishing half of the store (UsageStorePublishing.swift), written only here.
    private(set) var lastPublishedAccounts: [AccountUsage] = []
    private(set) var lastLaunchHomes: [String: String] = [:]


    /// Accounts the user removed, and the rounds that must not resurrect them (AccountRemovals).
    private var removals = AccountRemovals()

    /// Forget everything this store remembers about one account, because the user removed it
    /// (RemoveAccountAction). Every cache below is keyed by an id that a recreated `~/.claude3`
    /// takes again, so a first fetch failing in the NEW account's home would otherwise show the
    /// previous account's numbers, publish them, and let smart pick route on them.
    func forgetAccount(_ accountID: String) {
        lastGood[accountID] = nil
        failureStreak[accountID] = nil
        lastPublishedAccounts.removeAll { $0.id == accountID }
        lastLaunchHomes[accountID] = nil
        removals.remove(accountID)
        LoginStatusStore.shared.forgetIdentity(accountID: accountID)
        hideAccounts { $0.id == accountID }
        // The snapshot the CLI launches from still names this account until the refresh behind the
        // removal lands - which is 10-20 seconds of `tally` being able to exec into the Trash.
        republishSnapshot()
    }

    /// Last successful snapshot per account, so a failed refresh can keep showing the numbers.
    private var lastGood: [String: AccountUsage] = [:]
    /// Consecutive failed polls per account, so a single transient failure doesn't flip the badge.
    private var failureStreak: [String: Int] = [:]

    /// Only flag "Outdated" after this many consecutive failures. A single miss - e.g. the brief window
    /// while the CLI rotates the OAuth token, which 1-minute polling reliably catches - keeps showing the
    /// last-good numbers unbadged, so the badge stops flickering on every token refresh.
    private static let staleAfterFailures = 2

    /// On success, record the snapshot. On a failure hand the round to `foldLastGood`
    /// (Core/LastGoodFold.swift), which decides what the card shows and what the CLI is told: the
    /// last-good numbers either way, flagged as held over from the first failure, and badged
    /// "Outdated" only once the failures are sustained (≥ staleAfterFailures in a row). An account
    /// that never succeeded still shows a bare error immediately.
    ///
    /// The streak counters stay here because they are this store's state across rounds; the fold
    /// itself is a function of one round, which is what lets a suite assert it (tests/lastgood).
    private func applyLastGood(_ usage: AccountUsage) -> AccountUsage {
        if usage.error == nil {
            failureStreak[usage.id] = 0
            let fresh = foldLastGood(usage, previous: nil, failureStreak: 0,
                                     staleAfterFailures: Self.staleAfterFailures)
            lastGood[usage.id] = fresh
            return fresh
        }
        let streak = (failureStreak[usage.id] ?? 0) + 1
        failureStreak[usage.id] = streak
        return foldLastGood(usage, previous: lastGood[usage.id], failureStreak: streak,
                            staleAfterFailures: Self.staleAfterFailures)
    }
}
