import SwiftUI

/// The usage advisor strip: one line per provider under the fleet gauge answering "at my pace, do
/// I need another account?". The provider's own icon and name on the left (the same identity the
/// gauge above uses), the running weekly demand right-aligned (the number to read), and in between
/// either a mini progress capsule while history is still collecting or the account pips once a week
/// backs a verdict: one filled pip per account owned, plus a single hollow one when the pace asks
/// for another. The words behind it (the verdict sentence, active pace, starved hours, the next
/// refills) live in the hover tooltip so the line stays a glance. It has its own visibility switch
/// (`showAdvisor`), independent of the fleet gauge.
extension PopoverRootView {
    /// Pip diameter: large enough that solid and hollow are told apart at a glance, small enough to
    /// sit inside a caption row without becoming the loudest thing in it.
    private static let pipSize: CGFloat = 7
    /// Beyond this many pips the row asks to be counted rather than seen; the rest fold into "+N".
    private static let maxPips = 4
    /// Hollow pips fold sooner: a gap of four is a sentence, not a shape.
    private static let maxHollowPips = 3

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
            // The same identity the gauge above uses. Two stacked strips naming one provider two
            // ways (icon there, a verdict glyph and bare text here) read as two unrelated widgets;
            // one vocabulary makes the advisor a sibling of the gauge instead.
            ProviderIconView(providerID: reading.provider, size: 11)
            Text(ProviderCatalog.displayName(for: reading.provider))
                .foregroundStyle(Color.secondary)
            // Middle column: a progress capsule while the history is still short, else the demand
            // pips - which say what the sentence used to say, without a sentence.
            if reading.verdict == .collecting {
                advisorProgress(reading)
                Text(collectingCaption(reading))
                    .foregroundStyle(.secondary)
            } else {
                demandPips(reading)
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
        // The verdict is a shape now, and shapes are not read aloud: state it for VoiceOver so the
        // row still says what it means, not just its two numbers.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ProviderCatalog.displayName(for: reading.provider)), "
            + "\(verdictSentence(reading)), \(demandFigure(reading))")
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

    /// The account count as pips, left to right: solid for the accounts already owned, hollow for
    /// the ones the pace says to add. Two solid and one hollow reads as "you have two, a third is
    /// what your week asks for" in one glance, in any language, which is the whole verdict without
    /// a sentence to translate. How many hollow ones follows the advisor's own recommendation, not
    /// a second threshold invented here, so the pips and the tooltip can never disagree; when the
    /// fleet is sufficient there are none at all and the row stays calm.
    private func demandPips(_ reading: UsageAdvisor.Reading) -> some View {
        let owned = max(1, store.orderedAccounts.filter { $0.providerID == reading.provider }.count)
        // Past four, pips stop being countable at a glance (and the demo fleet is five), so the
        // rest collapse into a "+N" the eye reads instead of counts.
        let shown = min(owned, Self.maxPips)
        let folded = owned - shown
        let missing = missingAccounts(reading)
        return HStack(spacing: 3) {
            ForEach(0 ..< shown, id: \.self) { _ in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: Self.pipSize, height: Self.pipSize)
            }
            if folded > 0 {
                Text(verbatim: "+\(folded)").foregroundStyle(.secondary)
            }
            // A recommendation of one is one ring; a bigger gap becomes a ring with a multiplier,
            // because four identical rings are counted, not seen, and they crowd the figure.
            ForEach(0 ..< min(missing, Self.maxHollowPips), id: \.self) { _ in
                Circle()
                    .strokeBorder(TallyColor.warning, lineWidth: 1.2)
                    .frame(width: Self.pipSize, height: Self.pipSize)
            }
            if missing > Self.maxHollowPips {
                Text(verbatim: "×\(missing)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(TallyColor.warning)
            }
        }
    }

    /// How many accounts short the week's pace leaves this provider. The shortfall the demand figure
    /// implies (its ceiling over what is owned) when there is one, and otherwise a single account:
    /// the verdict can also fire on a flagship window or on starved hours, where the weekly figure
    /// alone would say nothing is missing yet the advice still stands. Zero unless the advisor is
    /// actually recommending, so a sufficient fleet shows no warning colour at all.
    private func missingAccounts(_ reading: UsageAdvisor.Reading) -> Int {
        guard reading.verdict == .addAccount else { return 0 }
        let owned = max(1, store.orderedAccounts.filter { $0.providerID == reading.provider }.count)
        let asked = Int(min(99, max(0, reading.demandPerWeek)).rounded(.up))
        return max(1, asked - owned)
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

    /// The verdict in words. The row says it in pips; the tooltip is where it stays sayable, for
    /// the reading that wants certainty rather than a glance.
    private func verdictSentence(_ reading: UsageAdvisor.Reading) -> String {
        switch reading.verdict {
        case .collecting: return L("still collecting history")
        case .sufficient: return L("current accounts are sufficient")
        case .addAccount:
            // Say the number when the pace asks for more than one, so the tooltip never stays
            // vaguely singular while the row shows a multiplier.
            let missing = missingAccounts(reading)
            guard missing > 1 else { return L("consider adding an account") }
            return String(localized: "at this pace, add \(missing) accounts", bundle: AppLocale.bundle)
        }
    }

    /// The numbers behind the verdict, for the hover tooltip - the "why" the one-liner elides -
    /// followed by when the provider next gets quota back, because "do I need another account"
    /// is really "can I wait for the refill". Same wording as the gauge's refill label and the
    /// same +gain the fleet tooltip lists, so one schedule never reads two ways.
    private func advisorTooltip(_ reading: UsageAdvisor.Reading) -> String {
        let demand = String(format: "%.1f", reading.demandPerWeek)
        let burn = "\(Int(reading.activeBurnPerHour.rounded()))%"
        let starved = String(format: "%.1fh", reading.starvedHoursPerWeek)
        var lines = [verdictSentence(reading),
                     String(localized: "weekly need \(demand) accounts · active burn \(burn)/h · starved \(starved)/wk",
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
