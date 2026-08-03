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
        let (next, dormant) = KnownAccountLogic.advance(
            remembered: remembered,
            discovered: discovered.compactMap(KnownAccount.init),
            homeExists: Self.directoryExists)
        if next != remembered {
            remembered = next
            if let data = try? JSONEncoder().encode(next) {
                UserDefaults.standard.set(data, forKey: Self.stateKey)
            }
        }
        let revived = dormant.map(ProviderAccount.init(dormant:))
        return (discovered + revived, revived)
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
