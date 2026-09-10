import SwiftUI

/// The same session and deadline facts on the card, compact row and account settings.
struct AccountLoginHealthView: View {
    let accountID: String
    let owner: String
    let canRenew: Bool
    var compact = false
    var showsExpiry = true
    private var health: LoginHealthStore { .shared }

    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 5))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
        layout {
            if !health.problems(accountID).isEmpty {
                renewalMark("Session needs sign-in", icon: "person.crop.circle.badge.exclamationmark",
                            color: TallyColor.critical, deadline: nil)
            }
            if showsExpiry, let deadline = health.deadline(accountID) {
                let state = health.expiryState(accountID)
                if state == .expiring || state == .expired {
                    let title = state == .expired ? "Login expired" : "Login expires soon"
                    renewalMark(title, icon: "clock.badge.exclamationmark",
                                color: state == .expired ? TallyColor.critical : TallyColor.warning,
                                deadline: deadline)
                }
            }
        }
    }

    private func renewalMark(_ title: String, icon: String, color: Color, deadline: Date?) -> some View {
        Button {
            guard canRenew else { return }
            RenewLoginStore.shared.renew(accountID: accountID)
        } label: {
            mark(title, icon: icon, color: color)
        }
        .buttonStyle(.plain)
        .disabled(!canRenew)
        .tallyTooltipAroundControl(owner, detail:
            [L(title), deadline.map(AppLocale.shortDateTime), L("Renew login")]
                .compactMap { $0 }.joined(separator: "\n"))
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
