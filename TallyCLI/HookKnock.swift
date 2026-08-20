import Foundation

// The `tally hook-knock <event>` subcommand: Claude Code's `UserPromptSubmit` and `PostToolUse`
// hooks, registered by the app's Integrations pane. It delivers the one sentence this session's
// supervisor has filed for it (QuotaKnockNotice.swift holds the record and every rule about the
// file; this is the plumbing around them).
//
// THE SAME HARD CONSTRAINTS AS THE OTHER HOOKS, and one more that is this one's alone. Like them it
// never throws, never blocks and answers 0 whatever happens: this runs inside somebody's session,
// several times a turn, on events they did not ask for. UNLIKE them it PRINTS, because printing is
// how a hook hands Claude Code context - so the rule "never print" becomes the sharper one that
// STDOUT CARRIES THE HOOK JSON OR NOTHING AT ALL. Every failure path here returns 0 in silence: a
// diagnostic on stdout is not a diagnostic, it is a parse error in the middle of somebody's turn.
//
// WHAT IT COSTS WHEN THERE IS NOTHING TO SAY, which is nearly every run: one `rename(2)` that
// answers ENOENT, after two environment lookups and one small read. The ordinary session pays that
// per tool call and delivers nothing.

/// The audit word a delivered knock leaves in the input log (grep `input=quota-knock-delivered`).
///
/// ITS OWN OUTCOME BESIDE THE FILING, which is what makes the two halves of this channel separable
/// afterwards: `quota-knock-filed` says the supervisor decided a session should be told, and this
/// one says the session was actually told. A file written and never claimed leaves the first and not
/// the second, and that pair is the whole evidence that an idle session's hook never ran.
let quotaKnockDeliveredOutcome = "quota-knock-delivered"

/// `tally hook-knock <event>` - one of the two hooks a filed knock is delivered through.
///
/// A SESSION THIS TOOL DID NOT LAUNCH IS NOT OURS TO SPEAK INTO: without the supervisor marker in
/// the environment there is nobody who could have filed anything, so it returns before reading
/// stdin.
///
/// Every collaborator is injected with the real one as its default, so the whole table above is
/// assertable without a supervisor, a config home or a terminal.
func runHookKnock(args: [String],
                  environment: [String: String] = ProcessInfo.processInfo.environment,
                  input: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
                  dir: URL = supervisorStateDir,
                  alive: (pid_t) -> Bool = { supervisorAlive($0) },
                  watching: (String) -> String? = {
                      readSessionContext(pid: $0)?.transcriptSessionID
                  },
                  log: URL = sessionInputLog,
                  now: Date = Date(),
                  emit: (String) -> Void = { print($0) }) -> Int32 {
    guard let supervisor = environment["TALLY_SUPERVISOR_PID"],
          let pid = pid_t(supervisor), alive(pid) else { return 0 }
    let payload = (try? JSONSerialization.jsonObject(with: input())) as? [String: Any]
    // WHICH EVENT THIS IS, because the answer has to name it back (`hookEventName`) and Claude Code
    // reads a reply that names the wrong one as a reply to something else. The payload's own word
    // leads and the registered argument is the fallback: they agree in every ordinary run, and where
    // they cannot (a registration somebody wrote by hand, an event renamed in a later Claude Code)
    // the one the event actually arrived under is the true one.
    //
    // AN EVENT NEITHER OF THEM NAMES CONSUMES NOTHING. An allow-list rather than a passthrough
    // because `additionalContext` does not mean the same thing on every event: on `Stop` it
    // CONTINUES THE CONVERSATION (`quotaKnockHookEvents` states the measurement), so a hook wired by
    // hand onto that event would spend a model turn on this. Returning silently leaves the sentence
    // on disk for one of the two events that carry it for free.
    guard let event = quotaKnockHookEvent(registered: args.first,
                                          payload: payload?["hook_event_name"] as? String)
    else { return 0 }
    // WHOSE EVENT IS THIS. The marker above is inherited by every descendant of a supervised
    // session, a `claude` launched from inside one included, so a nested session would otherwise
    // take the sentence filed for the conversation its parent is having - and take it for good,
    // since a claim consumes it. Both ends have to be able to say who they are: an event with no id,
    // or a supervisor too old to publish which conversation it watches, reads as "cannot say", which
    // is the same fail-open every other witness on this track takes.
    let session = (payload?["session_id"] as? String).flatMap {
        isTranscriptSessionID($0) ? $0 : nil
    }
    if let session, let watched = watching(supervisor), watched != session { return 0 }
    guard let notice = claimQuotaKnockNotice(pid: supervisor, dir: dir) else { return 0 }
    emit(quotaKnockHookOutput(event: event, context: notice.message))
    // ON THE SAME CHANNEL THE TYPED KNOCK IS RECORDED ON, and for the same reason: the question that
    // log answers is "what reached my conversation, and when", and a sentence nobody asked for is
    // exactly the entry a reader needs to be able to tell from one they did.
    appendSessionInputLine(sessionInputLogLine(pid: supervisor, outcome: quotaKnockDeliveredOutcome,
                                               text: notice.message, now: now), to: log)
    return 0
}

/// The event this run answers for, or nil when it is not one a knock may be delivered on.
///
/// Pure, so the reconciliation above is assertable: the payload's word wins when it names an event
/// this build delivers on, the registered argument answers otherwise, and anything else is nothing.
func quotaKnockHookEvent(registered: String?, payload: String?) -> String? {
    if let payload, quotaKnockHookEvents.contains(payload) { return payload }
    guard let registered, quotaKnockHookEvents.contains(registered) else { return nil }
    return registered
}

/// The one line this subcommand ever prints: Claude Code's hook JSON, carrying the sentence as
/// context for the model to read on its next request.
///
/// `additionalContext` rather than plain stdout, though both are read on `UserPromptSubmit`: only
/// the JSON form is read on `PostToolUse`, and one shape for both events is one thing to get right
/// (hooks reference, 2026-08-20). Neither form produces a visible transcript entry; both arrive as a
/// system reminder naming the hook.
///
/// BUILT BY THE SERIALIZER rather than by interpolation, because what goes in it is a sentence
/// carrying an account label the user typed: a quote or a backslash in that label would otherwise
/// end the JSON early and hand Claude Code a document it cannot parse. The fallback can only be
/// reached by a String that is not representable in JSON, which is not a thing a Swift String can
/// be, and it is an empty object rather than an empty string so that the one line printed is always
/// a document.
func quotaKnockHookOutput(event: String, context: String) -> String {
    let document: [String: Any] = ["hookSpecificOutput": ["hookEventName": event,
                                                          "additionalContext": context]]
    guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}
