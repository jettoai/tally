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

/// The registered command for one event. Through the public path, like the hooks beside it, because
/// that is the one that survives the app bundle moving.
func quotaKnockHookCommand(_ event: String) -> String {
    "/usr/local/bin/tally hook-knock \(event)"
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

/// The answer, remembered per config home for the life of the supervisor that asks.
///
/// A READ OF A FILE ON A 2s POLL is what this is for. The question is only asked on a tick that is
/// about to announce something, which is rare, but a session handed between accounts asks it about
/// each home it lands on and an unmemoized answer would be a parse of somebody's whole harness
/// configuration every time.
///
/// PER LAUNCH RATHER THAN PER TICK, and the staleness that buys is stated rather than defended: a
/// user who installs the integration while a session is running keeps the typed channel until that
/// session restarts, which is the same lag every other Integrations row has (the hook itself is only
/// registered for Claude Code processes that start afterwards).
struct QuotaKnockChannel {
    private var answers: [String: Bool] = [:]

    /// `probe` is injected for the suite alone; the supervisor always asks the filesystem.
    mutating func hookInstalled(home: String?,
                                probe: (String?) -> Bool = quotaKnockHookRegistered(home:)) -> Bool {
        // A home nothing can name is asked once and never remembered: there is no key to remember it
        // under, and the answer is the fallback either way.
        guard let home else { return probe(nil) }
        if let known = answers[home] { return known }
        let answer = probe(home)
        answers[home] = answer
        return answer
    }
}
