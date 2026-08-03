import Foundation

/// One account Tally has seen signed in, written down so that signing OUT of it cannot make the
/// account disappear from the app entirely.
///
/// Discovery is credential-shaped on purpose: a `~/.claude*` home is an account because its
/// Keychain login exists, a `~/.codex*` home because its `auth.json` does. Which means the very
/// event the expiry alert exists to report, the credential going away, is also the event that
/// removes the account from every list Tally keeps. Nothing would be probed, no chip could light,
/// and "Renew login" would have no config home left to point at. So the accounts that WERE signed
/// in are remembered, and one whose credential is gone while its directory is still there stays on
/// as a dormant account: probed like any other, and renewable.
///
/// A directory that is GONE is the other event, and deliberately not the same one: the user removed
/// that account, so it is forgotten rather than announced as an expired login. Drawing that line is
/// the whole reason this file exists.
///
/// The memory only ever grows from accounts seen signed in, so one that was already signed out
/// before Tally first ran this code stays invisible until it has been signed in once. That is the
/// honest cost of not guessing: every other rule for "was this home ever an account?" has to read
/// leftovers in the provider's own files, which the provider is free to stop leaving behind.
struct KnownAccount: Codable, Equatable, Sendable {
    var id: String
    var providerID: String
    var label: String
    /// The CLI config home, which is both halves of the point: the directory's existence is the
    /// evidence the account was not removed, and the path itself is what a renewal points at.
    var home: String
}

/// The pure half: what the memory becomes this round, and which remembered accounts are dormant.
/// Pure so the logged-out / removed distinction can be tested without a home directory, the same
/// split as `LoginAlertLogic`.
enum KnownAccountLogic {
    /// `discovered` is what this round's credential-shaped discovery found; `homeExists` answers
    /// whether a remembered account's directory is still on disk.
    ///
    /// Discovery wins wherever the two disagree: a home that is discoverable again has been signed
    /// back into, so its label is re-read from it rather than kept from the memory.
    static func advance(remembered: [KnownAccount], discovered: [KnownAccount],
                        homeExists: (String) -> Bool)
        -> (remembered: [KnownAccount], dormant: [KnownAccount]) {
        let live = Set(discovered.map(\.id))
        let dormant = remembered.filter { !live.contains($0.id) && homeExists($0.home) }
        return (discovered + dormant, dormant)
    }
}
