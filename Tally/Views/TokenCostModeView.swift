import SwiftUI

/// Layout 2's unit switch on the Tokens page.
enum TokenStatsUnit: Hashable, CaseIterable {
    case tokens, cost
    var label: String { self == .tokens ? L("Tokens") : L("Cost") }
}

/// Layout 2: the Tokens page in dollars. The same three cards, with the four classes priced (which
/// shows at a glance whether cache reads are where the money goes) and every bar and share by cost.
struct TokenCostModeView: View {
    var cost: CostSummary

    private static let valueColumn: CGFloat = 62
    private static let shareColumn: CGFloat = 34
    private static let nameColumn: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: TallyMetrics.sectionSpacing) {
            headline
            if !cost.providers.isEmpty { providers }
            if !cost.projects.isEmpty { projects }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Total cost")).font(.caption).foregroundStyle(.secondary)
                Text(CostFormat.dollars(cost.total))
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                CostCaveats(cost: cost)
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                column(L("Input"), cost.parts.input)
                column(L("Cache write"), cost.parts.cacheWrite)
                column(L("Cache read"), cost.parts.cacheRead)
                column(L("Output"), cost.parts.output)
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
    }

    private func column(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(CostFormat.dollars(value)).font(.callout.weight(.medium)).monospacedDigit()
                Text(UsageFormat.sharePercent(value / max(cost.total, 0.000_001)))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providers: some View {
        VStack(spacing: 7) {
            ForEach(cost.providers) { row in
                HStack(spacing: 6) {
                    ProviderIconView(providerID: row.providerID, size: 12)
                    Text(ProviderCatalog.displayName(for: row.providerID))
                        .font(.footnote).foregroundStyle(Color.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    if let c = row.cost {
                        trailing(share: c / max(cost.total, 0.000_001), value: CostFormat.dollars(c))
                    } else {
                        Text(L("Not priced")).font(.caption2).foregroundStyle(.tertiary)
                        trailing(share: nil, value: "—")
                    }
                }
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: TallyMetrics.headerToCard) {
            Text(L("Projects")).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 7) {
                ForEach(cost.projects) { p in
                    HStack(spacing: 8) {
                        Text(p.name)
                            .font(.footnote)
                            .foregroundStyle(p.isOther ? Color.secondary.opacity(0.7) : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: Self.nameColumn, alignment: .leading)
                            .tallyTooltip(p.isOther ? L("Scratch directories and sessions with no project") : p.key)
                        bar(p.share)
                        trailing(share: p.share, value: CostFormat.dollars(p.cost))
                    }
                }
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
    }

    private func trailing(share: Double?, value: String) -> some View {
        HStack(spacing: 8) {
            Text(share.map(UsageFormat.sharePercent) ?? "")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: Self.shareColumn, alignment: .trailing)
            Text(value)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .frame(width: Self.valueColumn, alignment: .trailing)
        }
    }

    private func bar(_ share: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(2, proxy.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: 5)
    }
}
