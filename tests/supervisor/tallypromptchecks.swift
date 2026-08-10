import Foundation

// `/tally` - one command for both axes, and the reading of the line typed after it
// (TallyPrompt.swift).
//
// THE WHOLE RISK OF THE MERGE IS IN THIS READING. Two commands never had to tell the axes apart:
// `/tally-account Claude` meant an account because of the command it was typed after. One command
// has to decide from the words, and the two vocabularies overlap in exactly the place that matters
// most - a fleet's first account, on the machine this was written on, is called "Claude".
//
// So the rule is not "try the model grammar first" (which accepts any single word as a model name,
// deliberately, since model ids are open text). It is: a line names a model when the word IS one
// this session would be offered, or when it carries a depth beside it. Everything else is a label.
func runTallyPromptChecks() {
    /// The models a session with nothing declared would offer, which is what the panel draws.
    let offered = mcpModelOptions(ModelStatus()).map(\.value)

    func read(_ line: String) -> TallyPromptIntent { tallyPromptIntent(line, models: offered) }

    // MARK: - 38a. Nothing named opens the panel

    check("a bare command opens the panel", read("") == .palette)
    check("…as does a line of nothing but whitespace", read("   ") == .palette)

    // MARK: - 38b. A model, because the words name one

    check("a model the panel offers is a model",
          read("opus") == .model(.pin(model: "opus", effort: nil)))
    check("…at a depth, when one is named",
          read("opus high") == .model(.pin(model: "opus", effort: "high")))
    // The id a transcript carries is the same model as its alias, so typing either works.
    check("…and the full id a response was served by is the same model",
          read("claude-opus-4-8") == .model(.pin(model: "claude-opus-4-8", effort: nil)))
    // A MODEL NOBODY HAS HEARD OF YET still works when it carries a depth: the pair form is
    // unmistakable, which is what keeps the direct path from going stale with the alias table.
    check("a model this build does not know is one anyway when a depth is beside it",
          read("gpt-6-whatever high") == .model(.pin(model: "gpt-6-whatever", effort: "high")))
    // …and a depth that is not one is still the model path, so the answer is "that is not an
    // effort" rather than "no account called opus 2" (`modelIntentProblem` says the useful thing).
    check("a known model with a bad depth stays on the model path, where the error is useful",
          read("opus 2") == .model(.pin(model: "opus", effort: "2")))

    // MARK: - 38c. An account, because the words do not name a model

    // THE CASE THE OBVIOUS READING GETS WRONG. `modelIntent` accepts any single word as a model, so
    // reading the line that way would send this to the model path and pin a model called "Claude".
    check("a one-word account label is an account, not a model", read("Claude") == .account("Claude"))
    check("…and so is a two-word one whose second word is not a depth",
          read("Claude 2") == .account("Claude 2"))
    check("…and a longer one, which no model grammar accepts at all",
          read("My Work Account") == .account("My Work Account"))
    // Passed on AS WRITTEN, under the rule the account command has always applied to its own line:
    // a label may contain spaces, and re-parsing it would be a second quoting rule.
    check("the line is handed over verbatim, quotes and all",
          read("  \"Claude 4\"  ") == .account("\"Claude 4\""))

    // MARK: - 38d. The one form the merge cannot read

    // BOTH AXES HAVE A RELEASE, so `auto` names two opposite instructions and neither is guessed at.
    check("`auto` on its own is refused rather than resolved", read("auto") == .release)
    check("…in either spelling, and whatever the case",
          read("--auto") == .release && read("AUTO") == .release)
    check("…and the refusal says all three ways out",
          tallyPromptReleaseRefusal.contains("nothing was queued")
              && tallyPromptReleaseRefusal.contains("tally model auto")
              && tallyPromptReleaseRefusal.contains("tally account --auto")
              && tallyPromptReleaseRefusal.contains("release row"))
    // Beside a model it is not a release at all: the model grammar refuses that pair itself, and an
    // account is what the line is left as.
    check("`auto` beside something else is not the release form",
          read("opus auto") == .account("opus auto"))

    // MARK: - 38e. What the reading is done against

    // The list is the PANEL'S, so the direct path recognises exactly what the panel would offer: a
    // model named only by this project's profile is typeable the moment it is drawable.
    var status = ModelStatus()
    status.project = SessionModelPin(model: "gpt-5.6-sol", effort: nil)
    let withProject = mcpModelOptions(status).map(\.value)
    check("a model only this session declares is recognised too",
          tallyPromptIntent("gpt-5.6-sol", models: withProject)
              == .model(.pin(model: "gpt-5.6-sol", effort: nil)))
    check("…while the same word is an account to a session that never heard of it",
          tallyPromptIntent("gpt-5.6-sol", models: offered) == .account("gpt-5.6-sol"))
    // The release row's own value is in that list and must never be read as a model name.
    check("the panel's release row is not a model this can be pinned to",
          !tallyPromptNamesModel(mcpModelAutoValue, among: offered))

    // MARK: - 38f. The tool behind the command, end to end

    // A named account moves the session, and a named model pins the pair, THROUGH THE SAME TOOL:
    // the difference is the words, which is the whole of the merge.
    var moved: [SwitchIntent] = []
    var pinned: [ModelIntent] = []
    func run(_ line: String) -> String {
        mcpPickTally(input: MCPHookInput(arguments: ["command_args": line, "cwd": "/tmp/w"]),
                     world: pickWorld(applied: { moved.append($0) }, model: { pinned.append($0) }),
                     ask: { _ in .declined })
    }
    var decision = run("Claude 2")
    check("a named account moves the conversation, with no panel raised",
          moved == [.pin("Claude 2")] && pinned.isEmpty && decision.contains("queued the move"))
    decision = run("opus high")
    check("…and a named model pins the pair, also without a panel",
          pinned == [.pin(model: "opus", effort: "high")]
              && decision.contains("queued the pair"))
    moved = []
    pinned = []
    decision = run("auto")
    check("…while the release is answered and nothing is queued",
          moved.isEmpty && pinned.isEmpty && decision.contains("nothing was queued"))

    // THE PANEL OPENS ON THE FLEET, which is this command's one arbitrary choice: a person who
    // typed a command with no axis in its name is reading, and the accounts column reads first.
    var raised: MCPPickOffer?
    _ = mcpPickTally(input: MCPHookInput(arguments: ["command_args": "", "cwd": "/tmp/w"]),
                     world: pickWorld(), ask: { offer in
                         raised = offer
                         return .declined
                     })
    check("a bare command raises the panel, focused on the accounts",
          raised?.kind == .account && raised?.sections.map(\.kind) == [.account, .model])
    // …unless there is no fleet to focus on, which would be a panel opening on an empty column.
    var alone = pickWorld()
    alone.fleetRows = { _ in ([], nil, "no snapshot") }
    var fallback: MCPPickOffer?
    _ = mcpPickTally(input: MCPHookInput(arguments: [:]), world: alone, ask: { offer in
        fallback = offer
        return .declined
    })
    check("…and opens on the models where there is no fleet to move to",
          fallback?.kind == .model && fallback?.sections.map(\.kind) == [.model])
}
