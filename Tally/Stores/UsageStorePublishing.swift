import Foundation

// What the store PUBLISHES rather than what it shows: the non-secret snapshot the `tally` CLI reads
// to pick a launch account, the fleet shapes inside it, and the tripwire that watches the flagship
// pool. Lifted out of UsageStore.swift (past the repo's 500-line cap) along the seam the callers
// already use - the refresh loop and the settings writes call in here, and nothing here fetches.

extension UsageStore {
    /// Rewrite the snapshot from the cached accounts + current settings. No-op for a build nobody
    /// installed and for demo mode (neither may publish), or before the first successful refresh.
    /// `isUnshipped` rather than `isDev` because the settings writes reach here directly: gating only
    /// the refresh loop would leave a locally built Release republishing on every toggle.
    func republishSnapshot() {
        guard !BuildVariant.isUnshipped, !DemoUsage.isActive,
              !lastPublishedAccounts.isEmpty else { return }
        let (fleet, fleetPools) = fleetForSnapshot()
        // Outside the gauge switch and for single-account providers too: this is the one number a
        // reader draws a provider's remaining from, not a pool the panel shows.
        let weighted = FleetMath.weighted(accounts: lastPublishedAccounts)
            .mapValues { UsageSnapshot.Weighted(remainingPercent: $0.remainingPercent,
                                                weightSource: $0.source.rawValue) }
        UsageSnapshot.make(accounts: lastPublishedAccounts, launchHomes: lastLaunchHomes,
                           statuslineFullQuota: SettingsStore.shared.statuslineFullQuota,
                           displayMode: SettingsStore.shared.displayMode.rawValue,
                           fleet: fleet, fleetPools: fleetPools,
                           fleetWeighted: weighted.isEmpty ? nil : weighted,
                           // What the PANEL shows, for the surfaces that mirror it. The accounts
                           // themselves keep the order they are written in, because readers that
                           // resolve near-ties by taking the first candidate depend on it
                           // (UsageSnapshot.accountOrder states the whole trade).
                           accountOrder: SettingsStore.shared
                               .orderedAccountIDs(lastPublishedAccounts.map(\.id)),
                           resetStates: Dictionary(lastPublishedAccounts.map {
                               ($0.id, RedeemAction.offer(for: $0).stateName)
                           }, uniquingKeysWith: { first, _ in first }),
                           loginRejected: LoginStatusStore.shared.usageRejectedAccounts).write()
    }

    /// Feed the claude flagship weekly pool to the dry-pool notifier. The flagship window is chosen
    /// by tier order (not the gauge's display focus), so the tripwire watches the top model pool
    /// regardless of what the panel currently shows. No pool (fewer than two accounts share the
    /// flagship window) means nothing to arm.
    func notifyFlagshipDryness(accounts labeled: [AccountUsage]) {
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
            // Weighted like `remaining`: a flagship pool mixing plans counts a Max seat as five Pro
            // seats. The multiples are published for overall usage, so reading them onto a model
            // sub-quota is an assumption (`PlanWeight`).
            capacity: pool.capacity,
            accountCount: pool.members.count,
            resetAt: pool.nextReset,
            windowName: pool.modelName ?? pool.label)
    }

    /// The display always leads with the account-wide weekly budget, so there is no model window to
    /// name. Kept as the one seam the menu-bar closures call (`MenuBarSegments`); always nil.
    static func focusedModel(providerID: String, available: [String]) -> String? { nil }

    /// `tally status`'s fleet line follows the SAME switch as the panel's gauge: published
    /// only while the gauge is on, and only for providers with a real pool (2+ accounts with a
    /// weekly window). Launch mode is deliberately irrelevant - one toggle, one meaning.
    ///
    /// Two shapes from one pass: `fleet` keeps the single headline pool (the pre-0.17 contract
    /// older CLIs render) and `fleetPools` carries the panel's ordered pool list (gauge focus
    /// applied, session pools excluded) for CLIs that render every pool the gauge shows.
    /// A provider split by plan (FleetMath `byPlan`) publishes every plan's pools under its
    /// `fleetPools` entry, each stamped with `plan`, and no single `fleet` pool.
    func fleetForSnapshot() -> ([String: UsageSnapshot.Fleet]?,
                                        [String: [UsageSnapshot.Fleet]]?) {
        guard SettingsStore.shared.showFleetGauge else { return (nil, nil) }
        var fleet: [String: UsageSnapshot.Fleet] = [:]
        var fleetPools: [String: [UsageSnapshot.Fleet]] = [:]
        let now = Date()
        for summary in FleetMath.summaries(accounts: lastPublishedAccounts, byPlan: true,
                                           label: { $0.accountLabel }) {
            let focused = Self.focusedModel(providerID: summary.providerID,
                                            available: summary.modelPoolNames)
            let weight = FleetMath.planWeight(of: summary, accounts: lastPublishedAccounts)
            func published(_ pool: FleetPool) -> UsageSnapshot.Fleet {
                var dryAt: Date?
                var sustainable = false
                if let rate = fleetRates[FleetForecast.rateKey(
                    provider: summary.providerID, window: pool.kind.rawValue,
                    model: pool.modelName, plan: summary.planTier?.key)] {
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
                    capacity: pool.capacity,
                    dryAt: dryAt, sustainable: sustainable,
                    poolName: pool.kind == .weeklyModel ? (pool.modelName ?? pool.label) : nil,
                    plan: summary.planTier.map { $0.name ?? "unknown" },
                    capacityWeight: weight?.value, weightSource: weight?.source.rawValue)
            }
            // A provider split by plan has no single headline pool; older CLIs that read only
            // `fleet` then print no pool line for it instead of one plan's pool labelled as the
            // whole provider.
            guard let pool = summary.headline(focusedModel: focused), pool.kind != .session else {
                continue
            }
            if summary.planTier == nil { fleet[summary.providerID] = published(pool) }
            // Mirrors FleetStripView.displayedPools, so `tally status` shows the same pool
            // as the panel: the account-wide weekly headline.
            // Accumulate: a provider split by plan arrives once per plan.
            fleetPools[summary.providerID, default: []].append(published(pool))
        }
        return (fleet.isEmpty ? nil : fleet, fleetPools.isEmpty ? nil : fleetPools)
    }
}
