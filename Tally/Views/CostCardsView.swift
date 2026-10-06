import SwiftUI

/// Layout 3: a card per project with its cost split by model, by main loop against subagents, and
/// over the range. The top twelve get a card; the rest pool into Other.
struct CostCardsView: View {
    var cost: CostSummary
    var range: TokenStatsRange

    private static let cardLimit = 12
    private static let palette: [Color] = [.accentColor, TallyColor.ai, .orange, .teal, .pink]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CostHeadline(cost: cost, range: range)
            legend
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(cards) { card($0) }
            }
        }
    }

    /// Models by cost across the whole range: the legend's order and each model's colour.
    private var models: [String] {
        var totals: [String: Double] = [:]
        for p in cost.projects { for m in p.byModel { totals[m.model, default: 0] += m.cost } }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    private func color(_ model: String) -> Color {
        guard let i = models.firstIndex(of: model), i < Self.palette.count - 1 else { return .gray }
        return Self.palette[i]
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(models.prefix(Self.palette.count - 1), id: \.self) { m in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color(m)).frame(width: 8, height: 8)
                    Text(CostFormat.modelName(m))
                }
            }
            if models.count >= Self.palette.count {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray).frame(width: 8, height: 8)
                    Text(L("Other models"))
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// The first twelve named projects, then one Other card for the rest and the unattributed.
    private var cards: [CostSummary.ProjectRow] {
        let named = cost.projects.filter { !$0.isOther }
        let rest = named.dropFirst(Self.cardLimit) + cost.projects.filter(\.isOther)
        guard var other = rest.first else { return Array(named.prefix(Self.cardLimit)) }
        other.key = TokenProject.otherKey
        other.name = TokenProject.displayName(forKey: TokenProject.otherKey)
        other.previousCost = nil
        for p in rest.dropFirst() {
            other.cost += p.cost
            other.share += p.share
            other.mainCost += p.mainCost
            other.subagentCost += p.subagentCost
            other.byModel += p.byModel
            other.series = zip(other.series, p.series).map(+)
        }
        return Array(named.prefix(Self.cardLimit)) + [other]
    }

    private func card(_ p: CostSummary.ProjectRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.name).font(.footnote.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(p.isOther ? Color.secondary : .primary)
                Spacer(minLength: 4)
                Text(UsageFormat.sharePercent(p.share)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(CostFormat.dollars(p.cost)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            modelBar(p)
            HStack(alignment: .bottom) {
                Text(String(format: L("Main %1$@ · Subagents %2$@"),
                            CostFormat.dollars(p.mainCost), CostFormat.dollars(p.subagentCost)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                sparkBars(p.series)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
        .tallyTooltip(p.isOther ? L("Scratch directories and sessions with no project") : p.key)
    }

    private func modelBar(_ p: CostSummary.ProjectRow) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(Array(p.byModel.enumerated()), id: \.offset) { _, m in
                    Rectangle().fill(color(m.model))
                        .frame(width: max(1, proxy.size.width * m.cost / max(p.cost, 0.000_001)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }

    private func sparkBars(_ series: [Double]) -> some View {
        let peak = max(series.max() ?? 0, 0.000_001)
        let bars = series.suffix(14)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 4, height: max(1, 18 * v / peak))
            }
        }
        .frame(height: 18, alignment: .bottom)
    }
}
