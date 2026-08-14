import Foundation

/// THE ORDER SOMEBODY PUT THE SESSION BOARD IN, as project directories rather than as cards.
///
/// The board sorts itself by state (`SessionRosterStore.sorted`: what needs somebody first), and
/// that is what it does until a card is dragged. From the first drag on, the arrangement below
/// replaces the state sort outright, blocked cards included: a waiting card already carries a red
/// dot, its state in words and its reason line, so its POSITION does not have to be a fourth
/// marker, and a board that kept re-seating the card under the pointer would not be an arrangement
/// at all.
///
/// KEYED BY THE DIRECTORY, NOT BY THE SESSION. A supervisor pid lives for one session, so an order
/// written in pids would be forgotten by tomorrow morning, which is the opposite of what dragging
/// a card is for: the user is arranging PROJECTS, and the project is what comes back next time
/// (a worktree is its own directory, so parallel lines stay separate cards). Two sessions in one
/// directory therefore share one seat on this list and keep the state sort between themselves.
///
/// KEYS RATHER THAN ROWS, so this file has nothing to say about `SessionRow` and can be reasoned
/// about (and asserted) as plain string algebra; the store maps its rows onto it
/// (`SessionRosterStore.arranged`) and the view is only the hand that calls it.
enum SessionBoardOrder {
    /// Where the arrangement is remembered, spelled ONCE. Reading and writing it are one file
    /// apart in `SettingsStore` (its `init` and a property observer), which is the shape a silent
    /// rename drifts through: a store that saved under one key and loaded another would forget
    /// every arrangement on every launch and look exactly like a board that was never dragged.
    static let defaultsKey = "sessionBoardOrder"

    /// The arrangement as it comes back from disk. Cleaned on the way in for the reason
    /// `deduped` gives: what lands here is whatever is in the user's defaults, which is not
    /// necessarily what this app last wrote there.
    static func load(from defaults: UserDefaults) -> [String] {
        deduped(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ keys: [String], to defaults: UserDefaults) {
        defaults.set(deduped(keys), forKey: defaultsKey)
    }

    /// Whether the board is in an order somebody chose. An EMPTY arrangement is the state sort,
    /// which is what makes the way back a plain erase rather than a second stored flag: two places
    /// holding "is this board arranged" is two places to disagree, and the disagreement would show
    /// as a board sorting itself by state under a control offering to sort it by state.
    static func isManual(_ manualKeys: [String]) -> Bool { !deduped(manualKeys).isEmpty }

    /// Where each arranged key sits. First mention wins, so a defaults value edited by hand into
    /// naming one project twice still yields one seat per project.
    static func ranking(_ manualKeys: [String]) -> [String: Int] {
        Dictionary(deduped(manualKeys).enumerated().map { ($1, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// The arrangement after one card is dropped past another, or nil when nothing moves.
    ///
    /// - dragged/target: the two projects, the second being the card the first was dropped onto.
    /// - listedKeys: the projects ON SCREEN, in the order they are drawn. The filter can be hiding
    ///   some of the board, and a drag can only mean something about the cards the hand can see.
    /// - boardKeys: every project on the board, in the order the board would draw them.
    /// - manualKeys: the arrangement as it stands, empty while the board is still sorting itself.
    ///
    /// PAST THE TARGET WHEN MOVING FORWARD, BEFORE IT WHEN MOVING BACKWARD, which is the reading
    /// the account cards' own drag already established (`SettingsStore.moveAccount`): always
    /// inserting AT the target's index makes a forward drop onto the next card a no-op.
    ///
    /// THE FIRST DRAG STARTS FROM WHAT IS ON SCREEN. With no arrangement yet, the keys come back
    /// in the order the board is drawing them at that moment, which is the state sort: the card
    /// the user grabbed lands where they dropped it and nothing else moves, rather than the board
    /// re-shuffling around a first key.
    ///
    /// A FILTERED DRAG IS WRITTEN BACK INTO THE WHOLE BOARD. Only the visible seats are re-filled
    /// (the same reseating `SettingsStore.applyProviderOrder` does one axis over), so the projects
    /// the filter is holding back keep the positions they had and come back where they were left.
    static func manualOrder(moving dragged: String, onto target: String,
                            listedKeys: [String], boardKeys: [String],
                            manualKeys: [String]) -> [String]? {
        let visible = deduped(listedKeys)
        guard dragged != target,
              let from = visible.firstIndex(of: dragged),
              let to = visible.firstIndex(of: target) else { return nil }
        var moved = visible
        moved.remove(at: from)
        guard let adjusted = moved.firstIndex(of: target) else { return nil }
        moved.insert(dragged, at: min(from < to ? adjusted + 1 : adjusted, moved.count))
        guard moved != visible else { return nil }
        // Everything this arrangement has ever named, then whatever the board is showing that it
        // has not: a project whose sessions have all ended keeps its seat (the whole point of
        // keying by directory), and a project seen for the first time goes to the end rather than
        // into the middle of an arrangement it was never part of.
        let universe = deduped(manualKeys + boardKeys)
        var seat = moved.makeIterator()
        let onScreen = Set(visible)
        let next = universe.map { onScreen.contains($0) ? (seat.next() ?? $0) : $0 }
        return next == deduped(manualKeys) ? nil : next
    }

    /// One entry per project, first mention winning, and nothing blank. A blank key is not a
    /// project: it is a session whose directory nobody published, and letting one in would hand
    /// every such card the same seat.
    private static func deduped(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
