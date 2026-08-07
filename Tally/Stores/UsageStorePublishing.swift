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
        UsageSnapshot.make(accounts: lastPublishedAccounts, launchHomes: lastLaunchHomes,
                           statuslineFullQuota: SettingsStore.shared.statuslineFullQuota,
                           displayMode: SettingsStore.shared.displayMode.rawValue,
                           fleet: fleet, fleetPools: fleetPools).write()
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
    func fleetForSnapshot() -> ([String: UsageSnapshot.Fleet]?,
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
}
