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
        if let state = advisorState(providerID), let tag = state.tag {
            let tint = conclusionTint(state.conclusion)
            Text(tag)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint == TallyColor.warning ? Self.amberTagInk : tint)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(tint.opacity(0.15)))
                .tallyTooltip(lazyBlocks: { advisorTooltip(state) })
                .accessibilityLabel(state.sentence)
        }
    }

    /// The same hover for a heading that carries no tag (B-1570): a provider with nothing to act on
    /// this week still has its four-week figures and its next refills, so the provider's name answers
    /// with them. Empty while the tag is showing, which keeps the hover on the tag alone.
    func advisorHeadingTooltip(_ providerID: String) -> [TallyTooltipBlock] {
        guard let state = advisorState(providerID), state.tag == nil else { return [] }
        return advisorTooltip(state)
    }

    /// One provider's advice, read once for both the tag and the heading's hover.
    private struct AdvisorState {
        let reading: UsageAdvisor.Reading
        let conclusion: AdvisorConclusion
        let sentence: String
        let dryPools: [DryPool]
        let now: Date
        let tag: String?
    }

    private func advisorState(_ providerID: String) -> AdvisorState? {
        guard let reading = visibleAdvisorReadings.first(where: { $0.provider == providerID }) else { return nil }
        let now = Date()
        let dryPools = advisorDryPools(providerID, now: now)
        let conclusion = advisorConclusion(reading, dryPools: dryPools)
        let sentence = conclusionSentence(conclusion, reading: reading, dryPools: dryPools)
        return AdvisorState(reading: reading, conclusion: conclusion, sentence: sentence, dryPools: dryPools, now: now,
                            tag: tagText(conclusion, sentence: sentence, reading: reading, dryPools: dryPools))
    }

    /// Amber text: the tag here and the pool forecast line. The shared amber reads about 2:1 on a
    /// pale capsule or white in light mode, so light mode darkens the text only; dark mode keeps
    /// the shared tint (B-1524).
    static let amberTagInk = textInk(dark: TallyColor.warning, light: (0.55, 0.33, 0.0))
    /// The pool forecast's green ("won't run dry") and red (under a day) as text. On the light
    /// panel the shared tints read 3.3:1 and about 4.5:1, so light mode darkens them (6.4:1 and
    /// 7.1:1 measured); on the dark panel the shared red reads 3.6:1, so dark mode lightens the
    /// red only, and the green keeps its shared tint (5.0:1) (B-1543).
    static let sustainableInk = textInk(dark: TallyColor.normal, light: (0.18, 0.47, 0.25))
    static let criticalInk = textInk(dark: Color(red: 0.97, green: 0.45, blue: 0.42),
                                     light: (0.72, 0.16, 0.14))

    /// Text in a meter tint: `dark` on the dark appearance, the given sRGB on the light one, where
    /// the meter tints are too pale to read as text.
    private static func textInk(dark: Color, light: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: 1)
        })
    }

    /// The tag's words: what to do, or nothing. It shows only when it asks for something: accounts
    /// to add (`AdvisorConclusion.tagAdd`, which also needs the pool rows to run dry, so "add 1"
    /// never sits beside "won't run dry"), or the plans short at this pace (B-1544).
    private func tagText(_ conclusion: AdvisorConclusion, sentence: String, reading: UsageAdvisor.Reading,
                         dryPools: [DryPool]) -> String? {
        switch conclusion {
        case .enough, .collecting: return nil
        case .shortAtPace: return sentence
        case .add(_, let plan), .nearCapacity(_, _, let plan):
            return conclusion.tagAdd(fourWeek: fourWeekFigures(plan: plan, reading: reading),
                                     dryPools: joinPools(dryPools))
                .map { addText(count: $0.count, plan: $0.plan) }
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

    private func joinPools(_ dryPools: [DryPool]) -> [AdvisorConclusion.DryPool] {
        dryPools.map { entry in
            .init(byPlan: entry.summary.planTier != nil, plan: entry.summary.planTier?.name,
                  accountCount: entry.summary.accountCount, dryAt: entry.dry)
        }
    }

    private func ownedAccountCount(_ providerID: String) -> Int {
        store.orderedAccounts.filter { $0.providerID == providerID }.count
    }

    /// The conclusion. The join with the gauge's dry pools and the decision both live in
    /// `AdvisorConclusion.join`, so they are tested together.
    private func advisorConclusion(_ reading: UsageAdvisor.Reading,
                                   dryPools: [DryPool]) -> AdvisorConclusion {
        AdvisorConclusion.join(
            verdict: reading.verdict, daysOfData: reading.daysOfData,
            pooledDemandPerWeek: reading.demandPerWeek, tierDemands: reading.tierDemands,
            ownedAccounts: ownedAccountCount(reading.provider),
            dryPools: joinPools(dryPools),
            starvedHoursPerWeek: reading.starvedHoursPerWeek)
    }

    /// The conclusion in words: the row's text, the hover's first line, and VoiceOver's label.
    /// Counts and plan names go in as STRINGS, like every figure this app catalogues: an
    /// interpolated Int keys the entry on `%lld` and misses the `%@` catalogue entry (2026-08-04).
    private func conclusionSentence(_ conclusion: AdvisorConclusion, reading: UsageAdvisor.Reading,
                                    dryPools: [DryPool]) -> String {
        switch conclusion {
        case .enough:
            return L("enough accounts")
        case .collecting(let days):
            guard days > 1 else { return L("account advice in 1 day") }
            let count = "\(days)"
            return String(localized: "account advice in \(count) days", bundle: AppLocale.bundle)
        case .add(let count, let plan):
            guard let figures = fourWeekFigures(plan: plan, reading: reading) else {
                return addText(count: count, plan: plan)
            }
            return twoScaleSentence(figures.demand, owned: figures.owned, plan: plan, dryPools: dryPools)
        case .nearCapacity(let demand, let owned, let plan):
            guard let demand else { return L("near limit over 4 wks") }
            return twoScaleSentence(demand, owned: owned, plan: plan, dryPools: dryPools)
        case .shortAtPace(let plans):
            guard !plans.isEmpty else { return L("short at this pace") }
            let names = plans.map { $0 ?? L("Unknown plan") }.joined(separator: " · ")
            return String(localized: "\(names) short at this pace", bundle: AppLocale.bundle)
        }
    }

    private func addText(count: Int, plan: String?) -> String {
        let number = "\(count)"
        switch (plan, count) {
        case (nil, 1): return L("add 1 account")
        case (nil, _): return String(localized: "add \(number) accounts", bundle: AppLocale.bundle)
        case (let plan?, 1): return String(localized: "add 1 \(plan) account", bundle: AppLocale.bundle)
        case (let plan?, _): return String(localized: "add \(number) \(plan) accounts", bundle: AppLocale.bundle)
        }
    }

    /// The four-week use and the accounts it is measured against, for the plan when named.
    private func fourWeekFigures(plan: String?, reading: UsageAdvisor.Reading) -> (demand: Double, owned: Int)? {
        guard let plan else { return (reading.demandPerWeek, max(1, ownedAccountCount(reading.provider))) }
        return reading.tierDemands.first { $0.plan?.lowercased() == plan.lowercased() }
            .map { ($0.demandPerWeek, max(1, $0.accountCount)) }
    }

    /// Both time scales in one line: the four-week average against the accounts owned, then this
    /// week's pace, read from the pool rows' own dry forecast so it never contradicts them.
    private func twoScaleSentence(_ demand: Double, owned: Int, plan: String?, dryPools: [DryPool]) -> String {
        let figure = String(format: "%.1f", demand)
        let count = "\(owned)"
        let dry = joinPools(dryPools)
        let runsDry = AdvisorConclusion.runsDryThisWeek(plan: plan, dryPools: dry)
        switch (plan, runsDry) {
        case (nil, false):
            return String(localized: "Past 4 weeks averaged \(figure) accounts a week, you have \(count); at this week's pace it lasts until the refill", bundle: AppLocale.bundle)
        case (nil, true):
            return String(localized: "Past 4 weeks averaged \(figure) accounts a week, you have \(count); at this week's pace it runs dry before the refill", bundle: AppLocale.bundle)
        case (let plan?, false):
            return String(localized: "\(plan): past 4 weeks averaged \(figure) accounts a week, you have \(count); at this week's pace it lasts until the refill", bundle: AppLocale.bundle)
        case (let plan?, true):
            return String(localized: "\(plan): past 4 weeks averaged \(figure) accounts a week, you have \(count); at this week's pace it runs dry before the refill", bundle: AppLocale.bundle)
        }
    }

    private func conclusionTint(_ conclusion: AdvisorConclusion) -> Color {
        switch conclusion {
        case .enough, .collecting: return .secondary
        // Near capacity only draws a tag when it asks to add (`tagAdd`), the same action in the
        // same words as "add", so it takes the same amber (B-1544).
        case .add, .nearCapacity, .shortAtPace: return TallyColor.warning
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

    /// Every window in one column under a "By window | acct/wk" heading, shortest first: the unit
    /// once in the heading, the figures right-aligned beneath it so the four read at a glance
    /// (B-1570). A split provider's rung lists its plans in the row's order, because a ladder that
    /// pooled Pro and Team would contradict the per-plan rows above it.
    private func ladderLines(_ reading: UsageAdvisor.Reading) -> [TallyTooltipRow] {
        let order = gaugePlanOrder(reading.provider)
        let rungs = reading.windowDemands.map { window in
            TallyTooltipRow(windowLabel(window.days), figuresText(AdvisorConclusion.windowFigures(
                window, readingTiers: reading.tierDemands, planOrder: order)), style: .sub)
        }
        guard !rungs.isEmpty else { return [] }
        return [TallyTooltipRow(L("By window"), L("acct/wk"), style: .strong)] + rungs
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
            let missing = AdvisorConclusion.shortfall(demandPerWeek: reading.demandPerWeek,
                                                      owned: ownedAccountCount(reading.provider))
            guard missing > 1 else { return L("add 1 account") }
            let count = "\(missing)"
            return String(localized: "add \(count) accounts", bundle: AppLocale.bundle)
        }
    }

    /// The numbers behind the verdict, for the hover - the "why" the tag elides - then when the
    /// provider next gets quota back, because "do I need another account" is really "can I wait
    /// for the refill". One block, one fact per row, figures in the right-hand column (B-1570).
    /// The conclusion is the title, word for word the tag's sentence. There is no "weekly need"
    /// row: it is the 28-day rung itself (`UsageAdvisor.Reading.windowDemands`), and printing it
    /// twice was the hover's loudest repetition.
    private func advisorTooltip(_ state: AdvisorState) -> [TallyTooltipBlock] {
        let (reading, now) = (state.reading, state.now)
        var rows: [TallyTooltipRow] = []
        // This week's reading, in the gauge's own words, for each pool that runs dry: the reason
        // the tag can say "not enough" while the four-week average below says otherwise. Named
        // with the gauge's pool name too, so a provider's weekly and model pools never read alike.
        for entry in state.dryPools {
            let owner = entry.summary.planTier.map { $0.name ?? L("Unknown plan") }
                ?? ProviderCatalog.displayName(for: reading.provider)
            let name = owner + " " + poolDisplayName(entry.pool)
            let body = UsageFormat.durationBody(entry.dry.timeIntervalSince(now))
            rows.append(TallyTooltipRow(name, String(localized: "runs dry in about \(body)", bundle: AppLocale.bundle)))
        }
        // Near capacity IS the four-week reading, already the title with its figure; "4-week
        // average: add 1 account" under it would bring the contradiction back.
        if case .nearCapacity = state.conclusion {} else {
            rows.append(TallyTooltipRow(L("4-week average"), verdictSentence(reading)))
        }
        // Each tier's four-week figure, named the way the gauge names a plan (plan ×N), with the
        // reason they are not added up closing the block.
        let tiers = AdvisorConclusion.splitTiers(reading.tierDemands)
        for tier in tiers {
            let figure = String(format: "%.1f", tier.demandPerWeek)
            rows.append(TallyTooltipRow("\(tierName(tier)) ×\(tier.accountCount)",
                                        String(localized: "\(figure) acct/wk", bundle: AppLocale.bundle)))
        }
        let starved = String(format: "%.1fh", reading.starvedHoursPerWeek)
        rows.append(TallyTooltipRow(L("Active burn"), "\(Int(reading.activeBurnPerHour.rounded()))%/h"))
        rows.append(TallyTooltipRow(L("Starved"), String(localized: "\(starved)/wk", bundle: AppLocale.bundle)))
        // THE LADDER: the whole point of the shorter windows is the COMPARISON (is this week still
        // last month's average?), so every rung sits in one column.
        rows.append(contentsOf: ladderLines(reading))
        let refills = upcomingRefills(reading.provider, now: now)
        if !refills.isEmpty {
            rows.append(TallyTooltipRow(L("Next refill"), "", style: .strong))
            for refill in refills {
                rows.append(TallyTooltipRow(
                    refill.accountLabel,
                    UsageFormat.countdownBody(refill.at, now: now) + " · " + UsageFormat.absoluteBody(refill.at)
                        + " · +" + refill.poolShareText,
                    style: .sub))
            }
        }
        if !tiers.isEmpty {
            rows.append(TallyTooltipRow(L("Plan quotas differ, so tiers are counted separately."), "", style: .note))
        }
        return [TallyTooltipBlock(title: state.sentence, rows: rows)]
    }

    /// The provider's next two quota refills. Pooled straight from FleetMath rather than through
    /// `fleetSummaries`: that property is gated on the fleet gauge's switch and the advisor has
    /// its own, so going through it would blank these lines whenever the gauge is hidden. The pool
    /// picked is the one the gauge leads with, so both surfaces name the same window.
    ///
    /// A single-account provider has no pool at all (a pool of one is just that account), so its
    /// own binding window stands in - built as a one-member refill, which is exactly what the pool
    /// math would have made of it: the window's reset instant, and the used percent as the gain
    /// (a one-member pool, so the pool share is the gain).
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
        return [FleetPool.Refill(at: at, accountLabel: label, gain: window.usedPercent, poolSize: 1)]
    }
}
