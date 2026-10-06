import SwiftUI

/// Which of the three candidate cost layouts this instance shows (`-TallyCostLayout 1|2|3`, demo or
/// dev builds only, argument domain so nothing persists). Unset on every release launch, where no
/// cost view exists at all until one layout is chosen.
///
/// 1: a ranked table on its own Cost page. 2: a Tokens/Cost switch inside the Tokens page.
/// 3: project cards with a model split on their own Cost page.
enum CostLayout: Int {
    case table = 1, tokensSwitch, cards

    static var current: CostLayout? {
        guard DemoUsage.isActive || BuildVariant.isDev else { return nil }
        return CostLayout(rawValue: UserDefaults.standard.integer(forKey: "TallyCostLayout"))
    }

    /// Layouts 1 and 3 are a page of their own; layout 2 lives inside the Tokens page.
    var hasOwnTab: Bool { self != .tokensSwitch }
}

/// The Cost page: whichever own-page layout is on, under the Tokens tab's range switch.
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
            } else if CostLayout.current == .cards {
                CostCardsView(cost: store.cost, range: store.range)
            } else {
                CostHeadline(cost: store.cost, range: store.range)
                CostTableView(cost: store.cost, range: store.range)
            }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
    }
}

/// Total cost, the subagent part of it, and what it leaves out.
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
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
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

/// Layout 1: one row per project, ranked by cost, with the figures to compare them by.
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
