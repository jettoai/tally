import SwiftUI

/// The roomy account row (B-1355 direction pack, `-TallySettingsDensity loose`), on Jetto Voice's
/// settings-row measure: 52pt minimum, 20pt sides. Line one is the name (renamed in place) with
/// the sharing mark; line two is the address, the plan and the 5-hour and weekly figures; the two
/// labelled switches and the actions button sit on the right.
extension SettingsAccountsView {
    func looseRow(_ item: ProviderAccount, usage: AccountUsage?, badge: Int?,
                  moveUp: (() -> Void)?, moveDown: (() -> Void)?) -> some View {
        let enabled = settings.isAccountEnabled(item.id)
        let signIn = signInState(of: item)
        return HStack(spacing: 12) {
            // The number stands where a Voice row has its icon, in a column every row keeps.
            ZStack {
                if let badge {
                    Circle().fill(.quaternary)
                    Text("\(badge)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                nameLine(item, showsHome: badge != nil, isPersonal: isPersonal(item))
                looseDetail(item, usage: usage, enabled: enabled, signIn: signIn)
                // Session incidents are independent of the account's local sign-in verdict.
                AccountLoginHealthView(accountID: item.id, owner: rowOwner(item, usage: usage),
                    canRenew: RenewLoginStore.shared.canRenew(accountID: item.id,
                        providerID: item.providerID, home: item.launchHome),
                    showsExpiry: signIn == .signedIn)
            }
            .layoutPriority(1)
            // Fills the row instead of sitting beside a Spacer: that spacer's minimum plus its
            // extra gap cost 24pt the address line needs ("clientacme@example.com" was cut).
            .frame(maxWidth: .infinity, alignment: .leading)

            // Always laid out (dimmed + inert when the account is off) so toggling never shifts
            // the controls around.
            menuBarToggle(item.id)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
            HStack(spacing: 6) {
                Text(L("Enabled")).font(.caption).foregroundStyle(.secondary).fixedSize()
                enabledSwitch(item)
            }
            actionsMenu(item, moveUp: moveUp, moveDown: moveDown)
        }
        .opacity(enabled ? 1 : 0.6)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    /// "alex@example.com · Max 20x · ● 98% ● 71%". A login problem REPLACES the plan and the
    /// numbers rather than crowding in beside them: those numbers are whatever was true before the
    /// credential went, and the chip is the one actionable thing on the row.
    private func looseDetail(_ item: ProviderAccount, usage: AccountUsage?, enabled: Bool,
                             signIn: AccountSignIn.State) -> some View {
        HStack(spacing: 5) {
            if let email = identityEmail(item, usage: usage) {
                // The part that gives way, from the middle so the domain survives.
                Text(email).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    .tallyTooltip(email)
                Text(verbatim: "·").fixedSize()
            }
            Group {
                if signIn != .signedIn {
                    signInState(signIn, item, usage: usage)
                } else if !enabled {
                    Text(L("Disabled")).foregroundStyle(.tertiary)
                } else if let usage {
                    if let plan = usage.planName {
                        Text(plan)
                        Text(verbatim: "·")
                    }
                    if usage.metrics.isEmpty, let error = usage.error {
                        Text(error).lineLimit(1)
                    } else {
                        liveStatus(usage, font: .system(size: 13).monospacedDigit())
                    }
                } else {
                    ProgressView().controlSize(.mini)
                    Text(L("Loading…"))
                }
            }
            .fixedSize()
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        // Constant height across every variant, so toggling never shifts the neighbours.
        .frame(height: 18, alignment: .leading)
    }
}
