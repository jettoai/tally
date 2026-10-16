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
            // One line of controls, the session board's arrangement (SessionBoardView): which view
            // of the scan on the left, which range on the right. The range lives here rather than
            // on each page because both pages read the one `store.range`, so a switch drawn twice
            // would only be the same control fading out and back in. Both the quieter size: the
            // header's switch chooses what the window is about. Never `dragsWindow`: the header's
            // is the only switch that doubles as a grab area (dragortap suite).
            HStack(spacing: 6) {
                NeutralSegmentedPicker(selection: $page, options: CostSubpage.allCases,
                                       size: .small) { $0.label }
                Spacer(minLength: 0)
                NeutralSegmentedPicker(selection: $store.range, options: TokenStatsRange.allCases,
                                       size: .small) { $0.label }
            }
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

/// The Cost page: the total and what it is made of, then one row per project, for the range chosen
/// on the Cost tab's control line (`CostTabPage`). It reads the same priced cells
/// `~/.tally/project-cost.json` is written from (TokenStatsStore), so the page and `tally cost`
/// agree on a scan.
struct CostPage: View {
    @Bindable var store: TokenStatsStore
    var width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: TallyMetrics.sectionSpacing) {
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

    /// One project's figures as drawn. Built once so the column widths are measured on exactly the
    /// strings the rows then show.
    private struct Cells {
        var cost: String, share: String, tokens: String, rate: String
        /// nil: no figure (All, Other). `up` nil: the previous window is incomplete, a placeholder.
        var change: (text: String, up: Bool?)?
    }

    private struct Columns { var money, share, tokens, rate, change: CGFloat }

    private static let gap: CGFloat = 8

    var body: some View {
        let cells = cost.projects.map(cells(for:))
        let columns = columns(for: cells)
        VStack(alignment: .leading, spacing: 7) {
            row(name: Text(L("Project")), cost: Text(L("Cost")), share: Text(L("Share")),
                tokens: Text(L("Tokens")), rate: Text(L("$/M tok")),
                change: Text(headerChange), columns: columns)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .tallyTooltip(L("$/M tok is the blended price per million tokens: high where a project runs on dearer models"))
            Divider()
            ForEach(Array(zip(cost.projects, cells)), id: \.0.id) { p, c in
                row(name: Text(p.name).foregroundStyle(p.isOther ? Color.secondary.opacity(0.7) : .primary),
                    cost: Text(c.cost).fontWeight(.semibold),
                    share: Text(c.share).foregroundStyle(.secondary),
                    tokens: Text(c.tokens).foregroundStyle(.secondary),
                    rate: Text(c.rate).foregroundStyle(.secondary),
                    change: changeView(c.change), columns: columns)
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

    private var headerChange: String { range == .all ? "" : L("vs prev") }

    private func cells(for p: CostSummary.ProjectRow) -> Cells {
        Cells(cost: CostFormat.dollars(p.cost), share: UsageFormat.sharePercent(p.share),
              tokens: UsageFormat.compactCount(p.tokens.total),
              rate: p.tokens.total > 0 ? CostFormat.dollars(p.cost / Double(p.tokens.total) * 1e6) : "—",
              change: changeFigure(p))
    }

    private func changeFigure(_ p: CostSummary.ProjectRow) -> (text: String, up: Bool?)? {
        guard range != .all, p.previousCost != nil else { return nil }
        // The previous window reaches back past what Claude Code still keeps: a percentage against
        // its remnant (B-2039: "+65482%") says nothing about the project.
        guard cost.previousWindowCovered else { return ("—", nil) }
        guard let label = CostFormat.change(p.cost, previous: p.previousCost) else { return nil }
        let up = (p.previousCost ?? 0) < p.cost
        return ((up ? "▲ " : "▼ ") + label.trimmingCharacters(in: CharacterSet(charactersIn: "+-")), up)
    }

    @ViewBuilder
    private func changeView(_ change: (text: String, up: Bool?)?) -> some View {
        if let change, let up = change.up {
            Text(change.text).foregroundStyle(up ? TallyColor.warning : TallyColor.normal)
        } else if let change {
            Text(change.text).foregroundStyle(.tertiary)
                .tallyTooltip(L("Previous period data is incomplete (Claude Code only keeps the last 30 days of transcripts)"))
        } else {
            Text("")
        }
    }

    /// Each column is as wide as the widest string it will carry, header included, measured the way
    /// `FleetStripView.poolLabelColumnWidth` does: a translated header or a longer figure widens the
    /// column instead of wrapping onto a second line. The name column takes what is left.
    private func columns(for cells: [Cells]) -> Columns {
        let body = NSFont.preferredFont(forTextStyle: .footnote)
        let mono = NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .semibold)
        let head = NSFont.preferredFont(forTextStyle: .caption2)
        func width(_ font: NSFont, _ strings: [String]) -> CGFloat {
            ceil(strings.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
        }
        func column(_ header: String, _ font: NSFont, _ values: [String]) -> CGFloat {
            max(width(head, [header]), width(font, values)) + 1
        }
        return Columns(
            money: column(L("Cost"), bold, cells.map(\.cost)),
            share: column(L("Share"), mono, cells.map(\.share)),
            tokens: column(L("Tokens"), mono, cells.map(\.tokens)),
            rate: column(L("$/M tok"), mono, cells.map(\.rate)),
            change: column(headerChange, mono, cells.compactMap(\.change?.text)))
    }

    private func row<Change: View>(name: Text, cost: Text, share: Text, tokens: Text, rate: Text,
                                   change: Change, columns: Columns) -> some View {
        HStack(spacing: Self.gap) {
            name.lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            cost.lineLimit(1).frame(width: columns.money, alignment: .trailing)
            share.lineLimit(1).frame(width: columns.share, alignment: .trailing)
            tokens.lineLimit(1).frame(width: columns.tokens, alignment: .trailing)
            rate.lineLimit(1).frame(width: columns.rate, alignment: .trailing)
            change.lineLimit(1).frame(width: columns.change, alignment: .trailing)
        }
    }
}
