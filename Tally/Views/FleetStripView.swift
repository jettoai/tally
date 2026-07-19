import SwiftUI

/// The fleet gauge: for each provider with 2+ accounts, the accounts' quota unified into one
/// meter - a segmented bar (one segment per account, the whole track = the combined budget), the
/// total left as "accounts' worth" (2.9/5), the soonest refill, and a forecast of how long the
/// pool lasts at the recently measured pace (counting the quota each staggered reset brings
/// back). The tooltip breaks every pooled window class down per account. Providers with a single
/// account contribute nothing: a pool of one is just that account's card.
extension PopoverRootView {
    @ViewBuilder
    var fleetStrip: some View {
        let summaries = FleetMath.summaries(accounts: store.orderedAccounts) { usage in
            settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
        }
        if !summaries.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(summaries, id: \.providerID) { summary in
                    fleetGauge(summary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(fleetTooltip(summaries))
            Divider()
        }
    }

    @ViewBuilder
    private func fleetGauge(_ summary: FleetSummary) -> some View {
        if let pool = summary.headline {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ProviderIconView(providerID: summary.providerID, size: 11)
                    (poolTitle(pool) + forecastText(summary, pool))
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let at = pool.nextReset, let account = pool.nextResetAccountLabel,
                       let reset = UsageFormat.resetText(at, style: settings.resetDisplay) {
                        Text("\(account) \(reset)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                segmentedBar(pool)
            }
        }
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "Weekly pool 58% · 2.9/5" - the pool's fill and the same fact in the unit a multi-account
    /// user actually thinks in: how many accounts' worth of quota are left.
    private func poolTitle(_ pool: FleetPool) -> Text {
        let name = pool.kind == .weeklyAll ? L("Weekly pool") : L("Session pool")
        let worth = String(format: "%.1f", pool.totalRemaining / 100)
        return Text("\(name) \(percent(pool.averageRemaining)) · \(worth)/\(pool.members.count)")
            .foregroundStyle(Color.secondary)
    }

    /// The "does it last" verdict from the measured pace: dry-run date (amber, red inside a day),
    /// sustainable check, or "measuring" while the history is still too young to trust.
    private func forecastText(_ summary: FleetSummary, _ pool: FleetPool) -> Text {
        guard pool.kind == .weeklyAll else { return Text(verbatim: "") }
        guard let rate = store.fleetRates[summary.providerID] else {
            return (Text(" · ") + Text(L("measuring pace…"))).foregroundStyle(.tertiary)
        }
        let now = Date()
        let dry = FleetForecast.depletion(
            remaining: pool.totalRemaining,
            refills: pool.refills.map { ($0.at, $0.gain) },
            perHour: rate.perHour,
            steadyRefillPerHour: pool.steadyRefillPerHour(windowHours: 168),
            now: now)
        guard let dry else {
            return Text(" · ").foregroundStyle(Color.secondary)
                + Text("\(L("sustainable at this pace")) ✓").foregroundStyle(TallyColor.normal)
        }
        let seconds = dry.timeIntervalSince(now)
        let tint = seconds < 86_400 ? TallyColor.critical : TallyColor.warning
        let body = UsageFormat.durationBody(seconds)
        return Text(" · ").foregroundStyle(Color.secondary)
            + Text(String(localized: "lasts about \(body)", bundle: AppLocale.bundle))
                .foregroundStyle(tint)
    }

    /// One segment per account, equal widths (equal-weight pooling), each filled by its own
    /// remaining and tinted by its own severity - the union total AND the weak spot in one look.
    private func segmentedBar(_ pool: FleetPool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(pool.members.enumerated()), id: \.offset) { _, member in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(member.severity.color)
                            .frame(width: max(3, geo.size.width * member.remaining / 100))
                    }
                }
                .frame(height: 5)
                .help("\(member.accountLabel) \(percent(member.remaining)) \(L("left"))")
            }
        }
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
