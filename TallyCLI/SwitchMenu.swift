import Foundation

// The arrow-key account picker behind a bare `tally switch`, drawn with the same menu component the
// worktree commands use (WorktreeMenu.swift, which draws on /dev/tty rather than stdout).
//
// FOUR WAYS IN, AND WHOSE SCREEN EACH ONE DRAWS ON, which is why this is its own file rather than a
// branch inside the hook:
//
//   tally switch <account>   act, never ask. A named account is an instruction.
//   tally switch (a tty)     the fleet as a menu, here, on the user's own terminal.
//   tally switch (a pipe)    the usage text, exactly as before: a script must not meet a menu.
//   /tally-switch            NEVER a menu. That path runs as a child of Claude Code, whose TUI owns
//                            the screen; a raw-mode menu drawn under it would fight the thing that
//                            is already drawing there. It answers with a list and a name to type
//                            (SwitchHook.swift), which needs no screen of its own.
//
// The rows, the order and the recommendation come from `switchFleetRows`, shared with that list, so
// the two surfaces cannot come to disagree about which account is the one to pick.

/// What a bare `tally switch` came to.
enum SwitchMenuOutcome: Equatable {
    /// The ACCOUNT ID of the row that was chosen (see `switchMenuPick` for why not the label).
    case picked(String)
    /// Esc, q, or Ctrl-C: the user said no, so nothing happens and nothing is printed.
    case cancelled
    /// No menu was possible (no tty, a dumb terminal, no snapshot, no signed-in account). The
    /// caller falls back to the usage text, which still tells them what to type.
    case unavailable
}

/// Everything the picker draws: the fleet rows as menu lines, and the trailing action line that goes
/// with them - of which there is none, because an account picker has nothing to create.
///
/// The two travel TOGETHER so the tty-only call site has no decision left to make, and so the
/// decision it does not make is one a test can hold: `action` is the difference between this menu
/// and the worktree one, and it cannot be asserted through a terminal nobody has in a test.
///
/// Pure, so that mapping is asserted without a terminal: the label leads, the remaining windows sit
/// in the dim parentheses the worktree menu uses for age, and the tags trail dimmed. Nothing here is
/// dirty, so the yellow marker never appears.
func switchMenuFrame(_ rows: [SwitchFleetRow]) -> (rows: [MenuRow], action: String?) {
    let lines = rows.map {
        MenuRow(branch: $0.label, age: $0.windows, dirty: false,
                subject: $0.tags.joined(separator: ", "))
    }
    return (rows: lines, action: nil)
}

/// What a chosen row means: the ACCOUNT ID that row named, and never the label it displayed.
///
/// A label would go back through `accountMatching`, which resolves a NAME: a query, answered against
/// the fleet as it stands, which may legitimately be ambiguous (AccountPick.swift). A selected row is
/// not a query, and two things follow that no amount of fixing that matcher changes. It now REFUSES
/// an ambiguous name rather than guessing at one, so two accounts carrying the same label would make
/// a picked row unresolvable - a refusal for a row the user had just pointed at. And an id cannot go
/// through it at all: an id is `<provider>:<config-dir name>`, which is neither of the two names it
/// compares.
///
/// The history is worth keeping because this surface is where it was found. On a machine whose
/// accounts are "Claude", "Claude 2", "Claude 3", "Claude 4" (this repo owner's), every label
/// contains the first, and the matcher answered with the first hit: picking the row labelled
/// "Claude" moved the session to whichever the snapshot listed first. The defect had two halves -
/// this surface throwing away an answer it was already holding, and the matcher guessing where it
/// should refuse - and they are fixed separately, because either alone leaves the other standing.
///
/// An index outside the rows is `.unavailable` rather than a crash: the caller then prints the usage
/// text, which still says what to type.
func switchMenuPick(_ rows: [SwitchFleetRow], index: Int) -> SwitchMenuOutcome {
    guard rows.indices.contains(index) else { return .unavailable }
    return .picked(rows[index].id)
}

/// The row the menu opens on: the one it recommends.
///
/// Zero is the obvious default and is wrong exactly when the fleet is healthiest. The rows are
/// sorted by headroom and the account this session is ALREADY on is excluded from the
/// recommendation (`switchFleetRows`), so whenever that account has the most room it sits at row 0
/// while the recommendation sits at row 1 - and Enter, the key a menu teaches you to press first,
/// would pick the account the user opened the menu to leave. Falls back to the first row when
/// nothing is marked, which is the behaviour every other menu here has.
func switchMenuStart(_ rows: [SwitchFleetRow]) -> Int {
    rows.firstIndex { $0.tags.contains(switchRecommendedTag) } ?? 0
}

/// Read the fleet, draw the menu, and report what the user chose.
func pickSwitchTarget() -> SwitchMenuOutcome {
    let (rows, problem) = liveSwitchFleetRows()
    if let problem { warn(problem) }
    guard let rows, !rows.isEmpty else { return .unavailable }
    let frame = switchMenuFrame(rows)
    guard let selection = selectMenuRow(rows: frame.rows, action: frame.action,
                                        selected: switchMenuStart(rows)) else {
        return .unavailable
    }
    switch selection {
    case .existing(let index):
        return switchMenuPick(rows, index: index)
    case .newWorktree:
        return .unavailable   // unreachable without an action line; never a silent wrong move
    case .cancelled:
        return .cancelled
    }
}
