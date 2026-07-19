import SwiftUI

/// The fleet gauge: for each provider with 2+ accounts, the accounts' quota unified into one
/// meter. Laid out in the exact grammar of a card's metric row (label column · bar · right-
/// aligned value, context line beneath) so the strip reads as part of the same family: the label
/// names the provider and fleet size ("Claude ×2"), the bar is segmented (one segment per
/// account, the whole track = the combined budget, each tinted by its own severity), and the
/// context line carries the pool total in accounts' worth (2.9/5), the pace forecast, and the
/// soonest refill. The tooltip breaks every pooled window class down per account. Providers with
/// a single account contribute nothing: a pool of one is just that account's card.
extension PopoverRootView {
    private static let fleetLabelWidth: CGFloat = 88
    private static let fleetValueWidth: CGFloat = 46

    @ViewBuilder
    var fleetStrip: some View {
        let summaries = FleetMath.summaries(accounts: store.orderedAccounts) { usage in
            settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
        }
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
            Divider()
        }
    }

    @ViewBuilder
    private func fleetGauge(_ summary: FleetSummary) -> some View {
        if let pool = summary.headline {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        ProviderIconView(providerID: summary.providerID, size: 11)
                        (Text(ProviderCatalog.displayName(for: summary.providerID))
                            .foregroundStyle(Color.secondary)
                         + Text(" ×\(summary.accountCount)").foregroundStyle(.tertiary))
                            .font(.footnote)
                            .lineLimit(1)
                    }
                    .frame(width: Self.fleetLabelWidth, alignment: .leading)
                    segmentedBar(pool)
                    Text(percent(poolValue(pool)))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(width: Self.fleetValueWidth, alignment: .trailing)
                }
                contextLine(summary, pool)
            }
        }
    }

    /// Mirrors the card rows' context line: the pool's own facts on the left, the soonest refill
    /// on the right (same click-to-toggle reset label as everywhere else).
    private func contextLine(_ summary: FleetSummary, _ pool: FleetPool) -> some View {
        HStack(spacing: 6) {
            (poolWorth(pool) + forecastText(summary, pool))
                .font(.caption2)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let at = pool.nextReset, let account = pool.nextResetAccountLabel {
                refillLabel(at: at, account: account)
            }
        }
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// The headline number follows the Used/Left toggle, like every meter on the cards.
    private func poolValue(_ pool: FleetPool) -> Double {
        settings.displayMode == .used ? 100 - pool.averageRemaining : pool.averageRemaining
    }

    /// "Weekly pool 2.9/5 left" - the combined budget in the unit a multi-account user actually
    /// thinks in: how many accounts' worth of quota remain.
    private func poolWorth(_ pool: FleetPool) -> Text {
        let name = pool.kind == .weeklyAll ? L("Weekly pool") : L("Session pool")
        let worth = String(format: "%.1f", pool.totalRemaining / 100)
        return Text("\(name) \(worth)/\(pool.members.count) \(L("left"))")
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

    /// "Claude 3 resets in 19h 11m", click-to-toggle between countdown and exact time - the same
    /// behaviour as every reset label on the cards.
    private func refillLabel(at: Date, account: String) -> some View {
        let style = settings.resetDisplay
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            Button {
                settings.resetDisplay = style.toggled
            } label: {
                Text("\(account) \(UsageFormat.resetText(at, style: style, now: context.date) ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("\(account) \(UsageFormat.resetText(at, style: style.toggled, now: context.date) ?? "")")
        }
    }

    /// One segment per account, equal widths (equal-weight pooling), each filled by its own
    /// value and tinted by its own severity - the union total AND the weak spot in one look.
    /// Same fill geometry as the card bars: used grows from the left, remaining hugs the right.
    private func segmentedBar(_ pool: FleetPool) -> some View {
        let mode = settings.displayMode
        return HStack(spacing: 2) {
            ForEach(Array(pool.members.enumerated()), id: \.offset) { _, member in
                GeometryReader { geo in
                    ZStack(alignment: mode == .used ? .leading : .trailing) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(member.severity.color)
                            .frame(width: max(3, geo.size.width
                                * (mode == .used ? 100 - member.remaining : member.remaining) / 100))
                    }
                }
                .frame(height: 6)
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
