import SwiftUI
import AppKit

/// The menu-bar popover: header, one card per account, footer with the used/left toggle + settings.
///
/// The popover sizes to its content in a single pass via the hosting controller's
/// `sizingOptions = .preferredContentSize` (set in `StatusItemController`). There is deliberately no
/// ScrollView + measured `.frame(height:)` here: that made the popover open at one size then resize to
/// fit, so AppKit's frame animation fought SwiftUI's layout — the "two clocks" stutter openusage
/// documents. Static content + one-pass sizing avoids the fight entirely.
struct PopoverRootView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    /// Reports the content's ACTUAL rendered size so the host (popover / panel) can size itself to it.
    /// Measuring the real size beats asking `sizeThatFits`, which returned a greedy screen-tall height.
    var onContentSize: ((CGSize) -> Void)? = nil

    private static let reorderSpace = "tallyCardReorder"
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var activeCardID: String?
    @State private var cardLift: CardLift?

    var body: some View {
        // Rebuild the whole tree on language change. A bare read of languageOverride only re-runs THIS
        // body — SwiftUI still diffs child View structs (AccountCardView, MetricRowView, EmptyStateView)
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

    /// Go two-column once any provider has more than one visible account — the multi-account case
    /// where a single column would scroll forever. Otherwise stay a narrow single column.
    private var useTwoColumns: Bool {
        Dictionary(grouping: store.orderedAccounts, by: \.providerID).values.contains { $0.count > 1 }
    }

    private var popoverWidth: CGFloat { useTwoColumns ? 560 : 380 }

    /// Definite card width. `.frame(maxWidth: .infinity)` cards would fight the hosting controller's
    /// `.preferredContentSize` sizing (content wants to shrink to fit, cards want infinite width) and
    /// recurse the layout engine to a stack overflow — so derive an exact width from the fixed popover
    /// width (12pt content padding each side, 10pt gap between two columns).
    private var cardWidth: CGFloat {
        let inner = popoverWidth - 24
        return useTwoColumns ? (inner - 10) / 2 : inner
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Everything except the refresh button doubles as the pinned panel's window-move handle
            // (an AppKit background view would steal the button's clicks, so the button sits outside).
            // The handle carries the leading/vertical padding and fills the header's full height —
            // backing only the text line left a thin ~17pt grab strip that was easy to miss.
            HStack(spacing: 6) {
                Text("Tally").font(.headline)
                // Brand credit: quiet, with the official Jetto lock-up (logo + logotype), tinted
                // like secondary text. Even-odd fill keeps the letter counters hollow.
                HStack(spacing: 4) {
                    Text("by").font(.caption2).foregroundStyle(.tertiary)
                    ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                        .fill(Color.secondary, style: FillStyle(eoFill: true))
                        .frame(width: 44, height: 10)
                }
                .padding(.top, 3)   // optically align with the title's baseline
                Spacer()
                // TimelineView re-evaluates on a clock, so "updated 2m ago" keeps advancing while the
                // popover/panel stays open (a plain render froze it at whatever it said on open). The
                // date sits alongside as the anchor for the absolute reset times.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 6) {
                        Text(UsageFormat.nowShort(context.date))
                            .font(.caption2).foregroundStyle(.tertiary)
                        if let updated = UsageFormat.updatedAgo(store.lastSuccessfulRefreshAt,
                                                                now: context.date) {
                            Text(updated).font(.caption2).foregroundStyle(.secondary)
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
                // Cards glide (not teleport) whenever the order changes — from a drag here or the
                // settings window.
                .animation(CardMotion.spring, value: store.orderedAccounts.map(\.id))
        }
    }

    /// Accounts in rows of two when multi-account, one column otherwise. A hand-built grid (not
    /// LazyVGrid) so the whole thing lays out in one pass — lazy loading only helps long scrolls and
    /// here fought the one-pass sizing.
    @ViewBuilder
    private var accountLayout: some View {
        if useTwoColumns {
            VStack(spacing: 10) {
                ForEach(accountRows.indices, id: \.self) { row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(accountRows[row]) { usage in
                            card(usage, fillsRowHeight: true).frame(width: cardWidth, alignment: .top)
                        }
                        // Keep a lone trailing card at half width so the grid stays aligned.
                        if accountRows[row].count == 1 {
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

    /// An account card that can be dragged to reorder (OpenUsage-style in-view drag: the source card
    /// hides, a floating copy tracks the pointer, and neighbors spring out of the way live). The order
    /// is persisted and applied everywhere (popover, dashboard, menu bar). Reordering never changes the
    /// content's size, so the live mutation can't feed the old sizing-loop crash (hosts size via the
    /// deferred `onContentSize` path regardless).
    private func card(_ usage: AccountUsage, fillsRowHeight: Bool = false) -> some View {
        AccountCardView(usage: usage, settings: settings,
                        showsDragHandle: true, fillsRowHeight: fillsRowHeight)
            .opacity(activeCardID == usage.id ? 0 : 1)
            .contentShape(Rectangle())
            .highPriorityGesture(dragGesture(for: usage))
            .cardFrame(id: usage.id, in: Self.reorderSpace)
    }

    private func dragGesture(for usage: AccountUsage) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.reorderSpace))
            .onChanged { value in
                activeCardID = usage.id
                if cardLift?.id != usage.id, let frame = cardFrames[usage.id] {
                    cardLift = CardLift(
                        id: usage.id, usage: usage, sourceFrame: frame,
                        touchOffset: CGPoint(x: value.startLocation.x - frame.minX,
                                             y: value.startLocation.y - frame.minY),
                        location: value.location)
                }
                cardLift?.location = value.location
                guard let target = reorderTarget(at: value.location, frames: cardFrames,
                                                 excluding: usage.id,
                                                 orderedIDs: store.orderedAccounts.map(\.id))
                else { return }
                var moved = false
                withAnimation(CardMotion.spring) {
                    moved = settings.moveAccount(usage.id, onto: target, allIDs: store.accounts.map(\.id))
                }
                if moved { Haptics.snap() }
            }
            .onEnded { _ in
                activeCardID = nil
                cardLift = nil
            }
    }

    /// Accounts chunked into pairs for the two-column grid.
    private var accountRows: [[AccountUsage]] {
        let ordered = store.orderedAccounts
        return stride(from: 0, to: ordered.count, by: 2).map { start in
            Array(ordered[start ..< min(start + 2, ordered.count)])
        }
    }

    private var footer: some View {
        HStack {
            // A segmented control, not a switch: both states are valid views (nothing is "off"), and
            // showing both labels at once means the current mode and the alternative are always legible.
            Picker("", selection: $settings.displayMode) {
                Text(L("Left")).tag(DisplayMode.remaining)
                Text(L("Used")).tag(DisplayMode.used)
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
    }
}
