import SwiftUI

/// The fleet gauge: for each provider with 2+ accounts, the accounts' weekly quota unified into
/// ONE meter, in the storage-bar grammar (one continuous fill = the whole fleet's remaining,
/// hairlines inside the fill marking each account's contribution) - chosen over per-account
/// segments, which read as several broken little meters instead of a pool. Laid out in the
/// cards' metric-row grammar: provider + fleet size as the label column, the pooled bar, and
/// the total as "accounts' worth" (1.8/2) in the value column; the context line carries the
/// pace forecast and the next refill. Who exactly is running dry stays on the cards below and
/// in the tooltip - the gauge answers "how much does the whole fleet have and does it last",
/// and only that. Providers with a single account contribute nothing: a pool of one is just
/// that account's card.
extension PopoverRootView {
    private static let fleetLabelWidth: CGFloat = 88
    private static let fleetValueWidth: CGFloat = 46

    /// Providers whose gauge is actually rendered right now - the only providers a collapse
    /// (hidden cards) may apply to.
    var pooledProviderIDs: Set<String> {
        Set(fleetSummaries.filter { $0.headline != nil }.map(\.providerID))
    }

    /// The pools this provider's gauge renders, leading pool first. "All" shows every weekly-cycle
    /// pool (primary budget + weekly total - both runways at once); the single-pool modes show
    /// just the focus-resolved one.
    func displayedPools(_ summary: FleetSummary) -> [FleetPool] {
        let focused = UsageStore.focusedModel(providerID: summary.providerID,
                                              available: summary.modelPoolNames)
        switch settings.gaugeFocus {
        case .all: return summary.displayPools(focusedModel: focused)
        case .primary, .weekly: return summary.headline(focusedModel: focused).map { [$0] } ?? []
        }
    }

    var fleetSummaries: [FleetSummary] {
        settings.showFleetGauge
            ? FleetMath.summaries(accounts: store.orderedAccounts) { usage in
                settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
            }
            : []
    }

    @ViewBuilder
    var fleetStrip: some View {
        let summaries = fleetSummaries
        if !summaries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summaries, id: \.providerID) { summary in
                    fleetGauge(summary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(fleetTooltip(summaries))
            // The strip's own divider separates it from the cards; with every card folded away
            // the footer's divider is next, and two adjacent dividers drew as a doubled line.
            if !visibleAccounts.isEmpty {
                Divider()
            }
        }
    }

    @ViewBuilder
    private func fleetGauge(_ summary: FleetSummary) -> some View {
        let pools = displayedPools(summary)
        if !pools.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(pools.enumerated()), id: \.offset) { index, pool in
                    poolBlock(summary, pool, leading: index == 0)
                }
            }
        }
    }

    /// One pool's two lines: the meter row and its context line. The FIRST pool's label column
    /// carries the provider identity and the fold chevron (the disclosure header for the whole
    /// provider); follow-up pools name their own window there instead, so "which budget is this
    /// bar" reads in the same column on every line.
    @ViewBuilder
    private func poolBlock(_ summary: FleetSummary, _ pool: FleetPool, leading: Bool) -> some View {
        let collapsed = settings.collapsedProviders.contains(summary.providerID)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if leading {
                    HStack(spacing: 5) {
                        ProviderIconView(providerID: summary.providerID, size: 11)
                        (Text(ProviderCatalog.displayName(for: summary.providerID))
                            .foregroundStyle(Color.secondary)
                         + Text(" ×\(summary.accountCount)").foregroundStyle(.tertiary))
                            .font(.footnote)
                            .lineLimit(1)
                    }
                    .frame(width: Self.fleetLabelWidth, alignment: .leading)
                } else {
                    Text(poolDisplayName(pool))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .frame(width: Self.fleetLabelWidth, alignment: .leading)
                }
                pooledBar(pool)
                Text(worthValue(pool))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(width: Self.fleetValueWidth, alignment: .trailing)
                // The leading row doubles as a disclosure header: click folds this provider's
                // cards away (the pools stay - they ARE the summary), click again brings them
                // back. The chevron is the affordance; the whole row is the target. Follow-up
                // rows keep an equal-width spacer so every bar column aligns.
                if leading {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                        .help(L("Show or hide this provider's account cards"))
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
            }
            .contentShape(Rectangle())
            // Instant, not animated: the surrounding window resize can't be synchronized with
            // a SwiftUI layout animation, and the half-animated combination read as a bounce.
            .onTapGesture { if leading { settings.toggleCollapsed(summary.providerID) } }
            contextLine(summary, pool, named: leading)
        }
    }

    private func poolDisplayName(_ pool: FleetPool) -> String {
        switch pool.kind {
        case .weeklyModel:
            let model = pool.modelName ?? pool.label
            return String(localized: "\(model) pool", bundle: AppLocale.bundle)
        case .session:
            return L("Session pool")
        default:
            return L("Weekly pool")
        }
    }

    /// Mirrors the card rows' context line: which window this pool sums (on the leading line
    /// only - follow-up pools already name themselves in the label column) and the pace verdict
    /// on the left, the next refill on the right (click toggles countdown/exact time, like every
    /// reset label).
    private func contextLine(_ summary: FleetSummary, _ pool: FleetPool, named: Bool) -> some View {
        let prefix = named
            ? Text("\(poolDisplayName(pool)) · ").foregroundStyle(Color.secondary)
            : Text(verbatim: "")
        return HStack(spacing: 6) {
            (prefix + forecastText(summary, pool))
                .font(.caption2)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let refill = pool.refills.first {
                refillLabel(refill)
            }
        }
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private func worth(_ units: Double) -> String { String(format: "%.1f", units / 100) }

    /// "1.8/2" - the pool total in the unit a multi-account user actually thinks in: accounts'
    /// worth of quota. Follows the Used/Left toggle like every meter (used mode shows the worth
    /// spent).
    private func worthValue(_ pool: FleetPool) -> String {
        let capacity = Double(pool.members.count) * 100
        let shown = settings.displayMode == .used
            ? capacity - pool.totalRemaining : pool.totalRemaining
        return "\(worth(shown))/\(pool.members.count)"
    }

    /// The "does it last" verdict from the measured pace: dry-run date (amber, red inside a day),
    /// sustainable check, or "measuring" while the history is still too young to trust.
    private func forecastText(_ summary: FleetSummary, _ pool: FleetPool) -> Text {
        guard pool.kind != .session else { return Text(verbatim: "") }
        guard let rate = store.fleetRates[FleetForecast.rateKey(
            provider: summary.providerID, window: pool.kind.rawValue, model: pool.modelName)] else {
            return Text(L("measuring pace…")).foregroundStyle(.tertiary)
        }
        let now = Date()
        let dry = FleetForecast.depletion(
            remaining: pool.totalRemaining,
            refills: pool.refills.map { ($0.at, $0.gain) },
            perHour: rate.perHour,
            steadyRefillPerHour: pool.steadyRefillPerHour(windowHours: 168),
            now: now)
        guard let dry else {
            return Text("\(L("sustainable at this pace")) ✓").foregroundStyle(TallyColor.normal)
        }
        let seconds = dry.timeIntervalSince(now)
        let tint = seconds < 86_400 ? TallyColor.critical : TallyColor.warning
        let body = UsageFormat.durationBody(seconds)
        return Text(String(localized: "lasts about \(body)", bundle: AppLocale.bundle))
            .foregroundStyle(tint)
    }

    /// "next refill Claude in 4d 6h" - refill wording, not "resets", so it can't be confused
    /// with the per-window reset labels on the cards. Click toggles to the exact time.
    private func refillLabel(_ refill: FleetPool.Refill) -> some View {
        let style = settings.resetDisplay
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            Button {
                settings.resetDisplay = style.toggled
            } label: {
                Text(refillText(refill, style: style, now: context.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(refillText(refill, style: style.toggled, now: context.date))
        }
    }

    private func refillText(_ refill: FleetPool.Refill, style: ResetDisplay, now: Date) -> String {
        let account = refill.accountLabel
        if style == .relative {
            let body = UsageFormat.durationBody(max(60, refill.at.timeIntervalSince(now)))
            return String(localized: "next refill \(account) in \(body)", bundle: AppLocale.bundle)
        }
        return String(localized: "next refill \(account) at \(UsageFormat.absoluteBody(refill.at))",
                      bundle: AppLocale.bundle)
    }

    /// One continuous fill anchored like every meter (used grows left, remaining hugs right),
    /// sized by the whole pool's total. No internal account dividers: they read as mystery
    /// notches (user-confirmed), and the per-account story already lives on the cards and in the
    /// tooltip. One colour for the whole pool, by the pool's own health - a single sick account
    /// doesn't repaint the fleet.
    private func pooledBar(_ pool: FleetPool) -> some View {
        let mode = settings.displayMode
        let capacity = Double(pool.members.count) * 100
        let color = MetricSeverity.fromUsedPercent(100 - pool.averageRemaining).color
        let shown = mode == .used ? capacity - pool.totalRemaining : pool.totalRemaining
        return GeometryReader { geo in
            ZStack(alignment: mode == .used ? .leading : .trailing) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: max(3, geo.size.width * shown / capacity))
            }
        }
        .frame(height: 6)
    }

    /// Full breakdown: every pooled window class with its weakest account, the refill schedule,
    /// then every account's own remaining numbers - the "how did the pool get here" detail that
    /// would crowd the gauge.
    private func fleetTooltip(_ summaries: [FleetSummary]) -> String {
        summaries.map { summary in
            var lines = ["\(ProviderCatalog.displayName(for: summary.providerID)) × \(summary.accountCount)"]
            for pool in summary.pools {
                lines.append("\(L(pool.label)): \(percent(pool.averageRemaining)) \(L("left"))"
                    + " · \(L("lowest")) \(pool.minAccountLabel) \(percent(pool.minRemaining))")
            }
            if let refills = summary.headline?.refills, !refills.isEmpty {
                let schedule = refills.prefix(3).compactMap { refill in
                    UsageFormat.resetText(refill.at, style: settings.resetDisplay).map {
                        "\(refill.accountLabel) +\(percent(refill.gain)) \($0)"
                    }
                }
                lines.append(schedule.joined(separator: " · "))
            }
            for usage in store.orderedAccounts where usage.providerID == summary.providerID {
                guard !usage.metrics.isEmpty else { continue }
                let label = settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
                let parts = usage.metrics.map {
                    "\(L($0.label)) \(percent($0.remainingPercent))"
                }
                lines.append("\(label): \(parts.joined(separator: " · ")) \(L("left"))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
