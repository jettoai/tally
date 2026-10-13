import Foundation

// A login that lands while the app is running (B-1702), split out of UsageStore.swift (line
// limit). Such an account is new to this launch: the Settings row says "Signing in" for it until
// its address is known, and its first failed poll retries in seconds rather than a minute.

extension UsageStore {
    /// Records the accounts a later discovery adds. The first discovery of a launch is not news:
    /// accounts that were already signed in when the app started are not logins landing now.
    func noteArrivals(_ accounts: [ProviderAccount]) {
        guard hasDiscovered else { return }
        arrivedThisLaunch.formUnion(accountsArrived(from: discoveredAccounts, to: accounts))
    }

    /// Whether this round's failures earn the quick second look (`FailureRetry`).
    func retriesSoon(_ results: [AccountUsage], streaks: [String: Int]) -> Bool {
        FailureRetry.isSoon(failed: results.filter { $0.error != nil }.map(\.id),
                            streaks: streaks, arrived: arrivedThisLaunch)
    }

    /// Who each polled account turned out to be, written down before the enabled filter can make
    /// it unaskable: only enabled accounts are polled, so this round is the only chance to learn an
    /// address that a switched-off row will still want to show (AccountIdentity.swift).
    ///
    /// Except a name the poll found after the split read nobody: the provider reads the profile
    /// again once its probe returns, so a just-landed login is named this round. Remembered now, a
    /// home signed into an existing account would read as unchanged on the next split
    /// (`SharedLogin` `identityUnchanged`) and the kept side could fall to id order. The row still
    /// shows the address; the next round's split sees it first and only then is it remembered.
    func rememberIdentities(_ rows: [AccountUsage], round: SharedLoginRound) {
        LoginStatusStore.shared.rememberIdentities(rows.filter {
            !(round.unnamedBeforePoll.contains($0.id) && $0.accountEmail != nil)
        })
    }
}
