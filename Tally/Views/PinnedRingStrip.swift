import SwiftUI

/// The pinned panel's rings-only strip: one 28 point ring per account, no text. Accounts of one
/// provider are told apart by the same-provider number on the ring's lower right (the number the
/// menu bar and the labeled strip use), and the pointer hovering a ring answers with its name, figure
/// and countdown. A close button fades in on the top-left corner arc, half of it outside the strip,
/// while the pointer is over the strip.
///
/// Every inset is `PinnedStripMetrics.edge`, the same on all four sides, and the corner radius is that
/// inset plus the ring's radius so the end of the strip is concentric with the ring in it. There is
/// no drag handle: every gap, separator and cell is a drag surface, so the whole strip moves.
///
/// SIZE HAS ONE AUTHORITY AND IT IS NOT THIS FILE (see `PinnedCompactView`): the strip lays out at its
/// natural size and reports it through `onContentSize`. `SurfaceSizer` writes the frame. Nothing here
/// touches a window.
struct PinnedRingStrip: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    var vertical: Bool
    var onContentSize: ((CGSize) -> Void)?
    var hostScreen: () -> NSScreen? = { NSScreen.main }
    var hostTopEdge: () -> CGFloat? = { nil }

    private static let ringDiameter: CGFloat = 28
    /// A cell is the ring alone: the badge hangs off its lower right into the gap (2 right, 2 down),
    /// so the ring stays centred in the strip and the inset is measured to the ring.
    private static let cellSize = CGSize(width: ringDiameter, height: ringDiameter)
    /// Room between neighbouring cells along the strip, per side, taken off that axis' end gaps.
    private static let pitchPad: CGFloat = 3

    @State private var screenCap: CGFloat?
    @State private var screenWidth: CGFloat?
    @State private var scrollerGutter = ScreenFitStack.scrollerGutter
    @State private var hovering = PinnedCloseButton.forcedVisible

    var body: some View {
        let radius = PinnedStripMetrics.ringsRadius
        // Minute-grained countdowns: a 30s tick keeps the tooltip's "3:12" honest without a timer of our own.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            strip(PinnedCompactCell.make(store.orderedAccounts, mode: settings.displayMode,
                                         now: timeline.date) {
                settings.displayLabel(accountID: $0.id, fallback: $0.accountLabel)
            })
        }
        .fixedSize()
        .background(PanelBackdrop(settings: .shared, cornerRadius: radius, skin: true))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(PanelRim(cornerRadius: radius))
        .pinnedCloseCorner(visible: hovering, radius: radius)
        .onHover { hovering = $0 || PinnedCloseButton.forcedVisible }
        .background(sizeReporter)
        // The surface stays against the corner the host holds while the host catches up with the
        // size just reported (see `HostAnchored`).
        .anchoredInHost(enabled: onContentSize != nil)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { _ in
            refreshScreenCap()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in refreshScreenCap() }
        .onReceive(NotificationCenter.default.publisher(for: PanelDrag.ended)) { _ in
            refreshScreenCap()
        }
        .trackingScrollerGutter($scrollerGutter)
        .onAppear { DispatchQueue.main.async { refreshScreenCap() } }
    }

    /// Same rule as `PinnedCompactView.refreshScreenCap`: not while the panel is being carried, re-read
    /// when the hand lets go.
    private func refreshScreenCap() {
        guard !PanelDrag.isActive else { return }
        let height = ScreenFitStack.maxHeight(on: hostScreen(), topEdge: hostTopEdge())
        if screenCap != height { screenCap = height }
        let width = ScreenFitStack.maxWidth(on: hostScreen())
        if screenWidth != width { screenWidth = width }
    }

    private var sizeReporter: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size, initial: true) { _, size in onContentSize?(size) }
        }
    }

    private func strip(_ cells: [PinnedCompactCell]) -> some View {
        let edge = PinnedStripMetrics.edge, along = Self.pitchPad
        let items = ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
            if index > 0 { separator(sameProvider: cell.providerID == cells[index - 1].providerID) }
            cellRow(cell)
        }
        let width = Self.cellSize.width + 2 * edge
        return Group {
            if vertical {
                // The accounts scroll once the column would outgrow the screen.
                ScreenFitStack(maxHeight: screenCap
                                ?? ScreenFitStack.maxHeight(on: hostScreen(), topEdge: hostTopEdge())) {
                    PinnedDragGap(width: width, height: edge - along)
                    ScrollView(.vertical) { VStack(spacing: 0) { items } }
                        .frame(width: width + scrollerGutter, alignment: .leading)
                        .screenFitFlexible()
                    PinnedDragGap(width: width, height: edge - along)
                }
            } else {
                let cap = (screenWidth ?? ScreenFitStack.maxWidth(on: hostScreen())) - 2 * (edge - along)
                HStack(spacing: 0) {
                    PinnedDragGap(width: edge - along)
                    ScrollView(.horizontal) { HStack(spacing: 0) { items } }
                        .frame(maxWidth: max(0, cap.rounded(.down)))
                    PinnedDragGap(width: edge - along)
                }
            }
        }
        .pinnedWaitingDot(waiting: SessionRosterStore.shared.blockedCount > 0, vertical: vertical)
    }

    /// One cell with the cross-axis gaps to the strip's edge on its two sides.
    @ViewBuilder
    private func cellRow(_ cell: PinnedCompactCell) -> some View {
        let edge = PinnedStripMetrics.edge
        let ring = PinnedRingCellView(cell: cell, vertical: vertical, diameter: Self.ringDiameter,
                                      size: Self.cellSize, along: Self.pitchPad)
        if vertical {
            HStack(spacing: 0) { PinnedDragGap(width: edge); ring; PinnedDragGap(width: edge) }
        } else {
            VStack(spacing: 0) { PinnedDragGap(height: edge); ring; PinnedDragGap(height: edge) }
        }
    }

    /// Nothing between accounts of one provider, a hairline between providers.
    @ViewBuilder
    private func separator(sameProvider: Bool) -> some View {
        if !sameProvider {
            let hairline = Color.primary.opacity(0.12)
            if vertical {
                Color.clear.frame(height: 9).overlay(hairline.frame(width: 26, height: 0.5)).windowDragSurface()
            } else {
                Color.clear.frame(width: 9).overlay(hairline.frame(width: 0.5, height: 18)).windowDragSurface()
            }
        }
    }
}

/// One account: the ring at 28 points in a cell that lights on hover, the same-provider number on its
/// lower right. No text; the name, figure and countdown are the tooltip.
private struct PinnedRingCellView: View {
    let cell: PinnedCompactCell
    let vertical: Bool
    let diameter: CGFloat
    let size: CGSize
    /// Padding on the two ends of the cell along the strip's axis; part of the drag surface.
    let along: CGFloat
    @State private var hovering = false

    var body: some View {
        PinnedRing(cell: cell, diameter: diameter)
            .overlay(alignment: .bottomTrailing) {
                if let badge = cell.badge { badgeView(badge).offset(x: 2, y: 2) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .padding(vertical ? .vertical : .horizontal, along)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0)).padding(-2))
            .opacity(cell.ring.isFaded ? 0.4 : 1)
            .onHover { hovering = $0 }
            // A press that travels moves the panel; a plain click does nothing.
            .windowDragOrTap {}
            .help(tooltip)
    }

    private func badgeView(_ number: Int) -> some View {
        Text(verbatim: "\(number)")
            .font(.system(size: 8.5, weight: .bold).monospacedDigit())
            .foregroundStyle(Color.primary.opacity(0.72))
            .padding(.horizontal, 1.5)
            .frame(minWidth: 11, minHeight: 11)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PanelStyle.panelSolid))
            .allowsHitTesting(false)
    }

    private var tooltip: String {
        let head = (cell.badge.map { "\($0) " } ?? "") + cell.name
        let tail = [cell.percent, cell.reset].compactMap { $0 }.joined(separator: " · ")
        return "\(head)  \(tail)"
    }
}
