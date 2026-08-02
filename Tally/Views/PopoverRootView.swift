import SwiftUI
import AppKit

/// The menu-bar popover: header, one card per account, footer with the used/left toggle + settings.
///
/// The popover sizes to its content in a single pass via the hosting controller's
/// `sizingOptions = .preferredContentSize` (set in `StatusItemController`). There is deliberately no
/// ScrollView + measured `.frame(height:)` here: that made the popover open at one size then resize to
/// fit, so AppKit's frame animation fought SwiftUI's layout - the classic "two clocks" stutter. Static content + one-pass sizing avoids the fight entirely.

/// What a surface is showing. Not a window concept: the popover, the pinned panel and the dashboard
/// window are all this same view, and all three can be flipped to the token history and back.
enum SurfaceTab: String, CaseIterable, Identifiable {
    case usage, tokens
    var id: String { rawValue }
    var label: String { self == .usage ? L("Usage") : L("Tokens") }
}

struct PopoverRootView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    /// Reports the content's ACTUAL rendered size so the host (popover / panel) can size itself to it.
    /// Measuring the real size beats asking `sizeThatFits`, which returned a greedy screen-tall height.
    var onContentSize: ((CGSize) -> Void)? = nil
    /// Whether the host window itself draws glass (the popover's vibrancy, the pinned panel's
    /// behind-window blur). The dashboard window is opaque, so it opts out and keeps solid cards -
    /// a within-window material there would only sample that window's own grey.
    var hostDrawsGlass: Bool = true
    var tokens: TokenStatsStore = .shared

    /// Per surface, deliberately: flipping the pinned panel to token history should not also flip
    /// the menu-bar popover, which is opened for one glance at the quota and closed again. Every
    /// host holds one of these, so no host needs to hand its own selection in.
    ///
    /// It also outlives a close, because each host's view is built once and reused: reopening shows
    /// what the user last chose rather than silently undoing it, and the header switch says which
    /// view this is. A reset on close would be the only way to disagree, and that would need this
    /// state hoisted back out of the surface it belongs to.
    @State private var ownTab: SurfaceTab = .usage

    /// Internal: the header extension binds its switch to it.
    var tabSelection: Binding<SurfaceTab> { $ownTab }
    var tab: SurfaceTab { ownTab }

    private static let reorderSpace = "tallyCardReorder"
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var cardLift: CardLift?
    /// True while the reorder drag is tracking. @GestureState resets automatically on BOTH end and
    /// cancellation - the only hook SwiftUI guarantees for a cancelled gesture (onEnded is skipped) -
    /// so cardLift cleanup keys off its reset instead of trusting onEnded alone.
    @GestureState private var isReorderDragActive = false
    /// A need, not a preference - the same rule the glass follows for Reduce Transparency. Every
    /// animated change on this surface reads it and goes instant.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The System Settings pane vocabulary: a short crossfade with just enough vertical drift to say
    /// the panel was replaced rather than repainted. Symmetric, and deliberately not a push - a slide
    /// would imply the two views sit side by side in some order, and they do not.
    private var tabTransition: AnyTransition {
        .opacity.combined(with: .offset(y: 8))
    }

    var body: some View {
        // Rebuild the whole tree on language change. A bare read of languageOverride only re-runs THIS
        // body - SwiftUI still diffs child View structs (AccountCardView, MetricRowView, EmptyStateView)
        // as unchanged and skips re-localizing them, leaving cards stuck in the old language. Keying
        // `.id` on the language forces a full teardown + rebuild so every L() re-resolves.
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                // Header and footer frame both tabs: the countdown and the refresh stay reachable
                // while reading token history, and the footer button that switched here is the one
                // that switches back (a surface that swallowed its own way out would be a trap).
                header
                Divider()
                // A ZStack of two independent conditions, not one if/else: mid-crossfade both views
                // exist, and stacked they occupy the taller of the two rather than the sum of them.
                // In a VStack the host would chase a height neither tab has - the surface would
                // balloon and collapse on every switch.
                ZStack(alignment: .top) {
                    if tab == .usage {
                        VStack(spacing: 0) {
                            launchSummaryStrip
                            fleetStrip
                            advisorStrip
                            // Fully folded (all cards behind their gauges) skips the card container
                            // entirely: its 12pt padding read as a hollow band between two dividers.
                            if store.contentState != .hasAccounts || !visibleAccounts.isEmpty {
                                content
                            }
                        }
                        .transition(tabTransition)
                    }
                    if tab == .tokens {
                        TokenStatsView(store: tokens, width: popoverWidth)
                            // Every visit brings the numbers up to date; the scan itself skips files
                            // whose identity has not changed, so a repeat visit costs a directory walk.
                            .onAppear { tokens.refresh() }
                            .transition(tabTransition)
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: tab)
                Divider()
                footer
            }
            .frame(width: popoverWidth)
            .background(sizeReporter)
            // The floating copy of the dragged card, above everything, tracking the pointer.
            if let cardLift {
                CardLiftPreview(lift: cardLift, settings: settings)
            }
        }
        .coordinateSpace(name: Self.reorderSpace)
        .onPreferenceChange(CardFramePreferenceKey.self) { cardFrames = $0 }
        .environment(\.tallyCardStyle, cardStyle)
        .id(settings.languageOverride ?? "system")
    }

    /// The card fill for this surface: glass only where the host has glass to sample AND the user
    /// asked for it. Reduce Transparency is a need, not a preference, so it clamps the cards to
    /// solid regardless of the setting - the same rule the pinned panel's backdrop follows.
    private var cardStyle: TallyCardStyle {
        guard hostDrawsGlass, settings.isPanelTranslucent,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return .solid }
        return .glassVariant
    }

    /// Measures the laid-out content size and reports it upward (fires on appear + on change).
    private var sizeReporter: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                onContentSize?(size)
            }
        }
    }

    /// How many card columns. An explicit 1/2/3/4 is a width the user chose and is never
    /// second-guessed: folding cards shrinks the panel's height only (want it narrow? that's
    /// what the view menu is for). Auto is the mode that delegates layout to the system, so
    /// there it follows what's actually visible: two columns once any provider shows more than
    /// one card, a single narrow column otherwise - including the fully folded gauges-only view.
    private var columnCount: Int {
        if (1 ... 4).contains(settings.panelColumns) { return settings.panelColumns }
        let multi = Dictionary(grouping: visibleAccounts, by: \.providerID).values
            .contains { $0.count > 1 }
        return multi ? 2 : 1
    }

    /// The two-column panel width, named because two other surfaces gate on reaching it (the fleet
    /// strip's and the advisor strip's side-by-side pairs). Adjusting the case-2 width below without
    /// this constant would silently strand those gates.
    static let twoColumnPanelWidth: CGFloat = 560

    /// Constant card width (263pt) across the 2/3/4-column layouts; only the window grows.
    /// Internal: the strip and footer extensions lay themselves out against it.
    var popoverWidth: CGFloat {
        switch columnCount {
        case 1: return 380
        case 2: return Self.twoColumnPanelWidth
        case 3: return 834    // 24 padding + 3×263 cards + 2×10 gaps
        default: return 1108  // 24 padding + 4×263 cards + 3×10 gaps
        }
    }

    /// Definite card width. `.frame(maxWidth: .infinity)` cards would fight the hosting controller's
    /// `.preferredContentSize` sizing (content wants to shrink to fit, cards want infinite width) and
    /// recurse the layout engine to a stack overflow - so derive an exact width from the fixed popover
    /// width (12pt content padding each side, 10pt gap between columns).
    private var cardWidth: CGFloat {
        let inner = popoverWidth - 24
        let columns = CGFloat(columnCount)
        return (inner - 10 * (columns - 1)) / columns
    }

    @ViewBuilder
    private var content: some View {
        // Volatile launch flag: force the empty state so its copy and the app's mark can be looked
        // at on a machine that has accounts. Reads the argument domain, so a normal launch never
        // sees it (same pattern as -TallyDemoData).
        if UserDefaults.standard.bool(forKey: "TallyEmptyStatePreview") {
            EmptyStateView(state: .noAccounts)
        } else if store.contentState != .hasAccounts {
            EmptyStateView(state: store.contentState)
        } else {
            accountLayout
                // One glass pass for the whole grid under the Liquid Glass variant; nothing at all
                // under the others (see `tallyCardGroup`).
                .tallyCardGroup(cardStyle)
                .padding(12)
                // Cards glide (not teleport) whenever the order changes - from a drag here or the
                // settings window - and equally when the grouping switch or the column count re-seats
                // every card without the order itself moving. Same spring as the drag, so a card
                // moving under its own steam and a card moved by hand travel the same way.
                .animation(reduceMotion ? nil : CardMotion.spring, value: cardSeatingSignature)
                // The reorder gesture lives HERE on the stable cards container, never on a card: a
                // live reorder changes AccountRow identities, and SwiftUI CANCELS (not ends) a
                // gesture whose view that diff tears down - onEnded never fires, and lift state
                // parked there leaked forever (stuck floating preview, 2026-07-17). The container
                // survives every reorder, so one drag keeps tracking across commits.
                .highPriorityGesture(reorderGesture)
                // Cancellation safety net: mirror @GestureState's guaranteed reset into cardLift.
                // Plain assignment, no spring - a cancelled preview should vanish, not fly home.
                .onChange(of: isReorderDragActive) { _, active in
                    if !active { cardLift = nil }
                }
                .onDisappear { cardLift = nil }
        }
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
    private var accountLayout: some View {
        if settings.groupByProvider {
            VStack(alignment: .leading, spacing: 14) {
                let groups = accountGroups
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        // One provider needs no heading: a label over the only section names what
                        // nothing else could be, so it is pure noise.
                        if groups.count > 1 { groupHeader(group) }
                        cardGrid(group.items)
                    }
                }
            }
        } else {
            cardGrid(visibleAccounts)
        }
    }

    /// The cards themselves, in the current column count. Called once for a flat layout and once per
    /// provider when grouped, so both layouts share one grid and can't drift in spacing or widths.
    @ViewBuilder
    private func cardGrid(_ accounts: [AccountUsage]) -> some View {
        let columns = columnCount
        if columns > 1 {
            VStack(spacing: 10) {
                ForEach(rows(accounts)) { row in
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

    /// A section's label line: who these cards belong to and how many there are, in the fleet
    /// column header's vocabulary but lighter - this names a section, it does not meter anything.
    /// The fold chevron appears only while this provider's pooled gauge is on screen to summarize
    /// the cards it would hide (the invariant the fleet strip's own chevron keeps).
    private func groupHeader(_ group: AccountGroup) -> some View {
        let foldable = pooledProviderIDs.contains(group.providerID)
        return HStack(spacing: 5) {
            providerLabel(group.providerID, count: group.items.count)
                .font(.caption)
            if foldable { foldChevron(group.providerID) }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if foldable { settings.toggleCollapsed(group.providerID) } }
    }

    private struct AccountRow: Identifiable {
        let items: [AccountUsage]
        var id: String { items.map(\.id).joined(separator: "|") }
    }

    /// One provider's cards, kept together when grouping is on.
    private struct AccountGroup: Identifiable {
        let providerID: String
        let items: [AccountUsage]
        var id: String { providerID }
    }

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
    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.reorderSpace))
            .updating($isReorderDragActive) { _, state, _ in state = true }
            .onChanged { value in
                if cardLift == nil {
                    guard let grabbed = cardFrames.first(where: { $0.value.contains(value.startLocation) }),
                          let usage = store.orderedAccounts.first(where: { $0.id == grabbed.key })
                    else { return }
                    cardLift = CardLift(
                        id: grabbed.key, usage: usage, sourceFrame: grabbed.value,
                        touchOffset: CGPoint(x: value.startLocation.x - grabbed.value.minX,
                                             y: value.startLocation.y - grabbed.value.minY),
                        location: value.location)
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

    /// Cards on screen: a provider collapsed behind its fleet gauge hides its cards, but ONLY
    /// while that gauge is actually rendered - no pool (single account) or gauge off, and the
    /// cards come straight back. Cards can never be hidden with nothing summarizing them.
    var visibleAccounts: [AccountUsage] {
        let pooled = pooledProviderIDs
        let collapsed = settings.collapsedProviders
        guard !pooled.isEmpty, !collapsed.isEmpty else { return store.orderedAccounts }
        return store.orderedAccounts.filter {
            !(collapsed.contains($0.providerID) && pooled.contains($0.providerID))
        }
    }

    /// Accounts chunked into rows of the current column count.
    private func rows(_ accounts: [AccountUsage]) -> [AccountRow] {
        let columns = columnCount
        return stride(from: 0, to: accounts.count, by: columns).map { start in
            AccountRow(items: Array(accounts[start ..< min(start + columns, accounts.count)]))
        }
    }

    /// Visible cards bucketed by provider. Provider order follows first appearance in the user's own
    /// card order, and each bucket keeps that order inside it - so grouping re-seats the cards
    /// without inventing a second ordering the user never chose.
    private var accountGroups: [AccountGroup] {
        var order: [String] = []
        var buckets: [String: [AccountUsage]] = [:]
        for usage in visibleAccounts {
            if buckets[usage.providerID] == nil { order.append(usage.providerID) }
            buckets[usage.providerID, default: []].append(usage)
        }
        return order.map { AccountGroup(providerID: $0, items: buckets[$0] ?? []) }
    }

    /// What a card move animates against: the persisted order, the grouping switch (flipping it moves
    /// every card while the order underneath stays byte-identical), and the column count, which
    /// re-seats every card without touching either. The resolved count, not the raw setting: Auto is
    /// the mode whose number moves on its own, and it is the number the cards are laid out by.
    private var cardSeatingSignature: String {
        "cols:\(columnCount)|" + (settings.groupByProvider ? "grouped:" : "flat:")
            + store.orderedAccounts.map(\.id).joined(separator: "|")
    }

    // Footer state lives here (stored properties can't live in extensions); the footer view
    // itself is in PopoverFooterView.swift.
    @State var showLaunchHelp = false
    @State var showViewOptions = false
    @State var footerWidths = FooterWidths()
}

