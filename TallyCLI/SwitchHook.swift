import Foundation

// `tally hook-switch` - what makes `/tally-switch <account>` cost NOTHING.
//
// Claude Code fires a `UserPromptExpansion` hook when a slash command is typed, BEFORE any model is
// woken: the hook reads the invocation as JSON on stdin, and exiting 2 stops the expansion there,
// showing its stderr to the user. So the whole feature is: read the account name out of that JSON,
// queue the move through the same code the command uses (SessionSwitch.swift), say one line, and
// exit 2. No turn runs, no tokens are spent, and moving accounts stops costing more than it saves.
//
// The two exits are the entire contract, and neither is a failure mode:
//
//   exit 2  the hook handled it (queued, or explained why it could not). The prompt stops.
//   exit 0  the hook has nothing to say, so the expansion goes through: the command file installed
//           beside the skill runs a model turn that lists the accounts and asks which one.
//
// Exit 0 is therefore the DEGRADED path, not the error path, and everything unexpected takes it:
// stdin that is not JSON, a payload without the field, a shape from a future Claude Code. The
// command file answers every one of those correctly, just for the price of a turn.
//
// A named account that cannot be moved to still exits 2. Spending a model turn to re-say "no
// account matches that" would be paying for the one thing this file exists to avoid, so the
// message has to stand on its own - which is why `SwitchAttempt.message` is written to.

/// What the hook does with the payload it was handed.
enum HookSwitchAction: Equatable {
    /// An account was named: queue the move and stop the expansion.
    case queue(String)
    /// Nothing to act on here: let the expansion through to the model turn.
    case passThrough
}

/// The decision, pure: everything about the payload, nothing about the world. `command_args` is what
/// Claude Code puts the rest of the typed line in, already past its own quote handling, so the value
/// IS the account name and is passed on as written (an account label may contain spaces, and
/// re-parsing it here would be a second, different, quoting rule).
func hookSwitchAction(_ raw: String) -> HookSwitchAction {
    guard let data = raw.data(using: .utf8),
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let arguments = payload["command_args"] as? String else { return .passThrough }
    let name = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    // Bare `/tally-switch`: the user wants to choose, and choosing means reading the fleet and
    // asking. That is a model's job, so let the expansion through.
    return name.isEmpty ? .passThrough : .queue(name)
}

/// `tally hook-switch`: the hook entry. Registered by the app with the skill (IntegrationsStore),
/// never typed by hand, so it is absent from the usage text.
func runHookSwitch() -> Int32 {
    let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    guard case .queue(let name) = hookSwitchAction(raw) else { return 0 }
    let attempt = attemptSwitch(name: name)
    // Stderr for all of it: this is the only channel a blocked expansion shows the user, and stdout
    // is discarded on exit 2.
    warn(attempt.message)
    for note in attempt.notes { warn(note) }
    return 2
}
