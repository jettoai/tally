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

    // MARK: - What the snapshot read said about ITSELF

    // The whole claim of the zero-turn path is that it answers from the file on disk. That carries
    // the obligation to say how old the file is: with Tally.app stopped, every percentage below is
    // stale and so is the recommendation drawn from them. The terminal menu has always warned; this
    // surface dropped the warning on the floor (found in review of 0.38.1's zero-turn work).
    let stale = "snapshot is 74m old - is Tally.app running?"
    let staleListing = hookSwitchListing(rows: rows, provider: "claude", problem: stale)
    check("a stale snapshot is said before the numbers it makes stale",
          staleListing.first == stale)
    check("…and the listing itself is unchanged underneath it",
          Array(staleListing.dropFirst()) == hookSwitchListing(rows: rows, provider: "claude"))
    // With no rows at all the problem IS the answer, and the more specific one: it names the age,
    // where the generic line can only guess at the cause.
    check("with nothing to rank, the problem replaces the generic line",
          hookSwitchListing(rows: nil, provider: "claude", problem: stale) == [stale])
    check("…and a signed-out fleet still says how to get a login, after it",
          hookSwitchListing(rows: [], provider: "claude", problem: stale)
              == [stale, "no claude account is signed in right now, so there is nowhere to move "
                  + "this session - `tally add claude` logs one in"])
    check("no problem adds no line",
          hookSwitchListing(rows: rows, provider: "claude", problem: nil).count == 5)

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

    // MARK: - What a chosen row means

    // THE FIX THIS SECTION EXISTS FOR. A picked row used to be reported as its LABEL and re-resolved
    // through `accountMatching`, which resolves a NAME. A typed name is a query and may be
    // ambiguous; a row somebody selected is neither, and the answer to it is already in hand.
    //
    // The fixture is this repo owner's own machine: "Claude", "Claude 2", "Claude 3". Two things
    // still follow now that the matcher itself refuses an ambiguous name rather than guessing at one
    // (AccountPick.swift): an id is not a name it accepts at all, and an ambiguous query is a
    // REFUSAL - which is an absurd answer to a row the user just pointed at. Either alone is enough
    // to keep the pick out of the matcher, and they are fixed separately because either alone would
    // otherwise leave the other standing.
    let lookalikes = [
        fleetAccount("claude:.claude2", label: "Claude 2", session: 90, weekly: 80, model: 70),
        fleetAccount("claude:.claude3", label: "Claude 3", session: 70, weekly: 60, model: 55),
        fleetAccount("claude:.claude", label: "Claude", session: 30, weekly: 25, model: 20),
    ]
    let lookalikeFleet = Snapshot(version: 2, generatedAt: Date(), accounts: lookalikes)
    let lookalikeRows = switchFleetRows(accounts: lookalikes, provider: "claude", current: nil)
    check("the row this menu draws last is the one labelled Claude",
          lookalikeRows[2].label == "Claude")
    // (That an ID is not a name the matcher accepts at all is asserted where the fixture's config
    // homes are realistic: tests/projectpolicy/matcherchecks.swift.)
    check("a name that IS ambiguous is refused, which is no answer for a chosen row",
          accountMatching("Clau", provider: "claude", in: lookalikeFleet) == .several(lookalikes))
    check("picking a row yields the account THAT ROW named",
          switchMenuPick(lookalikeRows, index: 2) == .picked("claude:.claude"))
    check("…including the first row, where the two answers happen to agree",
          switchMenuPick(lookalikeRows, index: 0) == .picked("claude:.claude2"))
    // A row index outside the list is the caller's arithmetic, not the user's: fall back to the
    // usage text rather than moving a session somewhere nobody pointed at.
    check("a row that is not there picks nothing",
          switchMenuPick(lookalikeRows, index: 3) == .unavailable
              && switchMenuPick([], index: 0) == .unavailable)
    // And the resolved id reaches the request as an id: it can never go back through the matcher,
    // which compares labels and config-dir names and would find nothing in `claude:.claude`.
    check("a resolved pick is its own intent, distinct from a typed name",
          SwitchIntent.pinAccount("claude:.claude") != SwitchIntent.pin("claude:.claude"))

    // MARK: - Where the menu opens

    // Enter is the key a menu teaches you to press first, and row 0 is the account with the most
    // room - which is the account this session is already ON whenever it is the healthiest one. The
    // menu therefore opens on the row it RECOMMENDS, not on the first one.
    let onBest = switchFleetRows(accounts: fleet, provider: "claude", current: "roomy")
    check("with the session already on the roomiest account, row 0 is not the recommendation",
          onBest[0].tags == ["this session"] && switchMenuStart(onBest) == 1)
    check("with the session elsewhere, the recommendation is row 0 and so is the highlight",
          switchMenuStart(switchFleetRows(accounts: fleet, provider: "claude",
                                          current: "drained")) == 0)
    check("nothing recommended opens on the first row",
          switchMenuStart([]) == 0)
    // The clamp the drawing code applies, asserted here because everything else about it needs a
    // real terminal and an out-of-range start would fail inside raw mode.
    check("a start index is clamped into the menu",
          menuStartIndex(selected: 9, lineCount: 3) == 2
              && menuStartIndex(selected: -1, lineCount: 3) == 0
              && menuStartIndex(selected: 0, lineCount: 0) == 0)

    // MARK: - Which session a manual-pick surface is describing

    // The two halves of one command have to agree on this. The half that WRITES the request has
    // always gone through `sessionLookup`, so it finds the single supervisor running in this
    // directory even with no marker in the environment; the halves that DRAW the fleet first read
    // only the marker, so from a second terminal they marked no row as "this session" and could
    // recommend the account that session was already on - and then move it there for real.
    let lookupDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-session-lookup-\(UUID().uuidString)")
    let here = "/tmp/tally-lookup-project"
    let livePid = String(getpid())
    markSupervisorLive(pid: livePid, dir: lookupDir)
    writeSupervisorCwd(here, pid: livePid, dir: lookupDir)
    let fromOutside = currentSessionLookup(cwd: here, dir: lookupDir, environment: [:])
    check("a shell with no marker still finds the one session in this directory",
          fromOutside?.key == livePid)
    check("…and knows it is not inside it, so the environment cannot answer for it",
          fromOutside?.isThisSession == false)
    let fromInside = currentSessionLookup(cwd: here, dir: lookupDir,
                                          environment: ["TALLY_SUPERVISOR_PID": livePid])
    check("a shell inside the session names it from the marker",
          fromInside?.key == livePid && fromInside?.isThisSession == true)
    check("a directory nothing is supervising answers nothing",
          currentSessionLookup(cwd: "/tmp/tally-lookup-empty", dir: lookupDir,
                               environment: [:]) == nil)
    // Two sessions in one directory and the command from outside both: no way to tell which was
    // meant, so no surface may claim to describe either.
    markSupervisorLive(pid: "1", dir: lookupDir)
    writeSupervisorCwd(here, pid: "1", dir: lookupDir)
    check("two sessions in one directory answer nothing from outside",
          currentSessionLookup(cwd: here, dir: lookupDir, environment: [:]) == nil)
    check("…while a marker still names the one it was typed in",
          currentSessionLookup(cwd: here, dir: lookupDir,
                               environment: ["TALLY_SUPERVISOR_PID": livePid])?.key == livePid)
    try? FileManager.default.removeItem(at: lookupDir)

    // MARK: - Which invocations may meet a menu at all

    // Both ends have to be a terminal. `tally switch | cat` from an interactive shell still has a
    // tty on stdin, so a stdin-only test drew the menu on /dev/tty - invisible to the pipe reader -
    // and blocked the pipeline on a keypress nobody knew to make. Same rule, same reason, as
    // `shouldSupervise` reading stdout (LaunchFlags.swift).
    check("a menu needs a keyboard AND a screen",
          switchMenuAvailable(stdinIsTTY: true, stdoutIsTTY: true))
    check("…so a piped stdout gets the usage text, tty stdin or not",
          !switchMenuAvailable(stdinIsTTY: true, stdoutIsTTY: false)
              && !switchMenuAvailable(stdinIsTTY: false, stdoutIsTTY: false))
    check("…and so does a piped stdin",
          !switchMenuAvailable(stdinIsTTY: false, stdoutIsTTY: true))

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
