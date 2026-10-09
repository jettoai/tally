import SwiftUI

/// THE STATUS HALF OF AN ACCOUNTS-PANE ROW, split out of SettingsAccountsView for file size: what
/// the row says about the account's login, and the two switches.
///
/// The login state takes the status column, replacing the plan and the numbers rather than crowding
/// in beside them, and each piece is a second surface for something the panel already shows. Which
/// state wins, and in which words, is decided in the files they call (AccountSignIn), never here.
extension SettingsAccountsView {
    /// The row's login state: an inline "Sign in again" in the severity colour when the account is
    /// signed out, the running renewal while one is in flight, nothing at all otherwise.
    ///
    /// The same button the card's expiry chip is, in the same colour, starting the same renewal
    /// through the same store - this list is simply the other place people look for it. Which state
    /// wins is decided in AccountSignIn.swift, so the two surfaces cannot disagree about whether an
    /// account needs signing in.
    @ViewBuilder
    func signInState(_ state: AccountSignIn.State, _ item: ProviderAccount,
                     usage: AccountUsage?) -> some View {
        let renew = RenewLoginStore.shared
        switch state {
        case .signedIn:
            EmptyView()
        case .renewing:
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text(L("Browser sign-in…"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .needsSignIn:
            Group {
                // Where no renewal can start (a demo fixture has no config home behind it) the chip
                // is a plain label rather than a disabled button: the state still has to read at
                // full contrast, and the system's disabled dimming took it to 2.4:1.
                if renew.canRenew(accountID: item.id, providerID: item.providerID,
                                  home: item.launchHome) {
                    Button { renew.renew(accountID: item.id) } label: { signInChip }
                        .buttonStyle(.plain)
                } else {
                    signInChip
                }
            }
            // Tally's own callout rather than the system box this row used to hand back: the panel
            // answers every hover in the app's own chip, and one native tooltip in the middle of a
            // pane full of them reads as a different application (owner's report, 2026-08-24). Two
            // lines, in the shape the panel's marks use: whose login it is, then what the click
            // does. The word for the state is on the second line rather than in the button, which
            // says "Sign in again" either way, and WHICH word is `AccountSignIn`'s answer rather
            // than this row's: an expired credential and a signed-out home are one offer and two
            // sentences, and the panel's own expiry mark has to tell the same one.
            .tallyTooltipAroundControl(rowOwner(item, usage: usage),
                                       detail: L(AccountSignIn.detailKey(isDormant: item.isDormant)))
        }
    }

    /// The "Sign in again" chip, in colours that hold 4.5:1 in both appearances (SettingsChrome).
    private var signInChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
            Text(L("Sign in again")).lineLimit(1)
        }
        .fixedSize()
        .font(.caption2.weight(.semibold))
        .foregroundStyle(SettingsChrome.signInText)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(SettingsChrome.signInFill))
        .contentShape(Capsule())
    }

    /// Whose row this is, in the words the row itself shows: the signed-in address when the store
    /// knows one, the display name otherwise. The first line of every callout in this list, and the
    /// same answer the panel's marks put there (`AccountFacts.markOwner`), asked of the one shared
    /// identity chain so the two surfaces cannot name an account differently.
    func rowOwner(_ item: ProviderAccount, usage: AccountUsage?) -> String {
        LoginStatusStore.shared.identityEmail(accountID: item.id, polled: usage?.accountEmail)
            ?? settings.displayLabel(accountID: item.id, fallback: item.label)
    }

    // The row's menu-bar switch, unlabelled: the card header names the column.
    //
    // DEAD IN THE POOLED LAYOUT, and said so rather than left looking alive: that segment sums
    // every account (the strip never asks this switch there - UsageStorePresentation), so a live
    // control would be a silent no-op with nothing on screen saying why. The hover carries the way
    // back; switching Display to Accounts restores it.
    func menuBarToggle(_ accountID: String) -> some View {
        let pooled = settings.menuBarLayout == .pooled
        return Toggle(isOn: Binding(
            get: { settings.isShownInMenuBar(accountID) },
            set: { settings.setShownInMenuBar(accountID, $0); UsageStore.shared.onChange?() }
        )) { EmptyView() }
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(pooled)
        // Around the control, not on it: pooled greys the switch out, and a disabled control stops
        // routing hover, which is precisely the state whose hover carries the way back.
        .tallyTooltipAroundControl(pooled
              ? L("The menu bar is pooling each provider into one segment, so it shows every account. Set Menu bar shows to Accounts in Display to pick which ones appear.")
              : L("Show in menu bar"))
    }

    /// The row's login state, both sources of "signed out" plus a renewal in flight folded into one
    /// answer (AccountSignIn.swift).
    func signInState(of item: ProviderAccount) -> AccountSignIn.State {
        AccountSignIn.state(isRenewing: RenewLoginStore.shared.isRenewing(item.id),
                            isExpired: LoginStatusStore.shared.isExpired(item.id),
                            isDormant: item.isDormant)
    }

    /// The account's own switch, mirroring the provider switch one level up: off means not polled,
    /// no card, no menu-bar segment, and the CLI skips it.
    func enabledSwitch(_ item: ProviderAccount) -> some View {
        Toggle(isOn: Binding(
            get: { settings.isAccountEnabled(item.id) },
            set: { on in
                settings.setAccountEnabled(item.id, on)
                // Optimistic, same as the provider switch.
                if on { store.showCachedAccounts(providerID: item.providerID) }
                else { store.hideAccounts { $0.id == item.id } }
                Task { await store.refresh(userInitiated: false) }
            }
        )) { EmptyView() }
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    func isPersonal(_ item: ProviderAccount) -> Bool {
        PersonalAccount.isPersonal(accountID: item.id,
                                   home: PersonalAccount.home(accountID: item.id,
                                                              launchHome: item.launchHome))
    }
}
