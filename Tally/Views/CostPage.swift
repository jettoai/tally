import SwiftUI

/// The Cost tab: a Spend / Tokens switch over the two pages that read the token scan. Spend is the
/// priced view (`CostPage`), Tokens the token history (`TokenStatsView`), each exactly as it was
/// when it was a tab of its own. One store behind both, so the switch is instant and never
/// rescans; arriving on the tab is what brings the numbers up to date, the way visiting either
/// page did before.
struct CostTabPage: View {
    @Bindable var store: TokenStatsStore
    /// This surface's own choice (`SurfaceTabState.costPage`): one per host, handed over on a pin.
    @Binding var page: CostSubpage
    var width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The quieter size, like the range switch on each page: the header's switch chooses
            // what the window is about, this one which view of the same scan. Never `dragsWindow`:
            // the header's is the only switch that doubles as a grab area (dragortap suite).
            NeutralSegmentedPicker(selection: $page, options: CostSubpage.allCases,
                                   size: .small) { $0.label }
                .padding([.horizontal, .top], 12)
            // Independent conditions in a top-leading ZStack, for the reason the tabs are
            // (PopoverRootView): mid-crossfade both pages exist, and stacked they take the taller
            // one's height rather than the sum, so the host never chases a height neither has.
            ZStack(alignment: .topLeading) {
                if page == .spend {
                    CostPage(store: store, width: width)
                        .transition(PopoverRootView.tabTransition)
                }
                if page == .tokens {
                    TokenStatsView(store: store, width: width)
                        .transition(PopoverRootView.tabTransition)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: page)
        }
        .frame(width: width, alignment: .leading)
        .onAppear { store.refresh() }
    }
}

/// The Cost page: the total and what it is made of, then one row per project, under the same
/// range switch the Tokens page has. It reads the same priced cells `~/.tally/project-cost.json` is written from
/// (TokenStatsStore), so the page and `tally cost` agree on a scan.
struct CostPage: View {
    @Bindable var store: TokenStatsStore
    var width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: TallyMetrics.sectionSpacing) {
            NeutralSegmentedPicker(selection: $store.range, options: TokenStatsRange.allCases,
                                   size: .small) { $0.label }
                .frame(maxWidth: .infinity, alignment: .trailing)
            if store.hasScanned && store.cost.isEmpty {
                CostEmptyState()
            } else {
                CostHeadline(cost: store.cost, range: store.range)
                CostTableView(cost: store.cost, range: store.range)
            }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
    }
}

/// Total cost, the subagent part of it, what it leaves out, and the four token classes it is made of
/// (which shows at a glance whether the money goes on cache reads).
struct CostHeadline: View {
    var cost: CostSummary
    var range: TokenStatsRange

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: L("Total cost (%@)"), range.label))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(CostFormat.dollars(cost.total))
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                Text(String(format: L("Subagents %1$@ (%2$@)"), CostFormat.dollars(cost.subagentCost),
                            UsageFormat.sharePercent(cost.subagentCost / max(cost.total, 0.000_001))))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            CostCaveats(cost: cost)
            Divider().padding(.vertical, 6)
            HStack(alignment: .top, spacing: 0) {
                part(L("Input"), cost.parts.input)
                part(L("Cache write"), cost.parts.cacheWrite)
                part(L("Cache read"), cost.parts.cacheRead)
                part(L("Output"), cost.parts.output)
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
    }
}

extension CostHeadline {
    private func part(_ label: String, _ value: Double) -> some View {
        let share = UsageFormat.sharePercent(value / max(cost.total, 0.000_001))
        return VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(CostFormat.dollars(value)).font(.callout.weight(.medium)).monospacedDigit()
                Text(share).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label), \(CostFormat.dollars(value)), \(share)"))
    }
}

/// What the figure does not include: providers with no price list, and turns on unknown models.
struct CostCaveats: View {
    var cost: CostSummary

    var body: some View {
        let unpriced = cost.providers.filter { $0.cost == nil && !$0.tokens.isEmpty }
        if !unpriced.isEmpty || cost.unpricedTurns > 0 {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(unpriced) { row in
                    Text(String(format: L("%1$@: %2$@ tokens, not priced"),
                                ProviderCatalog.displayName(for: row.providerID),
                                UsageFormat.compactCount(row.tokens.total)))
                }
                if cost.unpricedTurns > 0 {
                    Text(String(format: L("%lld turns on unpriced models"), cost.unpricedTurns))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

struct CostEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "dollarsign.circle")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(L("No cost recorded in this range."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// One row per project, ranked by cost, with the figures to compare them by.
struct CostTableView: View {
    var cost: CostSummary
    var range: TokenStatsRange

    private static let money: CGFloat = 64
    private static let share: CGFloat = 38
    private static let tokens: CGFloat = 52
    private static let rate: CGFloat = 52
    private static let change: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            row(name: Text(L("Project")), cost: Text(L("Cost")), share: Text(L("Share")),
                tokens: Text(L("Tokens")), rate: Text(L("$/M tok")),
                change: Text(range == .all ? "" : L("vs prev")))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .tallyTooltip(L("$/M tok is the blended price per million tokens: high where a project runs on dearer models"))
            Divider()
            ForEach(cost.projects) { p in
                row(name: Text(p.name).foregroundStyle(p.isOther ? Color.secondary.opacity(0.7) : .primary),
                    cost: Text(CostFormat.dollars(p.cost)).fontWeight(.semibold),
                    share: Text(UsageFormat.sharePercent(p.share)).foregroundStyle(.secondary),
                    tokens: Text(UsageFormat.compactCount(p.tokens.total)).foregroundStyle(.secondary),
                    rate: Text(p.tokens.total > 0 ? CostFormat.dollars(p.cost / Double(p.tokens.total) * 1e6) : "—")
                        .foregroundStyle(.secondary),
                    change: changeText(p))
                    .font(.footnote.monospacedDigit())
                    .tallyTooltip(p.isOther ? L("Scratch directories and sessions with no project") : p.key)
                    .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
    }

    private func changeText(_ p: CostSummary.ProjectRow) -> Text {
        guard let label = CostFormat.change(p.cost, previous: p.previousCost) else { return Text("") }
        let up = (p.previousCost ?? 0) < p.cost
        return Text((up ? "▲ " : "▼ ") + label.trimmingCharacters(in: CharacterSet(charactersIn: "+-")))
            .foregroundStyle(up ? TallyColor.warning : TallyColor.normal)
    }

    private func row(name: Text, cost: Text, share: Text, tokens: Text, rate: Text, change: Text) -> some View {
        HStack(spacing: 8) {
            name.lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            cost.frame(width: Self.money, alignment: .trailing)
            share.frame(width: Self.share, alignment: .trailing)
            tokens.frame(width: Self.tokens, alignment: .trailing)
            rate.frame(width: Self.rate, alignment: .trailing)
            change.frame(width: Self.change, alignment: .trailing)
        }
    }
}
