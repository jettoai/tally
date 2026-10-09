import SwiftUI

/// The row an account that is still being added stands in with, inside its provider's list
/// (B-1033). Drawn from `AddAccountStore.phase` alone, the one record of where the add is: while
/// the login runs it reads "Adding an account · ~/.claudeN", and when it did not land it carries the
/// flow's own reason with a retry and a way to dismiss it. Never a real account row: nothing here is
/// polled, renamed, reordered or switched, and the row goes once the phase does.
struct SettingsPendingAccountRow: View {
    let flow: AddAccountStore

    /// What the row says, or nil for the phases that have no row: nothing started, or an account
    /// that landed and is now listed as itself.
    static func content(_ phase: AddAccountPhase) -> (title: String, detail: String, failed: Bool)? {
        switch phase {
        case .idle, .added: return nil
        case .preparing: return (L("Adding an account"), L("Preparing the config home…"), false)
        case .signingIn(let name):
            return (L("Adding an account") + " · ~/\(name)",
                    L("Finish the sign-in in your browser; Tally will say when it lands."), false)
        case .pending(let name, let reason, _):
            return (L("Account not added") + " · ~/\(name)", reason, true)
        case .failed(let reason): return (L("Account not added"), reason, true)
        }
    }

    /// Whether the account this login is signing in to is already listed as itself.
    static func isListed(_ phase: AddAccountPhase, homes: [String]) -> Bool {
        guard case .signingIn(let name) = phase else { return false }
        return homes.contains { ($0 as NSString).lastPathComponent == name }
    }

    var body: some View {
        if let content = Self.content(flow.phase) {
            HStack(spacing: 10) {
                Group {
                    if content.failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(content.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(content.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                // Only where the flow itself would allow it: a Terminal window still signing in to
                // this home owns the login, and a second start here is the race the flow refuses.
                if content.failed, flow.phase.allowsNewRun {
                    Button(L("Try again")) {
                        flow.beginEntry(providerID: flow.runProviderID)
                        flow.start()
                    }
                    .controlSize(.small)
                    Button(L("Remove")) { flow.reset() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .padding(.leading, 18)
        }
    }
}
