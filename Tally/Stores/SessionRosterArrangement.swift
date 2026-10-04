import Foundation

// The board's second order, the one somebody dragged it into, split out of SessionRosterStore.swift
// for the 500-line rule. Pure functions of what they are handed (`ordered` is the shared stable
// ordering, still in that file).
extension SessionRosterStore {
    /// The board in the order somebody DRAGGED it into, given what they have arranged so far
    /// (`SessionBoardOrder`, which says why the arrangement is written in project directories).
    ///
    /// Handed the seated board and nothing else, so the two orders compose in one direction only:
    /// an empty arrangement is the seating untouched, and inside one seat - two sessions of the
    /// same project - the seating is what still separates them. The stable tie-break is what
    /// carries that, so it is not an implementation detail: rewrite it as an unstable sort and two
    /// sessions of one project start swapping places twice a second.
    ///
    /// A PROJECT NOBODY HAS ARRANGED SITS LAST, in the order it arrived in. A session started in a
    /// new checkout has to appear somewhere, and anywhere else means the board rearranging itself
    /// around a card the user never touched.
    ///
    /// `nonisolated` for the reason `sorted` is: it is a pure function of what it is handed, which
    /// is also what lets the assertion harness state the order without an app around it.
    nonisolated static func arranged(_ rows: [SessionRow], manualKeys: [String]) -> [SessionRow] {
        guard SessionBoardOrder.isManual(manualKeys) else { return rows }
        return ordered(rows, by: manualKeys, key: orderKey)
    }

    /// What a card is ARRANGED by: the directory its session runs in, which outlives the session
    /// (`SessionBoardOrder`). Nil for a session that has published no directory at all - it cannot
    /// be dragged and cannot be dropped onto, because there is nothing about it to remember.
    nonisolated static func orderKey(_ row: SessionRow) -> String? {
        guard let directory = row.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else { return nil }
        return directory
    }
}
