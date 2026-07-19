import SwiftUI

/// The fleet strip: one caption line per provider with 2+ accounts, pooling the same quota window
/// across the accounts - "the whole fleet's weekly budget at a glance". Headlines the weekly pool
/// (average left), the weakest account, and the soonest upcoming refill; the tooltip breaks every
/// pooled window class down per account. Providers with a single account contribute nothing: a
/// pool of one is just that account's card.
extension PopoverRootView {
    @ViewBuilder
    var fleetStrip: some View {
        let summaries = FleetMath.summaries(accounts: store.orderedAccounts) { usage in
            settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
        }
        if !summaries.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(summaries, id: \.providerID) { summary in
                    fleetRow(summary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(fleetTooltip(summaries))
            Divider()
        }
    }

    private func fleetRow(_ summary: FleetSummary) -> some View {
        HStack(spacing: 5) {
            ProviderIconView(providerID: summary.providerID, size: 11)
            if let pool = summary.headline {
                (headlineText(pool) + lowestText(pool) + refillText(pool))
                    .font(.caption2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private func headlineText(_ pool: FleetPool) -> Text {
        let name = pool.kind == .weeklyAll ? L("Weekly pool") : L("Session pool")
        return Text("\(name) \(percent(pool.averageRemaining)) \(L("left"))")
            .foregroundStyle(Color.secondary)
    }

    /// The weakest account, tinted by how little it has left - the strip's only colour, so an
    /// account running dry is visible without reading. The separator dot stays secondary: only
    /// the fact itself carries the warning colour.
    private func lowestText(_ pool: FleetPool) -> Text {
        let severity = MetricSeverity.fromUsedPercent(100 - pool.minRemaining)
        let tint: Color = severity == .normal ? .secondary : severity.color
        return Text(" · ").foregroundStyle(Color.secondary)
            + Text("\(L("lowest")) \(pool.minAccountLabel) \(percent(pool.minRemaining))")
                .foregroundStyle(tint)
    }

    private func refillText(_ pool: FleetPool) -> Text {
        guard let reset = UsageFormat.resetText(pool.nextReset, style: settings.resetDisplay),
              let account = pool.nextResetAccountLabel else { return Text(verbatim: "") }
        return Text(" · \(account) \(reset)").foregroundStyle(Color.secondary)
    }

    /// Full breakdown: every pooled window class, then every account's own remaining numbers -
    /// the "how did the pool get here" detail that would crowd the strip.
    private func fleetTooltip(_ summaries: [FleetSummary]) -> String {
        summaries.map { summary in
            var lines = ["\(ProviderCatalog.displayName(for: summary.providerID)) × \(summary.accountCount)"]
            for pool in summary.pools {
                var line = "\(L(pool.label)): \(percent(pool.averageRemaining)) \(L("left"))"
                    + " · \(L("lowest")) \(pool.minAccountLabel) \(percent(pool.minRemaining))"
                if let reset = UsageFormat.resetText(pool.nextReset, style: settings.resetDisplay),
                   let account = pool.nextResetAccountLabel {
                    line += " · \(account) \(reset)"
                }
                lines.append(line)
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
