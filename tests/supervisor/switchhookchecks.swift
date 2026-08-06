import Foundation

// `tally hook-switch`: the decision that makes `/tally-switch <account>` cost nothing
// (SwitchHook.swift). Claude Code fires the hook before any model is woken and hands it the
// invocation as JSON on stdin; exiting 2 stops the expansion there.
//
// So the whole surface is one question asked of a payload this code does not own, and the two
// answers are not "success" and "failure":
//
//   .queue      handle it here, and stop the prompt (exit 2). Free.
//   .passThrough let the expansion run the command file, which does the same work in a model turn.
//
// Every assertion below is therefore about which of those a payload lands on. The bias is the point:
// anything unrecognisable takes the passThrough, because the degraded path still gives the user the
// right answer while a wrong .queue would move a session to an account nobody named.
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

    // Bare `/tally-switch`: the user wants to CHOOSE, which needs the fleet read and a question
    // asked. That is a model's job, so the expansion goes through.
    check("no account named falls through to the command file",
          hookSwitchAction(payload(["command_args": ""])) == .passThrough)
    check("…and so does whitespace, which is the same thing typed differently",
          hookSwitchAction(payload(["command_args": " \n\t "])) == .passThrough)

    // Everything unrecognisable takes the same fall-through: a payload from a future Claude Code,
    // a field that changed type, an empty stdin because nothing was piped at all. None of these is
    // a reason to guess at an account, and all of them are answered correctly one turn later.
    check("a payload without the field falls through",
          hookSwitchAction(payload(["command_name": "tally-switch"])) == .passThrough)
    check("a field of the wrong type falls through",
          hookSwitchAction(payload(["command_args": 42])) == .passThrough)
    check("stdin that is not JSON falls through", hookSwitchAction("not json at all") == .passThrough)
    check("empty stdin falls through", hookSwitchAction("") == .passThrough)
    check("JSON that is not an object falls through",
          hookSwitchAction("[\"Claude 4\"]") == .passThrough)

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
