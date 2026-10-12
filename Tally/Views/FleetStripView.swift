import SwiftUI

/// The fleet gauge: for each provider with 2+ accounts, the accounts' weekly quota unified into
/// ONE meter, in the storage-bar grammar (one continuous fill = the whole fleet's remaining,
/// hairlines inside the fill marking each account's contribution) - chosen over per-account
/// segments, which read as several broken little meters instead of a pool. Laid out in the
/// cards' metric-row grammar, ONE line per pool: a narrow label column (plan or pool name, when
/// the heading above does not already say it), the pooled bar, the level, the pace forecast and
/// the next refill in its short form. Who exactly is running dry stays on the cards below and
/// in the tooltip - the gauge answers "how much does the whole fleet have and does it last",
/// and only that. Providers with a single account contribute nothing: a pool of one is just
/// that account's card.
extension PopoverRootView {
    /// Internal because the section heading lays its label block in this same column, so every
    /// bar on the panel starts on one vertical line (`providerSection`).
    static let fleetLabelWidth: CGFloat = 96
    private static let fleetValueWidth: CGFloat = 34
    static let fleetRowSpacing: CGFloat = 8
    /// The pool rows' own label column, narrower than the heading's: it carries at most a plan
    /// name with its count or a pool name, never the provider. This is its floor, the longest
    /// English pool name (61pt at footnote); `poolLabelColumnWidth` widens it to
    /// the widest label actually on the panel.
    private static let poolLabelWidth: CGFloat = 62
    /// Fixed, so every bar starts and ends on the same two vertical lines whatever the forecast and
    /// refill beside it say. A row too narrow for both on one line puts the refill under the
    /// forecast (`forecastAndRefill`) rather than truncating either.
    private static let fleetBarWidth: CGFloat = 100
    private static let fleetChevronWidth: CGFloat = 12

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
            ? FleetMath.summaries(accounts: store.orderedAccounts, byPlan: true) { usage in
                settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
            }
            : []
    }

    /// One summary's pool rows, under its provider's section heading (`providerSection`). The hover
    /// belongs to this block rather than to the whole section: a callout is placed against the rect
    /// its target reports (`TooltipPlacement`), so a wider target put the chip far from the row the
    /// pointer was on. One target, one subject, one gap.
    @ViewBuilder
    func fleetGauge(_ summary: FleetSummary, forcedTooltip: Bool = false) -> some View {
        let pools = displayedPools(summary)
        if !pools.isEmpty {
            let labelWidth = poolLabelColumnWidth
            VStack(alignment: .leading, spacing: 3) {
                // A split provider's plan gets a title line of its own, so every row under it names
                // its window: the plan name used to stand in the first row's label, and a Codex plan
                // with only a weekly reading showed no pool name at all (B-1544).
                if let tier = summary.planTier {
                    (Text(planName(tier)).foregroundStyle(Color.secondary)
                     + Text(" ×\(summary.accountCount)").foregroundStyle(.tertiary))
                        .font(.footnote)
                        .lineLimit(1)
                }
                ForEach(pools.indices, id: \.self) { index in
                    poolRow(summary, pools[index], labelWidth: labelWidth)
                }
                // "All pools" with no 5-hour reading says so, rather than drawing one row fewer
                // than the plan above it, which read as a row left out.
                if settings.gaugeFocus == .all, !pools.contains(where: { $0.kind == .session }) {
                    HStack(spacing: Self.fleetRowSpacing) {
                        Text(L("5-hour pool")).foregroundStyle(Color.secondary)
                            .frame(width: labelWidth, alignment: .leading)
                        Text(L("No reading")).foregroundStyle(.tertiary)
                    }
                    .font(.footnote)
                    .lineLimit(1)
                }
            }
            .tallyTooltip(lazyBlocks: { fleetTooltipBlocks([summary]) }, forced: forcedTooltip)
        }
    }

    /// Provider identity and fleet size on one line: mark, display name, ×N. The one label form the
    /// gauges and the grouped cards' section headings both speak, so the two surfaces cannot drift
    /// into naming the same provider two ways. The caller sets the font (the gauges take footnote,
    /// a section heading is lighter). A split provider's plan rows show the plan name INSTEAD of the
    /// provider name (vendor string, never translated): the mark already says which provider, and
    /// the full "Codex Team ×1" did not fit the single-column 88pt label.
    func providerLabel(_ providerID: String, count: Int,
                       plan: FleetSummary.Tier? = nil) -> some View {
        HStack(spacing: 5) {
            ProviderIconView(providerID: providerID, size: 11)
            (Text(plan.map(planName) ?? ProviderCatalog.displayName(for: providerID))
                .foregroundStyle(Color.secondary)
             + Text(" ×\(count)").foregroundStyle(.tertiary))
        }
        .lineLimit(1)
    }

    /// A split provider's plan as shown: the vendor's name, or "Unknown plan".
    private func planName(_ tier: FleetSummary.Tier) -> String { tier.name ?? L("Unknown plan") }

    /// The disclosure affordance, shared by both gauge layouts and by the grouped cards' section
    /// headings: click folds this provider's cards away (the pools stay - they ARE the summary),
    /// click again brings them back.
    func foldChevron(_ providerID: String) -> some View {
        let collapsed = settings.collapsedProviders.contains(providerID)
        return Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: Self.fleetChevronWidth)
            .tallyTooltip(L("Show or hide this provider's account cards"))
    }

    /// One pool on one line: label, bar, level, pace forecast, then the short refill on the right
    /// (the full sentence, with the account and the clock time, is its tooltip). The pool name
    /// sits in the label column, not in front of the forecast, and the forecast's
    /// tooltip repeats it.
    private func poolRow(_ summary: FleetSummary, _ pool: FleetPool,
                         labelWidth: CGFloat) -> some View {
        let phrase = forecastPhrase(summary, pool)
        return HStack(spacing: Self.fleetRowSpacing) {
            Text(poolDisplayName(pool)).foregroundStyle(Color.secondary)
                .font(.footnote)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            pooledBar(pool).frame(width: Self.fleetBarWidth)
            Text(worthValue(pool))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: Self.fleetValueWidth, alignment: .trailing)
            forecastAndRefill(pool, phrase)
        }
    }

    /// The forecast with the refill at the far right, or, when the panel is too narrow for both
    /// (the 380pt single column cannot seat a forecast and a refill beside a bar in any language),
    /// the refill on a second line under the forecast. Neither sentence is ever cut (B-1544).
    /// Every pool shows its own refill, even when it repeats the row above: Anthropic resets the
    /// model and weekly windows at the same moment, and a same-moment dedupe left the weekly slot
    /// permanently empty, which read as missing data (2026-07-23).
    private func forecastAndRefill(_ pool: FleetPool, _ phrase: (text: String, tint: Color)) -> some View {
        let forecast = Text(phrase.text)
            .foregroundStyle(phrase.tint)
            .font(.caption2)
            .lineLimit(1)
            .tallyTooltip("\(poolDisplayName(pool)) · \(phrase.text)")
        let refill = pool.refills.first.map { refillLabel($0, compact: true) }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Self.fleetRowSpacing) {
                forecast
                Spacer(minLength: 6)
                refill
            }
            VStack(alignment: .leading, spacing: 1) {
                forecast
                refill
            }
        }
    }

    /// The label column's width for the whole panel: the widest label any pool row on it carries,
    /// never under the English floor. One width for every provider, so every bar still starts on
    /// one vertical line, and a longer translation widens the column
    /// instead of truncating (B-1524). The font and size stay put: shrinking one row's text would
    /// leave the column in two sizes.
    private var poolLabelColumnWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.preferredFont(forTextStyle: .footnote)]
        let names = fleetSummaries.flatMap { displayedPools($0).map(poolDisplayName) }
            + (settings.gaugeFocus == .all ? [L("5-hour pool")] : [])
        let widest = names.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
        return max(Self.poolLabelWidth, ceil(widest))
    }

    func poolDisplayName(_ pool: FleetPool) -> String {
        poolDisplayName(kind: pool.kind, modelName: pool.modelName, label: pool.label)
    }

    /// The same name from the parts alone, for a caller holding a pool's identity rather than the
    /// pool (the hover's model). ONE implementation, so the gauge's rows and its hover can
    /// never name the same pool two ways.
    private func poolDisplayName(kind: MetricKind, modelName: String?, label: String) -> String {
        switch kind {
        case .weeklyModel:
            let model = modelName ?? label
            return String(localized: "\(model) pool", bundle: AppLocale.bundle)
        case .session:
            return L("5-hour pool")
        default:
            return L("Weekly pool")
        }
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private func worth(_ units: Double) -> String { String(format: "%.1f", units / 100) }

    /// The pool's level as a percentage - the same numeric language as the cards and the menu
    /// bar, so the whole panel reads in one unit (the label's ×N already carries the fleet size,
    /// and the invented "accounts' worth" unit lives in the tooltip instead). Follows the
    /// Used/Left toggle like every meter.
    private func worthValue(_ pool: FleetPool) -> String {
        percent(settings.displayMode == .used
            ? 100 - pool.averageRemaining : pool.averageRemaining)
    }

    /// When this pool runs dry at its measured pace, `.some(nil)` when it outlasts the forecast
    /// horizon, and nil when there is no pace yet (still measuring) or the pool is a session pool,
    /// which paces work rather than capping it. Internal because the advisor row asks the same
    /// question and must get the same answer: its "short at this pace" is exactly this
    /// line's amber "runs dry in about", never a second threshold.
    func poolDryDate(_ summary: FleetSummary, _ pool: FleetPool, now: Date) -> Date?? {
        guard pool.kind != .session else { return nil }
        guard let rate = store.fleetRates[FleetForecast.rateKey(
            provider: summary.providerID, window: pool.kind.rawValue, model: pool.modelName,
            plan: summary.planTier?.key)] else { return nil }
        return .some(FleetForecast.depletion(
            remaining: pool.totalRemaining,
            refills: pool.refills.map { ($0.at, $0.gain) },
            perHour: rate.perHour,
            steadyRefillPerHour: pool.steadyRefillPerHour(windowHours: 168),
            now: now))
    }

    /// The pace verdict as words plus its tint, so the line and its tooltip cannot drift: the row
    /// clips this sentence when a column is narrow, and the hover has to answer with the same one.
    private func forecastPhrase(_ summary: FleetSummary,
                                _ pool: FleetPool) -> (text: String, tint: Color) {
        guard pool.kind != .session else { return ("", .secondary) }
        let now = Date()
        guard let outlook = poolDryDate(summary, pool, now: now) else {
            return (L("measuring pace…"), Color.secondary.opacity(0.7))
        }
        // Both branches already count every refill the forecast sees: the check means the pool
        // never runs out at this pace, and the amber time is when it does with refills included.
        // Neither is about the next refill, which is the row's own label on the right.
        guard let dry = outlook else {
            return ("\(L("lasts at this pace")) ✓", Self.sustainableInk)
        }
        let seconds = dry.timeIntervalSince(now)
        let body = UsageFormat.durationBody(seconds)
        return (String(localized: "runs dry in about \(body)", bundle: AppLocale.bundle),
                seconds < 86_400 ? Self.criticalInk : Self.amberTagInk)
    }

    /// "refill in 4d 6h" on the row (the full "next refill Claude in 4d 6h" with `compact: false`):
    /// refill wording, not "resets", so it can't be confused with the per-window reset labels on
    /// the cards. Which account and the exact time are in the hover.
    private func refillLabel(_ refill: FleetPool.Refill, compact: Bool = false) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(refillText(refill, now: context.date, compact: compact))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Both readings, always, and never the compact form: a truncated line is exactly
                // when a reader reaches for the tooltip, so it has to answer with the whole thing
                // (which account, the date and time, and how long that is from now).
                .tallyTooltip(String(localized: "next refill \(refill.accountLabel) at \(UsageFormat.absoluteBody(refill.at))",
                                     bundle: AppLocale.bundle)
                    + " · " + refillText(refill, now: context.date))
        }
    }

    /// Internal: the advisor tooltip lists the same refills in the same words, so the two surfaces
    /// can never phrase one schedule two ways.
    /// Always says how much comes back: a bare "refill in 19h" read as the whole pool refilling,
    /// right beside a "runs dry" forecast that already counts it (B-1544 r7).
    func refillText(_ refill: FleetPool.Refill, now: Date, compact: Bool = false) -> String {
        let account = refill.accountLabel
        let body = UsageFormat.countdownBody(refill.at, now: now)
        let gain = "\(Int(refill.gain.rounded()))%"
        return compact
            ? String(localized: "refill +\(gain) in \(body)", bundle: AppLocale.bundle)
            : String(localized: "next refill \(account) +\(gain) in \(body)", bundle: AppLocale.bundle)
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

    /// The gauge's hover, one block per summary asked about - which is ONE, the provider whose rows
    /// are being hovered: the capacity unit the value column gives up, the tightest window in that
    /// fleet with the account that owns it, and the next refill. It stayed plural because the shape
    /// is the block list's, and a caller holding several summaries would build several blocks.
    ///
    /// WHAT IS NOT HERE, deliberately: a line per account. Those numbers are on the cards directly
    /// below, and repeating them made the hover a wall of text whose useful half was the part that
    /// was NOT already on screen. What the selection means and why these three lines lives in
    /// FleetTooltip.swift; this turns its answer into words and colours.
    /// The value column of the hover's refill line. Digits only: which account it belongs to is
    /// already the label beside it, so the strip's whole sentence would say the name twice.
    private func refillBody(_ value: FleetTooltip.RefillValue) -> String {
        UsageFormat.durationBody(value.countdown) + " · " + UsageFormat.absoluteBody(value.clock)
    }

    private func fleetTooltipBlocks(_ summaries: [FleetSummary]) -> [TallyTooltipBlock] {
        summaries.compactMap { summary in
            guard let model = FleetTooltip.model(summary, displayed: displayedPools(summary))
            else { return nil }
            var rows: [TallyTooltipRow] = [
                TallyTooltipRow(
                    poolDisplayName(kind: model.poolKind, modelName: model.poolModelName,
                                    label: model.poolLabel),
                    // The string the old wall already used, word for word, so this carries no new
                    // translation: the capacity unit is unchanged, only where it is shown. BOTH
                    // interpolations are Strings on purpose - the count as an Int makes the key
                    // "%@/%lld …", which matches no entry in the catalog and silently renders the
                    // English source in every other language (caught in the zh capture, 2026-08-04).
                    String(localized: "\(worth(model.unitsRemaining))/\(String(model.poolAccountCount)) accounts' worth left",
                           bundle: AppLocale.bundle))
            ]
            // The one thing a pooled average structurally hides: four healthy accounts and one at
            // 3% average out fine. Named with its account, because "which of them" is the next
            // question and the answer is two words long.
            if let tightest = model.tightest {
                rows.append(TallyTooltipRow(
                    L("Tightest") + " · " + tightest.accountLabel + " "
                        + poolDisplayName(kind: tightest.poolKind, modelName: tightest.modelName,
                                          label: tightest.poolLabel),
                    // Follows the Used/Left toggle like every meter in the panel: in Used mode the
                    // card beside it reads 88%, and a hover answering 12% for the same window reads
                    // as a different number about a different thing. The TINT still keys off
                    // remaining, so severity never flips with the toggle - the meters' own rule.
                    percent(settings.displayMode == .used ? 100 - tightest.remaining
                                                          : tightest.remaining),
                    severity: tightest.severity))
            }
            if let refill = model.nextRefill {
                // Countdown and clock both, as every reset hover in the panel answers.
                rows.append(TallyTooltipRow(
                    L("Next refill") + " · " + refill.accountLabel,
                    refillBody(FleetTooltip.refillValue(refill, now: Date()))))
            }
            return TallyTooltipBlock(
                title: ProviderCatalog.displayName(for: summary.providerID)
                    + (summary.planTier.map { " " + planName($0) } ?? "")
                    + " ×\(model.accountCount)",
                rows: rows)
        }
    }

}
