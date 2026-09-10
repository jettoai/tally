import SwiftUI

/// The same session and deadline facts on the card, compact row and account settings.
struct AccountLoginHealthView: View {
    let accountID: String
    let canRenew: Bool
    var compact = false
    var showsExpiry = true
    private var health: LoginHealthStore { .shared }

    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 5))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
        layout {
            let problems = health.problems(accountID)
            if let first = problems.first {
                if problems.count == 1 {
                    Button { health.openSession(first.id) } label: {
                        mark("Session needs sign-in", icon: "person.crop.circle.badge.exclamationmark", color: TallyColor.critical)
                    }
                    .buttonStyle(.plain)
                    .disabled(DemoUsage.isActive)
                    .tallyTooltipAroundControl(L("A session on this account needs /login. Open that session to sign in again."))
                } else {
                    Menu {
                        ForEach(problems) { session in
                            Button((session.directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("Session"))
                                   + " · " + String(session.childPid ?? 0)) { health.openSession(session.id) }
                        }
                    } label: {
                        mark("Session needs sign-in", icon: "person.crop.circle.badge.exclamationmark", color: TallyColor.critical)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if showsExpiry, let deadline = health.deadline(accountID) {
                let state = health.expiryState(accountID)
                if state == .expiring || state == .expired {
                    let title = state == .expired ? "Login expired" : "Login expires soon"
                    Button { RenewLoginStore.shared.renew(accountID: accountID) } label: {
                        mark(title, icon: "clock.badge.exclamationmark",
                             color: state == .expired ? TallyColor.critical : TallyColor.warning)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRenew)
                    .tallyTooltipAroundControl(L(title), detail: AppLocale.shortDateTime(deadline) + "\n" + L("Renew login"))
                }
            }
        }
    }

    private func mark(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: compact ? 9 : 10))
            if !compact { Text(L(title)).lineLimit(1) }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 0 : 5).padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(compact ? 0 : 0.15)))
        .fixedSize()
        .contentShape(Rectangle())
        .accessibilityLabel(L(title))
    }
}
