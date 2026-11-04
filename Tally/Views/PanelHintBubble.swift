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
/// account id, as anchors the panel resolves into its own space.
struct PanelHintTargetKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// The first hint, floated over the account cards and pointing at the first meter on screen. As a
/// row of the layout its whole height was taken out of the panel and left it hollow around the
/// bubble; here it takes none. `room` reports how tall the content must be for the bubble to fit
/// inside the scroll view (which clips at the content's edge); it is 0 whenever the bubble is not
/// showing, and only matters when the content is shorter than the bubble's reach.
struct PanelHintBubbleOverlay: View {
    let store: UsageStore
    let targets: [String: Anchor<CGRect>]
    @Binding var room: CGFloat

    @State private var bubbleHeight: CGFloat = 0
    private let memory = PanelHintMemory.shared

    private var shows: Bool {
        if let held = PanelHintMemory.preview { return held == .bubble && !memory.seen }
        return PanelHints.showsBubble(seen: memory.seen, hasData: store.accounts.contains { !$0.metrics.isEmpty })
    }

    var body: some View {
        GeometryReader { proxy in
            let tip = shows ? firstMeterTip(in: proxy) : nil
            ZStack(alignment: .topLeading) {
                if let tip {
                    let x = min(max(tip.x - 44, 12), max(12, proxy.size.width - 12 - PanelHintBubble.width))
                    PanelHintBubble(arrowX: tip.x - x) { memory.markSeen() }
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { bubbleHeight = $0 }
                        .offset(x: x, y: tip.y)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: tip.map { $0.y + bubbleHeight + 12 } ?? 0, initial: true) { _, needed in room = needed }
        }
    }

    /// The bottom middle of the first bar on screen: the topmost row, the leftmost within it, so a
    /// regrouped or flat list is read the way the eye reads it.
    private func firstMeterTip(in proxy: GeometryProxy) -> CGPoint? {
        let rects = targets.values.map { proxy[$0] }
        guard let first = rects.min(by: {
            abs($0.minY - $1.minY) > 1 ? $0.minY < $1.minY : $0.minX < $1.minX
        }) else { return nil }
        return CGPoint(x: first.minX + AccountListRowView.barWidth / 2, y: first.maxY + 2)
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
/// shadows) whose arrow points up at the meter it explains.
private struct PanelHintBubble: View {
    static let width: CGFloat = 250

    /// The arrow's centre, from the bubble's leading edge.
    let arrowX: CGFloat
    let onGotIt: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = PanelHintBubbleShape(arrowX: arrowX)
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
        .padding(.top, PanelHintBubbleShape.arrow.height)
        .frame(width: Self.width, alignment: .leading)
        .background {
            shape.fill(.regularMaterial)
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            // Dark: the wash alone is the panel's own near-black, so lift the bubble one step above it.
            if colorScheme == .dark { shape.fill(Color.white.opacity(0.10)) }
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
    static let arrow = CGSize(width: 16, height: 8)

    func path(in rect: CGRect) -> Path {
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
