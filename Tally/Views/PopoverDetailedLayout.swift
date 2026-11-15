import SwiftUI

/// The account region of the Detailed panel (`PanelDensity.list`): one card per provider, its head
/// (`providerCardHeader`) over a column-title line and one row per account, all inside the one
/// card surface with one hairline over the column titles. The rows are the same `AccountListRowView` the list always
/// used, so every control, mark and tooltip on a row is still there; what changed is the grid they
/// stand on: an identity column that takes what is left and a fixed block of meter cells, the
/// same on the title line and on every row, so a window keeps one x down the whole card.
extension PopoverRootView {
    /// The padding around the card region: the Detailed body's own, or the cards' 12pt.
    var contentInsets: EdgeInsets {
        guard settings.panelDensity == .list else { return EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12) }
        return EdgeInsets(top: PanelStyle.bodyPadTop, leading: PanelStyle.bodyPadH,
                          bottom: PanelStyle.bodyPadBottom, trailing: PanelStyle.bodyPadH)
    }

    /// A definite width, for the reason the card grid's is (see `cardWidth`): the surface's width
    /// less the body's own padding.
    var detailedCardWidth: CGFloat { scrollContentWidth - 2 * PanelStyle.bodyPadH }

    /// The provider cards, grouped, or one card of every account when grouping is off. A provider
    /// folded away keeps its head, which is the summary of what is folded and the way back.
    @ViewBuilder
    var detailedAccountLayout: some View {
        let groups = accountGroups
        // One meter cell for the whole panel, sized by the widest card's block, so the weekly column
        // (always the last) stands at one x on every card whatever else a card reports.
        let shownCards = settings.groupByProvider ? groups.filter { !$0.isFolded }.map(\.items) : [visibleAccounts]
        let widest = shownCards.map { displayColumns($0.map { AccountFacts(usage: $0, settings: settings) }).count }.max() ?? 0
        let cell = PanelStyle.meterCellWidth(columns: widest, rowWidth: detailedCardWidth - 2 * PanelStyle.cardPadH)
        VStack(alignment: .leading, spacing: PanelStyle.cardGap) {
            if settings.groupByProvider {
                ForEach(groups) { group in
                    providerCard(group.providerID, accounts: group.items, folded: group.isFolded, cell: cell)
                }
            } else {
                ForEach(groups.filter(\.isFolded)) { group in
                    providerCard(group.providerID, accounts: [], folded: true, cell: cell)
                }
                if !visibleAccounts.isEmpty { providerCard(nil, accounts: visibleAccounts, folded: false, cell: cell) }
            }
            let advice = advisorCardLines()
            if !advice.isEmpty { AdvisorCard(lines: advice).frame(width: detailedCardWidth, alignment: .leading) }
        }
    }

    private func providerCard(_ providerID: String?, accounts: [AccountUsage], folded: Bool, cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let providerID { providerCardHeader(providerID, count: accounts.count) }
            if !folded, !accounts.isEmpty { accountRows(accounts, cell: cell) }
        }
        .frame(width: detailedCardWidth, alignment: .leading)
        .panelCard()
    }

    /// One set of meter columns per card, so every row's figures line up with the titles above them;
    /// each window kind keeps its own column (a row without a 5-hour window leaves it empty).
    private func displayColumns(_ rowFacts: [AccountFacts]) -> [MeterColumnKey] {
        MeterColumns.displayBlock(rowFacts.filter { !$0.isHardError }.map(\.meterKeys))
    }

    private func accountRows(_ accounts: [AccountUsage], cell: CGFloat) -> some View {
        let rowFacts = accounts.map { AccountFacts(usage: $0, settings: settings) }
        let meterColumns = displayColumns(rowFacts)
        let titles = columnTitles(rowFacts)
        // Once per provider rather than once per row: each pick walks every account (TALLY-7Z).
        let autoPicks = Set(Set(accounts.map(\.providerID)).compactMap { AccountFacts.autoPickID(providerID: $0) })
        let soonest = soonestResets(rowFacts)
        let flat = !settings.groupByProvider
        return VStack(spacing: 0) {
            columnHead(meterColumns, titles: titles, cell: cell)
            ForEach(accounts) { usage in
                listRow(usage, meterColumns: meterColumns, cell: cell, isAutoPick: autoPicks.contains(usage.id),
                        soonestResets: soonest[usage.id] ?? [], showsProviderIcon: flat)
            }
        }
        .padding(.horizontal, PanelStyle.cardPadH)
        .padding(.bottom, 6)
    }

    /// What each meter column is called: the label of the first window of that kind any row reports.
    private func columnTitles(_ rowFacts: [AccountFacts]) -> [MeterColumnKey: String] {
        var titles: [MeterColumnKey: String] = [:]
        for facts in rowFacts where !facts.isHardError {
            for (key, metric) in zip(facts.meterKeys, facts.orderedMetrics) where titles[key] == nil {
                titles[key] = L(metric.label)
            }
        }
        return titles
    }

    private func columnHead(_ keys: [MeterColumnKey], titles: [MeterColumnKey: String], cell: CGFloat) -> some View {
        VStack(spacing: 0) {
            PanelHairline()
            HStack(spacing: PanelStyle.meterGap) {
                Text(L("Account")).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: PanelStyle.meterGap) {
                    ForEach(keys, id: \.self) { key in
                        Text(titles[key] ?? "").frame(width: cell, alignment: .leading)
                    }
                }
            }
            .font(PanelStyle.font(9, 650))
            .tracking(0.7)
            .textCase(.uppercase)
            .foregroundStyle(PanelStyle.text2)
            .lineLimit(1)
            .padding(.horizontal, PanelStyle.rowInsetH)
            .padding(.top, 4)
            .frame(height: PanelStyle.colHeadHeight - PanelStyle.hairline, alignment: .center)
        }
    }

    /// Per account id, the meter columns whose reset is the soonest of its provider's rows. Grouped
    /// by provider so a flat layout (one block, several providers) and a grouped one agree, and rows
    /// that draw no meters (hard error, renewing login) neither compete nor light.
    private func soonestResets(_ rowFacts: [AccountFacts]) -> [String: Set<MeterColumnKey>] {
        var result: [String: Set<MeterColumnKey>] = [:]
        let drawing = rowFacts.filter { !$0.isHardError && !$0.isRenewingLogin }
        for group in Dictionary(grouping: drawing, by: \.usage.providerID).values {
            let states = group.map { f in
                Dictionary(uniqueKeysWithValues: zip(
                    f.meterKeys,
                    f.orderedMetrics.map { UsageFormat.resetState($0, resetPassed: f.usage.resetPassed($0)) }))
            }
            for (f, lit) in zip(group, UsageFormat.soonestResets(states)) where !lit.isEmpty {
                result[f.usage.id] = lit
            }
        }
        return result
    }

    private func listRow(_ usage: AccountUsage, meterColumns: [MeterColumnKey], cell: CGFloat, isAutoPick: Bool,
                         soonestResets: Set<MeterColumnKey>, showsProviderIcon: Bool) -> some View {
        AccountListRowView(usage: usage, settings: settings, showsDragHandle: true,
                           meterColumns: meterColumns, meterCellWidth: cell, isAutoPick: isAutoPick,
                           soonestResets: soonestResets, showsProviderIcon: showsProviderIcon)
            .opacity(cardLift?.id == usage.id ? 0 : 1)
            .contentShape(Rectangle())
            // Same frame registration the cards use, so the one drag gesture reorders both
            // densities (see `reorderGesture`).
            .cardFrame(id: usage.id, in: Self.reorderSpace)
    }
}
