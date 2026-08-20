import SwiftUI

/// THE STATUS HALF OF AN ACCOUNTS-PANE ROW, split out of SettingsAccountsView for file size: what
/// the row says about the account's login, its live quota, and the one switch that is about the menu
/// bar rather than about the account.
///
/// They travel together because they occupy ONE strip of the row - the line under the address, where
/// a login problem replaces the plan and the numbers rather than crowding in beside them - and
/// because each is a second surface for something the panel already shows. Which state wins, and in
/// which words, is decided in the files they call (AccountSignIn, UsageFormat), never here.
extension SettingsAccountsView {
    /// The row's login state: an inline "Sign in again" in the severity colour when the account is
    /// signed out, the running renewal while one is in flight, nothing at all otherwise.
    ///
    /// The same button the card's expiry chip is, in the same colour, starting the same renewal
    /// through the same store - this list is simply the other place people look for it. Which state
    /// wins is decided in AccountSignIn.swift, so the two surfaces cannot disagree about whether an
    /// account needs signing in.
    @ViewBuilder
    func signInState(_ state: AccountSignIn.State, _ item: ProviderAccount) -> some View {
        let renew = RenewLoginStore.shared
        switch state {
        case .signedIn:
            EmptyView()
        case .renewing:
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text(L("renewing login…"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .needsSignIn:
            Button { renew.renew(accountID: item.id) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                    Text(L("Sign in again")).lineLimit(1)
                }
                .fixedSize()
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TallyColor.critical)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(TallyColor.critical.opacity(0.15)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // Greyed where the menu entry is: a demo fixture has no config home behind it, so a
            // chip must never look more able than the action it starts.
            .disabled(!renew.canRenew(accountID: item.id, providerID: item.providerID,
                                      home: item.launchHome))
            .help(L("Sign in again to bring this account's usage back."))
        }
    }

    /// "● 98% · ● 71%" - session then weekly, dot coloured by the window's severity. Compact
    /// (no window names): the row also carries reorder arrows and two switches, and the full
    /// labels truncated; hover explains each value.
    func liveStatus(_ account: AccountUsage) -> some View {
        HStack(spacing: 8) {
            ForEach(account.metrics.filter { !$0.isModelScoped }.prefix(2)) { metric in
                HStack(spacing: 3) {
                    Circle().fill(metric.severity.color).frame(width: 5, height: 5)
                    Text(UsageFormat.percent(metric, mode: settings.displayMode))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("\(L(metric.label)) \(UsageFormat.percent(metric, mode: settings.displayMode)) \(UsageFormat.modeWord(settings.displayMode))")
            }
        }
    }

    // A labeled mini switch: an icon-only toggle here read as "no idea what this does".
    //
    // DEAD IN THE POOLED LAYOUT, and said so rather than left looking alive: that segment sums
    // every account (the strip never asks this switch there - UsageStorePresentation), so a live
    // control would be a silent no-op with nothing on screen saying why. The hover carries the way
    // back; switching Display to Accounts restores it.
    func menuBarToggle(_ accountID: String) -> some View {
        let pooled = settings.menuBarLayout == .pooled
        return HStack(spacing: 6) {
            Text(L("Menu bar")).font(.caption).foregroundStyle(.secondary)
                .opacity(pooled ? 0.55 : 1).fixedSize()
            Toggle(isOn: Binding(
                get: { settings.isShownInMenuBar(accountID) },
                set: { settings.setShownInMenuBar(accountID, $0); UsageStore.shared.onChange?() }
            )) { EmptyView() }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(pooled)
        }
        .help(pooled
              ? L("The menu bar is pooling each provider into one segment, so it shows every account. Set Menu bar shows to Accounts in Display to pick which ones appear.")
              : L("Show in menu bar"))
    }
}
