import SwiftUI

/// Distinct, actionable empty states shared by the popover and dashboard. Each says what's actually
/// wrong and offers the next step, instead of one generic "no accounts" message.
struct EmptyStateView: View {
    let state: UsageStore.ContentState

    var body: some View {
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
        case .loading: return "hourglass"
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
