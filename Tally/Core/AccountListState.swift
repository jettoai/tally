import Foundation

/// What a list of a provider's accounts should draw when it is holding no rows.
///
/// An empty list is two different answers wearing the same face: "this machine has no signed-in
/// accounts" and "nobody has looked yet". The Settings account list read it as the first one, so a
/// cold start - which every self-update performs, and which is exactly when somebody opens Settings
/// to see what survived - flashed "No signed-in accounts found" at a user with five of them.
///
/// Which one it is cannot be derived from the rows: it takes a fact only the store has, whether a
/// discovery pass has finished at all (`UsageStore.hasDiscovered`). Discovery lands at the END of a
/// refresh round, behind every provider CLI the round polls, so on a cold start the empty stretch
/// is seconds long rather than a frame.
enum AccountListState: Equatable {
    /// No pass has finished yet: the list knows nothing, and must not say anything that reads as
    /// an answer.
    case discovering
    /// A pass finished and found nothing - the negative sentence is now true.
    case empty
    /// There are accounts to draw.
    case populated

    static func resolve(hasDiscovered: Bool, accountCount: Int) -> AccountListState {
        // Rows in hand outrank the flag. A set can arrive by a route that is not a refresh (the
        // config-dir watcher adopts one on every event), and accounts already on screen must never
        // be withheld pending a formality.
        if accountCount > 0 { return .populated }
        return hasDiscovered ? .empty : .discovering
    }
}
