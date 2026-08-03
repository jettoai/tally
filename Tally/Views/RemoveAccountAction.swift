import Foundation

/// The one confirm-and-remove behind the card's "Remove account…" entry: the account's config home
/// goes to the Trash, and every trace Tally kept of that account is forgotten with it.
///
/// Why it exists: discovery is directory-shaped, so an account only leaves Tally when its config
/// home does. Until now the only way to drop one was to go and delete `~/.claudeN` by hand, in a
/// Finder that hides dotfolders - which left signed-out accounts sitting in the list forever, and a
/// pin, a nickname and an order entry behind them when the folder finally went.
///
/// Tally removes the DIRECTORY, never the account at the provider. Nothing here talks to a vendor,
/// and nothing here deletes: `trashAccountHome` moves the folder to the Trash, so the whole thing is
/// undoable from the user's own Finder.
@MainActor
enum RemoveAccountAction {
    /// The confirmation's body: what is about to move, where it is, what goes with it, and the one
    /// thing that does NOT happen (the provider account itself lives on).
    static func confirmMessage(home: String) -> String {
        [L("Tally will move this account's config folder to the Trash:") + "\n" + home,
         L("The conversations and settings in this folder will be moved to the Trash with it, so you can put them back from there."),
         L("Tally also forgets this account's name, pin and settings. The account at the provider is not touched.")]
            .joined(separator: "\n\n")
    }

    /// Ask, then remove. Everything after the question is one act: the home leaves first, and only
    /// a home that actually left is followed by forgetting the account - a card whose settings were
    /// cleared while its directory stayed would come straight back as a stranger.
    static func present(accountID: String, providerID: String, label: String, home: String) {
        // Re-asked here rather than trusted from the menu: the entry that opened this is drawn from
        // the same rule, and the main home must not be removable down any path at all.
        guard accountHomeIsRemovable(providerID: providerID, home: home),
              CentredAlert.confirm(title: "\(label) · \(L("Remove account"))",
                                   body: confirmMessage(home: home),
                                   confirmTitle: L("Move to Trash"))
        else { return }
        guard trashAccountHome(at: home) else {
            CentredAlert.notice(title: "\(label) · \(L("Remove account"))",
                                body: L("Tally could not move the config folder to the Trash.")
                                    + " " + home)
            return
        }
        // The three places an account id survives its directory: the launch policy the `tally` CLI
        // reads, the memory that keeps signed-out accounts listed, and the user's own per-account
        // settings. All of them are keyed by an id derived from the folder name, so a later
        // `~/.claude3` would inherit whatever is left here.
        LaunchPolicyStore.shared.forget(accountID: accountID)
        KnownAccountsStore.shared.forget(accountID: accountID)
        SettingsStore.shared.forgetAccount(accountID)
        // The fourth place, and the only one that is not on disk: the store's own per-account
        // caches. It drops the card in this frame, forgets the last-good numbers (a recreated
        // `~/.claude3` is `claude:.claude3` again, and its first failed fetch would otherwise be
        // filled in with THIS account's quota), and tombstones the id so a refresh that started
        // before the removal cannot publish it back.
        UsageStore.shared.forgetAccount(accountID)
        Task { await UsageStore.shared.refresh(userInitiated: true) }
    }
}
