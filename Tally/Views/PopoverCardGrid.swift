import SwiftUI

/// The account cards' layout and their drag-to-reorder, split out of PopoverRootView for file size:
/// the grouped and flat arrangements, the grid that both share, the card itself, and the one drag
/// gesture the whole grid is reordered by. The state these read (`cardFrames`, `cardLift`,
/// `isReorderDragActive`) has to stay on the view struct, because stored properties cannot live in
/// an extension; everything that only READS it lives here.

extension PopoverRootView {

    /// Definite card width. `.frame(maxWidth: .infinity)` cards would fight the hosting controller's
    /// `.preferredContentSize` sizing (content wants to shrink to fit, cards want infinite width) and
    /// recurse the layout engine to a stack overflow - so derive an exact width from the fixed popover
    /// width (12pt content padding each side, 10pt gap between columns). The cards scroll, so it is
    /// the scrolling region's width they divide up, not the surface's.
    private var cardWidth: CGFloat {
        PanelGeometry.cardWidth(inGridOf: scrollContentWidth, columns: columnCount)
    }

    /// Accounts in rows of two when multi-account, one column otherwise. A hand-built grid (not
    /// LazyVGrid) so the whole thing lays out in one pass - lazy loading only helps long scrolls and
    /// here fought the one-pass sizing.
    ///
    /// Rows are Identifiable BY CONTENT, never `ForEach(indices)`: with @Observable's fine-grained
    /// updates, a row closure can re-evaluate against a freshly shrunk accounts array while still
    /// holding an old index (crash 2026-07-17: toggling a provider off in Settings while the pinned
    /// panel was showing → index out of range).
    @ViewBuilder
    var accountLayout: some View {
        switch UsageLayout.active {
        case .ledger?: ledgerAccounts
        case .tray?: trayAccounts
        case nil: defaultAccountLayout
        }
    }

    /// The shipped layout, unchanged: what `accountLayout` draws when no preview layout is asked for.
    @ViewBuilder
    private var defaultAccountLayout: some View {
        if settings.panelDensity == .list {
            detailedAccountLayout
        } else {
            cardLayout
        }
    }

    @ViewBuilder
    private var cardLayout: some View {
        let groups = accountGroups
        if settings.groupByProvider {
            let headed = PanelSections.showsHeadings(sectionCount: groups.count)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        // A folded section keeps its heading exactly where it was and drops only its
                        // cards: the heading carries the provider's pools, so it IS the summary of
                        // what is folded and the way back - gauges-only included.
                        if showsSectionHeading(group.providerID, headed: headed) {
                            providerSection(group.providerID, count: group.items.count)
                        }
                        if !group.isFolded { cardGrid(group.items) }
                    }
                }
            }
        } else {
            // Flat: each provider's heading (where it has pools, advice or a launch chip to carry),
            // then one run of cards in the user's own order.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in
                    if showsSectionHeading(group.providerID, headed: false) {
                        providerSection(group.providerID, count: group.items.count)
                    }
                }
                if !visibleAccounts.isEmpty { cardGrid(visibleAccounts) }
            }
        }
    }

    /// Whether the card region is drawn at all. Not simply "are there visible cards": a pooled
    /// provider's heading carries its pools, and it stays when its cards are folded away. Folding
    /// needs a pool, so a region with nothing visible but a pooled provider still has a heading to
    /// draw; with neither it is skipped entirely - its 12pt padding read as a hollow band.
    var showsAccountRegion: Bool {
        !visibleAccounts.isEmpty || !pooledProviderIDs.isEmpty
    }

    /// The list surface's width: the scrolling region less the container's own 12pt padding each
    /// side. The preview layouts divide that up.
    var listWidth: CGFloat { scrollContentWidth - 2 * PanelGeometry.contentPadding }

    /// The cards themselves, in the current column count. Called once for a flat layout and once per
    /// provider when grouped, so both layouts share one grid and can't drift in spacing or widths.
    @ViewBuilder
    private func cardGrid(_ accounts: [AccountUsage]) -> some View {
        let columns = columnCount
        if columns > 1 {
            VStack(spacing: 10) {
                ForEach(rows(accounts, columns: columns)) { row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row.items) { usage in
                            card(usage, fillsRowHeight: true).frame(width: cardWidth, alignment: .top)
                        }
                        // Keep a short trailing row at full-grid card widths so columns stay aligned.
                        ForEach(0 ..< columns - row.items.count, id: \.self) { _ in
                            Color.clear.frame(width: cardWidth)
                        }
                    }
                    // One layout pass: the row's height = its tallest card's ideal height, and the
                    // shorter card stretches to match (equal-height row, no ragged bottoms).
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(accounts) { usage in
                    card(usage).frame(width: cardWidth)
                }
            }
        }
    }

    struct AccountRow: Identifiable {
        let items: [AccountUsage]
        var id: String { items.map(\.id).joined(separator: "|") }
    }

    /// One provider's cards, kept together when grouping is on, plus whether they are folded away
    /// behind the provider's gauge (`PanelSections`, which both fold entry points read).
    typealias AccountGroup = PanelSections.Section<AccountUsage>

    /// An account card that can be dragged to reorder (in-view drag: the source card
    /// hides, a floating copy tracks the pointer, and neighbors spring out of the way live). The order
    /// is persisted and applied everywhere (popover, dashboard, menu bar). Reordering never changes the
    /// content's size, so the live mutation can't feed the old sizing-loop crash (hosts size via the
    /// deferred `onContentSize` path regardless).
    private func card(_ usage: AccountUsage, fillsRowHeight: Bool = false) -> some View {
        AccountCardView(usage: usage, settings: settings,
                        showsDragHandle: true, fillsRowHeight: fillsRowHeight)
            .opacity(cardLift?.id == usage.id ? 0 : 1)
            .contentShape(Rectangle())
            .cardFrame(id: usage.id, in: Self.reorderSpace)
    }

    /// One drag gesture for the whole grid (see the attachment comment in `content`). The grabbed
    /// card is locked in from the drag's START location exactly once; later frames must not re-hit-test
    /// it, or a mid-drag layout shift could silently swap which card is being dragged.
    var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.reorderSpace))
            .updating($isReorderDragActive) { _, state, _ in state = true }
            .onChanged { value in
                if cardLift == nil {
                    guard let grip = ReorderLift(grabbing: value.startLocation, at: value.location,
                                                 frames: cardFrames),
                          let usage = store.orderedAccounts.first(where: { $0.id == grip.id })
                    else { return }
                    cardLift = CardLift(grip: grip, usage: usage)
                }
                guard var lift = cardLift else { return }   // grab began on the gap between cards
                lift.location = value.location
                cardLift = lift
                // The dragged account can vanish mid-drag (a provider refresh removed it): end the session.
                guard store.orderedAccounts.contains(where: { $0.id == lift.id }) else {
                    cardLift = nil
                    return
                }
                // Hit-test with the lifted card's centre (previewCentre - exactly where the preview
                // renders), not the pointer: a card grabbed by its corner - the natural grip is the
                // drag handle - keeps the pointer in every target's edge dead zone for the whole drag,
                // so the order never changes even when the preview visually covers the target.
                guard let target = reorderTarget(at: lift.previewCentre, frames: cardFrames,
                                                 excluding: lift.id,
                                                 orderedIDs: store.orderedAccounts.map(\.id))
                else { return }
                // Grouped layout reorders WITHIN the provider's own slots: the sections are ordered
                // by each provider's first appearance in the global order, so a plain global move
                // could swap two whole sections and rewrite the flat order behind the user's back
                // (see `moveAccountWithinProvider`). It also returns false for a card dropped on
                // another provider's card, which is the no-op the sections imply.
                let allIDs = store.accounts.map(\.id)
                var moved = false
                withAnimation(CardMotion.spring) {
                    moved = settings.groupByProvider
                        ? settings.moveAccountWithinProvider(
                            lift.id, onto: target,
                            siblingIDs: store.accounts
                                .filter { $0.providerID == lift.usage.providerID }.map(\.id),
                            allIDs: allIDs)
                        : settings.moveAccount(lift.id, onto: target, allIDs: allIDs)
                }
                if moved { Haptics.snap() }
            }
            .onEnded { _ in cardLift = nil }
    }

    /// Accounts chunked into rows of `columns` items - one implementation for both densities, so
    /// the card grid and the list can never disagree about reading order.
    func rows(_ accounts: [AccountUsage], columns: Int) -> [AccountRow] {
        stride(from: 0, to: accounts.count, by: columns).map { start in
            AccountRow(items: Array(accounts[start ..< min(start + columns, accounts.count)]))
        }
    }

    /// EVERY provider's cards bucketed, folded sections included - a folded one is drawn as its
    /// heading alone, so it has to still be in the list. Provider order follows first appearance in
    /// the user's own card order, and each bucket keeps that order inside it, so grouping re-seats
    /// the cards without inventing a second ordering the user never chose.
    var accountGroups: [AccountGroup] {
        PanelSections.sections(store.orderedAccounts, providerID: \.providerID,
                               pooled: pooledProviderIDs, collapsed: settings.collapsedProviders)
    }

    /// What a card move animates against: the persisted order, the grouping switch (flipping it moves
    /// every card while the order underneath stays byte-identical), and the column count, which
    /// re-seats every card without touching either. The resolved count, not the raw setting: Auto is
    /// the mode whose number moves on its own, and it is the number the cards are laid out by.
    var cardSeatingSignature: String {
        "density:\(settings.panelDensity.rawValue)|cols:\(columnCount)/\(listColumnCount)|"
            + (settings.groupByProvider ? "grouped:" : "flat:")
            + store.orderedAccounts.map(\.id).joined(separator: "|")
    }
}
