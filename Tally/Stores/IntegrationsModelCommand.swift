import Foundation

// `/tally-model` - the slash command that changes what THIS conversation runs. Installed, updated
// and removed with the skill by the machinery in IntegrationsPromptCommand.swift; what is here is
// this command's own text, and the list that tells that machinery there are two of them.
//
// The command file is the FALLBACK for a machine where the hook is not registered or shell execution
// is turned off by policy, and it is also the ONLY half a user can read - so it says what the hook
// does rather than assuming the hook is there.
extension IntegrationsStore {
    /// Every slash command Tally manages, in install order. The one list the sync, the uninstall and
    /// the "is this install current" check all walk, so a command cannot be added to one of those
    /// and forgotten by the others - which is exactly what happened to the pair that shipped
    /// together before there was a list.
    nonisolated static var promptCommands: [PromptCommand] {
        [switchPromptCommand, modelPromptCommand]
    }

    /// `/tally-model`: run this conversation on a named model and effort, for the rest of its life.
    nonisolated static var modelPromptCommand: PromptCommand {
        PromptCommand(name: "tally-model", hookMarker: "hook-model", mcpTool: .pickModel,
                      markdown: """
        ---
        description: Run this Claude Code session on a named model and effort, for the rest of it
        argument-hint: [model] [effort] | auto
        allowed-tools: Bash(tally:*)
        ---

        <!-- \(promptCommandMarker), managed by Tally.app (Settings -> Integrations); safe to delete -->

        # Run this conversation on a different model

        READING THIS MEANS TALLY DID NOT ANSWER, and that is the whole of what happened here.
        `/tally-model` is normally answered before any model is woken: a prompt hook queues the pair
        when one is named, and offers the models to pick from when one is not. Neither spends a
        turn, which is the point, because a common reason to reach for this command is that the
        model this session is on has nothing left to answer with.

        So this turn is the cost the command exists to avoid. SPEND IT ON ONE SHORT ANSWER.

        ## If `$ARGUMENTS` names anything

        Run it, once, and stop:

        ```
        tally model $ARGUMENTS
        ```

        Do not quote it as one word: this command takes up to two, and neither can contain a space.
        `auto` needs no special case either, the CLI reads it itself. Relay the one line it printed
        and nothing more. The change happens when this turn ENDS, the conversation survives it, and
        naming only a model leaves the effort exactly as it is. A non-zero exit means nothing was
        queued and the message says why.

        ## If nothing is named

        Do not run anything and do not open a picker: with no hook to draw one, listing the models
        here would spend a second turn on what should have cost none. Say this, in one line:

        > Tally's picker did not answer this prompt (it is not connected, or the dialog was left
        > open past its deadline). Try `/tally-model` again, run `tally model <model> [effort]` from
        > a terminal, or restart the session if it keeps happening.

        For "this project should ALWAYS run that model", the instruction is different and is written
        down instead: `tally project set --model <model> [--effort <effort>]`.
        """, commandManifest: "claudeModelCommand", hookManifest: "claudeModelHook")
    }
}
