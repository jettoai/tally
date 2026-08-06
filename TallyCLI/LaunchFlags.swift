import Foundation

// What a launch's own arguments say about how it must be treated, split out of
// SupervisorRuntime.swift for file size. Every reader here answers a question about the ARGS the
// child was given, and nothing about the fleet, the quota or the transcript, which is why they can
// be tested with a string array and no supervisor at all.

/// Whether auto-handoff is on for this launch (opt out with `--no-handoff` or TALLY_AUTO_HANDOFF=0).
func autoHandoffEnabled(args: [String]) -> Bool {
    if optionsOnly(args).contains("--no-handoff") { return false }
    if let raw = getenv("TALLY_AUTO_HANDOFF"), String(cString: raw) == "0" { return false }
    return true
}

/// Whether a running session adopts a later change to the launch-default model (Settings). Mirrors
/// the `--no-handoff` opt-out. A hand-typed `--model` is handled separately at the call site (a
/// deliberate model choice must never be overridden), so this only covers the explicit escape hatch.
func autoFollowEnabled(args: [String]) -> Bool {
    if optionsOnly(args).contains("--no-follow") { return false }
    if let raw = getenv("TALLY_AUTO_FOLLOW"), String(cString: raw) == "0" { return false }
    return true
}

/// `args` minus the given value-taking flags (and their values), with everything from a bare `--`
/// onward passed through untouched: that part is the prompt, and editing it edits what the user
/// said.
func removingFlagPairs(_ args: [String], _ flags: Set<String>) -> [String] {
    let options = optionsOnly(args)
    var out: [String] = []
    var skip = false
    for argument in options {
        if skip { skip = false; continue }
        if flags.contains(argument) { skip = true; continue }
        out.append(argument)
    }
    return out + args[options.count...]
}

// MARK: - Positionals, and why a relaunch must not carry them

/// The options a claude child takes that consume NO value, so the word after one is a POSITIONAL
/// rather than its value. Everything else that starts with a dash is assumed to take a value, which
/// is the safe assumption in the one place this is used (`withoutPositionals`): guessing "value"
/// wrongly leaves a stray word in the args, guessing "no value" wrongly DELETES a real one.
///
/// Deliberately small and evidence-based: every entry is a flag this repo already handles as
/// valueless somewhere else (`printFlags` and `continueFlags` are reused rather than respelled - the
/// latter is what `relaunchArgs` below skips without consuming a following word - and
/// `--dangerously-skip-permissions` is what `applyLaunchDefaults` injects on its own). A flag whose
/// arity we have not established is left out on purpose - it degrades to a positional surviving one
/// relaunch, never to a launch losing an argument it needed.
let valuelessChildFlags: Set<String> = printFlags.union(continueFlags)
    .union(["--dangerously-skip-permissions"])

/// `args` with every POSITIONAL argument removed, keeping the options and the values they take.
///
/// A positional handed to `claude` is the session's INITIAL PROMPT: the CLI types it into the input
/// box and submits it. That is right exactly once, on the launch the user typed. Every relaunch
/// after it resumes a conversation that already contains that prompt (and its answer), so carrying
/// the word along means submitting it again, and again, at every cap handoff, switch, reload and
/// self-update for the life of the session - which is what two live sessions were found doing on
/// 2026-08-06, re-typing `tj3裡` and `u0v49` (terminal noise that had landed in their argv before
/// the input drain existed) into every child since. The drain (TerminalHandover.swift) cleans the
/// TTY; nothing cleaned the argv, and the argv is copied forward across the self-update exec, so
/// those two would have carried their fossil indefinitely.
///
/// The parse follows the convention every other reader here uses (`flagValue`, `optionsOnly`,
/// `launchPrimaryModel`): a word after an option is that option's value, a word that is itself a
/// flag never is, and a bare `--` ends the options. Past that marker EVERYTHING is positional (that
/// is what the marker means), so the whole tail goes, marker included.
func withoutPositionals(_ args: [String]) -> [String] {
    let options = optionsOnly(args)
    var kept: [String] = []
    var index = 0
    while index < options.count {
        let token = options[index]
        index += 1
        // A bare "-" is not an option (it is the conventional name for stdin), and anything not
        // starting with a dash is the prompt.
        guard token.hasPrefix("-"), token != "-" else { continue }
        kept.append(token)
        // The word behind it is its value, unless the flag takes none or that word is a flag itself.
        if !valuelessChildFlags.contains(token), index < options.count,
           !options[index].hasPrefix("-") {
            kept.append(options[index])
            index += 1
        }
    }
    return kept
}

/// The launch args a relaunch runs with. A known session id resumes that conversation. With no id
/// (the child has not written a transcript yet, so the watcher located nothing) it depends on where
/// the relaunch lands: a move to ANOTHER account drops `--continue`/`--resume` so it cannot pull up
/// an unrelated old conversation there, but a relaunch on the SAME account keeps the original
/// `--continue` - stripping it would open an EMPTY session instead of the one the user resumed
/// (`tally claude --continue` restarted before its first turn, 2026-07-25). On the same home
/// `--continue` can only reach that same latest conversation.
///
/// EVERY relaunch loses the positionals, which is where the initial prompt lives (see
/// `withoutPositionals` above): the conversation being resumed already contains it, and re-passing
/// it submits it a second time. The one case that changes anything a user would want is a session
/// killed before it wrote a transcript at all, whose prompt then has to be retyped instead of being
/// silently sent again - a visible, one-off cost against a fossil that re-types itself forever.
func relaunchArgs(_ args: [String], sessionID: String?, sameAccount: Bool) -> [String] {
    // The prompt goes first, so a `-c` the user SAID can no longer be read as a request to
    // continue: the rewriting below only ever meant to touch the options, and what is left is
    // options and their values (`withoutPositionals`). The old start mode goes with it - `--resume`
    // through the value-dropping helper next door, `--continue` by name, since it carries none.
    let options = withoutPositionals(args)
    let next = removingFlagPairs(options, ["--resume", "-r"])
        .filter { !continueFlags.contains($0) }
    if let sessionID { return ["--resume", sessionID] + next }
    guard sameAccount, options.contains(where: { continueFlags.contains($0) })
    else { return next }
    return ["--continue"] + next
}

/// The two halves of `sessionFlags` (Snapshot.swift), partitioned rather than listed again so a flag
/// added there lands in one of them instead of being silently uncovered here.
let printFlags: Set<String> = ["--print", "-p"]
let resumeFlags = sessionFlags.subtracting(printFlags)

/// The two spellings of "continue the latest conversation", named because three readers above share
/// them (what takes no value, what a relaunch strips, what a same-account relaunch re-adds) and
/// three literal copies of a pair is how they would come to disagree. A named subset of
/// `resumeFlags` rather than a partition of it: the other half is `--resume`, which takes a value.
let continueFlags: Set<String> = ["--continue", "-c"]

/// Whether this session may be moved to another account, which is two questions wearing one name:
/// can the work be CARRIED, and is re-running it safe. A launch answers to one of three classes.
///
/// SECOND line of defence as of the entry gate below: a one-shot run is no longer supervised at all,
/// so nothing should ever ask this about one. It keeps its answer anyway, because "nothing should"
/// is a statement about today's callers - a supervisor from an older build is still resident on
/// somebody's machine, and the next entry point has not been written yet.
///
///  - A `--print` run: NEVER. There is no conversation to lose, which is exactly what made this one
///    easy to get wrong. Moving it means killing a command mid-flight and running it AGAIN on the
///    other account, so every tool call and every external write in it happens twice. Nothing about
///    a bound transcript makes that safe, so unlike the class below it is not a matter of waiting -
///    and a print run does write one (241 sit in each account's probe directory right now, which is
///    why `ClaudeUsageCLI` prunes them), so a rule reading only "is it located" would clear it.
///  - A `--continue`/`--resume` launch: only once `sessionLocated`. Crossing accounts drops those
///    flags (`relaunchArgs` above: on the target account they name a different conversation), so the
///    resumed id is the only way to bring the conversation along, and it comes from the binding.
///  - Anything else, a plain interactive launch: yes. There is nothing to carry and nothing to
///    re-run. Gating this one too would strand brand new sessions on a dying account to protect a
///    conversation that does not exist - `relaunchArgs` hands the move exactly the args a fresh
///    start would have got anyway.
///
/// `launchArgs` is what the CHILD was launched with, so a session that was moved once and now runs
/// `--resume <id>` reads as resuming, which it is.
func carryableSession(launchArgs: [String], sessionLocated: Bool) -> Bool {
    let options = optionsOnly(launchArgs)
    if options.contains(where: { printFlags.contains($0) }) { return false }
    return sessionLocated || !options.contains(where: { resumeFlags.contains($0) })
}

/// Whether the launch-default pair a follow adoption wants is ALREADY what this session runs, judged
/// against the flags the child actually carries rather than against the pair follow last adopted.
///
/// The two can disagree. `followedModel`/`followedEffort` in the loop record what FOLLOW set, and
/// every other rewrite of the launch args (the quota fallback profile, the safeguard restore)
/// deliberately leaves that baseline alone so its own change is never mistaken for a Settings change.
/// The cost is a stale baseline: once the user edits Settings to the very pair one of those rewrites
/// already put on the command line, follow compares against the old baseline, sees a difference, and
/// queues an adoption whose relaunch would change nothing ("adopting when this session goes idle" on
/// a session already running opus/xhigh, then a no-op restart at the next idle moment, 2026-07-27).
///
/// Model comparison goes through `modelsAgree`, so the alias a user types in Settings (`opus`) counts
/// as the full id an earlier rewrite may have written (`claude-opus-4-8`). Both sides nil is a match:
/// neither declares a model, so there is nothing to adopt. One side nil is not, because adopting
/// would add or drop the flag. Effort is exact (lowercased): a policy with no effort against args
/// carrying `--effort` IS a real change, since the adoption takes that flag away.
func followAlreadySatisfied(desiredModel: String?, desiredEffort: String?,
                            launchArgs: [String]) -> Bool {
    let currentModel = flagValue(launchArgs, "--model")
    let currentEffort = flagValue(launchArgs, "--effort")?.lowercased()
    let sameModel = (desiredModel == nil && currentModel == nil)
        || modelsAgree(desiredModel, currentModel)
    return sameModel && desiredEffort?.lowercased() == currentEffort
}

/// Whether a launch gets a resident supervisor at all, or is left to `exec` on its own.
///
/// Supervision earns its keep by outliving a conversation: it moves the session between accounts,
/// adopts Settings changes, restarts on request. Every one of those does the same physical thing -
/// kill the child, start it again - which a CONVERSATION survives (it is resumed by id) and a
/// one-shot run does not. Re-running `claude -p "ship it"` on another account does not continue
/// anything; it does the work a second time, tool calls, writes and all.
///
/// The mover paths each learned that separately and one at a time (`carryableSession` above is the
/// scar), which is the tell that the question was being asked in the wrong place. A one-shot run
/// does not need a cheaper handoff, it needs no supervisor, and refusing it here retires the
/// question for every path at once - including the ones that never asked it: the cap handoff, the
/// degradation rescue and the follow adoption all restart the child too.
///
/// `stdoutIsTTY` is not a detail. `--print` is the explicit spelling, but claude also enters print
/// mode implicitly when its stdout is not a terminal, so `tally claude 'summarise this' | tee out`
/// is a one-shot run carrying no flag that says so. Reading the terminal is how the CLI itself
/// decides, so it is how this decides.
///
/// Interactive launches are unaffected: a terminal on stdout and no print flag is every ordinary
/// session, and it is supervised exactly as before.
func shouldSupervise(args: [String], stdoutIsTTY: Bool) -> Bool {
    guard autoHandoffEnabled(args: args) else { return false }
    return stdoutIsTTY && !optionsOnly(args).contains(where: { printFlags.contains($0) })
}
