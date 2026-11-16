import SwiftUI

/// What the pinned panel shows instead of the full surface when the user picked a strip
/// (`PinnedStyle`): one cell per account, laid out as a row or a column (`PinnedAxis`), drawn from
/// the same numbers and colours as the menu-bar rings (`MenuBarSegments`, `PoolRing`). This file
/// holds the labeled strip; the rings-only strip is `PinnedRingStrip`.
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
        switch settings.pinnedStyle {
        case .full:
            chrome(radius: PanelMetrics.panelRadius, PopoverRootView(store: store, settings: settings, onContentSize: onContentSize,
                                   hostScreen: hostScreen, hostTopEdge: hostTopEdge,
                                   tabState: tabState, host: host))
        case .labeled:
            // Both strips draw their own chrome: the close button hangs over the clipped edge.
            PinnedCompactView(store: store, settings: settings,
                              vertical: settings.pinnedAxis == .vertical,
                              onContentSize: onContentSize,
                              hostScreen: hostScreen, hostTopEdge: hostTopEdge)
        case .rings:
            // Its radius follows its ring.
            PinnedRingStrip(store: store, settings: settings,
                            vertical: settings.pinnedAxis == .vertical,
                            onContentSize: onContentSize,
                            hostScreen: hostScreen, hostTopEdge: hostTopEdge)
        }
    }

    private func chrome(radius: CGFloat, _ content: some View) -> some View {
        content
            .background(PanelBackdrop(settings: .shared, cornerRadius: radius, skin: true))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(PanelRim(cornerRadius: radius))
    }
}

/// The numbers the two strips share. One inset, `edge`, between the strip's outer edge and the first
/// and last thing in it, on all four sides of all four strips (rings or labeled, vertical or
/// horizontal). The corner radius is that inset plus the ring's radius, which makes the strip's end
/// concentric with the ring in it. The close button is not inside the strip: its centre sits on the
/// corner arc at 45 degrees, half of it over the transparent triangle the rounding leaves in the window.
enum PinnedStripMetrics {
    static let edge: CGFloat = 8
    static let closeDiameter: CGFloat = 8
    /// Where the close button's top-left sits for a strip with this corner radius, so its centre is on
    /// the arc at 45 degrees: the arc is `radius * (1 - 1/sqrt2)` in from the window's corner on both axes.
    static func closeOrigin(radius: CGFloat) -> CGFloat {
        radius * (1 - 1 / 2.0.squareRoot()) - closeDiameter / 2
    }
    static let waitingDotDiameter: CGFloat = 5
    static let ringsRadius = edge + 14
    static let labeledRadius = edge + 11
}

/// A transparent run of strip that still moves the panel when pressed: the margins and gaps of a
/// strip that has no drag handle.
struct PinnedDragGap: View {
    var width: CGFloat?
    var height: CGFloat?

    var body: some View {
        Color.clear.frame(width: width, height: height).windowDragSurface()
    }
}

extension View {
    /// The close button, faded in on the top-left corner arc (`radius` is the strip's corner radius):
    /// it adds nothing to the size reported, and the strip does not move when it comes or goes. Put it
    /// outside the clip and the rim, or they cut and cross it.
    func pinnedCloseCorner(visible: Bool, radius: CGFloat) -> some View {
        overlay(alignment: .topLeading) {
            if visible {
                PinnedCloseButton()
                    .padding(.leading, PinnedStripMetrics.closeOrigin(radius: radius))
                    .padding(.top, PinnedStripMetrics.closeOrigin(radius: radius))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: visible)
    }

    /// The "a session is waiting" dot, centred in the strip's end gap (bottom of a column, right of a
    /// row). An overlay, so it takes no room of its own.
    func pinnedWaitingDot(waiting: Bool, vertical: Bool) -> some View {
        overlay(alignment: vertical ? .bottom : .trailing) {
            if waiting {
                let inset = (PinnedStripMetrics.edge - PinnedStripMetrics.waitingDotDiameter) / 2
                Circle().fill(Color.primary)
                    .frame(width: PinnedStripMetrics.waitingDotDiameter, height: PinnedStripMetrics.waitingDotDiameter)
                    .padding(vertical ? .bottom : .trailing, inset)
                    .allowsHitTesting(false)
            }
        }
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
    /// Same-provider index from the menu bar's own segment (nil for a lone account of its provider).
    var badge: Int?
    /// The label the user sees everywhere else (their rename first), so same-provider cells tell apart.
    var name: String

    @MainActor
    static func make(_ accounts: [AccountUsage], mode: DisplayMode, now: Date,
                     label: (AccountUsage) -> String) -> [PinnedCompactCell] {
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
                                     reset: resetsAt.flatMap { Self.countdown($0, now: now) },
                                     badge: segment.badge, name: label(account))
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
    var hostScreen: () -> NSScreen? = { NSScreen.main }
    var hostTopEdge: () -> CGFloat? = { nil }

    @Environment(\.colorScheme) private var scheme

    /// A cell's content (ring, figure, countdown) is 62 wide; the highlight reaches `cellPad` past it
    /// and the gap to the strip's edge makes up the rest of `PinnedStripMetrics.edge`. The figures
    /// are narrower than the 34 point column they sit in, so the far end of a row or column gives
    /// `trailingTrim` back to keep the ink as far from that edge as from the near one.
    private static let cellContentWidth: CGFloat = 62
    private static let cellPad: CGFloat = 4
    private static let trailingTrim: CGFloat = 1
    /// The ring and the text sit this far inside their cell's box (measured: the first ink is 2.5 below
    /// the box's top and above its bottom), so the gaps above and below take it off.
    private static let inkInset: CGFloat = 2.5
    /// What the display allows, re-read when the panel moves or the displays change (the same
    /// mechanism as `PopoverRootView.screenCap`). Nil until the first read.
    @State private var screenCap: CGFloat?
    @State private var screenWidth: CGFloat?
    @State private var scrollerGutter = ScreenFitStack.scrollerGutter
    /// The pointer is over the strip: the close button shows. Starts true under `-TallyPinnedHoverCapture`.
    @State private var hovering = PinnedCloseButton.forcedVisible

    var body: some View {
        let radius = PinnedStripMetrics.labeledRadius
        // Minute-grained countdowns: a 30s tick keeps "3:12" honest without a timer of our own.
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
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10),
                              lineWidth: 0.5)
                .allowsHitTesting(false))
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

    /// Same rule as `PopoverRootView.refreshScreenCap`: not while the panel is being carried (the
    /// cap follows the top edge, so every drag frame would resize it), re-read when the hand lets go.
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
        let edge = PinnedStripMetrics.edge, gap = edge - Self.cellPad, endGap = gap - Self.inkInset
        let items = ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
            if index > 0 { separator(sameProvider: cell.providerID == cells[index - 1].providerID) }
            cellRow(cell, gap: gap, endGap: endGap)
        }
        let width = Self.cellContentWidth + 2 * Self.cellPad + 2 * gap - Self.trailingTrim
        return Group {
            if vertical {
                // The accounts scroll once the column would outgrow the screen (a column that fits
                // lays out exactly as a plain VStack would).
                ScreenFitStack(maxHeight: screenCap
                                ?? ScreenFitStack.maxHeight(on: hostScreen(), topEdge: hostTopEdge())) {
                    PinnedDragGap(width: width, height: endGap)
                    ScrollView(.vertical) { VStack(spacing: 0) { items } }
                        .frame(width: width + scrollerGutter, alignment: .leading)
                        .screenFitFlexible()
                    PinnedDragGap(width: width, height: endGap)
                }
            } else {
                let cap = (screenWidth ?? ScreenFitStack.maxWidth(on: hostScreen())) - 2 * gap + Self.trailingTrim
                HStack(spacing: 0) {
                    PinnedDragGap(width: gap)
                    ScrollView(.horizontal) { HStack(spacing: 0) { items } }
                        .frame(maxWidth: max(0, cap.rounded(.down)))
                    PinnedDragGap(width: gap - Self.trailingTrim)
                }
            }
        }
        .pinnedWaitingDot(waiting: SessionRosterStore.shared.blockedCount > 0, vertical: vertical)
    }

    /// One cell with the cross-axis gaps to the strip's edge on its two sides.
    @ViewBuilder
    private func cellRow(_ cell: PinnedCompactCell, gap: CGFloat, endGap: CGFloat) -> some View {
        let view = PinnedCompactCellView(cell: cell, padding: Self.cellPad)
        if vertical {
            HStack(spacing: 0) { PinnedDragGap(width: gap); view; PinnedDragGap(width: gap - Self.trailingTrim) }
        } else {
            VStack(spacing: 0) { PinnedDragGap(height: endGap); view; PinnedDragGap(height: endGap) }
        }
    }

    /// Tight between accounts of one provider, wider with a hairline between providers.
    @ViewBuilder
    private func separator(sameProvider: Bool) -> some View {
        let hairline = Color.primary.opacity(0.12)
        if vertical {
            if sameProvider {
                Color.clear.frame(height: 2).windowDragSurface()
            } else {
                Color.clear.frame(height: 11).overlay(hairline.frame(width: 56, height: 0.5)).windowDragSurface()
            }
        } else {
            if sameProvider {
                Color.clear.frame(width: 4).windowDragSurface()
            } else {
                Color.clear.frame(width: 13).overlay(hairline.frame(width: 0.5, height: 18)).windowDragSurface()
            }
        }
    }
}

/// One account: the double ring with the provider's mark, then the weekly figure over its countdown.
private struct PinnedCompactCellView: View {
    let cell: PinnedCompactCell
    let padding: CGFloat
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                PinnedRing(cell: cell)
                VStack(alignment: .leading, spacing: 0) {
                    Text(cell.percent)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(cell.reset ?? " ")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(width: 34, alignment: .leading)
            }
            // Which account this is: the same-provider number, then the name. Pinned to the ring
            // plus figure width (22 + 6 + 34) so a long name truncates instead of widening the cell.
            (Text(verbatim: cell.badge.map { "\($0) " } ?? "").foregroundStyle(.tertiary).monospacedDigit()
                + Text(verbatim: cell.name))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 62, alignment: .leading)
        }
        .padding(padding)
        .help(cell.name)
        .background(RoundedRectangle(cornerRadius: TallyMetrics.calloutRadius, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .opacity(cell.ring.isFaded ? 0.4 : 1)
        .onHover { hovering = $0 }
        // A press that travels moves the panel; a plain click does nothing yet (expanding a cell
        // is a later step), so the tap is empty and only the drag half of the intent is live.
        .windowDragOrTap {}
    }
}

/// Weekly ring outside, 5-hour ring inside (when the account has that window), the provider's mark
/// in the middle. Same colours and dashed "no figure" state as the menu bar. Drawn at 22 for the
/// labeled strip and scaled from that design for the rings-only strip (`diameter`).
struct PinnedRing: View {
    let cell: PinnedCompactCell
    var diameter: CGFloat = 22

    var body: some View {
        let ring = cell.ring
        let hasInner = ring.innerFraction != nil
        let k = diameter / 22
        ZStack {
            arc(ring.fraction, severity: ring.severity, inset: 1.25 * k, lineWidth: 2.5 * k)
            if hasInner { arc(ring.innerFraction, severity: ring.innerSeverity, inset: 4.75 * k, lineWidth: 1.75 * k) }
            mark(size: (hasInner ? 8 : 11) * k)
        }
        .frame(width: diameter, height: diameter)
    }

    private func paint(_ severity: MetricSeverity) -> Color {
        severity == .unknown ? Color.primary : severity.color
    }

    @ViewBuilder
    private func arc(_ fraction: Double?, severity: MetricSeverity, inset: CGFloat, lineWidth: CGFloat) -> some View {
        let color = paint(severity)
        if let fraction {
            Circle().inset(by: inset).stroke(color, lineWidth: lineWidth).opacity(severity.smallRingTrackOpacity)
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

/// The pinned strip's close button: an 8 point disc with an x, faded in while the pointer is over the
/// strip. A press that travels moves the window (the usual grab behaviour); one that stays put unpins.
struct PinnedCloseButton: View {
    @Environment(\.colorScheme) private var scheme

    /// `-TallyPinnedHoverCapture YES` (demo or dev builds only): the strips draw with the pointer
    /// over them, so the button can be photographed without moving anybody's cursor.
    static let forcedVisible = (DemoUsage.isActive || BuildVariant.isDev)
        && CaptureLaunch.carries("TallyPinnedHoverCapture")

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Circle().fill(dark ? Color(red: 0x3a / 255, green: 0x3a / 255, blue: 0x3c / 255) : Color(white: 0.92))
            Circle().strokeBorder(dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12), lineWidth: 0.5)
            Path { path in
                path.move(to: CGPoint(x: 0.8, y: 0.8))
                path.addLine(to: CGPoint(x: 4.2, y: 4.2))
                path.move(to: CGPoint(x: 4.2, y: 0.8))
                path.addLine(to: CGPoint(x: 0.8, y: 4.2))
            }
            .stroke(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(width: 5, height: 5)
        }
        .frame(width: PinnedStripMetrics.closeDiameter, height: PinnedStripMetrics.closeDiameter)
        .windowDragOrTap { StatusItemController.unpin() }
        .help(L("Unpin window"))
        .accessibilityLabel(L("Unpin window"))
        .accessibilityAddTraits(.isButton)
        // The press above is an AppKit overlay's mouse-up; assistive tech activates through this.
        .accessibilityAction { StatusItemController.unpin() }
    }
}
