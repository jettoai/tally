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
    /// `-TallyPanelHintPreview hint|invite`: Dev builds and demo data only, like every capture flag.
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

/// Where the two nudges sit: under the account cards, in the panel's scrolling region. One view for
/// both because the invite reads what the panel looked like WHEN IT APPEARED (see
/// `PanelHints.showsInvite`), and two siblings would each have to take that snapshot in an order
/// nothing guarantees.
struct PanelHintsSection: View {
    let store: UsageStore
    /// The scrolling region's width, which decides how far in the bubble's arrow can sit.
    let width: CGFloat

    private let memory = PanelHintMemory.shared
    @State private var seenAtAppear = false
    @State private var opensAtAppear = 0
    @State private var commandAbsentAtAppear = false
    @State private var countedThisAppearance = false
    private let integrations = IntegrationsStore.shared

    private var hasReading: Bool { store.accounts.contains { !$0.metrics.isEmpty } }

    private var bubbleShows: Bool {
        if let held = PanelHintMemory.preview { return held == .bubble && !memory.seen }
        return PanelHints.showsBubble(seen: memory.seen, hasData: hasReading)
    }

    private var inviteShows: Bool {
        if let held = PanelHintMemory.preview { return held == .invite && !memory.inviteDismissed }
        return PanelHints.showsInvite(
            seenAtAppear: seenAtAppear, opensAtAppear: opensAtAppear, dismissed: memory.inviteDismissed,
            commandAbsent: commandAbsentAtAppear && integrations.cliToolPresence == .absent,
            hasClaudeAccount: store.accounts.contains { $0.providerID == "claude" })
    }

    var body: some View {
        VStack(spacing: 0) {
            if bubbleShows {
                PanelHintBubble(inset: max(12, width - 250 - 126)) { memory.markSeen() }
            }
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

/// The first hint: a blue bubble whose arrow points up at the account row above it.
private struct PanelHintBubble: View {
    let inset: CGFloat
    let onGotIt: () -> Void

    private let blue = Color(nsColor: .systemBlue)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BubbleArrow().fill(blue).frame(width: 16, height: 8).padding(.leading, 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("What's left, per account")).font(.system(size: 13, weight: .semibold))
                Text(L("The bars show how much of the 5-hour and weekly limits is left, and when each one refills."))
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onGotIt) {
                    Text(L("Got it")).font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.22)))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: 250, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(blue))
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.leading, inset)
        .padding(.top, -6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BubbleArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
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
