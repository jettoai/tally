import SwiftUI

/// The account region's own headings: the "Account Pool" title over the whole region, and one
/// heading per provider that carries that provider's whole summary - identity and fleet size, the
/// fold chevron, the advisor's tag, the launch chip, then the pooled bars with their pace and next
/// refill. Every one of those used to sit in a strip above the cards, which named each provider a
/// second time and took about a third of the panel before the first card (B-1524).
extension PopoverRootView {
    /// The region's title, in the same type and padding the private build gives its own region
    /// title, so the two regions read as siblings. Above the scroll view rather than inside it, so it
    /// is on screen without scrolling however long the fleet is. Its empty run moves the pinned
    /// panel, the job the launch strip's empty run used to do.
    @ViewBuilder
    var accountPoolTitle: some View {
        if store.contentState == .hasAccounts {
            HStack(spacing: 0) {
                Text(L("Account Pool")).fontWeight(.semibold)
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .windowDragSurface()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whether this provider's section gets a heading at all. Several sections always do (it names
    /// them apart); a lone provider does only when the heading has something to carry - a pool, an
    /// advice tag, a launch chip - since a bare name over the only section is noise.
    func showsSectionHeading(_ providerID: String, headed: Bool) -> Bool {
        headed || pooledProviderIDs.contains(providerID) || hasLaunchChip(providerID)
            || (settings.showAdvisor && store.advisorReadings.contains { $0.provider == providerID })
    }

    /// One provider's heading and pools. The fold chevron appears only while the provider's pools
    /// are on screen to summarize the cards it would hide; a folded section is this block alone,
    /// and a click on its name, its empty run or its bars brings the cards back. Both regions that
    /// fold read and write one set (`PanelSections`), so they cannot drift.
    func providerSection(_ providerID: String, count: Int) -> some View {
        let foldable = pooledProviderIDs.contains(providerID)
        let toggle = { if foldable { settings.toggleCollapsed(providerID) } }
        let summaries = fleetSummaries.filter { $0.providerID == providerID && !displayedPools($0).isEmpty }
        // A design capture forces ONE callout (they all publish into a single preference slot), so
        // it forces the first pooled provider's - see `tallyTooltip(blocks:forced:)`.
        let forcedID = TallyTooltip.previewForced(.fleet)
            ? fleetSummaries.first { !displayedPools($0).isEmpty }?.id : nil
        // Every bar sits on a row of its own under the heading, in the label column's grid, and the
        // heading line itself carries no bar. So each bar starts and ends on the same two vertical
        // lines in every provider, whether or not the advice tag or the launch chip is showing and
        // whatever the language (B-1524 round 3: a bar sharing the heading line with them changed
        // length whenever they did).
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                // Name and chevron, then the empty run, are the fold targets (and on the pinned
                // panel, grab areas). The tag and the launch chip stay outside them: a drag layer
                // over either would swallow its hover and its click.
                ZStack(alignment: .leading) {
                    // A hidden one-glyph twin of the advice tag holds the line at the tag's height,
                    // so the rows below do not move up when the tag goes away. A CJK glyph (escaped,
                    // the source stays English) because CJK is the tallest line the tag can carry.
                    Text(verbatim: "\u{5EFA}").font(.caption2.weight(.medium)).padding(.vertical, 1).hidden()
                    HStack(spacing: 5) {
                        // No tag on this heading: the advisor's hover answers on the name instead
                        // (B-1570). Beside the chevron, not around it, so the two hovers never nest.
                        providerLabel(providerID, count: count)
                            .font(.footnote)
                            .tallyTooltip(lazyBlocks: { advisorHeadingTooltip(providerID) })
                        if foldable { foldChevron(providerID) }
                    }
                }
                .frame(width: Self.fleetLabelWidth, alignment: .leading)
                .contentShape(Rectangle())
                .windowDragOrTap(toggle)
                .onTapGesture(perform: toggle)
                advisorTag(providerID)
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .windowDragOrTap(toggle)
                    .onTapGesture(perform: toggle)
                launchChip(providerID)
            }
            .fixedSize(horizontal: false, vertical: true)
            if !summaries.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(summaries, id: \.id) { summary in
                        fleetGauge(summary, forcedTooltip: summary.id == forcedID)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
            }
        }
    }
}
