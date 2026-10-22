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
                        if !group.isFolded { accountBlock(group.items) }
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
                if !visibleAccounts.isEmpty { accountBlock(visibleAccounts) }
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

    /// One run of accounts, at whichever density the panel is set to. Both layouts hang off this one
    /// place so the grouping switch, the empty cases and the reorder wiring stay written once.
    @ViewBuilder
    private func accountBlock(_ accounts: [AccountUsage]) -> some View {
        if settings.panelDensity == .list {
            rowStack(accounts)
        } else {
            cardGrid(accounts)
        }
    }

    /// The compact density: one row per account, all of them inside ONE card surface with hairlines
    /// between. A card each would put fourteen points of padding and a border around a 26pt row and
    /// hand back most of the height the density exists to save; a list is one object with rules in
    /// it, which is also how every system list draws.
    ///
    /// Several columns share that one surface rather than taking one each, so the section still
    /// reads as a single object: the columns are runs INSIDE it, split by the same 10pt gutter the
    /// card grid uses and ruled only within themselves.
    private func rowStack(_ accounts: [AccountUsage]) -> some View {
        let columns = listColumnCount
        let width = listColumnWidth
        // One identity column and one set of meter columns per block, so every row's figures and
        // track lengths line up down the block. A grouped layout calls this once per provider,
        // which is what lets a one-window provider lay one long bar per row.
        let identityWidth = accounts.compactMap { listIdentityWidths[$0.id] }.max()
        let meterSlots = accounts
            .map { AccountFacts(usage: $0, settings: settings) }
            .filter { !$0.isHardError }
            .map(\.orderedMetrics.count)
            .max() ?? 0
        // Once per provider rather than once per row: each pick walks every account (TALLY-7Z).
        let autoPicks = Set(Set(accounts.map(\.providerID)).compactMap { AccountFacts.autoPickID(providerID: $0) })
        // Row-major, the same chunking the card grid uses, so the reading order is the one the eye
        // already learned here: across, then down.
        return VStack(spacing: 0) {
            ForEach(Array(rows(accounts, columns: columns).enumerated()), id: \.element.id) { band, row in
                HStack(alignment: .top, spacing: AccountListRowView.columnGap) {
                    ForEach(row.items) { usage in
                        VStack(spacing: 0) {
                            // A rule between two rows OF ONE COLUMN, never drawn across the gutter:
                            // the columns are separate runs of accounts, and one line through both
                            // would read as a single row cut in half.
                            if band > 0 { Divider() }
                            listRow(usage, identityWidth: identityWidth, meterSlots: meterSlots,
                                    isAutoPick: autoPicks.contains(usage.id))
                        }
                        .frame(width: width)
                    }
                    // Keep a short trailing band at full column widths so the columns stay aligned.
                    ForEach(0 ..< columns - row.items.count, id: \.self) { _ in
                        Color.clear.frame(width: width, height: 0)
                    }
                }
            }
        }
        .frame(width: listWidth)
        .tallyCard()
    }

    private func listRow(_ usage: AccountUsage, identityWidth: CGFloat?,
                         meterSlots: Int, isAutoPick: Bool) -> some View {
        AccountListRowView(usage: usage, settings: settings, showsDragHandle: true,
                           identityWidth: identityWidth, meterSlots: meterSlots,
                           onIdentityWidth: { width in
                               if listIdentityWidths[usage.id] != width {
                                   listIdentityWidths[usage.id] = width
                               }
                           }, isAutoPick: isAutoPick)
            .opacity(cardLift?.id == usage.id ? 0 : 1)
            .contentShape(Rectangle())
            // Same frame registration the cards use, so the one drag gesture reorders both
            // densities (see `reorderGesture`).
            .cardFrame(id: usage.id, in: Self.reorderSpace)
    }

    /// The list surface's width: the scrolling region less the container's own 12pt padding each
    /// side. Its columns then divide that up, exactly as the cards' do.
    var listWidth: CGFloat { scrollContentWidth - 2 * PanelGeometry.contentPadding }

    private var listColumnWidth: CGFloat {
        let columns = CGFloat(listColumnCount)
        return (listWidth - AccountListRowView.columnGap * (columns - 1)) / columns
    }

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
