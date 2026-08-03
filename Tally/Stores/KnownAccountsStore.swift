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
    /// currently discoverable, and a write only when the answer actually changed.
    func reconcile(discovered: [ProviderAccount])
        -> (all: [ProviderAccount], dormant: [ProviderAccount]) {
        // Discovery is credential-shaped, so every account in here is one Tally can SEE signed in -
        // which is exactly the moment the home stops being an unfinished "Add account" attempt.
        // Clearing the marker here rather than in the add flow covers the surface that cannot do it
        // itself: `tally add` execs the provider's login over its own process and never comes back.
        // A marker left behind would make this home look reusable again the day its login expires,
        // which is the bug the slot rule exists to close (Tally/Core/AddAccount.swift).
        for account in discovered {
            guard let home = account.launchableHome else { continue }
            clearAddAccountPendingMarker(in: URL(fileURLWithPath: home))
        }
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

    private func persist(_ accounts: [KnownAccount]) {
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
