import Foundation

extension AddAccountStore {
    /// Why a login that just landed in a NEW Claude home is not a new account: its identity is one
    /// an existing home already holds (B-4530). The browser answers the OAuth round trip with
    /// whoever it is signed in as, so adding an account while already signed into one Tally has
    /// used to be announced as "Account added" and read as a duplicate row a poll later. nil when
    /// it is genuinely new, or when the home has not said who is in it (`oauthAccount` lands after
    /// the credential, so it is waited for first, RenewalIdentity.landedIdentity).
    static func duplicateLoginReason(providerID: String, dir: URL) async -> String? {
        guard providerID == ClaudeAccounts.providerID else { return nil }
        let landed = await RenewalIdentity.landedIdentity(expected: nil, before: nil) {
            let who = ClaudeAccounts.profile(configDir: dir.path)
            return (RenewalIdentity.Who(email: who.email, uuid: who.accountUUID), nil)
        }
        let others = UsageStore.shared.discoveredAccounts.filter {
            $0.providerID == providerID && $0.launchHome != dir.path
        }
        let homes = others.compactMap { account in
            account.launchHome.map {
                SharedLogin.Home(id: account.id,
                                 identity: ClaudeAccounts.profile(configDir: $0).accountUUID)
            }
        }
        guard let clash = SharedLogin.homes(sharing: landed?.uuid, among: homes).first,
              let account = others.first(where: { $0.id == clash }) else { return nil }
        let name = SettingsStore.shared.displayLabel(accountID: account.id, fallback: account.label)
        return String(format: L("This sign-in is the same account as %@, which Tally already has. Sign in with an account that is not in Tally yet."), name)
    }

    static func reason(_ error: Error) -> String {
        switch error as? AddAccountFailure {
        case .noFreeSlot:
            return L("Every numbered account folder for this provider already has a login.")
        case .couldNotCreateHome(let path):
            return L("Tally could not create the account folder") + " (\(path))."
        case nil:
            return L("Tally could not prepare an account folder for the new account.")
        }
    }
}
