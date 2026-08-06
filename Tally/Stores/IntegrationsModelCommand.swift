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
        PromptCommand(name: "tally-model", hookMarker: "hook-model", markdown: """
        ---
        description: Run this Claude Code session on a named model and effort, for the rest of it
        argument-hint: [model] [effort] | auto
        allowed-tools: Bash(tally:*), AskUserQuestion
        ---

        <!-- \(promptCommandMarker), managed by Tally.app (Settings -> Integrations); safe to delete -->

        # Run this conversation on a different model

        YOU ARE THE FALLBACK. Tally normally answers `/tally-model` without waking a model at all,
        in both of its shapes: a prompt hook queues the change when a model is named, and prints
        what this session runs when one is not. Either way the prompt stops there and no turn is
        spent, which is the point, because a common reason to reach for this command is that the
        model this session is on has nothing left to answer with.

        So reaching this file means the hook did not answer: it is not registered on this machine,
        or shell execution is turned off by policy. Do the work here instead.

        ## What this command is for

        Claude Code's own `/model` changes the model of the running process. Tally's supervisor
        relaunches that process from its own command line whenever it hands the session to another
        account, adopts a settings change, or replaces itself after an app update - and every one of
        those puts the original model back. This command writes the choice where the relaunch reads
        it, so it survives all of them and lasts for the rest of the conversation.

        ## When a model is named

        `$ARGUMENTS` carries whatever followed the command: a model, optionally an effort after it,
        or the word `auto`. Pass it straight through:

        ```
        tally model $ARGUMENTS
        ```

        Do not quote it as one word: this command takes up to two, and neither can contain a space.
        `auto` needs no special case either - the CLI reads it itself, so the same line releases the
        pin.

        ## When nothing is named

        With the hook in place the user has already seen what the session runs, so this is the
        degraded path: do by hand what the hook would have done for free.

        1. Run `tally model`. With no arguments and no terminal to draw a menu on, it prints what
           this session runs, which layer decided each half of it, and the effort levels that exist.
        2. Ask with AskUserQuestion which model they want, one option per model the output listed,
           and mention that naming no effort leaves the current one alone.
        3. Apply it: `tally model <model> [effort]`.

        Mention, once, that the free path exists: with Tally's hook installed `/tally-model` answers
        both shapes itself, and in a terminal `tally model` on its own opens an arrow-key picker.
        Neither spends a turn.

        ## What to tell them afterwards

        Relay what the command printed, and the rest of what it means:

        - THE CHANGE HAPPENS WHEN THIS TURN ENDS, not while the command runs. The session then
          restarts on the new pair with the conversation intact, so the next thing they type is
          answered from the same context.
        - IT STICKS FOR THE REST OF THE SESSION. The launch default in Tally's Settings stops moving
          this conversation, which is the difference between this and asking again in ten minutes.
        - Naming only a model leaves the effort exactly as it is. Say so, because the alternative
          reading (that it reset the depth) is the one that would worry them.
        - `tally model auto` hands the session back to this project's profile and then the app's
          default. It is the only way out; nothing else releases it.
        - Changing the model can also move the session to another ACCOUNT, because a drained window
          for one model does not rule an account out for another. If no account has room for the
          model they named, it runs there anyway and says so rather than waiting.
        - A non-zero exit means nothing was queued: an effort that is not a real level (the message
          lists them), a model name with characters that cannot go on a command line, or a session
          nothing is supervising. Read the message rather than assuming it worked.

        For "this project should ALWAYS run that model", the instruction is different and is written
        down instead: `tally project set --model <model> [--effort <effort>]`.
        """, commandManifest: "claudeModelCommand", hookManifest: "claudeModelHook")
    }
}
