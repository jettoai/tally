import SwiftUI

// The "ledger" usage-tab preview layout (-TallyUsageLayout ledger, B-2625): one row per account, three
// horizontal bars lined up in columns (5h, week, flagship), ONE printed number: the tightest window.
// Nothing here is reached without the launch flag. The pool figures come from the same sources the
// default section heading reads (`fleetSummaries`, `displayedPools`, `poolDryDate`), the tightest
// window only from `AccountFacts.bindingWindow`, and colours only from `MetricSeverity`, so this file
// holds no threshold and takes no minimum of its own (tests/usagelayout locks both).

private enum LedgerMetrics {
    // Widths come from UsageLayout.Ledger, derived from the region actually given (listWidth) (B-3461).
    static let nameWidth = UsageLayout.Ledger.nameWidth
    static let barHeight: CGFloat = 5
    /// A heading's pool bar is two thirds of a column bar: beside the label, the level and the
    /// refill it is what makes room for the longest window name ("Flagship") in one region.
    static func poolBarWidth(_ bar: CGFloat) -> CGFloat { bar * 2 / 3 }
    static let numberWidth = UsageLayout.Ledger.numberWidth
    static let badgeWidth = UsageLayout.Ledger.badgeWidth
    static let gap = UsageLayout.Ledger.gap
    static let rowHeight: CGFloat = 24
    /// A single-window account draws its one bar across the width of all three columns.
    static func spanWidth(_ bar: CGFloat) -> CGFloat { bar * 3 + gap * 2 }
}

/// The ink of a printed tightest-window number: the text colour when healthy, the severity colour
/// otherwise, with amber darkened on a light background (the bar's amber reads weakly as text there).
func layoutNumberInk(_ severity: MetricSeverity) -> Color {
    switch severity {
    case .normal: return .primary
    case .warning: return TallyColor.warningInk
    default: return severity.color
    }
}

extension PopoverRootView {
    /// The account region in the ledger layout. No reorder gesture is attached on purpose: the preview
    /// is judged on screen, not dragged.
    @ViewBuilder
    var ledgerAccounts: some View {
        let bar = UsageLayout.Ledger.barWidth(in: listWidth)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(accountGroups) { group in
                ledgerSection(group, bar: bar)
            }
        }
        .padding(.horizontal, UsageLayout.Ledger.inset)
    }

    private func ledgerSection(_ group: AccountGroup, bar: CGFloat) -> some View {
        let providerID = group.providerID
        let plans = Self.ledgerPlans(group.items)
        // The rule FleetMath splits its summaries by, so a row never looks for a pool that is not there.
        let split = !FleetMath.planTiers(accounts: group.items).isEmpty
        // Once per provider: each pick walks every account (TALLY-7Z), same rule as the card grid.
        let pick = AccountFacts.autoPickID(providerID: providerID)
        let foldable = pooledProviderIDs.contains(providerID)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                providerLabel(providerID, count: group.items.count).font(.system(size: 12, weight: .semibold))
                if !split, plans.count == 1, let plan = plans.first?.name {
                    Text(plan).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if foldable { foldChevron(providerID) }
                Spacer(minLength: 8)
                if !split { ledgerPool(providerID, tier: nil, bar: bar) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if foldable { settings.toggleCollapsed(providerID) } }
            if !group.isFolded {
                if group.items.contains(where: { LayoutWindows($0).present.count > 1 }) {
                    ledgerColumnNames(bar: bar)
                }
                ForEach(Array(plans.enumerated()), id: \.offset) { _, plan in
                    if split {
                        HStack(spacing: 6) {
                            Text(plan.name ?? L("Unknown plan")).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            ledgerPool(providerID, tier: FleetSummary.Tier(name: plan.name), bar: bar)
                        }
                    }
                    // Leading, not the default centre: the 0.5pt separator is as wide as the region, which
                    // would otherwise centre the (narrower) rows and shift them off the other plans' columns.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(plan.items.enumerated()), id: \.element.id) { index, usage in
                            if index > 0 {
                                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                            }
                            LedgerAccountRow(usage: usage, settings: settings, isSmartPick: usage.id == pick,
                                             barWidth: bar)
                        }
                    }
                }
            }
        }
    }

    /// The accounts of one provider split by plan name, in order of first appearance.
    private static func ledgerPlans(_ items: [AccountUsage]) -> [(name: String?, items: [AccountUsage])] {
        var plans: [(name: String?, items: [AccountUsage])] = []
        for usage in items {
            if let index = plans.firstIndex(where: { $0.name == usage.planName }) {
                plans[index].items.append(usage)
            } else {
                plans.append((usage.planName, [usage]))
            }
        }
        return plans
    }

    private func ledgerColumnNames(bar: CGFloat) -> some View {
        HStack(spacing: LedgerMetrics.gap) {
            Color.clear.frame(width: LedgerMetrics.nameWidth, height: 1)
            ForEach(LayoutWindows.names, id: \.self) { name in
                Text(name).lineLimit(1).frame(width: bar, alignment: .leading)
            }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    /// The leading pool of one provider (`tier` nil) or of one plan (a tier, the unknown plan included
    /// when the provider is split), labelled by its own window: bar, level, then `⧗` when it runs dry
    /// before it refills, `↻` with the next refill otherwise. A plan with no pool reads "No reading"
    /// rather than another plan's figures; an unsplit provider with no pool (a single account) draws
    /// nothing, exactly as the default heading.
    @ViewBuilder
    private func ledgerPool(_ providerID: String, tier: FleetSummary.Tier?, bar: CGFloat) -> some View {
        let summary = UsageLayout.poolSummary(fleetSummaries, providerID: providerID, tier: tier)
        let pools = summary.map(displayedPools) ?? []
        if let summary, let pool = pools.first(where: { $0.kind == .weeklyAll }) ?? pools.first {
            let now = Date()
            let tint = MetricSeverity.fromUsedPercent(100 - pool.averageRemaining).color
            HStack(spacing: 6) {
                Text(UsageLayout.windowName(pool.kind)).foregroundStyle(.secondary).fixedSize()
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(LayoutTint.track)
                    .frame(width: LedgerMetrics.poolBarWidth(bar), height: LedgerMetrics.barHeight)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(tint)
                            .frame(width: max(1, LedgerMetrics.poolBarWidth(bar) * pool.averageRemaining / 100))
                    }
                Text(verbatim: "\(Int(pool.averageRemaining.rounded()))%").monospacedDigit()
                if case .some(.some(let dry)) = poolDryDate(summary, pool, now: now) {
                    Text(verbatim: "⧗ " + UsageFormat.durationBody(dry.timeIntervalSince(now)))
                        .foregroundStyle(TallyColor.warningInk)
                } else if let refill = pool.refills.first {
                    Text(verbatim: "↻ " + UsageFormat.countdownBody(refill.at, now: now)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
        } else if tier != nil {
            Text(L("No reading")).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

/// One account row. A struct of its own because the detail popover needs state, which an extension
/// of the panel cannot hold.
struct LedgerAccountRow: View {
    let usage: AccountUsage
    let settings: SettingsStore
    let isSmartPick: Bool
    let barWidth: CGFloat
    @State private var showsDetail = false

    var body: some View {
        let facts = AccountFacts(usage: usage, settings: settings)
        let windows = LayoutWindows(usage)
        let binding = facts.bindingWindow
        let present = windows.present
        HStack(spacing: LedgerMetrics.gap) {
            Text(facts.label).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                .frame(width: LedgerMetrics.nameWidth, alignment: .leading)
                .tallyTooltip(facts.markOwner, detail: facts.identityDetail)
            if present.count == 1, let only = present.first?.metric {
                LayoutBar(metric: only, length: LedgerMetrics.spanWidth(barWidth),
                          thickness: LedgerMetrics.barHeight, calmWhenHealthy: true)
            } else {
                ForEach(Array(windows.all.enumerated()), id: \.offset) { _, window in
                    LayoutBar(metric: window.metric, length: barWidth,
                              thickness: LedgerMetrics.barHeight, calmWhenHealthy: true)
                }
            }
            number(binding, severity: facts.bindingSeverity)
            badge(facts)
        }
        .frame(height: LedgerMetrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { showsDetail.toggle() }
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
            UsageDetailCard(facts: facts, isSmartPick: isSmartPick)
        }
    }

    private func number(_ binding: UsageMetric?, severity: MetricSeverity) -> some View {
        Group {
            if let binding {
                Text(verbatim: "\(Int(binding.remainingPercent.rounded()))")
                    .foregroundStyle(layoutNumberInk(severity))
            } else {
                Text(verbatim: "-").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
        .frame(width: LedgerMetrics.numberWidth, alignment: .trailing)
    }

    /// The smart pick wears the product's sparkle in its own colour; a pinned account a quiet dot.
    private func badge(_ facts: AccountFacts) -> some View {
        Group {
            if isSmartPick, facts.hasSiblings, facts.launchMode == .auto {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(TallyColor.ai)
                    .tallyTooltip(facts.smartPickTooltip)
            } else if facts.isPinnedActive {
                Circle().fill(Color.secondary).frame(width: 5, height: 5)
            } else {
                Color.clear
            }
        }
        .frame(width: LedgerMetrics.badgeWidth)
    }
}
