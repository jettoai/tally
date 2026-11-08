import SwiftUI

/// The head of one provider's card in the Detailed panel: the pool ring, the provider's name and
/// account count, the pace verdict as a status chip, and two quiet lines under the name (which pool
/// the ring shows and when it refills, then the advisor's tag and the launch chip when there are
/// any). Everything it says comes from the summaries the fleet gauge already builds; a provider
/// with no pool to show (one account, or the gauge switched off) gets the same head without the ring.
extension PopoverRootView {
    private var ringSize: CGFloat { PanelStyle.ringSize }

    /// The one summary the ring reads: the whole provider, every plan pooled, so a provider with a
    /// single account still has a ring of its own.
    private func ringSummary(_ providerID: String) -> FleetSummary? {
        guard settings.showFleetGauge else { return nil }
        let accounts = store.orderedAccounts.filter { $0.providerID == providerID }
        return FleetMath.summaries(accounts: accounts, minMembers: 1, byPlan: false) { usage in
            settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
        }.first
    }

    private func ringPool(_ summary: FleetSummary) -> FleetPool? {
        summary.pools.first { $0.kind == .weeklyAll } ?? summary.pools.first
    }

    /// The pace verdict, in the gauge's own words, and how worried to look about it.
    private func paceChip(_ summary: FleetSummary, _ pool: FleetPool) -> (text: String, state: PanelChipState)? {
        guard pool.kind != .session, let outlook = poolDryDate(summary, pool, now: Date()) else { return nil }
        let text = forecastPhrase(summary, pool).text
        guard let dry = outlook else { return (text, .green) }
        return (text, dry.timeIntervalSinceNow < 86_400 ? .red : .amber)
    }

    func accountCountText(_ count: Int) -> String {
        count == 1 ? L("1 account") : String(format: L("%lld accounts"), count)
    }

    func providerCardHeader(_ providerID: String, count: Int) -> some View {
        let foldable = pooledProviderIDs.contains(providerID)
        let toggle = { if foldable { settings.toggleCollapsed(providerID) } }
        let summary = ringSummary(providerID)
        let pool = summary.flatMap(ringPool)
        let chip = summary.flatMap { s in pool.flatMap { paceChip(s, $0) } }
        let forced = TallyTooltip.previewForced(.fleet)
            && providerID == fleetSummaries.first(where: { !displayedPools($0).isEmpty })?.providerID
        // The chip slot goes to the advisor's tag when it has something to say, else to the pace
        // verdict; when the tag has it, the pace verdict drops to the second line in its own colour.
        let advisor = hasAdvisorTag(providerID)
        let hasExtras = (advisor && chip != nil) || hasLaunchChip(providerID)
        return HStack(alignment: .center, spacing: 12) {
            if let summary, let pool {
                poolRing(providerID, pool)
                    .contentShape(Rectangle())
                    .windowDragOrTap(toggle)
                    .onTapGesture(perform: toggle)
                    .tallyTooltip(lazyBlocks: { fleetTooltipBlocks([summary]) }, forced: forced)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    HStack(spacing: 7) {
                        ProviderIconView(providerID: providerID, size: 13,
                                         tintOverride: PanelStyle.brand(providerID))
                        Text(ProviderCatalog.displayName(for: providerID))
                            .font(PanelStyle.font(14, 650))
                            .foregroundStyle(PanelStyle.text)
                            .lineLimit(1)
                            .tallyTooltip(lazyBlocks: { advisorHeadingTooltip(providerID) })
                        Text(accountCountText(count))
                            .font(PanelStyle.font(12, 500))
                            .foregroundStyle(PanelStyle.text2)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    .contentShape(Rectangle())
                    .windowDragOrTap(toggle)
                    .onTapGesture(perform: toggle)
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 16)
                        .contentShape(Rectangle())
                        .windowDragOrTap(toggle)
                        .onTapGesture(perform: toggle)
                    if advisor { advisorTag(providerID) } else if let chip { StatusChip(text: chip.text, state: chip.state) }
                    if foldable { foldChevron(providerID) }
                }
                if let pool { poolLine(pool).contentShape(Rectangle()).onTapGesture(perform: toggle) }
                if hasExtras {
                    HStack(spacing: 6) {
                        if advisor, let chip {
                            Text(chip.text).font(PanelStyle.font(11.5, 400)).foregroundStyle(chip.state.color).lineLimit(1)
                        }
                        launchChip(providerID)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
    }

    /// The ring: the weekly pool's share, in the Used/Left mode the rest of the panel is in, wearing
    /// the provider's colour while the pool is healthy and the status colour when it is not.
    private func poolRing(_ providerID: String, _ pool: FleetPool) -> some View {
        let used = settings.displayMode == .used
        let shown = used ? 100 - pool.averageRemaining : pool.averageRemaining
        let severity = MetricSeverity.fromUsedPercent(100 - pool.averageRemaining)
        return PoolRingView(size: ringSize, fraction: shown / 100,
                            tint: severity == .normal ? PanelStyle.brand(providerID) : PanelStyle.tint(severity),
                            figure: "\(Int(shown.rounded()))%",
                            caption: (used ? L("Used") : L("Left")).uppercased())
    }

    /// Which pool the ring shows and its next refill, ticking a minute at a time like every other
    /// countdown on the panel.
    private func poolLine(_ pool: FleetPool) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let refill = pool.refills.first.map { " · " + refillText($0, now: context.date, compact: true) } ?? ""
            Text(poolDisplayName(pool) + refill)
                .font(PanelStyle.font(11.5, 400))
                .foregroundStyle(PanelStyle.text2)
                .lineLimit(1)
        }
    }
}
