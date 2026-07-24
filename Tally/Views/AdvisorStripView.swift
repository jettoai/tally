import SwiftUI

/// The usage advisor strip: one line per provider under the fleet gauge answering "at my pace, do
/// I need another account?". A verdict glyph and the provider name on the left, the running weekly
/// demand right-aligned (the number to read), and in between either a mini progress capsule while
/// history is still collecting or the short verdict headline once a week backs it. The rest of the
/// numbers (active pace, starved hours) live in the hover tooltip so the line stays a glance. It
/// has its own visibility switch (`showAdvisor`), independent of the fleet gauge.
extension PopoverRootView {
    @ViewBuilder
    var advisorStrip: some View {
        let readings = visibleAdvisorReadings
        if !readings.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(readings, id: \.provider) { reading in
                    advisorRow(reading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !visibleAccounts.isEmpty {
                Divider()
            }
        }
    }

    /// Readings for providers with accounts currently on screen, in the panel's account order, and
    /// only while the advisor switch is on. History can outlive a removed provider, so a reading
    /// with no live accounts is dropped.
    private var visibleAdvisorReadings: [UsageAdvisor.Reading] {
        guard settings.showAdvisor else { return [] }
        let order = store.orderedAccounts.map(\.providerID)
        let present = Set(order)
        return store.advisorReadings
            .filter { present.contains($0.provider) }
            .sorted { (order.firstIndex(of: $0.provider) ?? 0) < (order.firstIndex(of: $1.provider) ?? 0) }
    }

    private func advisorRow(_ reading: UsageAdvisor.Reading) -> some View {
        HStack(spacing: 6) {
            Image(systemName: advisorGlyph(reading.verdict))
                .foregroundStyle(advisorTint(reading.verdict))
            Text(ProviderCatalog.displayName(for: reading.provider))
                .foregroundStyle(Color.secondary)
            // Middle column: a progress capsule while collecting, else the verdict headline.
            switch reading.verdict {
            case .collecting:
                advisorProgress(reading)
                Text(collectingCaption(reading))
                    .foregroundStyle(.secondary)
            case .addAccount:
                Text(L("consider adding an account"))
                    .foregroundStyle(advisorTint(.addAccount))
            case .sufficient:
                Text(L("current accounts are sufficient"))
                    .foregroundStyle(advisorTint(.sufficient))
            }
            Spacer(minLength: 6)
            // The running weekly demand, right-aligned in every state: the one number to read, so
            // it carries the fleet gauge's value weight and lands in the gauge's value column -
            // minWidth, not a fixed width, because "1.8 acct/wk" is wider than a bare percentage
            // and must not truncate; the trailing pad reserves the gauge's row gap + chevron slot,
            // which is what puts the two numbers' right edges on one line.
            Text(demandFigure(reading))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: Self.fleetValueWidth, alignment: .trailing)
                .padding(.trailing, Self.fleetRowSpacing + Self.fleetChevronWidth)
                .layoutPriority(1)
        }
        .font(.caption2)
        .lineLimit(1)
        .contentShape(Rectangle())
        .help(advisorTooltip(reading))
    }

    /// Mini quota-of-history bar: a quaternary track with a secondary fill proportional to how far
    /// the reading is toward `minimumDays`. A quiet visual of "still warming up", replacing the old
    /// "collecting data (5 of 7 days)" sentence.
    private func advisorProgress(_ reading: UsageAdvisor.Reading) -> some View {
        let fraction = min(1, max(0, reading.daysOfData / UsageAdvisor.minimumDays))
        return Capsule()
            .fill(.quaternary)
            .frame(width: 36, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary)
                    .frame(width: max(2, 36 * fraction), height: 3)
            }
    }

    private func advisorGlyph(_ verdict: UsageAdvisor.Verdict) -> String {
        switch verdict {
        case .collecting: return "hourglass"
        case .addAccount: return "person.badge.plus"
        case .sufficient: return "checkmark.circle"
        }
    }

    private func advisorTint(_ verdict: UsageAdvisor.Verdict) -> Color {
        switch verdict {
        case .collecting: return .secondary
        case .addAccount: return TallyColor.warning
        case .sufficient: return TallyColor.normal
        }
    }

    /// The collecting progress as a compact "5/7d" caption next to the capsule. Floors the days,
    /// never rounds: at 6.6 days the reading is still collecting, so "7/7d" would read as a
    /// contradiction.
    private func collectingCaption(_ reading: UsageAdvisor.Reading) -> String {
        let days = "\(Int(reading.daysOfData))"
        let target = "\(Int(UsageAdvisor.minimumDays))"
        return String(localized: "\(days)/\(target)d", bundle: AppLocale.bundle)
    }

    /// The running weekly demand as "1.8 acct/wk". Live from day one (only the recommendation waits
    /// for a week of history), so it shows in every state as the strip's headline number.
    private func demandFigure(_ reading: UsageAdvisor.Reading) -> String {
        let demand = String(format: "%.1f", reading.demandPerWeek)
        return String(localized: "\(demand) acct/wk", bundle: AppLocale.bundle)
    }

    /// The numbers behind the verdict, for the hover tooltip - the "why" the one-liner elides -
    /// followed by when the provider next gets quota back, because "do I need another account"
    /// is really "can I wait for the refill". Same wording as the gauge's refill label and the
    /// same +gain the fleet tooltip lists, so one schedule never reads two ways.
    private func advisorTooltip(_ reading: UsageAdvisor.Reading) -> String {
        let demand = String(format: "%.1f", reading.demandPerWeek)
        let burn = "\(Int(reading.activeBurnPerHour.rounded()))%"
        let starved = String(format: "%.1fh", reading.starvedHoursPerWeek)
        var lines = [String(localized: "weekly need \(demand) accounts · active burn \(burn)/h · starved \(starved)/wk",
                            bundle: AppLocale.bundle)]
        let now = Date()
        for refill in upcomingRefills(reading.provider, now: now) {
            lines.append(refillText(refill, style: settings.resetDisplay, now: now)
                         + " (+\(Int(refill.gain.rounded()))%)")
        }
        return lines.joined(separator: "\n")
    }

    /// The provider's next two quota refills. Pooled straight from FleetMath rather than through
    /// `fleetSummaries`: that property is gated on the fleet gauge's switch and the advisor has
    /// its own, so going through it would blank these lines whenever the gauge is hidden. The pool
    /// picked is the one the gauge leads with, so both surfaces name the same window.
    ///
    /// A single-account provider has no pool at all (a pool of one is just that account), so its
    /// own binding window stands in - built as a one-member refill, which is exactly what the pool
    /// math would have made of it: the window's reset instant, and the used percent as the gain.
    private func upcomingRefills(_ providerID: String, now: Date) -> [FleetPool.Refill] {
        let accounts = store.orderedAccounts.filter { $0.providerID == providerID }
        let summaries = FleetMath.summaries(accounts: accounts, now: now) { usage in
            settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
        }
        if let summary = summaries.first, let pool = displayedPools(summary).first {
            return Array(pool.refills.prefix(2))
        }
        guard accounts.count == 1, let single = accounts.first,
              let window = single.metrics.first(where: { $0.kind == .weeklyAll }) ?? single.headline,
              let at = window.resetsAt, at > now
        else { return [] }
        let label = settings.displayLabel(accountID: single.id, fallback: single.accountLabel)
        return [FleetPool.Refill(at: at, accountLabel: label, gain: window.usedPercent)]
    }
}
