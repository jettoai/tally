import SwiftUI

/// The usage advisor strip: one line per provider under the fleet gauge answering "at my pace, do
/// I need another account?". A verdict glyph, the provider name, and a plain headline; the numbers
/// behind it (weekly demand, active pace, starved hours) live in the hover tooltip so the line
/// stays a glance. It shares the fleet gauge's visibility switch - the advisor is the fleet view's
/// planning extension, not a separate toggle - and only ever shows "collecting data" until a week
/// of history backs a real recommendation.
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
    /// only while the shared fleet-gauge switch is on. History can outlive a removed provider, so a
    /// reading with no live accounts is dropped.
    private var visibleAdvisorReadings: [UsageAdvisor.Reading] {
        guard settings.showFleetGauge else { return [] }
        let order = store.orderedAccounts.map(\.providerID)
        let present = Set(order)
        return store.advisorReadings
            .filter { present.contains($0.provider) }
            .sorted { (order.firstIndex(of: $0.provider) ?? 0) < (order.firstIndex(of: $1.provider) ?? 0) }
    }

    private func advisorRow(_ reading: UsageAdvisor.Reading) -> some View {
        HStack(spacing: 5) {
            Image(systemName: advisorGlyph(reading.verdict))
                .font(.caption2)
                .foregroundStyle(advisorTint(reading.verdict))
            Text(ProviderCatalog.displayName(for: reading.provider))
                .foregroundStyle(Color.secondary)
            Text(advisorHeadline(reading))
                .foregroundStyle(advisorTint(reading.verdict))
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .lineLimit(1)
        .contentShape(Rectangle())
        .help(advisorTooltip(reading))
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

    /// The verdict as a localized one-liner. Mirrors `UsageAdvisor.englishHeadline` in meaning; the
    /// panel keeps its own copy so the strings live in the app's xcstrings.
    private func advisorHeadline(_ reading: UsageAdvisor.Reading) -> String {
        switch reading.verdict {
        case .collecting:
            let days = "\(Int(reading.daysOfData))"   // floor: 6.6 days is still collecting, not "7 of 7"
            let target = "\(Int(UsageAdvisor.minimumDays))"
            let collecting = String(localized: "collecting data (\(days) of \(target) days)",
                                    bundle: AppLocale.bundle)
            // The numbers are live from day one; only the RECOMMENDATION waits for a week of
            // history. Surface the running weekly demand inline so the strip is never a blank
            // promise (the rest stays in the tooltip).
            let demand = String(format: "%.1f", reading.demandPerWeek)
            let preliminary = String(localized: "so far \(demand) accounts/wk",
                                     bundle: AppLocale.bundle)
            return "\(collecting) · \(preliminary)"
        case .addAccount:
            return L("consider adding an account")
        case .sufficient:
            return L("current accounts are sufficient")
        }
    }

    /// The numbers behind the verdict, for the hover tooltip - the "why" the one-liner elides.
    private func advisorTooltip(_ reading: UsageAdvisor.Reading) -> String {
        let demand = String(format: "%.1f", reading.demandPerWeek)
        let burn = "\(Int(reading.activeBurnPerHour.rounded()))%"
        let starved = String(format: "%.1fh", reading.starvedHoursPerWeek)
        return String(localized: "weekly need \(demand) accounts · active burn \(burn)/h · starved \(starved)/wk",
                      bundle: AppLocale.bundle)
    }
}
