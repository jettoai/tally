import SwiftUI
import AppKit

/// What the panel remembers about its two one-time nudges (PanelHints). Every write goes through
/// here, and demo-data launches (screenshots) keep their answers for that launch only, the way
/// `ErrorReportingNoticeStrip` does: a capture must not tell the real defaults it has been read.
@MainActor
@Observable
final class PanelHintMemory {
    static let shared = PanelHintMemory()

    private(set) var seen: Bool
    private(set) var opens: Int
    private(set) var inviteDismissed: Bool
    /// `-TallyPanelHintPreview hint|invite|off`: Dev builds and demo data only, like every capture flag.
    static var preview: PanelHints.Preview? {
        guard BuildVariant.isDev || DemoUsage.isActive else { return nil }
        return PanelHints.preview(named: UserDefaults.standard.string(forKey: CaptureLaunch.panelHintPreview))
    }

    /// A demo launch and a held preview read and write nothing real.
    private let persists = !DemoUsage.isActive && PanelHintMemory.preview == nil
    private let defaults = UserDefaults.standard

    private init() {
        seen = persists && defaults.bool(forKey: PanelHints.seenKey)
        opens = persists ? defaults.integer(forKey: PanelHints.opensKey) : 0
        inviteDismissed = persists && defaults.bool(forKey: PanelHints.inviteDismissedKey)
    }

    func markSeen() {
        seen = true
        if persists { defaults.set(true, forKey: PanelHints.seenKey) }
    }

    /// One more opening with data; returns the new count.
    func countOpen() -> Int {
        opens += 1
        if persists { defaults.set(opens, forKey: PanelHints.opensKey) }
        return opens
    }

    func dismissInvite() {
        inviteDismissed = true
        if persists { defaults.set(true, forKey: PanelHints.inviteDismissedKey) }
    }
}

/// The invite, and the snapshot of what the panel looked like WHEN IT APPEARED that decides it (see
/// `PanelHints.showsInvite`). It is held under the scrolling region, at its own height: inside the
/// scroll view a panel capped to a short display scrolled it away. The first-run bubble floats over
/// the cards instead (`PanelHintBubbleOverlay`), so it takes no room here.
struct PanelHintsSection: View {
    let store: UsageStore

    private let memory = PanelHintMemory.shared
    @State private var seenAtAppear = false
    @State private var opensAtAppear = 0
    @State private var commandAbsentAtAppear = false
    @State private var countedThisAppearance = false
    private let integrations = IntegrationsStore.shared

    private var hasReading: Bool { store.accounts.contains { !$0.metrics.isEmpty } }

    private var inviteShows: Bool {
        if let held = PanelHintMemory.preview { return held == .invite && !memory.inviteDismissed }
        return PanelHints.showsInvite(
            seenAtAppear: seenAtAppear, opensAtAppear: opensAtAppear, dismissed: memory.inviteDismissed,
            commandAbsent: commandAbsentAtAppear && integrations.cliToolPresence == .absent,
            hasClaudeAccount: store.accounts.contains { $0.providerID == "claude" })
    }

    var body: some View {
        VStack(spacing: 0) {
            if inviteShows {
                TallyCommandInviteCard(
                    onSetUp: { TallyCommandWindowController.shared.show() },
                    onDismiss: { memory.dismissInvite() })
            }
            // Something to appear: a body that is empty draws nothing, and `onAppear` is not
            // reliably delivered for nothing.
            Color.clear.frame(height: 0)
        }
        .onAppear {
            countedThisAppearance = false
            seenAtAppear = memory.seen
            commandAbsentAtAppear = IntegrationsStore.detectCLIToolPresence() == .absent
            countIfReadable()
        }
        // A first reading can land after the panel is already up; that opening still counts.
        .onChange(of: hasReading) { _, _ in countIfReadable() }
    }

    private func countIfReadable() {
        guard !countedThisAppearance else { return }
        guard PanelHints.countsAsOpen(hasAccounts: !store.accounts.isEmpty, anyReading: hasReading) else {
            opensAtAppear = memory.opens
            return
        }
        countedThisAppearance = true
        opensAtAppear = memory.countOpen()
    }
}

/// Where the first hint's bubble should point: the first meter bar of each row or card, keyed by
/// account id, as anchors the panel resolves into its own space. The usage tab's scroll view adds
/// its own visible frame under `area` (B-3823), so the bubble can be drawn over the whole panel and
/// still be placed in the scroll area's space.
struct PanelHintTargetKey: PreferenceKey {
    /// Never an account id: ids are provider identifiers, none starts with a NUL.
    static let area = "\u{0}scroll-area"
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// The first hint, drawn over the whole panel body (header, scroll area, footer) and pointing at the
/// first meter on screen. It reports no size to anyone, so the panel is exactly as tall with the
/// hint as without it (B-3823): when the scroll area is too short for the bubble, the bubble spills
/// over the footer or the header instead of growing the panel.
struct PanelHintBubbleOverlay: View {
    let store: UsageStore
    /// Each account's first meter, plus the usage tab's scroll area under `PanelHintTargetKey.area`.
    let targets: [String: Anchor<CGRect>]

    @State private var bubbleHeight: CGFloat = 0
    private let memory = PanelHintMemory.shared

    private var shows: Bool {
        if let held = PanelHintMemory.preview { return held == .bubble && !memory.seen }
        return PanelHints.showsBubble(seen: memory.seen, hasData: store.accounts.contains { !$0.metrics.isEmpty })
    }

    var body: some View {
        GeometryReader { proxy in
            let shown = shows ? firstVisibleMeter(in: proxy) : nil
            ZStack(alignment: .topLeading) {
                if let shown {
                    let tipX = shown.meter.minX + AccountListRowView.barWidth / 2
                    let x = min(max(tipX - 44, 12), max(12, proxy.size.width - 12 - PanelHintBubble.width))
                    PanelHintBubble(arrowX: tipX - x, arrowAtBottom: shown.placement.above) { memory.markSeen() }
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { bubbleHeight = $0 }
                        .offset(x: x, y: shown.areaTop + shown.placement.y)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The first bar in view: the topmost row, the leftmost within it, so a regrouped or flat list
    /// is read the way the eye reads it. Bars scrolled out of the scroll area are skipped. No scroll
    /// area (another tab is up) means no bubble.
    private func firstVisibleMeter(in proxy: GeometryProxy)
        -> (meter: CGRect, placement: PanelHints.BubblePlacement, areaTop: CGFloat)? {
        guard let areaAnchor = targets[PanelHintTargetKey.area] else { return nil }
        let area = proxy[areaAnchor]
        let meters: [CGRect] = targets.filter { $0.key != PanelHintTargetKey.area }.values.map { proxy[$0] }
        let reading: [CGRect] = meters.sorted { (a: CGRect, b: CGRect) -> Bool in
            abs(a.minY - b.minY) > 1 ? a.minY < b.minY : a.minX < b.minX
        }
        for rect in reading {
            let inArea = rect.offsetBy(dx: 0, dy: -area.minY)
            if let placement = PanelHints.bubblePlacement(meter: inArea, bubbleHeight: bubbleHeight,
                                                          viewport: area.size, margin: 12,
                                                          headroom: area.minY,
                                                          overhang: proxy.size.height - area.maxY) {
                return (rect, placement, area.minY)
            }
        }
        return nil
    }
}

/// The mark both first-run hints share: a solid brand dot with an ink glyph inside it. Ink, not
/// brand-on-tint: green glyphs on a pale green dot measured 1.8:1.
struct PanelHintGlyph<Glyph: View>: View {
    let diameter: CGFloat
    @ViewBuilder let glyph: () -> Glyph

    /// The system's own near-black (#1D1D1F), held constant in both appearances because it sits on
    /// the brand green, not on the panel. A neutral, not a new brand colour.
    static var ink: Color { Color(red: 0.114, green: 0.114, blue: 0.122) }

    var body: some View {
        Circle().fill(TallyColor.brand)
            .frame(width: diameter, height: diameter)
            .overlay { glyph().foregroundStyle(Self.ink) }
            .accessibilityHidden(true)
    }
}

/// Three bars of different lengths, standing for the meters the bubble explains.
private struct PanelHintBars: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Capsule().frame(width: 9, height: 2)
            Capsule().frame(width: 7, height: 2)
            Capsule().frame(width: 4.5, height: 2)
        }
        .offset(x: -0.5)
    }
}

/// The neutral button both hints use: grey fill, hairline edge, the callout radius.
struct PanelHintButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 12.5

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: TallyMetrics.calloutRadius, style: .continuous)
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: TallyMetrics.hairline))
            .contentShape(shape)
    }
}

/// The first hint: a frosted bubble (material under a 92% window-colour wash, hairline edge, two
/// shadows) whose arrow points up at the meter it explains. On a dark glass panel it is solid black
/// instead (see the background).
private struct PanelHintBubble: View {
    static let width: CGFloat = 250
    /// The bubble's fill on a dark glass panel (see the background below).
    static let darkGlassFill = Color.black

    /// The arrow's centre, from the bubble's leading edge.
    let arrowX: CGFloat
    /// True when the bubble sits above its meter (B-4112): the arrow is on the bottom edge.
    let arrowAtBottom: Bool
    let onGotIt: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tallyCardStyle) private var cardStyle

    var body: some View {
        let shape = PanelHintBubbleShape(arrowX: arrowX, arrowAtBottom: arrowAtBottom)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PanelHintGlyph(diameter: 18) { PanelHintBars() }
                Text(L("What's left, per account")).font(.system(size: 13, weight: .semibold))
            }
            Text(L("The bars show how much of the 5-hour and weekly limits is left, and when each one refills."))
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onGotIt) { Text(L("Got it")) }
                .buttonStyle(PanelHintButtonStyle())
                .padding(.top, 6)
        }
        .padding(14)
        .padding(arrowAtBottom ? .bottom : .top, PanelHintBubbleShape.arrow.height)
        .frame(width: Self.width, alignment: .leading)
        .background {
            if colorScheme == .dark && cardStyle != .solid {
                // Dark glass follows the desktop, from 28.5 over black to 175.6 over white (B-3747 probe):
                // every fixed grey that copy stays readable on falls inside that range somewhere. Black
                // sits below the darkest glass and keeps each line of copy above 6:1.
                shape.fill(Self.darkGlassFill)
            } else {
                shape.fill(.regularMaterial)
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                // Dark: the wash alone is the panel's own near-black, so lift the bubble one step above it.
                if colorScheme == .dark { shape.fill(Color.white.opacity(0.10)) }
            }
        }
        .overlay { shape.stroke(colorScheme == .dark ? Color.white.opacity(0.22) : Color.primary.opacity(0.08), lineWidth: TallyMetrics.hairline) }
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
    }
}

/// One outline for body and arrow, so the hairline edge does not break at the join.
private struct PanelHintBubbleShape: Shape {
    /// The arrow's centre, from the bubble's leading edge.
    var arrowX: CGFloat
    /// Drawn with the arrow on the top edge, then mirrored when it belongs on the bottom one.
    var arrowAtBottom = false
    static let arrow = CGSize(width: 16, height: 8)

    func path(in rect: CGRect) -> Path {
        let up = upPath(in: rect)
        guard arrowAtBottom else { return up }
        return up.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY))
    }

    private func upPath(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + Self.arrow.height,
                          width: rect.width, height: rect.height - Self.arrow.height)
        let r = TallyMetrics.cardRadius
        // Keep the arrow on the straight part of the top edge, clear of both corners.
        let tip = min(max(arrowX, r + Self.arrow.width / 2), rect.width - r - Self.arrow.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: body.minX + r, y: body.minY))
        p.addLine(to: CGPoint(x: body.minX + tip - Self.arrow.width / 2, y: body.minY))
        p.addLine(to: CGPoint(x: body.minX + tip, y: rect.minY))
        p.addLine(to: CGPoint(x: body.minX + tip + Self.arrow.width / 2, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// Copy with commands in it, in the one convention the catalog uses for them: a run between
/// backticks is set in the monospaced face, the rest keeps the font the caller gives the Text.
enum HintText {
    static func withCode(_ text: String, size: CGFloat) -> Text {
        var out = AttributedString()
        for (index, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            var run = AttributedString(String(part))
            if index % 2 == 1 { run.font = .system(size: size, design: .monospaced) }
            out.append(run)
        }
        return Text(out)
    }
}
