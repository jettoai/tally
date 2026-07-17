import SwiftUI

/// Distinct, actionable empty states shared by the popover and dashboard. Each says what's actually
/// wrong and offers the next step, instead of one generic "no accounts" message.
struct EmptyStateView: View {
    let state: UsageStore.ContentState

    var body: some View {
        if state == .loading {
            // Skeleton cards, not a spinner: the placeholder mirrors the real card layout, so the
            // first data paint replaces grey shapes in place instead of swapping a whole screen.
            SkeletonCardsView()
        } else {
            message
        }
    }

    private var message: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if state == .allProvidersOff {
                Button(L("Open Settings")) { SettingsWindowController.shared.show() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    private var symbol: String {
        switch state {
        case .loading: return ""
        case .allProvidersOff: return "powersleep"
        case .noAccounts: return "person.crop.circle.badge.questionmark"
        case .hasAccounts: return "checkmark"
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
        case .noAccounts: return L("Sign in with a supported CLI to get started.")
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
