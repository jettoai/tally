import Foundation

/// The accounts the user has REMOVED, and the refreshes that must not bring them back.
///
/// A refresh that began before the removal captured its discovery, its launch homes and (for the
/// slow half) its provider fetches while the config home was still on disk. Committing that round
/// unchanged re-remembers the account, redraws its card, and publishes a snapshot pointing the
/// `tally` CLI at a directory that is now in the Trash - until a later round happens to correct it.
/// So a removal leaves a tombstone behind, and every round filters what it found through the
/// tombstones before committing anything.
///
/// The tombstone is deliberately not permanent. An account id is derived from the config home's
/// name, so a recreated `~/.claude3` IS `claude:.claude3` again, and a tombstone that never expired
/// would make that new account invisible forever. It lasts exactly until a round that STARTED after
/// the removal commits: that round's discovery ran against a filesystem without the home, so
/// whatever it found is news rather than an echo.
///
/// Pure and Foundation-only, so the ordering rules are assertable without a store, a refresh or a
/// filesystem.
struct AccountRemovals: Equatable {
    /// How many rounds have begun. Only the ORDER matters - a round compares its own number against
    /// the number a tombstone was filed under.
    private(set) var epoch = 0
    private var tombstones: [String: Int] = [:]

    /// Every account currently tombstoned, for the one filtering pass a round makes.
    var removedIDs: Set<String> { Set(tombstones.keys) }

    func isRemoved(_ accountID: String) -> Bool { tombstones[accountID] != nil }

    /// A round begins. The number it answers with is what it must hand back to `endRound`.
    mutating func beginRound() -> Int {
        epoch += 1
        return epoch
    }

    /// The user removed this account. Filed against the round in flight (or the last one that ran,
    /// when nothing is in flight), which is what decides how long the tombstone has to live.
    mutating func remove(_ accountID: String) { tombstones[accountID] = epoch }

    /// A round committed. Tombstones filed BEFORE it began have done their work: this round already
    /// discovered the world without them.
    mutating func endRound(_ round: Int) { tombstones = tombstones.filter { $0.value >= round } }
}
