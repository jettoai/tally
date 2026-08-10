import Foundation

// `/tally` - the one slash command Tally installs. Installed, updated and removed by the machinery
// in IntegrationsPromptCommand.swift; what is here is the command's own text, and the list that
// machinery walks.
//
// IT REPLACED TWO (`/tally-account` and `/tally-model`), and the replacement is a MERGE rather than
// a rename: the panel behind it holds both axes side by side, so two commands in front of it were
// two doors into one room. What that costs the machinery is written down where it is paid
// (`PromptCommand.formerHookMarkers`): the entries and files left by the pair are recognised as
// ours by what they used to run and call, so one sync clears them.
//
// The command file is the FALLBACK for a machine where the hook is not registered or shell execution
// is turned off by policy, and it is also the ONLY half a user can read - so it says what the hook
// does rather than assuming the hook is there.
extension IntegrationsStore {
    /// Every slash command Tally manages. One now, and still a list: the sync, the uninstall and the
    /// "is this install current" check all walk it, which is what stopped a command being added to
    /// one of them and forgotten by the others.
    nonisolated static var promptCommands: [PromptCommand] { [tallyPromptCommand] }

    /// `/tally`: pick an account or a model for this conversation, or name one and skip the panel.
    nonisolated static var tallyPromptCommand: PromptCommand {
        PromptCommand(name: "tally", hookMarker: "hook-tally", mcpTool: .pick,
                      markdown: """
        ---
        description: Move this Claude Code session to another account, or run it on another model
        argument-hint: [account name] | [model] [effort]
        allowed-tools: Bash(tally:*)
        ---

        <!-- \(promptCommandMarker), managed by Tally.app (Settings -> Integrations); safe to delete -->

        # Move this session, or change what answers it

        READING THIS MEANS TALLY DID NOT ANSWER, and that is the whole of what happened here.
        `/tally` is normally answered before any model is woken: a prompt hook queues the move or
        the model when one is named, and offers the accounts and the models on one panel when
        neither is. Neither spends a turn, which is the point, because the usual reason to reach for
        this command is that the account or the model this session is on has nothing left to answer
        with.

        So this turn is the cost the command exists to avoid. SPEND IT ON ONE SHORT ANSWER.

        ## If `$ARGUMENTS` names anything

        A model, with or without a depth (`opus`, `opus high`):

        ```
        tally model $ARGUMENTS
        ```

        Anything else is an account name, and it may contain spaces, so it is quoted as one word:

        ```
        tally account "$ARGUMENTS"
        ```

        Run ONE of them, once, and stop. Relay the one line it printed and nothing more. The change
        happens when this turn ENDS, the conversation survives it, and naming only a model leaves
        the depth exactly as it is. A non-zero exit means nothing was queued and the message says
        why.

        `auto` on its own is the one line to hand back rather than run: it releases a pin, and this
        command sets two. Say which axis was meant, in one line:

        > `auto` releases a pin and `/tally` sets two of them. Run `tally model auto` to hand the
        > model back, or `tally account --auto` to hand the account back.

        ## If nothing is named

        Do not run anything and do not open a picker: with no hook to draw one, reading the fleet
        and the models here would spend a second turn on what should have cost none. Say this, in
        one line:

        > Tally's picker did not answer this prompt (it is not connected, or the panel was left open
        > past its deadline). Try `/tally` again, run `tally account "<account>"` or
        > `tally model <model> [effort]` from a terminal, or
        > restart the session if it keeps happening.

        For "this project should ALWAYS run there", the instruction is different and is written down
        instead: `tally project set --account "<account>"`, or
        `tally project set --model <model> [--effort <effort>]`.
        """, commandManifest: "claudeTallyCommand", hookManifest: "claudeTallyHook",
                      // What it answered to before, so one sync takes the old pair away: the two
                      // commands themselves, and the name the account one had before THAT.
                      formerNames: ["tally-account", "tally-model", "tally-switch"],
                      formerHookMarkers: ["hook-switch", "hook-model"],
                      formerTools: [.pickAccount, .pickModel])
    }
}
