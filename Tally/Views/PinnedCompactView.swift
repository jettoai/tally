import SwiftUI

/// What the pinned panel shows instead of the full surface when the user picked a compact style
/// (`PinnedStyle`): one cell per account, laid out as a row or a column, drawn from the same
/// numbers and colours as the menu-bar rings (`MenuBarSegments`, `PoolRing`).
///
/// SIZE HAS ONE AUTHORITY AND IT IS NOT THIS FILE. The strip is laid out at its natural size and
/// reports it through `onContentSize`, exactly as `PopoverRootView` does; `SurfaceSizer` writes
/// the frame. Nothing here touches a window.
struct PinnedPanelRoot: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    var onContentSize: (CGSize) -> Void
    var hostScreen: () -> NSScreen?
    var hostTopEdge: () -> CGFloat?
    @Bindable var tabState: SurfaceTabState
    var host: SurfaceHost

    var body: some View {
        Group {
            switch settings.pinnedStyle {
            case .full:
                PopoverRootView(store: store, settings: settings, onContentSize: onContentSize,
                                hostScreen: hostScreen, hostTopEdge: hostTopEdge,
                                tabState: tabState, host: host)
            case .row, .column:
                PinnedCompactView(store: store, settings: settings,
                                  vertical: settings.pinnedStyle == .column,
                                  onContentSize: onContentSize)
            }
        }
        .background(PanelBackdrop(settings: .shared))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The data one cell draws, derived once per refresh from the menu-bar segment of the same account
/// so the strip and the cell can never disagree about a figure or its colour.
struct PinnedCompactCell: Equatable, Identifiable {
    var id: String
    var providerID: String
    var ring: PoolRing
    /// The weekly figure as the Used/Left toggle prints it ("62%"), or the menu bar's own
    /// placeholder glyph when there is nothing to read.
    var percent: String
    /// Time to the weekly reset: "3:12" inside a day, "2d 4h" beyond; nil when unknown or passed.
    var reset: String?

    @MainActor
    static func make(_ accounts: [AccountUsage], mode: DisplayMode, now: Date) -> [PinnedCompactCell] {
        let focus = UsageStore.focusedModel
        let segments = MenuBarSegments.perAccount(accounts, mode: mode, focusedModel: focus, now: now)
        return zip(accounts, segments).map { account, segment in
            var ring = PoolRing(segment)
            // The arc and the number tell one story: under "Used" both are what was spent.
            if mode == .used {
                ring.fraction = ring.fraction.map { 1 - $0 }
                ring.innerFraction = ring.innerFraction.map { 1 - $0 }
            }
            let weekly = MenuBarSegments.metrics(account, focusedModel: focus).last
            let resetsAt = weekly.flatMap { account.resetPassed($0, now: now) ? nil : $0.resetsAt }
            return PinnedCompactCell(id: account.id, providerID: account.providerID, ring: ring,
                                     percent: segment.lines.last ?? "—",
                                     reset: resetsAt.flatMap { Self.countdown($0, now: now) })
        }
    }

    static func countdown(_ date: Date, now: Date) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        if seconds >= 86_400 { return UsageFormat.durationBody(seconds) }
        return String(format: "%d:%02d", Int(seconds) / 3_600, Int(seconds) % 3_600 / 60)
    }
}

struct PinnedCompactView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    var vertical: Bool
    var onContentSize: ((CGSize) -> Void)?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Minute-grained countdowns: a 30s tick keeps "3:12" honest without a timer of our own.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            strip(PinnedCompactCell.make(store.orderedAccounts, mode: settings.displayMode,
                                         now: timeline.date))
        }
        .fixedSize()
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10),
                              lineWidth: 0.5)
                .allowsHitTesting(false))
        .background(sizeReporter)
        // The surface stays against the corner the host holds while the host catches up with the
        // size just reported (see `HostAnchored`).
        .anchoredInHost(enabled: onContentSize != nil)
    }

    private var sizeReporter: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size, initial: true) { _, size in onContentSize?(size) }
        }
    }

    private func strip(_ cells: [PinnedCompactCell]) -> some View {
        let waiting = SessionRosterStore.shared.blockedCount > 0
        let items = ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
            if index > 0 { separator(sameProvider: cell.providerID == cells[index - 1].providerID) }
            PinnedCompactCellView(cell: cell, horizontalPadding: vertical ? 8 : 6)
        }
        let dot = Circle().fill(Color.primary).frame(width: 6, height: 6)
        return Group {
            if vertical {
                VStack(spacing: 0) {
                    gripDots(columns: 3, rows: 2).frame(width: 84, height: 14).windowDragSurface()
                    items
                    if waiting { dot.frame(width: 84, alignment: .trailing).padding(.trailing, 8).padding(.top, 4) }
                    Color.clear.frame(width: 84, height: 8)
                }
            } else {
                HStack(spacing: 0) {
                    gripDots(columns: 2, rows: 3).frame(width: 14, height: 40).windowDragSurface()
                    items
                    if waiting { dot.padding(.leading, 8) }
                    Color.clear.frame(width: 8, height: 40)
                }
            }
        }
    }

    /// Tight between accounts of one provider, wider with a hairline between providers.
    @ViewBuilder
    private func separator(sameProvider: Bool) -> some View {
        let hairline = Color.primary.opacity(0.12)
        if vertical {
            if sameProvider {
                Color.clear.frame(width: 1, height: 2)
            } else {
                hairline.frame(width: 56, height: 0.5).padding(.vertical, 5)
            }
        } else {
            if sameProvider {
                Color.clear.frame(width: 4, height: 1)
            } else {
                hairline.frame(width: 0.5, height: 18).padding(.horizontal, 6)
            }
        }
    }

    /// The handle: a small grid of dots in the quiet tertiary ink.
    private func gripDots(columns: Int, rows: Int) -> some View {
        VStack(spacing: 2) {
            ForEach(0 ..< rows, id: \.self) { _ in
                HStack(spacing: 2) {
                    ForEach(0 ..< columns, id: \.self) { _ in
                        Circle().fill(Color.primary.opacity(0.25)).frame(width: 2, height: 2)
                    }
                }
            }
        }
    }
}

/// One account: the double ring with the provider's mark, then the weekly figure over its countdown.
private struct PinnedCompactCellView: View {
    let cell: PinnedCompactCell
    let horizontalPadding: CGFloat
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            PinnedRing(cell: cell)
            VStack(alignment: .leading, spacing: 0) {
                Text(cell.percent)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                Text(cell.reset ?? " ")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 40, alignment: .leading)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: TallyMetrics.calloutRadius, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .opacity(cell.ring.isFaded ? 0.4 : 1)
        .onHover { hovering = $0 }
        // A press that travels moves the panel; a plain click does nothing yet (expanding a cell
        // is a later step), so the tap is empty and only the drag half of the intent is live.
        .windowDragOrTap {}
        .padding(.vertical, 2)
    }
}

/// 22x22: weekly ring outside, 5-hour ring inside (when the account has that window), the
/// provider's mark in the middle. Same colours and dashed "no figure" state as the menu bar.
private struct PinnedRing: View {
    let cell: PinnedCompactCell

    var body: some View {
        let ring = cell.ring
        let hasInner = ring.innerFraction != nil
        ZStack {
            arc(ring.fraction, severity: ring.severity, inset: 1.25, lineWidth: 2.5)
            if hasInner { arc(ring.innerFraction, severity: ring.innerSeverity, inset: 4.75, lineWidth: 1.75) }
            mark(size: hasInner ? 8 : 11)
        }
        .frame(width: 22, height: 22)
    }

    private func paint(_ severity: MetricSeverity) -> Color {
        severity == .unknown ? Color.primary : severity.color
    }

    @ViewBuilder
    private func arc(_ fraction: Double?, severity: MetricSeverity, inset: CGFloat, lineWidth: CGFloat) -> some View {
        let color = paint(severity)
        if let fraction {
            Circle().inset(by: inset).stroke(color, lineWidth: lineWidth).opacity(0.28)
            Circle().inset(by: inset).trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, lineWidth: lineWidth)
                .rotationEffect(.degrees(-90))
        } else {
            Circle().inset(by: inset)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: [lineWidth, lineWidth]))
        }
    }

    @ViewBuilder
    private func mark(size: CGFloat) -> some View {
        let brand = ProviderBrand.markHex(for: cell.providerID).map {
            Color(red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255,
                  blue: Double($0 & 0xFF) / 255)
        } ?? Color.primary
        if let path = ProviderMarks.path(for: cell.providerID) {
            ProviderIconShape(pathData: path, inset: 0.04).fill(brand).frame(width: size, height: size)
        } else {
            Image(systemName: ProviderCatalog.iconName(for: cell.providerID))
                .font(.system(size: size - 2, weight: .semibold))
                .foregroundStyle(brand)
                .frame(width: size, height: size)
        }
    }
}
