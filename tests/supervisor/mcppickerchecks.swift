import Foundation

// The native pickers: what a bare command offers, what an answered dialog does, and the JSON-RPC
// round trip around both (MCPPicker.swift, MCPServe.swift).
//
// NOTHING HERE TOUCHES THE MACHINE. Every reading of the world and every write is injected
// (`MCPPickerWorld`), and the transport is a scripted pair of arrays rather than stdio, so the whole
// feature is asserted without a snapshot, a request file, or a Claude Code to talk to.

/// A connection whose input is scripted and whose output is collected.
final class MCPScriptedConnection {
    private var inbox: [String]
    private(set) var outbox: [String] = []

    init(_ lines: [[String: Any]]) {
        inbox = lines.compactMap {
            (try? JSONSerialization.data(withJSONObject: $0)).flatMap {
                String(data: $0, encoding: .utf8)
            }
        }
    }

    var connection: MCPConnection {
        MCPConnection(read: { [self] in inbox.isEmpty ? nil : inbox.removeFirst() },
                      write: { [self] in outbox.append($0) })
    }

    /// The messages the server sent, parsed.
    var sent: [[String: Any]] {
        outbox.compactMap {
            ($0.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) })
                as? [String: Any]
        }
    }
}

/// The decision text a `tools/call` result carries, or nil when the reply was not one.
func mcpDecisionText(_ message: [String: Any]) -> String? {
    guard let result = message["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]],
          let first = content.first else { return nil }
    return first["text"] as? String
}

func runMCPPickerChecks() {
    // MARK: - The variable names, verbatim
    //
    // THE ONE THING NO OTHER CHECK CAN CATCH. Claude Code substitutes a variable it does not
    // recognise with the EMPTY STRING, silently, so `${comand_args}` reaches the tool looking
    // exactly like a command typed with no arguments: the picker would open every time, on every
    // invocation, and nothing anywhere would say why. These five literals are the whole defence,
    // and they are spelled out rather than derived so that a rename has to be made twice.
    check("the hook input fields are spelled exactly as Claude Code substitutes them",
          PromptHookInputField.allCases.map(\.rawValue)
              == ["command_name", "command_args", "session_id", "cwd", "transcript_path"])
    check("…and each token is that name in the substitution syntax",
          PromptHookInputField.allCases.map(\.variable)
              == ["${command_name}", "${command_args}", "${session_id}", "${cwd}",
                  "${transcript_path}"])
    check("…and the block the app writes carries every one of them",
          promptHookInputBlock() == ["command_name": "${command_name}",
                                     "command_args": "${command_args}",
                                     "session_id": "${session_id}", "cwd": "${cwd}",
                                     "transcript_path": "${transcript_path}"])
    // ONE COMMAND CALLS ONE TOOL, and the two beside it are the compatibility surface: a
    // registration written before the merge is in somebody's settings.json until the self-heal
    // rewrites it, and a tool this server does not have is answered with an error the expansion
    // walks straight past - which costs the model turn the hook exists to save.
    check("the server and its tools are named the way the hooks call them",
          tallyMCPServerName == "tally"
              && PromptHookTool.allCases.map(\.rawValue) == ["pick", "pick_account", "pick_model"])
    check("…and the subcommand that runs it is one spelling", mcpServeCommand == "mcp-serve")

    // MARK: - Reading that block back

    let full = MCPHookInput(arguments: ["command_name": "tally-model", "command_args": "opus xhigh",
                                        "session_id": "s-1", "cwd": "/tmp/work",
                                        "transcript_path": "/tmp/t.jsonl", "unknown": "ignored"])
    check("every field arrives under its own key",
          full.commandName == "tally-model" && full.commandArgs == "opus xhigh"
              && full.sessionID == "s-1" && full.cwd == "/tmp/work"
              && full.transcriptPath == "/tmp/t.jsonl")
    check("the directory the hook reported is the one the session is addressed by",
          full.sessionDirectory == "/tmp/work")
    check("a line with arguments is not bare, and splits into its words",
          !full.isBare && full.words == ["opus", "xhigh"])
    // The empty string is "not said", never an error: it is what an unrecognised variable produces
    // and what a bare command produces, and the two cannot be told apart.
    let bare = MCPHookInput(arguments: ["command_args": "   "])
    check("whitespace after the command name is still a bare invocation", bare.isBare)
    check("…and an absent cwd falls back to this process's own rather than to nothing",
          bare.sessionDirectory == FileManager.default.currentDirectoryPath)
    // The typed line is passed on AS WRITTEN for the account command, which is why it is not
    // tokenised here: a label may contain spaces.
    check("the raw line survives, quotes and all",
          MCPHookInput(arguments: ["command_args": "\"Claude 4\""]).commandArgs == "\"Claude 4\"")

    // MARK: - The models a bare `/tally-model` offers

    var status = ModelStatus()
    status.observedModel = "claude-opus-4-8"
    status.fleet = SessionModelPin(model: "fable", effort: "high")
    status.project = SessionModelPin(model: "gpt-5.6-sol", effort: nil)
    status.pair = SessionModelPin(model: "gpt-5.6-sol", effort: "high")
    status.modelSource = modelLayerProject
    let options = mcpModelOptions(status)
    check("every documented alias is offered",
          claudeModelAliases.allSatisfy { alias in options.contains { $0.value == alias } })
    // The whole point of a dynamic list: a model nobody put in the alias table still appears,
    // because it is what this project declares and the picker's only reading of that would
    // otherwise be "none of these".
    check("a model named only by a layer is offered too",
          options.contains { $0.value == "gpt-5.6-sol" })
    // And the counterpart: the full id the transcript carries is the SAME model as the alias, so it
    // must not appear beside it as a second row.
    check("the id a response was served by does not appear beside its alias",
          options.filter { modelsAgree($0.value, "claude-opus-4-8") }.count == 1)
    check("…and the row that stands for it says it is running now",
          options.first { $0.value == "opus" }?.label.contains("running now") == true)
    check("…while a layer's model says which layer",
          options.first { $0.value == "gpt-5.6-sol" }?.label.contains(modelLayerProject) == true)
    check("the release is offered, last, and is not confused with a model",
          options.last?.value == mcpModelAutoValue
              && options.filter { $0.value == mcpModelAutoValue }.count == 1)
    check("nothing offers the flag spelling of the release, which is not what a person types",
          !options.contains { $0.value == modelAutoRequest })

    // MARK: - The schema those rows are drawn as

    let schema = mcpModelSchema(models: options, efforts: claudeEffortNames())
    let properties = schema["properties"] as? [String: Any] ?? [:]
    let modelProperty = properties[mcpModelField] as? [String: Any] ?? [:]
    check("the model field carries the values as an enum",
          modelProperty["enum"] as? [String] == options.map(\.value))
    check("…and the labels beside them, which is the column that carries the percentages",
          modelProperty["enumNames"] as? [String] == options.map(\.label))
    check("the model is required and the effort is not, which is what keeps an unnamed effort a "
              + "third state rather than a default",
          schema["required"] as? [String] == [mcpModelField]
              && properties[mcpEffortField] != nil)
    check("the effort field offers exactly the levels the CLI validates against",
          (properties[mcpEffortField] as? [String: Any])?["enum"] as? [String]
              == claudeEffortNames())
    // enumNames is omitted when it would only repeat the values: the efforts are their own labels.
    check("a field whose labels are its values carries no second column",
          (properties[mcpEffortField] as? [String: Any])?["enumNames"] == nil)

    // MARK: - The accounts, which mirror Tally's own panel
    //
    // The dialog is raised inches from the panel listing the same fleet and a person reads them
    // together, so both the ORDER of the rows and the ORDER of the numbers inside them are the
    // panel's rather than the text listing's (Albert, release UX pass 2026-08-07).

    /// The snapshot order, which is what the panel renders: Claude, then Claude 2.
    var first = switchAccount("claude:.claude", label: "Claude", home: "/tmp/a")
    first.modelRemaining = 54
    first.sessionRemaining = 86
    first.weeklyRemaining = 47
    first.modelWindowName = "Fable"
    // Given MORE headroom than the first, so the ranked order and the snapshot order genuinely
    // disagree: without that, every assertion below would pass whichever order the code used.
    var second = switchAccount("claude:.claude2", label: "Claude 2", home: "/tmp/b")
    second.modelRemaining = 90
    second.sessionRemaining = 95
    second.weeklyRemaining = 80
    second.modelWindowName = "Fable"
    // …and the RANKED reading of the same two, which is the other way round: the second account has
    // the most headroom, so the listing and the arrow-key menu put it first.
    let rows = switchFleetRows(accounts: [first, second], provider: "claude",
                               current: "claude:.claude")
    check("the ranking really does reorder these two, so the assertions below mean something",
          rows.map(\.id) == ["claude:.claude2", "claude:.claude"])
    let accountOptions = mcpAccountOptions(accounts: [first, second], ranked: rows)
    // THE ORDER IS THE PANEL'S. Not the ranking's - a person looking at both windows expects row
    // one here to be row one there.
    check("the dialog lists the accounts in the order the panel does",
          accountOptions.map(\.value) == ["claude:.claude", "claude:.claude2", switchAutoRequest])
    // …and nothing was lost by dropping the ranking: the recommendation was always a TAG.
    check("the recommendation is still marked, on whichever row earned it",
          accountOptions[1].label.contains(switchRecommendedTag)
              && accountOptions[0].label.contains(switchCurrentSessionTag))
    // THE FIELDS ARE THE PANEL'S TOO: flagship, then 5-hour, then weekly.
    check("each row reads flagship, then session, then weekly, as the panel does",
          accountOptions[0].label.contains("fable 54% · session 86% · weekly 47%"))
    check("…and the flagship window is named by the account rather than assumed",
          accountOptions[1].label.contains("fable 90% · session 95% · weekly 80%"))
    // THE FAILURE THIS PREVENTS: "Claude" is a prefix of "Claude 2", so a picker that handed back
    // the label would resolve through the matcher and could land on the wrong account. The row
    // already knows exactly which one it is.
    check("the value of a row is its account id, never its label",
          accountOptions[0].value == "claude:.claude")
    check("and the release is offered last", accountOptions.last?.value == switchAutoRequest)
    // An account the ranking excluded (no launch home, so nothing could move a session there) is
    // excluded here too, however the snapshot orders it.
    var loggedOut = switchAccount("claude:.claude3", label: "Claude 3")
    loggedOut.launchHome = nil
    check("an account that cannot be moved to is not offered, wherever it sits",
          mcpAccountOptions(accounts: [loggedOut, first, second],
                            ranked: switchFleetRows(accounts: [loggedOut, first, second],
                                                    provider: "claude", current: nil))
              .map(\.value) == ["claude:.claude", "claude:.claude2", switchAutoRequest])

    // AND THE ORDER IS THE PANEL'S, NOT THE SNAPSHOT'S. The snapshot writes its accounts sorted by
    // provider and label; the panel renders whatever order the user dragged them into, and the
    // dialog promised to mirror the PANEL. The order is published beside the accounts rather than
    // applied to them, because the array's own order decides near-ties for the launcher's account
    // pick (`smartPick`), so applying it is the reading surface's job (codex batch, 3c0635a).
    let dragged = accountsInPanelOrder([first, second],
                                       order: ["claude:.claude2", "claude:.claude"])
    check("a published drag order is what the dialog lists by",
          dragged.map(\.id) == ["claude:.claude2", "claude:.claude"])
    check("…and the options follow it",
          mcpAccountOptions(accounts: dragged,
                            ranked: switchFleetRows(accounts: [first, second], provider: "claude",
                                                    current: nil)).map(\.value)
              == ["claude:.claude2", "claude:.claude", switchAutoRequest])
    // An account the order does not mention keeps the place the snapshot gave it, after the ones it
    // does: a fleet gains accounts between drags, and a new one must not disappear or jump to front.
    check("an account the order never mentions keeps its snapshot place, behind the ordered ones",
          accountsInPanelOrder([first, second, loggedOut],
                               order: ["claude:.claude2"]).map(\.id)
              == ["claude:.claude2", "claude:.claude", "claude:.claude3"])
    // A snapshot from an app that predates the field says nothing, and nothing is what it changes.
    check("no published order leaves every account exactly where the snapshot put it",
          accountsInPanelOrder([first, second], order: nil).map(\.id)
              == ["claude:.claude", "claude:.claude2"]
              && accountsInPanelOrder([first, second], order: []).map(\.id)
                  == ["claude:.claude", "claude:.claude2"])
    // AND THE READING ACTUALLY APPLIES IT. The rule above is a pure function, and a pure function
    // nobody calls is the wiring defect this feature has now been bitten by twice: every assertion
    // here would still pass with `liveSwitchFleet` handing back the raw snapshot order. Locked by
    // shape, because the call sits behind a snapshot read this suite does not perform.
    let hookSource = (try? String(contentsOfFile: "TallyCLI/SwitchHook.swift", encoding: .utf8)) ?? ""
    check("the fleet reading hands the dialog its accounts in panel order",
          hookSource.contains("return (accountsInPanelOrder(accounts, order: snapshot?.accountOrder),"))
    // …and the app publishes the order for it to apply, which is the other half nobody else asserts.
    let publishing = (try? String(contentsOfFile: "Tally/Stores/UsageStorePublishing.swift",
                                  encoding: .utf8)) ?? ""
    check("…and the app publishes the panel's order beside the accounts",
          publishing.contains("accountOrder: SettingsStore.shared")
              && publishing.contains("orderedAccountIDs(lastPublishedAccounts.map(\\.id))"))

    // THE POOL IN THE HEADING, so the rows read as "the whole Claude fleet" rather than a filtered
    // view of it.
    check("the heading names the pool and counts it",
          mcpAccountPrompt(offering: 5, provider: "claude", problem: nil)
              == "Claude ×5 · Move this conversation to another account")
    check("…and a stale snapshot still says so first, above everything drawn from it",
          mcpAccountPrompt(offering: 2, provider: "claude", problem: "the snapshot is 74m old")
              == "the snapshot is 74m old\nClaude ×2 · Move this conversation to another account")

    // MARK: - What an answer does

    /// A world that records what it was asked to do and writes nothing.
    final class Recorder {
        var models: [ModelIntent] = []
        var accounts: [SwitchIntent] = []
        var asked = 0
        var status = ModelStatus()
        var rows: [SwitchFleetRow]? = []
        /// The same fleet in the order the snapshot lists it, which is what the dialog draws.
        var fleet: [Snapshot.Account] = []
        var problem: String?

        var world: MCPPickerWorld {
            var world = MCPPickerWorld()
            world.modelStatus = { [self] _ in status }
            world.applyModel = { [self] intent, _ in
                models.append(intent)
                return ModelAttempt(result: .queued, message: "queued the pair")
            }
            world.fleetRows = { [self] _ in (fleet, rows, problem) }
            world.applyAccount = { [self] intent, _ in
                accounts.append(intent)
                return SwitchAttempt(result: .queued, message: "queued the move",
                                     notes: ["the snapshot is 74m old"])
            }
            return world
        }

        /// The offer the picker built, kept so a check can look at what would have been drawn:
        /// one offer now carries both renderings (the one-step rows and the form's schema).
        var offer: MCPPickOffer?

        func ask(_ reply: MCPPickReply) -> MCPAsk {
            { [self] offer in
                asked += 1
                self.offer = offer
                return reply
            }
        }
    }

    // A named pair goes straight through: no dialog, which is the same division the typed surfaces
    // make. Asking again in front of an instruction is the one thing this must never do.
    let named = Recorder()
    var decision = mcpPickModel(
        input: MCPHookInput(arguments: ["command_args": "opus xhigh", "cwd": "/tmp/w"]),
        world: named.world, ask: named.ask(.declined))
    check("a named pair is queued without a dialog",
          named.models == [.pin(model: "opus", effort: "xhigh")] && named.asked == 0)
    check("…and the answer is a block decision carrying the attempt's own sentence",
          decision == #"{"decision":"block","reason":"queued the pair"}"#)

    let release = Recorder()
    _ = mcpPickModel(input: MCPHookInput(arguments: ["command_args": " auto "]),
                     world: release.world, ask: release.ask(.declined))
    check("`auto` typed after the command releases the pin, still without asking",
          release.models == [.auto] && release.asked == 0)

    let nonsense = Recorder()
    decision = mcpPickModel(input: MCPHookInput(arguments: ["command_args": "one two three"]),
                            world: nonsense.world, ask: nonsense.ask(.declined))
    check("a line this command cannot act on queues nothing and says so",
          nonsense.models.isEmpty && decision.contains("is neither"))

    // The bare path: the dialog is raised, and an unfilled optional field arrives as an ABSENT KEY
    // rather than a null - which is exactly the third state the effort axis needs.
    let picked = Recorder()
    picked.status.fleet = SessionModelPin(model: "fable", effort: "high")
    _ = mcpPickModel(input: MCPHookInput(arguments: [:]), world: picked.world,
                     ask: picked.ask(.accepted(["model": "sonnet"])))
    check("a bare command asks, and a model without an effort leaves the effort alone",
          picked.asked == 1 && picked.models == [.pin(model: "sonnet", effort: nil)])

    let both = Recorder()
    _ = mcpPickModel(input: MCPHookInput(arguments: [:]), world: both.world,
                     ask: both.ask(.accepted(["model": "opus", "effort": "xhigh"])))
    check("…and both fields answered pin both axes",
          both.models == [.pin(model: "opus", effort: "xhigh")])

    // The one combination a dialog can produce that the grammar refuses: the release beside an
    // effort. Two opposite instructions, so neither is guessed at.
    let contradiction = Recorder()
    decision = mcpPickModel(input: MCPHookInput(arguments: [:]), world: contradiction.world,
                            ask: contradiction.ask(.accepted(["model": mcpModelAutoValue,
                                                              "effort": "high"])))
    check("the release with an effort beside it queues nothing",
          contradiction.models.isEmpty && decision.contains("nothing was queued"))

    let escaped = Recorder()
    decision = mcpPickModel(input: MCPHookInput(arguments: [:]), world: escaped.world,
                            ask: escaped.ask(.declined))
    check("Escape changes nothing, and says so rather than saying nothing",
          escaped.models.isEmpty && decision.contains(mcpNothingChanged))

    // MARK: - The account tool

    let account = Recorder()
    account.rows = rows
    account.problem = "the snapshot is 74m old"
    _ = mcpPickAccount(input: MCPHookInput(arguments: [:]), world: account.world,
                       ask: account.ask(.accepted(["account": "claude:.claude2"])))
    check("a picked row moves the session by id, skipping the name matcher entirely",
          account.accounts == [.pinAccount("claude:.claude2")] && account.asked == 1)

    let releaseAccount = Recorder()
    releaseAccount.rows = rows
    _ = mcpPickAccount(input: MCPHookInput(arguments: [:]), world: releaseAccount.world,
                       ask: releaseAccount.ask(.accepted(["account": switchAutoRequest])))
    check("the release row releases the pin rather than pinning an account called --auto",
          releaseAccount.accounts == [.auto])

    let typedAccount = Recorder()
    typedAccount.rows = rows
    decision = mcpPickAccount(input: MCPHookInput(arguments: ["command_args": " Claude 4 "]),
                              world: typedAccount.world, ask: typedAccount.ask(.declined))
    check("a named account is queued without a dialog, by name, as written",
          typedAccount.accounts == [.pin("Claude 4")] && typedAccount.asked == 0)
    check("…and the note beside the answer travels with it rather than being dropped",
          decision.contains("queued the move") && decision.contains("74m old"))
    let typedAuto = Recorder()
    typedAuto.rows = rows
    _ = mcpPickAccount(input: MCPHookInput(arguments: ["command_args": switchAutoRequest]),
                       world: typedAuto.world, ask: typedAuto.ask(.declined))
    check("…and the flag spelling releases the pin, exactly as the text hook reads it",
          typedAuto.accounts == [.auto])

    // Nothing to choose from is not an empty dialog: the text listing says WHICH of the two reasons
    // it is and what to do about it, and that is the whole answer.
    let empty = Recorder()
    empty.rows = []
    decision = mcpPickAccount(input: MCPHookInput(arguments: [:]), world: empty.world,
                              ask: empty.ask(.declined))
    check("with no account to move to, no dialog is raised at all", empty.asked == 0)
    check("…and the reason is the listing's own sentence", decision.contains("tally add claude"))
    let noSnapshot = Recorder()
    noSnapshot.rows = nil
    noSnapshot.problem = "no snapshot"
    decision = mcpPickAccount(input: MCPHookInput(arguments: [:]), world: noSnapshot.world,
                              ask: noSnapshot.ask(.declined))
    check("…and an unreadable snapshot is reported as itself, not as an empty fleet",
          noSnapshot.asked == 0 && decision.contains("no snapshot"))

    runMCPAddressingChecks()
    runMCPTransportChecks()
}

/// WHICH SESSION THE PICKERS ACT ON, which is the one thing about this feature that can damage
/// somebody else's work.
///
/// The defect (QA, 2026-08-07): a bare `/tally-model` typed in an unsupervised scratch session
/// pinned opus/xhigh onto pid 23743, a different live conversation, and the dialog's header
/// described that conversation too. The cause is not in the resolution - it is in the WIRING. A
/// session is addressed by the environment marker its supervisor stamped, or by its directory when
/// there is no marker, and the marker wins unconditionally. The MCP server is a long-lived child of
/// Claude Code and inherits its environment from whatever launched Claude Code, so on a machine
/// where one session's shell starts another, that marker is a different session's supervisor.
func runMCPAddressingChecks() {
    // The resolution itself, at the layer the whole design now rests on: with no marker, the
    // directory is the only witness, and the two cases it cannot answer stay refusals.
    check("with no marker and nothing supervising the directory, no session is named",
          sessionLookup(envPid: nil, here: []) == .none)
    check("…one supervisor there IS the session",
          sessionLookup(envPid: nil, here: ["4242"]) == .session("4242"))
    check("…and several stay ambiguous rather than being guessed at",
          sessionLookup(envPid: nil, here: ["1", "2"]) == .ambiguous(["1", "2"]))
    // The behaviour being given up, stated so the trade is on the record: a marker still outranks
    // the directory, which is right for every surface a person types into.
    check("a marker still outranks the directory, which is what the typed surfaces need",
          sessionLookup(envPid: "9", here: ["4242"]) == .session("9"))

    // THE PROCESS WITNESS, which now answers first because it is the only one that cannot go stale
    // under the session and cannot be shared by two of them.
    let children = ["outer": 100, "inner": 200]
    // THE FOUR QUADRANTS of a mixed-build directory, which is the shape that broke twice.
    // 1. A match: a positive reading, and it ends the question.
    check("the supervisor whose child sent this prompt is it",
          sessionsRunning(200, among: ["outer", "inner"], published: { children[$0] })
              == WitnessReading(identified: true, candidates: ["inner"]))
    // 2. Everyone published and nobody matched: a real refusal, because every candidate was read
    //    and every one of them disagreed.
    check("…and where every candidate was read and none of them is it, nothing survives",
          sessionsRunning(200, among: ["outer"], published: { children[$0] })
              == WitnessReading(identified: false, candidates: []))
    // 3. THE MIXED CASE, and the one that took an old-build session's commands away: a witness
    //    that cannot speak for a candidate has said NOTHING about it, so it survives to the next
    //    stage rather than being buried with the ones that disagreed.
    check("a candidate this witness cannot read survives a stage that disproved the others",
          sessionsRunning(999, among: ["outer", "legacy"], published: { children[$0] })
              == WitnessReading(identified: false, candidates: ["legacy"]))
    // 4. Nobody published at all: the whole set goes on, which is how a directory of older
    //    supervisors still reaches the witnesses that can answer for it.
    check("a directory where nobody publishes hands every candidate on",
          sessionsRunning(200, among: ["quiet", "quieter"], published: { _ in nil })
              == WitnessReading(identified: false, candidates: ["quiet", "quieter"]))
    check("…as does a caller that cannot name its own Claude Code",
          sessionsRunning(nil, among: ["outer"], published: { children[$0] })
              == WitnessReading(identified: false, candidates: ["outer"]))

    // THE TWO CASES codex found in the transcript witness, both closed by the process one.
    //
    // `/clear` rebinds the transcript, and the `.session` document still names the OLD conversation
    // until the next publish. Judged on the transcript alone, the one correct supervisor is thrown
    // away and the command refuses - while the hook blocks the turn, so the session cannot even
    // send the ordinary prompt that would fix it.
    let cleared = SessionMarkerTrust.corroborated(
        PromptOrigin(marker: "inner", promptSession: "conv-AFTER-CLEAR", claudeCodePID: 200))
    check("a session that just cleared is still found, though its published conversation is stale",
          cleared.resolve(here: ["inner"], published: { _ in "conv-BEFORE-CLEAR" },
                          childOf: { children[$0] }) == .session("inner"))
    // Two supervisors that bound the same transcript by the mtime heuristic publish the SAME id.
    // The process witness separates them outright; the transcript witness needs the marker.
    check("two supervisors sharing a transcript id are separated by their processes",
          SessionMarkerTrust.corroborated(
            PromptOrigin(marker: "outer", promptSession: "conv-SAME", claudeCodePID: 200))
              .resolve(here: ["outer", "inner"], published: { _ in "conv-SAME" },
                       childOf: { children[$0] }) == .session("inner"))
    // THE MIXED-BUILD DIRECTORY, end to end: a new-build supervisor that is provably not it, and an
    // old-build one that cannot answer for itself. The old one has to survive the process stage and
    // be found by the witnesses that CAN speak for it, or every `/tally-*` in that session fails
    // until it restarts (codex review of 49dcdcd).
    check("an old-build session in a directory with a new-build one is still found",
          SessionMarkerTrust.corroborated(
            PromptOrigin(marker: "legacy", promptSession: nil, claudeCodePID: 999))
              .resolve(here: ["outer", "legacy"], published: { _ in nil },
                       childOf: { children[$0] }) == .session("legacy"))
    check("…and the new-build one it shares the directory with is not offered instead",
          SessionMarkerTrust.corroborated(
            PromptOrigin(marker: nil, promptSession: nil, claudeCodePID: 999))
              .resolve(here: ["outer", "legacy"], published: { _ in nil },
                       childOf: { children[$0] }) == .session("legacy"))
    // …and the nested case, which is what the whole witness exists for: the marker fits, the
    // directory fits, and the process does not.
    check("a nested session's prompt does not reach the session it was launched from",
          SessionMarkerTrust.corroborated(
            PromptOrigin(marker: "outer", promptSession: nil, claudeCodePID: 999))
              .resolve(here: ["outer"], published: { _ in nil },
                       childOf: { children[$0] }) == SessionLookup.none)

    // P1 IN THE FALLBACK ITSELF, for the older builds that reach it: two candidates publishing the
    // same conversation must not be answered by whichever sorts first.
    check("every candidate watching that conversation comes back, not the first",
          sessionsWatching("conv-SAME", among: ["outer", "inner"],
                           published: { _ in "conv-SAME" })
              == WitnessReading(identified: true, candidates: ["outer", "inner"]))
    check("…so the marker decides between them",
          SessionMarkerTrust.corroborated(
            PromptOrigin(marker: "inner", promptSession: "conv-SAME", claudeCodePID: nil))
              .resolve(here: ["outer", "inner"], published: { _ in "conv-SAME" },
                       childOf: { _ in nil }) == .session("inner"))
    check("…and a marker that decides nothing is a refusal, not a coin toss",
          SessionMarkerTrust.corroborated(
            PromptOrigin(marker: nil, promptSession: "conv-SAME", claudeCodePID: nil))
              .resolve(here: ["outer", "inner"], published: { _ in "conv-SAME" },
                       childOf: { _ in nil }) == .ambiguous(["outer", "inner"]))

    // THE CONVERSATION WITNESS, which is what corroboration alone could not supply.
    //
    // Corroboration asks "is that marker's supervisor running here", and in the nested case the
    // answer is yes: a `claude` started from inside another supervised session in the SAME
    // directory inherits a marker the directory happily confirms, so the inner session's prompts
    // were resolved onto the outer conversation (codex review of 512303b). Only an id that names
    // the conversation itself can separate them.
    let watching = ["outer": "conv-OUTER", "inner": "conv-INNER"]
    check("a candidate watching exactly this conversation is it, and alone",
          sessionsWatching("conv-INNER", among: ["outer", "inner"], published: { watching[$0] })
              == WitnessReading(identified: true, candidates: ["inner"]))
    check("…a candidate watching a different conversation is provably not it, and is dropped",
          sessionsWatching("conv-INNER", among: ["outer"], published: { watching[$0] })
              == WitnessReading(identified: false, candidates: []))
    // Silence means "cannot say", here as everywhere else on this track: a supervisor from a build
    // before this field existed keeps its place in the queue rather than being disqualified.
    check("…and a candidate publishing nothing is kept, so an older supervisor still works",
          sessionsWatching("conv-INNER", among: ["outer", "quiet"], published: { watching[$0] })
              == WitnessReading(identified: false, candidates: ["quiet"]))
    check("with no conversation id to compare, every candidate stands",
          sessionsWatching(nil, among: ["outer", "inner"], published: { watching[$0] }).candidates
              == ["outer", "inner"]
              && sessionsWatching("", among: ["outer"], published: { watching[$0] }).candidates
                  == ["outer"])

    // THE WHOLE RULE, composed: the nested case QA could not reach and codex found by reading.
    let nested = SessionMarkerTrust.corroborated(PromptOrigin(marker: "outer", promptSession: "conv-INNER"))
    check("the inner session's prompt does not reach the outer conversation",
          nested.resolve(here: ["outer"], published: { watching[$0] },
                         childOf: { _ in nil }) == SessionLookup.none)
    check("…and where the inner session IS supervised, its own prompt finds it",
          nested.resolve(here: ["outer", "inner"], published: { watching[$0] },
                         childOf: { _ in nil }) == .session("inner"))
    // Corroboration still does its own job for everything the witness cannot answer.
    let plain = SessionMarkerTrust.corroborated(PromptOrigin(marker: "7", promptSession: nil))
    check("a marker the directory confirms names the session, even among several",
          plain.resolve(here: ["7", "8"], published: { _ in nil }, childOf: { _ in nil }) == .session("7"))
    check("…a marker the directory has never heard of is DROPPED, not argued with",
          SessionMarkerTrust.corroborated(PromptOrigin(marker: "9", promptSession: nil))
              .resolve(here: ["7"], published: { _ in nil }, childOf: { _ in nil }) == .session("7"))
    check("…and dropping it leaves the directory's own answer, refusals included",
          SessionMarkerTrust.corroborated(PromptOrigin(marker: "9", promptSession: nil))
              .resolve(here: [], published: { _ in nil }, childOf: { _ in nil }) == SessionLookup.none
              && SessionMarkerTrust.corroborated(PromptOrigin(marker: "9", promptSession: nil))
                  .resolve(here: ["7", "8"], published: { _ in nil }, childOf: { _ in nil }) == .ambiguous(["7", "8"]))
    check("no marker at all is the same directory-only answer",
          SessionMarkerTrust.corroborated(PromptOrigin(marker: nil, promptSession: nil))
              .resolve(here: ["7"], published: { _ in nil }, childOf: { _ in nil }) == .session("7"))
    // The other half of the pair, unchanged and deliberately so: a person's shell DESCENDS from the
    // session, so its marker is good even from a subdirectory the supervisor never published, and
    // no witness is asked for.
    check("a trusted marker still needs no corroboration, which is what typed commands rely on",
          SessionMarkerTrust.trusted("9").resolve(here: [], published: { _ in "anything" }, childOf: { _ in nil })
              == .session("9"))
    check("…and its value is readable whether or not a resolution used it",
          SessionMarkerTrust.corroborated(PromptOrigin(marker: "9", promptSession: nil)).value == "9"
              && SessionMarkerTrust.trusted(nil).value == nil)

    // The witness is PUBLISHED from the transcript the supervisor is tailing, and follows a
    // `/clear` because it is derived rather than remembered.
    var tailing = TranscriptWatcher(projectDir: URL(fileURLWithPath: "/tmp"),
                                    file: URL(fileURLWithPath: "/t/conv-A.jsonl"), since: Date())
    check("the published witness is the transcript's own name, which is the session id",
          tailing.transcriptSessionID == "conv-A")
    tailing.file = URL(fileURLWithPath: "/t/conv-B.jsonl")
    check("…and it moves when the conversation does", tailing.transcriptSessionID == "conv-B")
    tailing.file = nil
    check("…and is absent before one is bound", tailing.transcriptSessionID == nil)

    // THE DISAMBIGUATION THE FIRST FIX GAVE AWAY, bought back: two sessions in one directory, and
    // the corroborated marker names the one that is asking. A directory-only rule can only refuse
    // both, which is what dropping the marker outright had done.
    let twoDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-corroborate-\(UUID().uuidString)")
    let shared = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-corroborate-here-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    let mine = String(getpid())
    let theirs = "1"        // launchd: alive, and certainly not this session
    for pid in [mine, theirs] {
        markSupervisorLive(pid: pid, dir: twoDir)
        writeSupervisorCwd(shared.path, pid: pid, dir: twoDir)
    }
    check("two supervisors really do share that directory",
          supervisorsInDirectory(shared.path, dir: twoDir).count == 2)
    // Neither supervisor here publishes a conversation (nothing wrote a `.session` file into this
    // temporary state directory), so this is the older-supervisor path: no witness, corroboration
    // alone, and the marker still names the session that is asking.
    check("a corroborated marker picks the session that is asking",
          currentSessionLookup(cwd: shared.path, dir: twoDir,
                               marker: .corroborated(PromptOrigin(marker: mine, promptSession: nil)))?.key
              == mine)
    check("…and knows it is that session, so the reading describes it",
          currentSessionLookup(cwd: shared.path, dir: twoDir,
                               marker: .corroborated(PromptOrigin(marker: mine,
                                                       promptSession: nil)))?.isThisSession == true)
    // The leak, in the same directory shape: a marker from a session that is NOT here is dropped,
    // and what is left is ambiguous rather than a confident answer about the wrong conversation.
    check("a marker from somewhere else is dropped, leaving the honest refusal",
          currentSessionLookup(cwd: shared.path, dir: twoDir,
                               marker: .corroborated(PromptOrigin(marker: "424242", promptSession: nil))) == nil)
    // THE NESTED CASE, end to end through the real reader: both supervisors publish, and the one
    // watching another conversation is ruled out even though the marker names it and the directory
    // confirms it. This is the shape codex found and QA could not reach without a second Claude
    // Code; a published `.session` file is all it takes to assert.
    writeSessionContext(SupervisedSession(accountID: "claude:.claude", contextTokens: 1_000,
                                          updatedAt: Date(), sessionPin: nil,
                                          axes: SessionAxes(), transcript: "conv-OUTER"),
                        pid: theirs, dir: twoDir)
    writeSessionContext(SupervisedSession(accountID: "claude:.claude", contextTokens: 1_000,
                                          updatedAt: Date(), sessionPin: nil,
                                          axes: SessionAxes(), transcript: "conv-INNER"),
                        pid: mine, dir: twoDir)
    check("the published witness round-trips through the file",
          readSessionContext(pid: mine, dir: twoDir)?.transcriptSessionID == "conv-INNER")
    check("an inner session's prompt is not answered by the outer session it was launched from",
          currentSessionLookup(cwd: shared.path, dir: twoDir,
                               marker: .corroborated(PromptOrigin(marker: theirs,
                                                       promptSession: "conv-INNER")))?.key == mine)
    check("…and the outer session's own prompt still finds the outer session",
          currentSessionLookup(cwd: shared.path, dir: twoDir,
                               marker: .corroborated(PromptOrigin(marker: theirs,
                                                       promptSession: "conv-OUTER")))?.key == theirs)
    check("…while a conversation neither of them is watching is refused outright",
          currentSessionLookup(cwd: shared.path, dir: twoDir,
                               marker: .corroborated(PromptOrigin(marker: theirs,
                                                       promptSession: "conv-GONE"))) == nil)
    try? FileManager.default.removeItem(at: twoDir)
    try? FileManager.default.removeItem(at: shared)

    // MARK: - What a hook reads about the prompt it is answering
    //
    // QA's one-line reproduction, as a test: an unsupervised directory and a fabricated marker must
    // produce the "nothing published yet" reading, never another session's. The payload fields are
    // measured against Claude Code 2.1.224.
    let payload = #"{"command_args":"","cwd":"/tmp/tally-hook-cwd","session_id":"fabricated","#
        + #""transcript_path":"/tmp/t.jsonl","hook_event_name":"UserPromptExpansion"}"#
    check("the hook reads the prompt's directory out of its payload",
          hookCommandCwd(payload) == "/tmp/tally-hook-cwd")
    check("…and a payload without one falls back to this process, as every version has",
          hookCommandCwd(#"{"command_args":""}"#) == nil
              && promptHookSession(#"{"command_args":""}"#).cwd
                  == FileManager.default.currentDirectoryPath)
    check("…and an unreadable payload is not a crash either", hookCommandCwd("not json") == nil)
    check("a hook never takes its marker on trust, whatever the payload says",
          promptHookSession(payload).marker
              == .corroborated(PromptOrigin(marker: liveSessionMarker(),
                                            promptSession: "fabricated",
                                            claudeCodePID: getppid())))
    // The pid it carries is its OWN parent, which is the Claude Code that ran it - not the
    // supervisor, and not anything further up.
    check("…and the process it names is the Claude Code that ran it",
          promptHookSession(payload).marker
              == .corroborated(PromptOrigin(marker: liveSessionMarker(),
                                            promptSession: "fabricated",
                                            claudeCodePID: getppid()))
              && String(getppid()) != liveSessionMarker())
    check("…and it carries the conversation the prompt came from, which is the witness",
          hookCommandSessionID(payload) == "fabricated"
              && hookCommandSessionID(#"{"command_args":"","session_id":""}"#) == nil)
    // The reading itself, against a directory nothing supervises and a marker that names a live
    // process which is not a supervisor of it. Read-only: this is the listing branch.
    let lonely = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-hook-lonely-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: lonely, withIntermediateDirectories: true)
    let stranded = liveModelStatus(
        cwd: lonely.path,
        marker: .corroborated(PromptOrigin(marker: String(getpid()), promptSession: "fabricated")))
    check("a prompt from a directory nothing supervises reads as nothing published",
          stranded.running == nil && stranded.observedModel == nil)
    check("…and says so, rather than describing the session whose marker leaked in",
          modelStatusRunningLines(stranded).first?.contains("nothing published yet") == true)
    try? FileManager.default.removeItem(at: lonely)

    // THE WIRING, WHICH IS WHERE THE BUG LIVED AND WHERE IT WOULD COME BACK. Each of the four
    // readings and writes the pickers make has to corroborate; forgetting one restores the defect
    // on that path alone, silently, and the defaults of a struct of closures cannot be interrogated
    // at runtime. So the source line is the lock, exactly as the shared-state gates in
    // tests/integrations are locked by shape (`gateSource`).
    //
    // The honest limit of this check, recorded rather than glossed: proving it behaviourally means
    // running the real binary with a poisoned marker and observing which session it acts on, and
    // the only observable difference is a request file written into the user's own `~/.tally`. This
    // suite does not write there.
    let picker = (try? String(contentsOfFile: "TallyCLI/MCPPicker.swift", encoding: .utf8)) ?? ""
    check("the addressing lock reads the file it is about", picker.contains("struct MCPPickerWorld"))
    for wiring in ["liveModelStatus(cwd: $0.sessionDirectory, marker: $0.sessionMarker)",
                   "attemptModel($0, cwd: $1.sessionDirectory, marker: $1.sessionMarker)",
                   "liveSwitchFleet(cwd: $0.sessionDirectory, marker: $0.sessionMarker)",
                   "attemptSwitch($0, cwd: $1.sessionDirectory, marker: $1.sessionMarker)"] {
        check("the picker addresses the session the HOOK described: \(wiring)",
              picker.contains(wiring))
    }
    // …and the other direction, which a fifth wiring would trip: nothing on this path may take a
    // marker on trust.
    for file in ["TallyCLI/MCPPicker.swift", "TallyCLI/MCPServe.swift"] {
        let source = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        check("\(file) never trusts a marker outright",
              !source.isEmpty && !source.contains(".trusted("))
    }
}

/// The wire: one conversation, driven end to end.
func runMCPTransportChecks() {
    let elicitID = "tally-elicit-1"
    let script = MCPScriptedConnection([
        ["jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": ["protocolVersion": "2025-11-25", "capabilities": ["elicitation": [:]]]],
        ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
        ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": ["name": "pick_model",
                    "arguments": ["command_name": "tally-model", "command_args": "",
                                  "cwd": "/tmp/work", "session_id": "conv-7"]]],
        // THE STRUCTURAL RULE, on the wire: the client keeps talking while the dialog is open. A
        // server that read only for its own reply would leave this unanswered and both sides would
        // wait for each other with a picker on screen.
        ["jsonrpc": "2.0", "id": 4, "method": "ping"],
        ["jsonrpc": "2.0", "id": elicitID, "result": ["action": "accept",
                                                      "content": ["model": "sonnet"]]],
    ])
    var applied: [ModelIntent] = []
    var world = MCPPickerWorld()
    world.modelStatus = { _ in ModelStatus() }
    world.applyModel = { intent, input in
        applied.append(intent)
        // The whole hook input reaches the write, not just its directory: the conversation id
        // travels with it, which is what the addressing rule needs (SessionMarkerTrust).
        return ModelAttempt(result: .queued,
                            message: "queued in \(input.sessionDirectory) for \(input.sessionID)")
    }
    MCPServer(connection: script.connection, world: world, pick: .unavailable).serve()

    let sent = script.sent
    check("initialize is answered with the version the client asked for",
          (sent.first?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
    check("…and with this server's own name, which is the one the hooks call",
          ((sent.first?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"]
              as? String == tallyMCPServerName)
    let listed = sent.first { $0["id"] as? Int == 2 }
    check("tools/list offers both pickers",
          ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
              .compactMap { $0["name"] as? String } == PromptHookTool.allCases.map(\.rawValue))
    let elicitation = sent.first { $0["method"] as? String == "elicitation/create" }
    check("a bare tool call raises an elicitation from inside it", elicitation != nil)
    let requested = (elicitation?["params"] as? [String: Any])?["requestedSchema"] as? [String: Any]
    check("…whose schema is the model form", requested?["required"] as? [String] == [mcpModelField])
    check("a ping that arrives while the dialog is open is answered",
          sent.contains { $0["id"] as? Int == 4 && $0["result"] != nil })
    check("the answer is applied against the directory the HOOK reported, not this process's",
          applied == [.pin(model: "sonnet", effort: nil)])
    // Read back as JSON rather than compared as bytes: the serializer escapes forward slashes
    // (`\/`, which is legal and parses back to `/`), and this reason carries a path.
    let answer = sent.first { $0["id"] as? Int == 3 }
    let carried = (mcpDecisionText(answer ?? [:])?.data(using: .utf8))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
    check("the tool call is answered with a hook decision",
          carried == ["decision": "block", "reason": "queued in /tmp/work for conv-7"])
    check("…and the whole conversation is one line per message",
          script.outbox.allSatisfy { !$0.contains("\n") })

    // A tool nobody has is an ERROR RESULT rather than a JSON-RPC error: the result still carries
    // text, so the prompt is answered rather than falling through to a model turn.
    let unknown = MCPScriptedConnection([
        ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": ["name": "pick_lunch", "arguments": [:]]],
        ["jsonrpc": "2.0", "id": 2, "method": "resources/list"],
        ["jsonrpc": "2.0", "id": 3, "method": "no/such/method"],
    ])
    MCPServer(connection: unknown.connection, pick: .unavailable).serve()
    let unknownSent = unknown.sent
    check("an unknown tool answers with text rather than nothing",
          (unknownSent.first?["result"] as? [String: Any])?["isError"] as? Bool == true)
    check("the listings a client asks for at start-up are answered empty, not refused",
          (unknownSent.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any])?["resources"]
              as? [Any] != nil)
    check("…while a method that really is not here is a protocol error",
          (unknownSent.first { $0["id"] as? Int == 3 }?["error"] as? [String: Any])?["code"]
              as? Int == -32601)

    // A dialog the client never answers is a DECLINE. Nothing is queued on a guess, and the server
    // exits instead of waiting forever.
    let abandoned = MCPScriptedConnection([
        ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": ["name": "pick_account", "arguments": ["command_args": ""]]],
    ])
    var moved: [SwitchIntent] = []
    var quiet = MCPPickerWorld()
    let onlyAccount = switchAccount("a", label: "A")
    quiet.fleetRows = { _ in
        ([onlyAccount],
         switchFleetRows(accounts: [onlyAccount], provider: "claude", current: nil), nil)
    }
    quiet.applyAccount = { intent, _ in
        moved.append(intent)
        return SwitchAttempt(result: .queued, message: "moved")
    }
    MCPServer(connection: abandoned.connection, world: quiet, pick: .unavailable).serve()
    check("a client that goes away mid-dialog moves nothing", moved.isEmpty)
    check("…and the tool call is still answered before the server stops",
          mcpDecisionText(abandoned.sent.first { $0["id"] as? Int == 1 } ?? [:])?
              .contains(mcpNothingChanged) == true)
}
