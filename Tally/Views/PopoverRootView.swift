import SwiftUI
import AppKit

/// The menu-bar popover: header, one card per account, footer with the used/left toggle + settings.
///
/// The popover sizes to its content in a single pass via the hosting controller's
/// `sizingOptions = .preferredContentSize` (set in `StatusItemController`). There is deliberately no
/// ScrollView + measured `.frame(height:)` here: that made the popover open at one size then resize to
/// fit, so AppKit's frame animation fought SwiftUI's layout - the classic "two clocks" stutter. Static content + one-pass sizing avoids the fight entirely.
struct PopoverRootView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    /// Reports the content's ACTUAL rendered size so the host (popover / panel) can size itself to it.
    /// Measuring the real size beats asking `sizeThatFits`, which returned a greedy screen-tall height.
    var onContentSize: ((CGSize) -> Void)? = nil

    private static let reorderSpace = "tallyCardReorder"
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var cardLift: CardLift?
    /// True while the reorder drag is tracking. @GestureState resets automatically on BOTH end and
    /// cancellation - the only hook SwiftUI guarantees for a cancelled gesture (onEnded is skipped) -
    /// so cardLift cleanup keys off its reset instead of trusting onEnded alone.
    @GestureState private var isReorderDragActive = false

    var body: some View {
        // Rebuild the whole tree on language change. A bare read of languageOverride only re-runs THIS
        // body - SwiftUI still diffs child View structs (AccountCardView, MetricRowView, EmptyStateView)
        // as unchanged and skips re-localizing them, leaving cards stuck in the old language. Keying
        // `.id` on the language forces a full teardown + rebuild so every L() re-resolves.
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                Divider()
                content
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
        .id(settings.languageOverride ?? "system")
    }

    /// Measures the laid-out content size and reports it upward (fires on appear + on change).
    private var sizeReporter: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                onContentSize?(size)
            }
        }
    }

    /// Go two-column once any provider has more than one visible account - the multi-account case
    /// where a single column would scroll forever. Otherwise stay a narrow single column.
    private var useTwoColumns: Bool {
        Dictionary(grouping: store.orderedAccounts, by: \.providerID).values.contains { $0.count > 1 }
    }

    private var popoverWidth: CGFloat { useTwoColumns ? 560 : 380 }

    /// Definite card width. `.frame(maxWidth: .infinity)` cards would fight the hosting controller's
    /// `.preferredContentSize` sizing (content wants to shrink to fit, cards want infinite width) and
    /// recurse the layout engine to a stack overflow - so derive an exact width from the fixed popover
    /// width (12pt content padding each side, 10pt gap between two columns).
    private var cardWidth: CGFloat {
        let inner = popoverWidth - 24
        return useTwoColumns ? (inner - 10) / 2 : inner
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Everything except the refresh button doubles as the pinned panel's window-move handle
            // (an AppKit background view would steal the button's clicks, so the button sits outside).
            // The handle carries the leading/vertical padding and fills the header's full height -
            // backing only the text line left a thin ~17pt grab strip that was easy to miss.
            HStack(spacing: 6) {
                // The logotype (brand T as the initial) - a bare glyph next to the word "Tally"
                // read as two Ts. The header is the product's line; the jetto credit lives quietly
                // in the footer's empty centre instead of trailing the wordmark like a byline.
                TallyWordmarkView(glyphHeight: 13)
                Spacer()
                // TimelineView re-evaluates every second so "updates in 42s" counts down live (a
                // plain render would freeze it at whatever it said on open). Hierarchy: the date is
                // the anchor the absolute reset times are read against, so it leads; the countdown
                // is a heartbeat, so it dims.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        Text(UsageFormat.nowShort(context.date))
                            .font(.caption2.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.primary)
                        if let counter = store.isRefreshing
                            ? L("updating…")
                            : UsageFormat.updatesIn(store.nextRefreshAt, now: context.date) {
                            // The counter's string width changes every second; hidden templates
                            // (the widest forms, localized) reserve a fixed slot so the ticking
                            // never pushes the date around. Trailing-aligned to hug the button.
                            ZStack(alignment: .trailing) {
                                ForEach(UsageFormat.updatesInTemplates, id: \.self) {
                                    Text($0).hidden()
                                }
                                Text(counter)
                            }
                            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.leading, 12)
            .frame(maxHeight: .infinity)
            .background(WindowDragArea())
            Button {
                Task { await store.refresh(userInitiated: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default, value: store.isRefreshing)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .accessibilityLabel(L("Refresh"))
            .help(L("Refresh"))
            .padding(.trailing, 12)
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private var content: some View {
        if store.contentState != .hasAccounts {
            EmptyStateView(state: store.contentState)
        } else {
            accountLayout
                .padding(12)
                // Cards glide (not teleport) whenever the order changes - from a drag here or the
                // settings window.
                .animation(CardMotion.spring, value: store.orderedAccounts.map(\.id))
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
        if useTwoColumns {
            VStack(spacing: 10) {
                ForEach(accountRows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row.items) { usage in
                            card(usage, fillsRowHeight: true).frame(width: cardWidth, alignment: .top)
                        }
                        // Keep a lone trailing card at half width so the grid stays aligned.
                        if row.items.count == 1 {
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
                ForEach(store.orderedAccounts) { usage in
                    card(usage).frame(width: cardWidth)
                }
            }
        }
    }

    private struct AccountRow: Identifiable {
        let items: [AccountUsage]
        var id: String { items.map(\.id).joined(separator: "|") }
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
                var moved = false
                withAnimation(CardMotion.spring) {
                    moved = settings.moveAccount(lift.id, onto: target, allIDs: store.accounts.map(\.id))
                }
                if moved { Haptics.snap() }
            }
            .onEnded { _ in cardLift = nil }
    }

    /// Accounts chunked into pairs for the two-column grid.
    private var accountRows: [AccountRow] {
        let ordered = store.orderedAccounts
        return stride(from: 0, to: ordered.count, by: 2).map { start in
            AccountRow(items: Array(ordered[start ..< min(start + 2, ordered.count)]))
        }
    }

    @State private var showLaunchHelp = false
    @State private var copiedCommand: String?

    /// A command chip that copies itself on click, flashing a green check as the receipt.
    private func commandChip(_ command: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copiedCommand = command
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copiedCommand == command { copiedCommand = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: command).font(.caption.monospaced())
                Image(systemName: copiedCommand == command ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(copiedCommand == command ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Copy"))
    }

    /// The "?" popover: how to actually launch on the picked account, and what clicking a card does.
    private var launchHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Launch account")).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(["tally claude", "tally codex"], id: \.self) { command in
                        commandChip(command)
                    }
                }
                Text(L("Launches a session on the account Tally picks."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L("With shell integration installed (Settings → Integrations), plain claude and codex commands follow the policy too."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Click a card to pin that account (Manual); click it again to go back to Auto."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            // A segmented control, not a switch: both states are valid views (nothing is "off"), and
            // showing both labels at once means the current mode and the alternative are always legible.
            // Used before Left, mirroring the meters' geometry: the used portion fills from the
            // track's left edge and the remainder hugs the right, so the toggle order matches
            // where each quantity lives in the bar.
            Picker("", selection: $settings.displayMode) {
                Text(L("Used")).tag(DisplayMode.used)
                Text(L("Left")).tag(DisplayMode.remaining)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .help(L("Meters show"))
            Spacer()
            // Footer icons are one muted set (secondary); only the pin lights up (accent) when active,
            // so an unpinned pin doesn't read as already-on.
            Button {
                showLaunchHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("Launch account"))
            .popover(isPresented: $showLaunchHelp, arrowEdge: .bottom) { launchHelp }
            Button {
                StatusItemController.togglePin()
            } label: {
                Image(systemName: settings.isUsagePanelPinned ? "pin.fill" : "pin")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(settings.isUsagePanelPinned ? Color.accentColor : Color.secondary)
            .help(settings.isUsagePanelPinned ? L("Unpin window") : L("Pin on top"))
            Button {
                MainWindowController.shared.show()
            } label: {
                Image(systemName: "macwindow")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("Open Tally"))
            Button {
                StatusItemController.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("Settings…"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        // The jetto credit, dead centre in the footer's empty middle - quiet, on every surface,
        // and off the header so the product wordmark stands alone.
        .overlay {
            HStack(spacing: 4) {
                Text("by").font(.caption2).foregroundStyle(.tertiary)
                ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                    .fill(Color.secondary, style: FillStyle(eoFill: true))
                    .frame(width: 40, height: 9)
            }
            .opacity(0.75)
            .allowsHitTesting(false)
        }
    }
}
