import Foundation

// What `tally mcp-serve` can be asked to do: offer the accounts and the models on one panel, and
// answer a line that names one of them.
// The transport around them is MCPServe.swift; what is here is the part with opinions - which
// options a bare command offers, what the person's answer means, and the one sentence that goes
// back to them.
//
// EVERY PATH ENDS IN A BLOCK DECISION, which is the whole reason a tool sits behind a prompt hook
// at all. `{"decision":"block","reason":"..."}` stops the expansion and shows the reason, so the
// command is answered without a model turn - exactly what the command-type hook achieves by
// exiting 2 (ModelHook.swift states the economics). The reason IS the user-facing surface: it is
// the only thing they see, so it is written to stand alone.
//
// AND THE ARGUMENT PATH NEVER OPENS A DIALOG. `/tally opus xhigh` already said everything;
// asking again would be a picker in front of an instruction. Only a bare command asks, which is
// the same division the typed surfaces make (`modelEntry`, `switchEntry`).

// MARK: - What the hook handed over

/// The `input` block of an `mcp_tool` hook, read back by the keys the app wrote it under
/// (`PromptHookInputField`, compiled into both targets so the two spellings cannot drift).
///
/// EVERY FIELD DEFAULTS TO EMPTY AND THAT IS NOT AN ERROR, because it cannot be told from one: a
/// variable Claude Code does not recognise is substituted with the empty string rather than left as
/// a literal or refused. So nothing here reads emptiness as a misconfiguration - it reads it as
/// "not said", falls back to something safe, and lets the tests carry the spellings.
struct MCPHookInput: Equatable {
    var commandName = ""
    var commandArgs = ""
    var sessionID = ""
    var cwd = ""
    var transcriptPath = ""
    /// The Claude Code this server belongs to, recorded rather than asked for.
    ///
    /// A hook can call `getppid()` when it needs it; this process cannot. It outlives individual
    /// requests, and a Claude Code that exits while it is still up leaves it reparented to launchd
    /// - so asking at request time would answer 1 and match nothing. Captured once, when the server
    /// starts (MCPServe.swift), while the answer is still true.
    var claudeCodePID: pid_t?

    init() {}

    init(arguments: [String: Any], claudeCodePID: pid_t? = nil) {
        self.claudeCodePID = claudeCodePID
        func read(_ field: PromptHookInputField) -> String {
            arguments[field.rawValue] as? String ?? ""
        }
        commandName = read(.commandName)
        commandArgs = read(.commandArgs)
        sessionID = read(.sessionID)
        cwd = read(.cwd)
        transcriptPath = read(.transcriptPath)
    }

    /// The directory that identifies the session being acted on.
    ///
    /// This process's own is the FALLBACK rather than the answer: an MCP server is spawned once per
    /// Claude Code session and lives for all of it, so its working directory is whatever that
    /// session was launched in - usually right, and quietly wrong for a session that moved. The
    /// hook's reading is the one that describes this prompt.
    var sessionDirectory: String {
        cwd.isEmpty ? FileManager.default.currentDirectoryPath : cwd
    }

    /// Whether the command named anything at all. Trimmed, because a trailing space after the
    /// command name is a bare invocation to the person who typed it.
    var isBare: Bool { commandArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The typed line split the way the command-type hook splits it: on whitespace, for a command
    /// whose two values cannot contain any (`hookModelAction`, ModelHook.swift).
    var words: [String] { commandArgs.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// How far this server may trust what it holds about which session asked.
    ///
    /// NEVER OUTRIGHT. This process is a long-lived child of Claude Code, which inherited its own
    /// environment from whatever launched it, so the marker can name a conversation this prompt has
    /// nothing to do with. `.corroborated` weighs it against the directory the hook reported AND
    /// against the conversation id it reported, which is the only pair that separates a session
    /// nested inside another one in the same directory (SessionMarkerTrust, SwitchRequest.swift).
    var sessionMarker: SessionMarkerTrust {
        .corroborated(PromptOrigin(marker: liveSessionMarker(),
                                   promptSession: sessionID.isEmpty ? nil : sessionID,
                                   claudeCodePID: claudeCodePID))
    }
}

// MARK: - The answer that goes back

/// The hook decision a tool returns as its text result. Serialised with sorted keys so the bytes
/// are the same on every run, which is what lets a test assert them.
func mcpBlockDecision(_ reason: String) -> String {
    let decision: [String: String] = ["decision": "block", "reason": reason]
    guard let data = try? JSONSerialization.data(withJSONObject: decision, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        // Unreachable for two strings, and still not a crash: an unanswered hook costs a turn,
        // never the session.
        return #"{"decision":"block","reason":"tally could not encode its answer"}"#
    }
    return text
}

/// An attempt as one block of text: the sentence, then whatever qualifies it. The hook's stderr
/// prints these as separate lines and a dialog has one string to spend, so they are joined rather
/// than dropped - a note about a stale snapshot or a supervisor mid-update is the difference
/// between "nothing happened" and "nothing happened YET".
func mcpAttemptText(_ message: String, notes: [String]) -> String {
    ([message] + notes).joined(separator: "\n")
}

/// Everything the pickers do to the world, in one place, so a test can drive the whole round trip
/// without reading this machine's snapshot or writing a request into `~/.tally`.
///
/// EVERY ONE OF THE FOUR ADDRESSES THE SESSION BY A CORROBORATED MARKER, AND THAT IS THE
/// LOAD-BEARING PART OF THIS TYPE.
///
/// This process is a long-lived child of Claude Code, and Claude Code inherited its environment
/// from whatever launched it. On a machine where one session's shell starts another session, the
/// supervisor marker travels straight down into a conversation it has nothing to do with -
/// measured (QA, 2026-08-07): a bare `/tally-model` in an unsupervised scratch session pinned
/// opus/xhigh onto pid 23743, another session entirely, and the dialog's header described that
/// session too.
///
/// `.corroborated` is the rule that fixes it WITHOUT throwing the marker away (SessionMarkerTrust,
/// SwitchRequest.swift): the marker counts where the directory the hook reported is actually
/// running that supervisor, and is dropped where it is not. Dropping it entirely was the first fix
/// and it cost something real - with several sessions in one directory, the directory alone can
/// only refuse them all, while a corroborated marker names the right one. In production the marker
/// IS this session's (the server is spawned by the very Claude Code the prompt was typed into), so
/// the disambiguation is back and the leak is still closed.
///
/// The hook's `session_id` narrows what corroboration alone cannot: a `claude` launched from inside
/// another supervised session IN THE SAME DIRECTORY inherits a marker the directory happily
/// confirms, so the inner session's prompts were resolved onto the outer conversation (codex review
/// of 512303b). Each supervisor publishes the conversation it is watching (`SupervisedSession`,
/// SessionContext.swift), so a candidate watching a different one is ruled out outright - which is
/// why the whole hook input travels to each of the four rather than only its directory.
///
/// What remains refused: a directory nothing supervises, and several sessions in one directory that
/// no marker and no published conversation can tell apart.
struct MCPPickerWorld {
    var modelStatus: (MCPHookInput) -> ModelStatus = {
        liveModelStatus(cwd: $0.sessionDirectory, marker: $0.sessionMarker)
    }
    var applyModel: (ModelIntent, MCPHookInput) -> ModelAttempt = {
        attemptModel($0, cwd: $1.sessionDirectory, marker: $1.sessionMarker)
    }
    var fleetRows: (MCPHookInput) -> (accounts: [Snapshot.Account], rows: [SwitchFleetRow]?,
                                     problem: String?) = {
        liveSwitchFleet(cwd: $0.sessionDirectory, marker: $0.sessionMarker)
    }
    var applyAccount: (SwitchIntent, MCPHookInput) -> SwitchAttempt = {
        attemptSwitch($0, cwd: $1.sessionDirectory, marker: $1.sessionMarker)
    }
}

// MARK: - The schema a dialog is drawn from

/// One row of a picker: the value that comes back, and the text the person reads.
///
/// TWO FIELDS BECAUSE THE PROTOCOL HAS TWO. `enum` is what the client returns and `enumNames` is
/// what it draws, and the first must be something this CLI can act on while the second is free to
/// carry the percentages that make the choice. Collapsing them - offering the label as the value -
/// is the account-label bug waiting to happen (SwitchMenu.swift: labels share prefixes, ids do not).
struct MCPPickOption: Equatable {
    let value: String
    let label: String
}

/// One enumerated field of a dialog.
func mcpEnumProperty(title: String, description: String,
                     options: [MCPPickOption]) -> [String: Any] {
    var property: [String: Any] = [
        "type": "string",
        "title": title,
        "description": description,
        "enum": options.map(\.value),
    ]
    // Omitted when it would say nothing: `enumNames` is optional in the protocol, and a copy of the
    // values adds a column of noise to the dialog.
    if options.contains(where: { $0.label != $0.value }) {
        property["enumNames"] = options.map(\.label)
    }
    return property
}

/// A dialog with one field, which the person must answer. Required rather than optional because a
/// dialog with nothing required is a dialog that can be submitted empty, and there is no instruction
/// in that.
func mcpEnumSchema(field: String, title: String, description: String,
                   options: [MCPPickOption]) -> [String: Any] {
    ["type": "object",
     "properties": [field: mcpEnumProperty(title: title, description: description,
                                           options: options)],
     "required": [field]]
}

/// The model dialog, which is the only one with a second axis - and the required/optional split IS
/// that axis's meaning: a model must be named, while an effort left unnamed keeps the one the
/// session is running (`ModelIntent.pin(model:effort:)` states why that is a real third state).
func mcpModelSchema(models: [MCPPickOption], efforts: [String]) -> [String: Any] {
    ["type": "object",
     "properties": [
         mcpModelField: mcpEnumProperty(
             title: "Model", description: "What this conversation runs from the end of this turn",
             options: models),
         mcpEffortField: mcpEnumProperty(
             title: "Effort",
             description: "How deeply it reasons. Leave it unset to keep the effort this session "
                 + "already has",
             options: efforts.map { MCPPickOption(value: $0, label: $0) }),
     ],
     "required": [mcpModelField]]
}

let mcpModelField = "model"
let mcpEffortField = "effort"
let mcpAccountField = "account"

/// The word the model picker offers for "stop naming one". The bare spelling rather than the flag,
/// because it is what a person types after `/tally-model` and `modelIntent` accepts both.
let mcpModelAutoValue = "auto"

// MARK: - The models a bare `/tally-model` offers

/// The rows of the model dialog: the documented aliases first, then anything this session is
/// actually involved with that is not already among them, then the release.
///
/// DYNAMIC ON PURPOSE. The aliases are suggestions and never a gate (LaunchAxisNames.swift), so a
/// session running a dated snapshot id, or a project profile naming one, must be able to see itself
/// in the list - otherwise the picker's only reading of the current state is "none of these".
/// Matching is `modelsAgree`, the same bidirectional rule used wherever an alias meets a full id,
/// so `claude-opus-4-8` does not appear beside `opus` as though they were two choices.
func mcpModelOptions(_ status: ModelStatus,
                     aliases: [String] = claudeModelAliases) -> [MCPPickOption] {
    /// Where this model already comes from, in the vocabulary the arrow-key menu uses
    /// (`modelMenuFrame`, ModelMenu.swift), so the two pickers describe one fleet the same way.
    func note(_ model: String) -> String {
        if modelsAgree(model, status.running?.model) { return "running now" }
        if modelsAgree(model, status.pair.model) { return status.modelSource }
        if modelsAgree(model, status.project.model) { return modelLayerProject }
        if modelsAgree(model, status.fleet.model) { return modelLayerFleet }
        return ""
    }
    var options: [MCPPickOption] = []
    func add(_ model: String?) {
        guard let model, !model.isEmpty, model != modelAutoRequest,
              !options.contains(where: { modelsAgree($0.value, model) }) else { return }
        let note = note(model)
        options.append(MCPPickOption(value: model,
                                     label: note.isEmpty ? model : "\(model)  (\(note))"))
    }
    for alias in aliases { add(alias) }
    // The session's own reality, after the suggestions: what answered last, what the command line
    // asks for, and what each layer declares. Anything already covered by an alias is dropped by
    // the agreement test above rather than listed twice.
    add(status.observedModel)
    add(status.declared?.model)
    add(status.session.model)
    add(status.project.model)
    add(status.fleet.model)
    return options + [MCPPickOption(
        value: mcpModelAutoValue,
        label: "auto  (follow this project's profile, then the fleet default)")]
}

/// The message above the model dialog: what this session is running, in the words the listing
/// already uses for it. Read from the same function, so the tense discipline that line was rewritten
/// three times for (ModelHook.swift) is not restated here in a form free to drift.
func mcpModelPrompt(_ status: ModelStatus) -> String {
    modelStatusRunningLines(status).first ?? "Run this conversation on another model"
}

// MARK: - The tools themselves

/// The account rows a palette offers beside the models, or none at all.
///
/// EMPTY IS A REAL ANSWER HERE, and it is why this is not simply the account picker's own reading:
/// a machine with no snapshot, or with nothing the ranking will move a session to, has nothing to
/// offer on that axis, and `mcpAccountPickRows` would still hand back a release row on its own.
/// A section holding only a way out of an axis nobody asked about is noise
/// (`mcpPickSections` drops it).
func mcpPaletteAccountRows(_ world: MCPPickerWorld, _ input: MCPHookInput) -> [PickRow] {
    let (accounts, ranked, _) = world.fleetRows(input)
    guard let ranked, !ranked.isEmpty else { return [] }
    return mcpAccountPickRows(accounts, ranked: ranked)
}

/// `pick`: the one tool `/tally` calls, and the merge of the two below.
///
/// THE TYPED PATH IS ANSWERED WITHOUT A PANEL, exactly as it was on both commands it replaces: what
/// changed is only that the line is read for WHICH axis it names rather than being told by which
/// command was typed (`tallyPromptIntent`). The bare path opens the palette that already holds both.
///
/// THE FLEET IS WHAT THE KEYBOARD OPENS ON, which is this command's one arbitrary choice and is
/// made here rather than left to the panel: a person who typed a command with no axis in its name
/// is reading, and the accounts column is the one that reads left to right first. A machine with no
/// fleet to offer opens on the models instead, because a focused column with nothing in it would be
/// a panel that answers nothing.
func mcpPickTally(input: MCPHookInput, world: MCPPickerWorld, ask: MCPAsk) -> String {
    let status = world.modelStatus(input)
    if !input.isBare {
        switch tallyPromptIntent(input.commandArgs,
                                 models: mcpModelOptions(status).map(\.value)) {
        case .model(let intent):
            let attempt = world.applyModel(intent, input)
            return mcpBlockDecision(mcpAttemptText(attempt.message, notes: attempt.notes))
        case .account(let name):
            let attempt = world.applyAccount(.pin(name), input)
            return mcpBlockDecision(mcpAttemptText(attempt.message, notes: attempt.notes))
        case .release:
            return mcpBlockDecision(tallyPromptReleaseRefusal)
        case .palette:
            break   // a line of nothing but spaces, which is a bare command to whoever typed it
        }
    }
    let (accounts, ranked, problem) = world.fleetRows(input)
    let accountRows = ranked.map { mcpAccountPickRows(accounts, ranked: $0) } ?? []
    let focus: PickKind = accountRows.isEmpty ? .model : .account
    // The sentence above the panel and the form behind it both describe the FOCUSED axis: the form
    // has one field per axis and no way to say "this field alone is the answer", so offering both
    // would be a dialog a person can submit half of (the design's §1). One ternary, so the two can
    // never end up describing different axes.
    let (message, schema): (String, [String: Any]) = focus == .account
        ? (mcpAccountPrompt(offering: ranked?.count ?? 0, provider: providers[0].id,
                            problem: problem),
           mcpAccountSchema(accounts: accounts, ranked: ranked ?? []))
        : (mcpModelPrompt(status),
           mcpModelSchema(models: mcpModelOptions(status), efforts: claudeEffortNames()))
    let offer = MCPPickOffer(
        kind: focus, message: message,
        sections: mcpPickSections(focus: focus, model: mcpModelPickRows(status),
                                  account: accountRows),
        schema: schema)
    guard case .accepted(let content) = ask(offer) else {
        return mcpBlockDecision(mcpNothingChanged)
    }
    return mcpQueuePick(content, input: input, world: world)
}

/// `pick_model`: queue what was named, or ask.
func mcpPickModel(input: MCPHookInput, world: MCPPickerWorld, ask: MCPAsk) -> String {
    if !input.isBare {
        guard let intent = modelIntent(input.words) else {
            return mcpBlockDecision(
                "`/tally-model` takes a model and an optional effort, or `auto`; "
                    + "\"\(input.commandArgs)\" is neither, so nothing was queued")
        }
        let attempt = world.applyModel(intent, input)
        return mcpBlockDecision(mcpAttemptText(attempt.message, notes: attempt.notes))
    }
    let status = world.modelStatus(input)
    // BOTH AXES, MODELS FIRST. The fleet is read even though this command is about models, because
    // the panel offers both and a person who typed the wrong one of the two commands is one click
    // from what they meant rather than an Escape and a retype (`mcpPickSections`).
    let offer = MCPPickOffer(kind: .model, message: mcpModelPrompt(status),
                             sections: mcpPickSections(focus: .model,
                                                       model: mcpModelPickRows(status),
                                                       account: mcpPaletteAccountRows(world, input)),
                             schema: mcpModelSchema(models: mcpModelOptions(status),
                                                    efforts: claudeEffortNames()))
    guard case .accepted(let content) = ask(offer) else {
        return mcpBlockDecision(mcpNothingChanged)
    }
    return mcpQueuePick(content, input: input, world: world)
}

/// `pick_account`: queue the move that was named, or ask.
func mcpPickAccount(input: MCPHookInput, world: MCPPickerWorld, ask: MCPAsk) -> String {
    func queue(_ intent: SwitchIntent) -> String {
        let attempt = world.applyAccount(intent, input)
        return mcpBlockDecision(mcpAttemptText(attempt.message, notes: attempt.notes))
    }
    if !input.isBare {
        // The value IS the account, and the flag is recognised here so both surfaces answer
        // `--auto` the same way (`attemptSwitch(name:)` states the rule). A name is passed on as
        // WRITTEN: a label may contain spaces, and re-parsing it would be a second quoting rule.
        let value = input.commandArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        return queue(value == switchAutoRequest ? .auto : .pin(value))
    }
    let (accounts, rows, problem) = world.fleetRows(input)
    // Nothing to choose from is not a dialog with no rows: the text listing already says which of
    // the two reasons it is (no snapshot at all, or no account signed in) and what to do about it.
    guard let rows, !rows.isEmpty else {
        return mcpBlockDecision(
            hookSwitchListing(rows: rows, provider: providers[0].id, problem: problem,
                              command: .tallyAccount).joined(separator: "\n"))
    }
    // Counting the ROWS rather than the accounts: the release is one of the options and is not an
    // account, and an account the ranking excluded is not in the pool being offered.
    let prompt = mcpAccountPrompt(offering: rows.count, provider: providers[0].id, problem: problem)
    // BOTH AXES, ACCOUNTS FIRST: the same palette the model command raises, opened the other way up
    // (`mcpPickSections`). The models come from this session's own reading, which is the same one
    // `/tally-model` would have shown.
    let offer = MCPPickOffer(kind: .account, message: prompt,
                             sections: mcpPickSections(
                                focus: .account,
                                model: mcpModelPickRows(world.modelStatus(input)),
                                account: mcpAccountPickRows(accounts, ranked: rows)),
                             schema: mcpAccountSchema(accounts: accounts, ranked: rows))
    guard case .accepted(let content) = ask(offer) else {
        return mcpBlockDecision(mcpNothingChanged)
    }
    return mcpQueuePick(content, input: input, world: world)
}

/// What a cancelled dialog says. One sentence for Escape and for Decline, and it names the state
/// rather than the keystroke: the question the person has after pressing Escape is whether they
/// changed anything by accident.
let mcpNothingChanged = "nothing was changed - this conversation stays exactly as it was"
