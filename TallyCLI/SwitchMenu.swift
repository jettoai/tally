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
    /// The label to pin, resolved by the same matcher a typed name goes through.
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

/// Read the fleet, draw the menu, and report what the user chose.
func pickSwitchTarget() -> SwitchMenuOutcome {
    let (rows, problem) = liveSwitchFleetRows()
    if let problem { warn(problem) }
    guard let rows, !rows.isEmpty else { return .unavailable }
    let frame = switchMenuFrame(rows)
    guard let selection = selectMenuRow(rows: frame.rows, action: frame.action) else {
        return .unavailable
    }
    switch selection {
    case .existing(let index):
        // The LABEL, not the id: it goes back through `accountMatching`, the one matcher every
        // typed name uses, so a pick from this menu and the same name typed by hand resolve
        // identically (AccountPick.swift).
        return .picked(rows[index].label)
    case .newWorktree:
        return .unavailable   // unreachable without an action line; never a silent wrong move
    case .cancelled:
        return .cancelled
    }
}
