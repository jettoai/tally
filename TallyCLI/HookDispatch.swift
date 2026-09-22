import Foundation

/// The internal hook subcommands, lifted out of main.swift's entry switch: they are one family,
/// they are never typed by a person, and the entry file is at its size cap.
/// Returns nil for a word that is not one of ours, which the caller reads as "not handled here".
func runHookSubcommand(_ word: String, _ rest: [String]) -> Int32? {
    switch word {
    case "hook-tally":    // internal: the `/tally` prompt hook (TallyHook.swift)
        return runHookTally(args: rest)
    case "hook-notify":   // internal: Claude Code's Notification hook (UserNotice.swift)
        return runHookNotify(args: rest)
    // internal: Claude Code's three subagent-facing hooks, which take the event as their argument
    // because one subcommand answers all three (HookAgents.swift).
    case "hook-agents":
        return runHookAgents(args: rest)
    // internal: Claude Code's two context-carrying hooks, which take the event as their argument for
    // the reason the three above do - one subcommand answers both, and the answer has to name the event
    // it is answering (HookKnock.swift).
    case "hook-knock":
        return runHookKnock(args: rest)
    // internal: Claude Code's `PreToolUse` hook on the `Artifact` tool, which takes no argument because
    // it answers for exactly one tool - the matcher it is registered under names it, and the payload
    // names it again (HookArtifact.swift).
    case "hook-artifact":
        return runHookArtifact()
    // The two the merge replaced. Still answered, because a registration written by an older app is in
    // somebody's settings.json until the self-heal rewrites it, and a hook that runs a subcommand this
    // binary does not have prints usage and lets the expansion through - a model turn, for a command
    // whose whole point is not spending one.
    case "hook-switch":   // internal: the pre-merge `/tally-account` prompt hook (SwitchHook.swift)
        return runHookSwitch(args: rest)
    case "hook-model":    // internal: the pre-merge `/tally-model` prompt hook (ModelHook.swift)
        return runHookModel(args: rest)
    default:
        return nil
    }
}
