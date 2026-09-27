import SwiftUI

/// The usage advisor strip: one line per provider under the fleet gauge answering "do I need
/// another account?" as a conclusion, not a figure to convert: enough accounts, add how many of
/// which plan, not enough at this pace, or how many days until advice. The provider's own icon and
/// name on the left, the same identity the gauge above uses. The raw figures (the window ladder in
/// acct/wk, the per-plan split, burn, starved hours, the next refills) and the two horizons behind
/// the conclusion live in the hover tooltip. The rule that keeps this line consistent with the pool
/// lines above it is `AdvisorConclusion`. It has its own visibility switch (`showAdvisor`),
/// independent of the fleet gauge.
extension PopoverRootView {
    /// What a figure reads while its window is still collecting. The repo's one sanctioned em dash:
    /// a no-data glyph, not prose (Tally/CLAUDE.md), spelled the same way the menu bar spells it.
    private static let noFigure = "—"

    @ViewBuilder
    var advisorStrip: some View {
        let readings = visibleAdvisorReadings
        if !readings.isEmpty {
            Group {
                // Two providers stand side by side on a wide enough panel, under the fleet gauges
                // that already split the same way: stacking two short rows down the left half left
                // the right half empty and the advisor reading as a separate, lesser strip.
                if readings.count == 2, popoverWidth >= Self.twoColumnPanelWidth {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(readings, id: \.provider) { reading in
                            advisorRow(reading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(readings, id: \.provider) { reading in
                            advisorRow(reading)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The same question the fleet strip's own divider asks (FleetStripView): not "are there
            // visible cards" but "is the account region drawn at all". A grouped layout with every
            // provider folded still draws its headings, and this strip has to be separated from them
            // exactly as it is from the cards; only when nothing follows would this divider land
            // against the footer's and draw as a doubled line.
            if showsAccountRegion {
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
        let now = Date()
        let dryPools = advisorDryPools(reading.provider, now: now)
        let conclusion = advisorConclusion(reading, dryPools: dryPools)
        let sentence = conclusionSentence(conclusion)
        return HStack(spacing: 6) {
            // The same identity the gauge above uses, so the row reads as its sibling.
            ProviderIconView(providerID: reading.provider, size: 11)
            Text(ProviderCatalog.displayName(for: reading.provider))
                .foregroundStyle(Color.secondary)
            // The conclusion, nothing to convert: whether the accounts are enough and, if not,
            // how many of which plan to add. The figures behind it are in the hover.
            Text(sentence)
                .foregroundStyle(conclusionTint(conclusion))
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .lineLimit(1)
        .contentShape(Rectangle())
        .tallyTooltip(advisorTooltip(reading, sentence: sentence, dryPools: dryPools, now: now))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ProviderCatalog.displayName(for: reading.provider)), \(sentence)")
    }

    private typealias DryPool = (summary: FleetSummary, pool: FleetPool, dry: Date)

    /// Every pool of this provider the gauge forecasts running dry, with its tier and dry date.
    /// Built from the same summaries and the same `poolDryDate` the gauge draws, split by plan
    /// exactly as the gauge splits, and computed even while the gauge is hidden: the advisor has
    /// its own switch, and "enough" must not depend on whether the other strip is showing.
    private func advisorDryPools(_ providerID: String, now: Date) -> [DryPool] {
        let accounts = store.orderedAccounts.filter { $0.providerID == providerID }
        let summaries = FleetMath.summaries(accounts: accounts, now: now, byPlan: true) { usage in
            settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
        }
        return summaries.flatMap { summary in
            displayedPools(summary).compactMap { pool -> DryPool? in
                guard case .some(.some(let dry)) = poolDryDate(summary, pool, now: now) else { return nil }
                return (summary, pool, dry)
            }
        }
    }

    /// The advisor's tiers joined with the gauge's dry signal by plan key (case-insensitive,
    /// "?" for an unnamed plan, the rule `FleetSummary.Tier.key` uses). A plan the gauge shows
    /// but the four-week history has not seen yet still counts, with no demand, so a short pool
    /// is never dropped for lack of history.
    private func advisorConclusion(_ reading: UsageAdvisor.Reading,
                                   dryPools: [DryPool]) -> AdvisorConclusion {
        func key(_ plan: String?) -> String { plan?.lowercased() ?? "?" }
        let dryKeys = Set(dryPools.compactMap { $0.summary.planTier?.key })
        let gaugeSplit = Set(dryPools.compactMap { $0.summary.planTier?.name }).count
        var tiers = splitTiers(reading.tierDemands).map { tier in
            AdvisorConclusion.Tier(plan: tier.plan, demandPerWeek: tier.demandPerWeek,
                                   accountCount: tier.accountCount,
                                   runsDry: dryKeys.contains(key(tier.plan)))
        }
        if tiers.isEmpty {
            // Unsplit: one tier for the whole provider, dry when any of its pools is.
            let owned = store.orderedAccounts.filter { $0.providerID == reading.provider }.count
            tiers = [.init(plan: nil, demandPerWeek: reading.demandPerWeek,
                           accountCount: max(1, owned), runsDry: !dryPools.isEmpty)]
        } else {
            for entry in dryPools {
                guard let tier = entry.summary.planTier,
                      !tiers.contains(where: { key($0.plan) == tier.key }) else { continue }
                tiers.append(.init(plan: tier.name, demandPerWeek: 0,
                                   accountCount: entry.summary.accountCount, runsDry: true))
            }
        }
        let split = Set(tiers.compactMap(\.plan)).count >= 2 || gaugeSplit >= 2
        return AdvisorConclusion.decide(verdict: reading.verdict, daysOfData: reading.daysOfData,
                                        tiers: tiers, split: split)
    }

    /// The conclusion in words: the row's text, the hover's first line, and VoiceOver's label.
    /// Counts and plan names go in as STRINGS, like every figure this app catalogues: an
    /// interpolated Int keys the entry on `%lld` and misses the `%@` catalogue entry (2026-08-04).
    private func conclusionSentence(_ conclusion: AdvisorConclusion) -> String {
        switch conclusion {
        case .enough:
            return L("enough accounts")
        case .collecting(let days):
            guard days > 1 else { return L("account advice in 1 day") }
            let count = "\(days)"
            return String(localized: "account advice in \(count) days", bundle: AppLocale.bundle)
        case .add(let count, let plan):
            let number = "\(count)"
            switch (plan, count) {
            case (nil, 1): return L("add 1 account")
            case (nil, _): return String(localized: "add \(number) accounts", bundle: AppLocale.bundle)
            case (let plan?, 1): return String(localized: "add 1 \(plan) account", bundle: AppLocale.bundle)
            case (let plan?, _):
                return String(localized: "add \(number) \(plan) accounts", bundle: AppLocale.bundle)
            }
        case .shortAtPace(let plans):
            guard !plans.isEmpty else { return L("not enough at this pace") }
            let names = plans.map { $0 ?? L("Unknown plan") }.joined(separator: " · ")
            return String(localized: "\(names) not enough at this pace", bundle: AppLocale.bundle)
        }
    }

    private func conclusionTint(_ conclusion: AdvisorConclusion) -> Color {
        switch conclusion {
        case .enough, .collecting: return .secondary
        case .add, .shortAtPace: return TallyColor.warning
        }
    }

    /// A window as a compact "28d". Catalogued with the number as an ARGUMENT (`%@`), like every
    /// other figure this app localizes: a key built by interpolating the value would only exist for
    /// whatever number happened to be on screen the day it was translated.
    private func windowLabel(_ days: Double) -> String {
        let count = "\(Int(days))"
        return String(localized: "\(count)d", bundle: AppLocale.bundle)
    }

    /// Every window's pooled figure on one line: "1d 4.1 · 3d 3.8 · 7d 3.6 · 28d 3.4". Windows that
    /// have not reached their own gate keep their rung and show the no-data glyph, so the ladder is
    /// the same shape on day one as it is in month two.
    private func demandLadder(_ reading: UsageAdvisor.Reading) -> String {
        reading.windowDemands
            .map { "\(windowLabel($0.days)) \(pooledFigure($0))" }
            .joined(separator: " · ")
    }

    /// One window's pooled figure to one decimal, or the no-data glyph while it is still short of
    /// its gate. ONE place decides what a missing number looks like: the row and the ladder show the
    /// same window side by side, and two spellings of "not yet" would read as two different states.
    private func pooledFigure(_ window: UsageAdvisor.WindowDemand) -> String {
        window.demandPerWeek.map { String(format: "%.1f", $0) } ?? Self.noFigure
    }

    /// The tiers worth splitting the figure into: none unless the provider's accounts actually sit
    /// on two or more NAMED plans. One plan (or none the app can name) means the accounts really
    /// are interchangeable, and the pooled figure is then both exact and the shorter read.
    private func splitTiers(_ tiers: [UsageAdvisor.TierDemand]) -> [UsageAdvisor.TierDemand] {
        guard Set(tiers.compactMap(\.plan)).count >= 2 else { return [] }
        return tiers
    }

    private func tierName(_ tier: UsageAdvisor.TierDemand) -> String {
        tier.plan ?? L("Unknown plan")
    }

    /// The four-week verdict alone, for the hover's "4-week average" line: the same words the row
    /// uses, so the two horizons read in one vocabulary.
    private func verdictSentence(_ reading: UsageAdvisor.Reading) -> String {
        switch reading.verdict {
        case .collecting: return L("still collecting history")
        case .sufficient: return L("enough accounts")
        case .addAccount:
            let owned = store.orderedAccounts.filter { $0.providerID == reading.provider }.count
            let missing = AdvisorConclusion.shortfall(demandPerWeek: reading.demandPerWeek, owned: owned)
            guard missing > 1 else { return L("add 1 account") }
            let count = "\(missing)"
            return String(localized: "add \(count) accounts", bundle: AppLocale.bundle)
        }
    }

    /// The numbers behind the verdict, for the hover tooltip - the "why" the one-liner elides -
    /// followed by when the provider next gets quota back, because "do I need another account"
    /// is really "can I wait for the refill". Same wording as the gauge's refill label and the
    /// same +gain the fleet tooltip lists, so one schedule never reads two ways.
    private func advisorTooltip(_ reading: UsageAdvisor.Reading, sentence: String,
                                dryPools: [DryPool], now: Date) -> String {
        let demand = String(format: "%.1f", reading.demandPerWeek)
        let burn = "\(Int(reading.activeBurnPerHour.rounded()))%"
        let starved = String(format: "%.1fh", reading.starvedHoursPerWeek)
        var lines = [sentence]
        // This week's reading, in the gauge's own words, for each pool that runs dry: the reason
        // the row can say "not enough" while the four-week average below says otherwise.
        for entry in dryPools {
            let name = entry.summary.planTier.map { $0.name ?? L("Unknown plan") }
                ?? ProviderCatalog.displayName(for: reading.provider)
            let body = UsageFormat.durationBody(entry.dry.timeIntervalSince(now))
            lines.append(name + " · " + String(localized: "lasts about \(body)", bundle: AppLocale.bundle))
        }
        let verdict = verdictSentence(reading)
        lines.append(String(localized: "4-week average: \(verdict)", bundle: AppLocale.bundle))
        // Each tier's four-week figure spelled out in full, with the reason they are not added
        // up. The pooled line below stays: it is still the honest total percent-points, and
        // dropping it would make the tooltip disagree with `demandPerWeek` everywhere else this
        // app publishes it.
        let tiers = splitTiers(reading.tierDemands)
        for tier in tiers {
            let figure = String(format: "%.1f", tier.demandPerWeek)
            // The count goes in as a STRING: an interpolated Int would key the entry on `%lld`,
            // and every catalogued figure in this app is keyed on `%@`.
            let count = "\(tier.accountCount)"
            lines.append(tier.accountCount == 1
                ? String(localized: "\(tierName(tier)): \(figure) acct/wk (1 account)",
                         bundle: AppLocale.bundle)
                : String(localized: "\(tierName(tier)): \(figure) acct/wk (\(count) accounts)",
                         bundle: AppLocale.bundle))
        }
        if !tiers.isEmpty {
            lines.append(L("Plan quotas differ, so tiers are counted separately."))
        }
        lines.append(
            String(localized: "weekly need \(demand) accounts · active burn \(burn)/h · starved \(starved)/wk",
                   bundle: AppLocale.bundle))
        // THE LADDER: the whole point of the shorter windows is the COMPARISON (is this week still
        // last month's average?), so every rung is side by side.
        lines.append(String(localized: "by window: \(demandLadder(reading)) acct/wk",
                            bundle: AppLocale.bundle))
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
