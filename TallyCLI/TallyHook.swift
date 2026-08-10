import Foundation

// `tally hook-tally`: the command hook behind `/tally`, and the backstop beside its tool call.
//
// THE SAME SHAPE THE TWO IT REPLACES HAD (SwitchHook.swift, ModelHook.swift state the rules it
// keeps): always answer, never let the expansion through, and put the answer where a blocked
// expansion shows it. What is new is only the reading of the line, which is now decided by what the
// words are rather than by which command was typed (`tallyPromptIntent`).
//
// AND A BARE LINE ANSWERS WITH BOTH LISTINGS, because this is the surface for a machine where the
// panel cannot be drawn: the fleet and the three model layers are what the panel would have shown,
// so the fallback shows them as text rather than naming one axis and hiding the other.

/// `tally hook-tally`: the hook entry. Registered by the app with the skill (IntegrationsStore),
/// never typed by hand, so it is absent from the usage text.
///
/// `--backstop` is the same work under a condition: it is registered BESIDE an `mcp_tool` hook that
/// raises the native picker, and it answers only when that picker is not there to
/// (PromptHookBackstop.swift states why it may not simply always answer).
func runHookTally(args: [String] = []) -> Int32 {
    let backstop = promptHookIsBackstop(args)
    if backstop, promptHookBackstopAction(pickerIsServing: nativePickerIsServing()) == .standDown {
        return 0
    }
    let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    // Which session this prompt belongs to, read off the payload rather than off this process
    // (`promptHookSession`, SwitchHook.swift, states why the two differ).
    let (cwd, marker) = promptHookSession(raw)
    let status = liveModelStatus(cwd: cwd, marker: marker)
    let lines: [String]
    // The models this session would be OFFERED are what a single word is recognised against, so the
    // typed path and the panel agree about what counts as a model name.
    switch tallyPromptIntent(hookCommandArguments(raw) ?? "",
                             models: mcpModelOptions(status).map(\.value)) {
    case .model(let intent):
        let attempt = attemptModel(intent, cwd: cwd, marker: marker)
        lines = [attempt.message] + attempt.notes
    case .account(let name):
        let attempt = attemptSwitch(name: name, cwd: cwd, marker: marker)
        lines = [attempt.message] + attempt.notes
    case .release:
        lines = [tallyPromptReleaseRefusal]
    case .palette:
        // One element, so the whole thing prints as a block under a single tag rather than one tag
        // per line - and as one `reason` rather than a decision per line on the other channel.
        // The fleet rows close with how to act on them, and that sentence belongs to the command
        // that raised them: `/tally <name>` here, and the release named in a terminal because
        // `/tally auto` is refused rather than resolved (`SwitchListingCommand`).
        lines = [(switchFleetListing(cwd: cwd, marker: marker, command: .tally)
                    + modelStatusLines(status)).joined(separator: "\n")]
    }
    return emitPromptHookOutput(promptHookOutput(lines, backstop: backstop))
}
