import Foundation

// `/tally-account` - the slash command that moves a session to another account. The machinery that
// installs it, and the prompt hook that makes it free, are shared with every command Tally ships and
// lives in IntegrationsPromptCommand.swift; what is here is this command's own text.
//
// The command file is the FALLBACK for a machine where the hook is not registered or shell execution
// is turned off by policy, and it is also the ONLY half a user can read - so it says what the hook
// does rather than assuming the hook is there.
extension IntegrationsStore {
    /// `/tally-account`: move this conversation to another account, keeping the conversation.
    /// Named for the axis it sets, like `/tally-model`: the pair reads as a set, and a list of
    /// `/tally-` commands explains itself without anyone having to try one.
    nonisolated static var switchPromptCommand: PromptCommand {
        PromptCommand(name: "tally-account", hookMarker: "hook-switch", mcpTool: .pickAccount,
                      markdown: """
        ---
        description: Pin this Claude Code session to another account, keeping the conversation
        argument-hint: [account name | --auto]
        allowed-tools: Bash(tally:*)
        ---

        <!-- \(promptCommandMarker), managed by Tally.app (Settings -> Integrations); safe to delete -->

        # Move this session to another account

        READING THIS MEANS TALLY DID NOT ANSWER, and that is the whole of what happened here.
        `/tally-account` is normally answered before any model is woken: a prompt hook queues the
        move when an account is named, and offers the fleet to pick from when one is not. Neither
        spends a turn, which is the point, because the usual reason to move accounts is that this
        one has no model left to answer with.

        So this turn is the cost the command exists to avoid. SPEND IT ON ONE SHORT ANSWER.

        ## If `$ARGUMENTS` names anything

        Run it, once, and stop:

        ```
        tally account "$ARGUMENTS"
        ```

        `--auto` needs no special case: it arrives like any other word and the CLI reads the flag
        itself. Relay the one line it printed and nothing more. The move happens when this turn
        ENDS, the conversation comes back intact on the other account, and the pin sticks for the
        rest of the session. A non-zero exit means nothing was queued and the message says why.

        ## If nothing is named

        Do not run anything and do not open a picker: with no hook to draw one, reading the fleet
        here would spend a second turn on what should have cost none. Say this, in one line:

        > Tally's picker did not answer this prompt (it is not connected, or the dialog was left
        > open past its deadline). Try `/tally-account` again, run `tally account "<account>"` from
        > a terminal, or restart the session if it keeps happening.

        For "this project should ALWAYS run on that account", the instruction is different and is
        written down instead: `tally project set --account "<account>"`.
        """, commandManifest: "claudeSwitchCommand", hookManifest: "claudeSwitchHook",
                      formerNames: ["tally-switch"])
    }
}
