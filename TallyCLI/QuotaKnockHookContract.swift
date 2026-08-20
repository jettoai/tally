import Foundation

// WHICH HOOKS CARRY A FILED KNOCK, spelled once for the two ends that have to agree about it.
//
// The app registers `tally hook-knock <event>` in every Claude account's settings.json
// (IntegrationsKnockHook.swift), the CLI answers to it (HookKnock.swift), and the supervisor asks
// whether that registration is there before it decides which channel to use (QuotaKnock.swift). All
// three read the spellings below rather than each writing their own, because a drift between them
// fails SILENTLY in both directions: a marker the app writes and the supervisor does not recognise
// reads as "no hook installed" and quietly goes back to typing, and one the CLI does not answer to
// is a hook that runs on every prompt and delivers nothing.
//
// Both targets compile this file for that reason (project.yml), the way PromptHookInput.swift and
// PickContract.swift are shared: these are separate processes speaking through a file the user owns.

/// The Claude Code events a filed knock may be delivered on, in the order a session meets them.
///
/// TWO, AND `Stop` IS DELIBERATELY NOT ONE OF THEM. `Stop` accepts `additionalContext` as well, and
/// Claude Code's own documentation says what it does with it: "the conversation continues so Claude
/// can act on it", under the same loop protections as `decision: "block"`. That is a model turn this
/// feature would be spending to deliver a sentence about running out of quota, which is the one
/// thing it must not cost (checked against the hooks reference, 2026-08-20). The two below add
/// nothing: `UserPromptSubmit` rides a turn the user has already started, and `PostToolUse` rides
/// one that is already running.
///
/// `PostToolUse` is what makes this feature reach the session it exists for. A conversation in the
/// middle of a work package calls tools constantly and submits no prompts for minutes at a time,
/// and that conversation is precisely the one the typed channel can never interrupt.
let quotaKnockHookEvents = ["UserPromptSubmit", "PostToolUse"]

/// The program a registration names. The public path, like the hooks beside it, because that is the
/// one that survives the app bundle moving - and a constant rather than a literal in the command
/// below, because the supervisor has to be able to ask whether the thing at it can actually run
/// (`quotaKnockCLIDeliverable`).
let quotaKnockHookCLIPath = "/usr/local/bin/tally"

/// The registered command for one event.
func quotaKnockHookCommand(_ event: String) -> String {
    "\(quotaKnockHookCLIPath) hook-knock \(event)"
}

/// The subcommand and its event as their own words. A SUFFIX RATHER THAN A SUBSTRING, load-bearing
/// for the reason `isOurHook` gives one file over: a user's own `/opt/bin/my-hook-knock PostToolUse`
/// would contain this string, and treating it as ours would silently replace their hook and delete
/// it on uninstall.
func quotaKnockHookMarker(_ event: String) -> String {
    " hook-knock \(event)"
}

/// Whether a parsed settings.json registers our hook for EVERY event a knock can be delivered on.
///
/// ALL RATHER THAN ANY, and that is the conservative direction rather than a strict one. What this
/// answers is "may the supervisor stop typing", so a half-registration has to read as no channel at
/// all: a session with only `UserPromptSubmit` registered would hear about a drought whenever it
/// next submits a prompt, which for the busy session this feature exists for can be an hour after
/// the account ran dry. Answering no costs the tty channel's own holds, which is where this feature
/// started.
///
/// Pure over the parsed document, so the whole table is assertable without a config home.
func quotaKnockHookRegistered(settings: [String: Any]) -> Bool {
    let hooks = settings["hooks"] as? [String: Any]
    return quotaKnockHookEvents.allSatisfy { event in
        ((hooks?[event] as? [[String: Any]]) ?? []).contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String)?.hasSuffix(quotaKnockHookMarker(event)) == true
            }
        }
    }
}

/// The same question of a config home on disk. Read-only, and every way of getting no answer reads
/// as "not registered": a home that is not there, a document that will not parse, a settings.json
/// this process cannot read. The cost of being wrong that way is the typed channel, which works.
func quotaKnockHookRegistered(home: String?) -> Bool {
    guard let home else { return false }
    let file = URL(fileURLWithPath: home).appendingPathComponent("settings.json")
    guard let data = try? Data(contentsOf: file),
          let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return false }
    return quotaKnockHookRegistered(settings: settings)
}

/// Whether the program those registrations name can actually be run.
///
/// AN ENTRY IS NOT A DELIVERY. The command is an absolute path into a symlink the user installs and
/// removes from a row of its own ("Command line tool"), so a settings.json can carry a perfect pair
/// of registrations that runs nothing: the link was never made, it was removed afterwards, or the
/// bundle it points into has been moved or thrown away. Claude Code tolerates a hook that fails
/// silently, so nothing anywhere would say so - and for THIS registration a silent failure is not a
/// feature that stays off, it is the fallback being switched off in favour of nothing.
///
/// `isExecutableFile` is the whole test, and it is the right one call here because it FOLLOWS the
/// link: a dangling symlink answers no. (The Integrations row next door has to work around exactly
/// that behaviour, because it needs to tell a dangling link of ours from an empty path so it can
/// keep offering Remove; this asks a boolean about running a program, which is the question that
/// answer already is.)
func quotaKnockCLIDeliverable(at path: String = quotaKnockHookCLIPath) -> Bool {
    FileManager.default.isExecutableFile(atPath: path)
}

/// Whether a knock filed for a session in this config home would actually be delivered: both hooks
/// registered, and the program they name able to run.
///
/// THE SCOPE OF THIS ANSWER IS ONE CHILD, and that is the correction this function exists to carry.
/// The hooks a Claude Code runs are the ones its settings.json held WHEN IT STARTED; installing them
/// into a running session changes nothing for that session, which is why the Integrations row has
/// always had that lag. So the supervisor asks this ONCE PER CHILD, at the moment it launches one,
/// and holds the answer for that child's life (Supervisor.swift). A memo keyed on the config home,
/// filled in lazily the first time a drought arrived, read the file at the wrong moment: after an
/// install it answered "filed" for a child whose snapshot has no such hook, and the sentence was
/// written to a file nothing would ever claim - with the arm already spent and the typed channel
/// skipped, which is worse than not having the feature (codex review of 2b4131f).
///
/// ASKED BEFORE THE CHILD IS SPAWNED, for the direction the race falls in. An install landing
/// between this reading and Claude Code's own leaves us with "not registered" and the child with the
/// hooks: the sentence is typed, and two hooks run for a file that is never there. The other order
/// puts the reading after the child's and gets the failure above.
///
/// `cli` is a parameter for the suite alone, and it is what makes the SECOND half assertable at all:
/// on a machine that has `tally` installed, the executability test answers true either way, so a
/// build that dropped it entirely would pass every check that asked this function about the real
/// path (measured here by mutation, 2026-08-20 - the mutant survived until this argument existed).
func quotaKnockFilingAvailable(home: String?, cli: String = quotaKnockHookCLIPath) -> Bool {
    quotaKnockHookRegistered(home: home) && quotaKnockCLIDeliverable(at: cli)
}
