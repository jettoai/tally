import Foundation

// `/tally-switch` - the slash command that moves a session to another account. The machinery that
// installs it, and the prompt hook that makes it free, are shared with every command Tally ships and
// lives in IntegrationsPromptCommand.swift; what is here is this command's own text.
//
// The command file is the FALLBACK for a machine where the hook is not registered or shell execution
// is turned off by policy, and it is also the ONLY half a user can read - so it says what the hook
// does rather than assuming the hook is there.
extension IntegrationsStore {
    /// `/tally-switch`: move this conversation to another account, keeping the conversation.
    nonisolated static var switchPromptCommand: PromptCommand {
        PromptCommand(name: "tally-switch", hookMarker: "hook-switch", markdown: """
        ---
        description: Pin this Claude Code session to another account, keeping the conversation
        argument-hint: [account name | --auto]
        allowed-tools: Bash(tally:*), AskUserQuestion
        ---

        <!-- \(promptCommandMarker), managed by Tally.app (Settings -> Integrations); safe to delete -->

        # Move this session to another account

        YOU ARE THE FALLBACK. Tally normally answers `/tally-switch` without waking a model at all,
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
        tally switch "$ARGUMENTS"
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
        3. Queue the move to the account they chose: `tally switch "<account>"`.

        Mention, once, that the free path exists: with Tally's hook installed `/tally-switch` lists
        the accounts itself, and in a terminal `tally switch` on its own opens an arrow-key picker.
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
        - Two ways out, and one of them is not theirs. `tally switch --auto` releases the pin and
          hands the session back to automatic selection. A HARD CAP hands it on anyway, because a
          session pinned to an account that cannot answer is worse than one that moved: that
          handoff clears the pin and says so, and they have to re-pin once quota returns.
        - No project profile is touched either way, and the pin dies with the session.
        - A non-zero exit means nothing was queued: no such account, a name that fits SEVERAL
          accounts (the message lists them - type one of those exactly), or a session nothing is
          supervising. Read the message rather than assuming it worked.

        For "this project should ALWAYS run on that account", the instruction is different and is
        written down instead: `tally project set --account "<account>"`.
        """, commandManifest: "claudeSwitchCommand", hookManifest: "claudeSwitchHook")
    }
}
