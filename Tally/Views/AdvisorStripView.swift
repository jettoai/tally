import SwiftUI

/// The usage advisor: per provider, "do I need another account?" as a conclusion, not a figure to
/// convert. On the panel it is a short tag on the provider's section heading (`providerSection`),
/// and only when there is something to act on (near capacity, add an account, not enough at this
/// pace); "enough" and "still collecting" take no room. The full sentence, the per-plan split, burn,
/// starved hours, every window's acct/wk figure and the next refills live in the tag's hover. The
/// rule that keeps the tag consistent with the pool lines beside it is `AdvisorConclusion`. It has
/// its own visibility switch (`showAdvisor`), independent of the fleet gauge.
extension PopoverRootView {
    /// What a figure reads while its window is still collecting. The repo's one sanctioned em dash:
    /// a no-data glyph, not prose (Tally/CLAUDE.md), spelled the same way the menu bar spells it.
    private static let noFigure = "—"

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

    /// The provider's advice as a heading tag, or nothing when there is no advice to give.
    @ViewBuilder
    func advisorTag(_ providerID: String) -> some View {
        if let reading = visibleAdvisorReadings.first(where: { $0.provider == providerID }) {
            let now = Date()
            let dryPools = advisorDryPools(providerID, now: now)
            let conclusion = advisorConclusion(reading, dryPools: dryPools)
            if let tag = tagText(conclusion) {
                let sentence = conclusionSentence(conclusion)
                let tint = conclusionTint(conclusion)
                Text(tag)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint == TallyColor.warning ? Self.amberTagInk : tint)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.15)))
                    .tallyTooltip(lazyText: { advisorTooltip(reading, sentence: sentence, conclusion: conclusion,
                                                             dryPools: dryPools, now: now) })
                    .accessibilityLabel(sentence)
            }
        }
    }

    /// Amber text: the tag here and the pool forecast line. The shared amber reads about 2:1 on a
    /// pale capsule or white in light mode, so light mode darkens the text only; dark mode keeps
    /// the shared tint (B-1524).
    static let amberTagInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(TallyColor.warning)
            : NSColor(srgbRed: 0.55, green: 0.33, blue: 0.0, alpha: 1)
    })

    /// The tag's words: short enough for a heading. Near capacity drops its four-week figure (the
    /// hover's first line carries it); "add" and "not enough" are already short.
    private func tagText(_ conclusion: AdvisorConclusion) -> String? {
        switch conclusion {
        case .enough, .collecting: return nil
        case .nearCapacity: return L("near limit over 4 wks")
        case .add, .shortAtPace: return conclusionSentence(conclusion)
        }
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

    /// The conclusion. The join with the gauge's dry pools and the decision both live in
    /// `AdvisorConclusion.join`, so they are tested together.
    private func advisorConclusion(_ reading: UsageAdvisor.Reading,
                                   dryPools: [DryPool]) -> AdvisorConclusion {
        AdvisorConclusion.join(
            verdict: reading.verdict, daysOfData: reading.daysOfData,
            pooledDemandPerWeek: reading.demandPerWeek, tierDemands: reading.tierDemands,
            ownedAccounts: store.orderedAccounts.filter { $0.providerID == reading.provider }.count,
            dryPools: dryPools.map { entry in
                .init(byPlan: entry.summary.planTier != nil, plan: entry.summary.planTier?.name,
                      accountCount: entry.summary.accountCount)
            },
            starvedHoursPerWeek: reading.starvedHoursPerWeek)
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
        case .nearCapacity(let demand, let owned, let plan):
            guard let demand else { return L("near limit over 4 wks") }
            let figure = String(format: "%.1f", demand)
            let count = "\(owned)"
            guard let plan else {
                return String(localized: "near limit over 4 wks: \(figure) accounts a week, \(count) owned",
                              bundle: AppLocale.bundle)
            }
            return String(localized: "near limit over 4 wks: \(plan) \(figure) accounts a week, \(count) owned",
                          bundle: AppLocale.bundle)
        case .shortAtPace(let plans):
            guard !plans.isEmpty else { return L("short at this pace") }
            let names = plans.map { $0 ?? L("Unknown plan") }.joined(separator: " · ")
            return String(localized: "\(names) short at this pace", bundle: AppLocale.bundle)
        }
    }

    private func conclusionTint(_ conclusion: AdvisorConclusion) -> Color {
        switch conclusion {
        case .enough, .collecting: return .secondary
        // One step under "add": the calm level of the three-step ramp, drawn the way
        // FootprintSparklineView's `.calm` is (no tint, the primary label colour), so it stands out
        // from the grey "enough" without borrowing the amber that asks for a purchase.
        case .nearCapacity: return .primary
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

    /// The plans of this provider in the fleet gauge's order, so the advisor names them in the
    /// order the pool rows above it do.
    private func gaugePlanOrder(_ providerID: String) -> [String?] {
        FleetMath.planGroups(store.orderedAccounts.filter { $0.providerID == providerID })
            .map(\.tier.name)
    }

    /// A figure to one decimal, or the no-data glyph while its window is short of its gate. ONE
    /// place decides what a missing number looks like, so "not yet" never reads two ways.
    private func figureText(_ demand: Double?) -> String {
        demand.map { String(format: "%.1f", $0) } ?? Self.noFigure
    }

    /// The window's figures without label or unit: "5.8", or "Pro 1.7 · Team 0.9" for a split
    /// provider (the unit then follows the whole list rather than repeating per plan).
    private func figuresText(_ figures: AdvisorConclusion.WindowFigures) -> String {
        guard figures.split else { return figureText(figures.figures.first?.demandPerWeek) }
        return figures.figures
            .map { "\($0.plan ?? L("Unknown plan")) \(figureText($0.demandPerWeek))" }
            .joined(separator: " · ")
    }

    /// Every window side by side for the hover: one line for a provider on one plan, one line per
    /// plan for a split one (the same split and order as the row), because a ladder that pooled Pro
    /// and Team would contradict the "counted separately" line right above it.
    private func ladderLines(_ reading: UsageAdvisor.Reading) -> [String] {
        let order = gaugePlanOrder(reading.provider)
        let perWindow = reading.windowDemands.map {
            AdvisorConclusion.windowFigures($0, readingTiers: reading.tierDemands, planOrder: order)
        }
        guard let first = perWindow.first, first.split else {
            let rungs = zip(reading.windowDemands, perWindow)
                .map { "\(windowLabel($0.days)) \(figuresText($1))" }
                .joined(separator: " · ")
            return [String(localized: "by window: \(rungs) acct/wk", bundle: AppLocale.bundle)]
        }
        return first.figures.indices.map { index in
            let plan = first.figures[index].plan ?? L("Unknown plan")
            let rungs = zip(reading.windowDemands, perWindow)
                .map { "\(windowLabel($0.days)) \(figureText($1.figures[index].demandPerWeek))" }
                .joined(separator: " · ")
            return String(localized: "\(plan) by window: \(rungs) acct/wk", bundle: AppLocale.bundle)
        }
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
                                conclusion: AdvisorConclusion,
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
            lines.append(name + " · " + String(localized: "runs dry in about \(body)", bundle: AppLocale.bundle))
        }
        // Near capacity IS the four-week reading, already on the first line with its figure;
        // "4-week average: add 1 account" under it would bring the contradiction back.
        if case .nearCapacity = conclusion {} else {
            let verdict = verdictSentence(reading)
            lines.append(String(localized: "4-week average: \(verdict)", bundle: AppLocale.bundle))
        }
        // Each tier's four-week figure spelled out in full, with the reason they are not added
        // up. The pooled line below stays: it is still the honest total percent-points, and
        // dropping it would make the tooltip disagree with `demandPerWeek` everywhere else this
        // app publishes it.
        let tiers = AdvisorConclusion.splitTiers(reading.tierDemands)
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
        // last month's average?), so every rung is side by side, per plan when the provider splits.
        lines.append(contentsOf: ladderLines(reading))
        for refill in upcomingRefills(reading.provider, now: now) {
            lines.append(refillText(refill, now: now) + " · " + UsageFormat.absoluteBody(refill.at)
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
