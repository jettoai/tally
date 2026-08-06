import Foundation

// `tally hook-switch`: the decision that makes `/tally-switch` cost nothing in either shape
// (SwitchHook.swift). Claude Code fires the hook before any model is woken and hands it the
// invocation as JSON on stdin; exiting 2 stops the expansion there.
//
// So the hook is one question asked of a payload this code does not own, and the two answers are
// not "success" and "failure":
//
//   .queue   an account was named: queue the move, and stop the prompt (exit 2). Free.
//   .list    anything else: print the fleet from the snapshot, and stop the prompt. Free too.
//
// Anything unrecognisable lands on .list rather than on a guess: a list is the right answer under
// every one of those, while a wrong .queue would move a session to an account nobody named. Neither
// answer spends a turn, which is the whole point - the usual reason to move accounts is that this
// one has no model left to answer with.
//
// The rest of the file holds what both manual-pick surfaces read (`switchFleetRows`, shared with the
// arrow-key menu in SwitchMenu.swift), the text the hook prints from it, and which of `tally
// switch`'s three surfaces an invocation lands on.
func runSwitchHookChecks() {
    func payload(_ fields: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }

    // The shape Claude Code actually sends, fields and all: the name is taken from `command_args`
    // and nothing else in the payload changes the answer.
    check("a named account is queued, from the real payload shape",
          hookSwitchAction(payload(["hook_event_name": "UserPromptExpansion",
                                    "command_name": "tally-switch",
                                    "command_args": "Claude 4",
                                    "session_id": "abc",
                                    "cwd": "/Users/x/workspace/tally"]))
              == .queue("Claude 4"))
    // Passed on exactly as typed. Claude Code has already done its own quote handling, so a second
    // parse here would be a second, different, rule about what an account name is - and labels
    // contain spaces ("Claude 4" is one account, not two).
    check("a multi-word label survives intact",
          hookSwitchAction(payload(["command_args": "  my other account  "]))
              == .queue("my other account"))

    // Bare `/tally-switch`: the user wants to CHOOSE, and choosing is answered HERE, from the
    // snapshot, for nothing. It used to let the expansion through so a model could list the fleet -
    // which works until the moment it is needed, because the reason to move accounts is usually
    // that this account has no model left to answer with (field report, 2026-08-06: "You've reached
    // your Fable 5 limit", and the command that could have moved the session needed a turn that
    // could not be sent).
    check("no account named is answered with the fleet, not with a model turn",
          hookSwitchAction(payload(["command_args": ""])) == .list)
    check("…and so is whitespace, which is the same thing typed differently",
          hookSwitchAction(payload(["command_args": " \n\t "])) == .list)

    // Everything unrecognisable lands on the SAME branch: a payload from a future Claude Code, a
    // field that changed type, an empty stdin because nothing was piped at all. A list is useful
    // under every one of those, and it is free - which a turn that may not be sendable is not.
    check("a payload without the field lists too",
          hookSwitchAction(payload(["command_name": "tally-switch"])) == .list)
    check("a field of the wrong type lists too",
          hookSwitchAction(payload(["command_args": 42])) == .list)
    check("stdin that is not JSON lists too", hookSwitchAction("not json at all") == .list)
    check("empty stdin lists too", hookSwitchAction("") == .list)
    check("JSON that is not an object lists too",
          hookSwitchAction("[\"Claude 4\"]") == .list)

    // MARK: - The fleet as a manual pick reads it

    func fleetAccount(_ id: String, label: String, session: Double, weekly: Double, model: Double,
                      window: String? = "fable", signedOut: Bool = false) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label,
                         launchHome: signedOut ? nil : "/tmp/\(id)", sessionRemaining: session,
                         weeklyRemaining: weekly, modelRemaining: model, sessionResetsAt: nil,
                         weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: window,
                         resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    let fleet = [
        fleetAccount("drained", label: "Claude 1", session: 40, weekly: 30, model: 2),
        fleetAccount("roomy", label: "Claude 2", session: 90, weekly: 80, model: 70),
        fleetAccount("middling", label: "Claude 3", session: 60, weekly: 55, model: 50),
        // Listed with no launch home: Tally saying that login is gone. Naming it would queue a move
        // that can never happen, so it is not on the menu at all.
        fleetAccount("dormant", label: "Claude 4", session: 99, weekly: 99, model: 99,
                     signedOut: true),
    ]
    let rows = switchFleetRows(accounts: fleet, provider: "claude", current: "roomy")
    check("only accounts a session could land on are offered",
          rows.map(\.id) == ["roomy", "middling", "drained"])
    check("the windows read in the vocabulary `tally status` already uses",
          rows[0].windows == "session 90% · weekly 80% · fable 70%")
    check("a provider with no flagship window says so generically",
          switchFleetRows(accounts: [fleetAccount("x", label: "X", session: 10, weekly: 10,
                                                  model: 10, window: nil)],
                          provider: "claude", current: nil)[0].windows
              == "session 10% · weekly 10% · model 10%")
    // The recommendation is the best account this session is NOT on: recommending the one it is
    // already on answers a question nobody asked.
    check("the account the session is on is marked, and not recommended",
          rows[0].tags == ["this session"])
    check("…so the recommendation is the best of the others",
          rows[1].tags == ["most headroom"] && rows[2].tags.isEmpty)
    check("with nowhere else to go, the only account is still recommended",
          switchFleetRows(accounts: [fleet[1]], provider: "claude",
                          current: "roomy")[0].tags == ["this session", "most headroom"])
    check("another provider's accounts are not this command's business",
          switchFleetRows(accounts: fleet, provider: "codex", current: nil).isEmpty)

    // The text form, which is all a hook has: the SAME rows the menu draws, rendered as lines.
    let listing = hookSwitchListing(rows: rows, provider: "claude")
    check("the listing opens by saying what it is",
          listing.first == "accounts you can move this session to:")
    check("…carries one line per usable account, best first",
          listing.count == 5 && listing[1].contains("Claude 2")
              && listing[1].contains("(this session)") && listing[2].contains("(most headroom)"))
    check("…and closes with both commands that act on it",
          listing.last == "pick one with `/tally-switch <name>`, or `/tally-switch --auto` to "
              + "follow automatic selection")
    // Nothing to choose from is still an answer, and both shapes of it are actionable.
    check("no snapshot names the thing to fix",
          hookSwitchListing(rows: nil, provider: "claude")
              == ["no fleet snapshot to read, so there is nothing to choose from - is Tally.app "
                  + "running? (`tally status` says what it can see)"])
    check("a fleet with no login says how to get one",
          hookSwitchListing(rows: switchFleetRows(accounts: [fleet[3]], provider: "claude",
                                                  current: nil),
                            provider: "claude")
              == ["no claude account is signed in right now, so there is nowhere to move this "
                  + "session - `tally add claude` logs one in"])

    // MARK: - The three surfaces, and which screen each of them owns

    // A named account acts, whatever the terminal is: an instruction is not a question.
    check("a named account never opens a menu",
          switchEntry(["Claude 4"], interactive: true) == .act(.pin("Claude 4"))
              && switchEntry(["Claude 4"], interactive: false) == .act(.pin("Claude 4")))
    check("…and neither does --auto", switchEntry(["--auto"], interactive: true) == .act(.auto))
    // Bare, with a human at a keyboard: the fleet as a menu.
    check("bare in a terminal offers the fleet", switchEntry([], interactive: true) == .menu)
    // Bare in a pipe: exactly what scripts have always got. A script that meets an arrow-key menu
    // hangs, which is a worse answer than the usage text it was written against.
    check("bare in a pipe still prints the usage text",
          switchEntry([], interactive: false) == .usage)
    // An argument list this command cannot act on is a refusal WITH SOMETHING TO SAY; answering it
    // with a menu would hide the mistake instead of naming it.
    check("a contradictory line is refused rather than turned into a menu",
          switchEntry(["--auto", "Claude 4"], interactive: true) == .usage)
    check("…as is an unknown flag, and two names",
          switchEntry(["--wat"], interactive: true) == .usage
              && switchEntry(["Claude 4", "Claude 2"], interactive: true) == .usage)

    // The menu rows are the SAME reading, mapped onto the worktree menu's row shape: the label
    // leads, the windows sit where an age would, the tags where a commit subject would, and nothing
    // is ever dirty.
    let frame = switchMenuFrame(rows)
    let menu = frame.rows
    // The difference between this menu and the worktree one it shares a component with. Held here
    // because the call site that draws it needs a terminal, and this is the value it draws with.
    check("the account picker offers no \"new worktree\" line to create", frame.action == nil)
    check("the picker draws the fleet reading, in the same order",
          menu.map(\.branch) == ["Claude 2", "Claude 3", "Claude 1"])
    check("…with the windows and the tags carried through",
          menu[0].age == rows[0].windows && menu[0].subject == "this session"
              && menu[1].subject == "most headroom" && menu[2].subject.isEmpty)
    check("…and no yellow dirty marker, which means nothing here",
          menu.allSatisfy { !$0.dirty })
    // The account picker has no "new" affordance, so the key that would commit one does nothing and
    // the highlight wraps over the rows alone.
    check("without an action line, enter on the last row picks that row",
          applyKey(.enter, highlighted: 2, rowCount: 3, hasAction: false).selection == .existing(2))
    check("…the new-worktree key commits nothing",
          applyKey(.newKey, highlighted: 0, rowCount: 3, hasAction: false).selection == nil)
    check("…and the highlight wraps over the rows alone",
          applyKey(.down, highlighted: 2, rowCount: 3, hasAction: false).highlighted == 0
              && applyKey(.up, highlighted: 0, rowCount: 3, hasAction: false).highlighted == 2)
    check("…while the worktree menu keeps its trailing line",
          applyKey(.down, highlighted: 2, rowCount: 3).highlighted == 3)
    check("a menu with no action line draws only its rows",
          renderRows(menu, highlighted: 0, action: nil).count == menu.count
              && renderRows(menu, highlighted: 0).count == menu.count + 1)

    // MARK: - The outcome both surfaces share

    // `SwitchAttempt` exists so the CLI and the hook cannot disagree about what happened. The exit
    // code is the part the hook does NOT use (it always exits 2, having said its piece), so it is
    // pinned here for the command that does.
    check("a refusal is a non-zero exit",
          SwitchAttempt(result: .refused, message: "no").exitCode == 1)
    check("a queued move is a zero exit",
          SwitchAttempt(result: .queued, message: "queued").exitCode == 0)
    // Not a failure and not a move: the session is where it was asked to be. `tally switch` has
    // always exited 0 for this, and a hook that reported it as an error would teach the user their
    // command is broken.
    check("being there already is a zero exit too",
          SwitchAttempt(result: .alreadyThere, message: "already on B").exitCode == 0)
}
