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
        PromptCommand(name: "tally-account", hookMarker: "hook-switch", markdown: """
        ---
        description: Pin this Claude Code session to another account, keeping the conversation
        argument-hint: [account name | --auto]
        allowed-tools: Bash(tally:*), AskUserQuestion
        ---

        <!-- \(promptCommandMarker), managed by Tally.app (Settings -> Integrations); safe to delete -->

        # Move this session to another account

        YOU ARE THE FALLBACK. Tally normally answers `/tally-account` without waking a model at all,
        in both of its shapes: a prompt hook queues the move when an account is named, and prints
        the fleet to pick from when one is not. Either way the prompt stops there and no turn is
        spent, which is the point, because the usual reason to move accounts is that this one has
        no model left to answer with.

        So reaching this file means the hook did not answer: it is not registered on this machine,
        or shell execution is turned off by policy. Do the work here instead.

        ## When an account is named

        `$ARGUMENTS` carries whatever followed the command. If it names an account, queue the move
        and stop:

        ```
        tally account "$ARGUMENTS"
        ```

        `--auto` needs no special case here. It arrives as `$ARGUMENTS` like any other word and the
        CLI reads the flag itself, so the same line releases the pin: one mapping, shared by the
        hook and the command, with nothing to keep in step.

        ## When nothing is named

        With the hook in place the user has already seen the fleet and only has to type a name, so
        this is the degraded path: do by hand what the hook would have done for free.

        1. Run `tally status`. Every Claude account is listed with the percent left of its session
           (5 hour), weekly, and flagship model windows, and `->` marks the one a launch would land
           on right now.
        2. Ask with AskUserQuestion, one option per Claude account: the account's label as the
           option, its three remaining windows as the description. Put the account with the most
           headroom first and mark it Recommended. Do not pick for the user: the whole point of the
           bare command is that they want the choice.
        3. Queue the move to the account they chose: `tally account "<account>"`.

        Mention, once, that the free path exists: with Tally's hook installed `/tally-account` lists
        the accounts itself, and in a terminal `tally account` on its own opens an arrow-key picker.
        Neither spends a turn.

        ## What to tell them afterwards

        Relay what the command printed, and the rest of what it means:

        - The move happens when this turn ENDS, not while the command runs. The session then comes
          back on the other account with this conversation intact, so the next thing they type is
          answered from the same context.
        - IT STICKS FOR THE REST OF THE SESSION. The account named is where this conversation
          stays: automatic account selection (the idle rebalance off a nearly dry account, the
          model-degradation rescue, a pin moved in the Tally panel) stops moving it. That is the
          difference between this and asking again in ten minutes, so say it.
        - The pin is theirs to release (`tally account --auto`), and a hard cap no longer takes it
          from them. A hard cap is answered inside that decision where it can be: the session
          keeps the account and drops to the fallback model Settings declares, provided this
          account can still serve one COMFORTABLY (a window with a few percent left does not
          count). Otherwise it is handed on, which clears the pin and says so on the terminal -
          unless `tally model` has pinned the model too (that pin wins: the model is kept, the
          account is not), or the numbers to decide on are missing, in which case it waits: about
          two minutes for a fresh reading of this account, and for as long as it takes if Tally
          has stopped publishing the snapshot or its own pin leaves this session nowhere to go.
          So "I hit a cap" is not a reason to re-pin: unless the terminal said the session was
          handed on, the pin is still there.
        - No project profile is touched either way, and the pin dies with the session.
        - A non-zero exit means nothing was queued: no such account, a name that fits SEVERAL
          accounts (the message lists them - type one of those exactly), or a session nothing is
          supervising. Read the message rather than assuming it worked.

        For "this project should ALWAYS run on that account", the instruction is different and is
        written down instead: `tally project set --account "<account>"`.
        """, commandManifest: "claudeSwitchCommand", hookManifest: "claudeSwitchHook",
                      formerNames: ["tally-switch"])
    }
}
