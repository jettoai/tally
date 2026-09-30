import Foundation

/// Persists the accounts Tally has seen signed in (`KnownAccounts.swift`), so a logout leaves a
/// dormant account behind rather than nothing at all.
///
/// Persisted rather than held in memory because the app restarts - every update relaunches it - and
/// an account that signed out before the last quit would otherwise be exactly as invisible as it
/// was before any of this existed.
@MainActor
final class KnownAccountsStore {
    static let shared = KnownAccountsStore()

    private static let stateKey = "ai.jetto.tally.knownAccounts"

    /// Read once and then kept, so the reconciliation that runs on every filesystem event does not
    /// decode the list each time.
    private lazy var remembered: [KnownAccount] = Self.load()

    private init() {}

    /// Record what discovery found this round and answer with every account this machine HAS:
    /// `all` is discovery plus the dormant ones, `dormant` just the accounts that are signed out
    /// but still here. Both come from one call so no caller has to remember to add them back.
    ///
    /// A dormant account carries its config home, which is what lets the login probe ask about it
    /// and "Renew login" act on it.
    ///
    /// Cheap enough for the watcher's path: one directory check per remembered account that is not
    /// currently discoverable, and a write only when the answer actually changed. The pending-add
    /// markers and the onboarding note are not handled here: both are filesystem work, done by
    /// `clearPendingMarkers` off the main thread (Sentry TALLY-38, main thread in `lstat`/`unlink`).
    func reconcile(discovered: [ProviderAccount])
        -> (all: [ProviderAccount], dormant: [ProviderAccount]) {
        let (next, dormant) = KnownAccountLogic.advance(
            remembered: remembered,
            discovered: discovered.compactMap(KnownAccount.init),
            homeExists: Self.directoryExists)
        if next != remembered {
            remembered = next
            persist(next)
        }
        let revived = dormant.map(ProviderAccount.init(dormant:))
        return (discovered + revived, revived)
    }

    /// Take the pending-add marker out of every discovered home that still has one, answering with
    /// the accounts whose marker was actually removed. Nonisolated so the callers can run it beside
    /// the discovery it follows, off the main thread.
    ///
    /// Discovery is credential-shaped, so every account in here is one Tally can SEE signed in -
    /// which is exactly the moment the home stops being an unfinished "Add account" attempt.
    /// Clearing the marker here rather than in the add flow covers the surface that cannot do it
    /// itself: `tally add` execs the provider's login over its own process and never comes back.
    /// A marker left behind would make this home look reusable again the day its login expires,
    /// which is the bug the slot rule exists to close (Tally/Core/AddAccount.swift).
    ///
    /// A marker that was still there is Tally's own note that it CREATED this home, and clearing it
    /// is the login landing. That pair of facts is the one moment the first-run wizard's note has
    /// to be put in (ClaudeOnboarding.swift): the add flow writes it too, but not every login comes
    /// back through the add flow - one handed to a Terminal window finishes where Tally cannot
    /// watch, and unless the user then says so in the sheet, this is the only surface that ever
    /// hears about it. Asking the clear rather than the directory is also what keeps the write off
    /// every home that was not pending, and off this one on every later round. The note is written
    /// right here, beside the clear, so no caller can drop it between the two (a watcher pass that
    /// loses to a newer adopt would otherwise have spent the marker and skipped the note).
    ///
    /// A build nobody installed does none of it. The marker is a file in a provider config home and
    /// the onboarding note is a key inside the user's `~/.claude.json`, and this runs before
    /// anything else in a refresh round, so gating further down the round would have let a locally
    /// built Release edit the installed app's config homes on every poll while looking gated
    /// (`isUnshipped`, codex review of e7fe1a0). Gated HERE rather than at the caller because three
    /// paths reach it - the refresh, the account watcher, and the launch-time
    /// `discoveredAccountsNow` - and a gate per caller is three chances to forget the fourth.
    /// `unshipped` exists for the test harness, whose bare binary always reads as unshipped.
    @discardableResult
    nonisolated static func clearPendingMarkers(_ discovered: [ProviderAccount],
                                                unshipped: Bool = BuildVariant.isUnshipped)
        -> [ProviderAccount] {
        discovered.filter { account in
            guard !unshipped, let home = account.launchableHome,
                  clearAddAccountPendingMarker(in: URL(fileURLWithPath: home)) else { return false }
            markClaudeOnboardingComplete(providerID: account.providerID, home: home)
            return true
        }
    }

    /// Discovery and the sweep that follows it, as one pass for the callers' detached tasks.
    nonisolated static func discoverClearingMarkers(_ providers: [any UsageProvider])
        -> [ProviderAccount] {
        let found = providers.flatMap { $0.discoverAccounts() }
        clearPendingMarkers(found)
        return found
    }

    /// Drop one account from the memory outright - the user REMOVED it (its config home went to the
    /// Trash, see RemoveAccountAction).
    ///
    /// The reconciliation above would forget it on its own the next time it ran, because the home is
    /// no longer on disk. Doing it here as well is what keeps the card from coming back as a dormant
    /// account in the moments between the removal and that next pass.
    func forget(accountID: String) {
        let next = remembered.filter { $0.id != accountID }
        guard next != remembered else { return }
        remembered = next
        persist(next)
    }

    /// In memory for everyone, on disk only for the app that owns the state. A build nobody
    /// installed carries the release bundle id, so this defaults domain is the INSTALLED app's: a
    /// test window polling beside it would otherwise teach the real app which accounts exist, and
    /// dormancy is exactly the kind of answer that must not come from a second poller.
    private func persist(_ accounts: [KnownAccount]) {
        guard !BuildVariant.isUnshipped else { return }
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    private static func load() -> [KnownAccount] {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let accounts = try? JSONDecoder().decode([KnownAccount].self, from: data)
        else { return [] }
        return accounts
    }

    /// A directory, specifically. A file left where a config home used to be is not an account
    /// waiting to be signed back into.
    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
