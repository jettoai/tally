import SwiftUI

/// Distinct, actionable empty states shared by the popover and dashboard. Each says what's actually
/// wrong and offers the next step, instead of one generic "no accounts" message.
struct EmptyStateView: View {
    let state: UsageStore.ContentState

    var body: some View {
        if state == .loading {
            // Skeleton cards, not a spinner: the placeholder mirrors the real card layout, so the
            // first data paint replaces grey shapes in place instead of swapping a whole screen.
            // Nothing in them is clickable, so the whole placeholder is a grab area: a panel that
            // was pinned while it is still fetching is otherwise held by its header alone.
            SkeletonCardsView()
                .windowDragSurface()
        } else {
            message
        }
    }

    /// The empty panel is nearly all quiet space, and on the pinned panel that space has to be
    /// somewhere a hand can hold: with no cards on screen the header was the only handle on the
    /// whole window (found reviewing 2ee0ebb). So the run of title and copy IS the grab area
    /// (`windowDragSurface`), and the one control down here stays out from under that overlay and
    /// takes the drag-or-tap variant instead - it can be pressed AND pulled. Just a title, a line
    /// and a button: the header above already carries the brand, so nothing here repeats it.
    private var message: some View {
        VStack(spacing: 8) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.horizontal, 16)
            // The bottom inset belongs to whichever of the two blocks is last, so the grab area
            // reaches the foot of the panel in the states that have no button at all.
            .padding(.bottom, hasAction ? 0 : 24)
            .windowDragSurface()
            if hasAction {
                HStack(spacing: 0) {
                    dragSlack
                    Button(actionTitle) { performAction() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        // Its own overlay, so the press decides between the click and the carry
                        // instead of the plain surface swallowing it (see `windowDragOrTap`).
                        .windowDragOrTap { performAction() }
                    dragSlack
                }
                // The fillers are greedy on both axes (they have to be, to take whatever is left
                // beside the button); this keeps that greed to the horizontal, so the row is still
                // exactly as tall as the button - the same pairing the launch strip uses.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Whether this state has a control in it, which is what decides where the bottom inset goes.
    private var hasAction: Bool { state == .allProvidersOff || state == .noAccounts }

    /// The quiet space either side of that one control. Flexible on both sides, so the button stays
    /// centred exactly where it was, and grabbable, so the row is not a dead band across the panel.
    private var dragSlack: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowDragSurface()
    }

    /// "No accounts" leads back to the welcome window (find, install, sign in), the way the menu's
    /// Welcome item does, so closing that window once is never a dead end.
    private var actionTitle: String {
        state == .noAccounts ? L("Add an Account") : L("Open Settings")
    }

    /// One implementation for the button's two entrances, so a press that turned out to be a click
    /// cannot do something other than what the button does.
    private func performAction() {
        if state == .noAccounts {
            WelcomeWindowController.shared.show()
        } else {
            SettingsWindowController.shared.show()
        }
    }

    private var title: String {
        switch state {
        case .loading: return L("Loading…")
        case .allProvidersOff: return L("All providers are off")
        case .noAccounts: return L("No signed-in accounts found")
        case .hasAccounts: return ""
        }
    }

    private var detail: String? {
        switch state {
        case .noAccounts: return L("Add a Claude or Codex account to get started.")
        case .allProvidersOff: return L("Turn a provider back on in Settings.")
        default: return nil
        }
    }
}

/// First-fetch placeholder: two grey account-card skeletons, gently pulsing. Mirrors the real
/// card anatomy (identity line, two meter rows) so the first data paint lands in place.
private struct SkeletonCardsView: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {
            card
            card
        }
        .padding(12)
        .opacity(pulse ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityLabel(L("Loading…"))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(.quaternary).frame(width: 16, height: 16)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 88, height: 11)
                Spacer()
            }
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 52, height: 8)
                    Capsule().fill(.quaternary).frame(height: 6).frame(maxWidth: .infinity)
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 32, height: 10)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.45)))
    }
}
