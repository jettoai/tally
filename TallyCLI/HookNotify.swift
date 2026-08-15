import Foundation

// The `tally hook-notify claude` subcommand: Claude Code's `Notification` hook, registered by the
// app's Integrations pane. Split from UserNotice.swift so the record and its file stay
// dependency-free (the suffix list in PendingNotice.swift needs them, and the test harnesses that
// compile that file must not have to bring a subcommand's whole world along) - the same split
// Statusline.swift and TranscriptIdentity.swift already keep one axis over.

// MARK: - Which of the nine this event is

/// The keys a `Notification` payload might carry its type under, in the order they are tried.
///
/// THE DOCUMENTATION NAMES THE NINE TYPES AND MATCHES ON THEM, BUT DOES NOT NAME THE FIELD THEY
/// ARRIVE IN, so this reads the plausible spellings rather than betting on one. `notification_type`
/// leads because every other field in a hook payload is snake_case (`session_id`,
/// `transcript_path`, `hook_event_name`); the camelCase twin and the bare `type` follow for a
/// payload that spells it either of the other ways.
///
/// GETTING THIS WRONG IS SAFE IN ONE DIRECTION ONLY, which is why it is a list and not a guess: a
/// field nobody finds reads as "no type", the filter fails open, and the board behaves exactly as
/// it did before this existed (every notification a wait). The registration's matcher is the layer
/// that does not depend on any of this - Claude Code never fires the hook for the settled four in
/// the first place, and this is the belt behind it.
let notificationTypeKeys = ["notification_type", "notificationType", "type"]

/// The type this event names, or nil when none of the spellings is present (or carries something
/// that is not a string, which reads the same way: this build cannot tell what kind of event it is).
func notificationTypeInEvent(_ event: [String: Any]?) -> String? {
    guard let event else { return nil }
    return notificationTypeKeys.lazy.compactMap { event[$0] as? String }
        .first { !$0.isEmpty }
}

// MARK: - The hook itself

/// `tally hook-notify claude` - Claude Code's `Notification` hook (registered by the app's
/// Integrations pane). Reads the event JSON on stdin and leaves it for this session's supervisor.
///
/// THE SAME HARD CONSTRAINTS AS THE STATUS LINE, and for a sharper reason: this runs inside
/// somebody's session on an event they did not ask for. It never throws, never prints, never
/// blocks on anything, and answers 0 whatever happens - a hook that failed loudly would put its
/// complaint on the terminal the child is drawing into (PendingNotice.swift states that rule) for
/// a feature nobody in that terminal is looking at.
///
/// A SESSION THIS TOOL DID NOT LAUNCH IS NOT OURS TO REPORT ON: without the supervisor marker in
/// the environment there is nobody to leave the event for, so it returns before reading anything.
func runHookNotify(args: [String]) -> Int32 {
    guard let supervisor = ProcessInfo.processInfo.environment["TALLY_SUPERVISOR_PID"],
          let pid = pid_t(supervisor), supervisorAlive(pid) else { return 0 }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
    // NOT EVERY NOTIFICATION IS A WAIT. Four of the nine are news - a login that succeeded, a
    // background agent that FINISHED, an elicitation completed or answered - and recording one as a
    // wait would turn every subagent's last breath into a red dot that stands until somebody types
    // (SessionState.swift carries the vocabulary and why both ends read it).
    //
    // The registration's matcher already asks Claude Code not to fire for these, so reaching here
    // means one of: a registration written by an older app, a matcher a future Claude Code stops
    // honouring, or a hook somebody wired by hand. This is the layer that does not depend on the
    // far end doing as it was asked.
    let type = notificationTypeInEvent(event)
    guard notificationWaitsForUser(type) else { return 0 }
    let sessionID = (event?["session_id"] as? String).flatMap {
        isTranscriptSessionID($0) ? $0 : nil
    }
    // WHOSE EVENT IS THIS. The marker above is inherited by every descendant of a supervised
    // session, including a `claude` launched from inside one, so a nested session's permission
    // request would otherwise be reported against the conversation its parent is having (the
    // defect family `SupervisedSession.transcriptSessionID` was added to close). Both ends have to
    // be able to say who they are for this to decide anything: an event with no id, or a
    // supervisor too old to publish which conversation it watches, reads as "cannot say" and the
    // event is recorded, which is the same fail-open every other witness on this track takes.
    if let sessionID, let watching = readSessionContext(pid: supervisor)?.transcriptSessionID,
       watching != sessionID {
        return 0
    }
    // THE TYPE IS WRITTEN DOWN AS WELL AS FILTERED ON, which is the whole of what makes the two
    // kinds of wait separable one file over (`UserNotice.type` states what reading them alike
    // costs). Whatever the payload spelled it as, recorded as Claude Code's own word.
    //
    // RECORDED RATHER THAN WRITTEN, because the file is one slot and this is the only writer of it:
    // an `idle_prompt` arriving 60s into a fan-out must not overwrite a worker's permission request
    // that nobody has answered (`recordUserNotice` carries the mechanism and what the single slot
    // still costs). Nothing else about the write changes, and a declined one answers 0 like any
    // other outcome here.
    recordUserNotice(UserNotice(message: (event?["message"] as? String) ?? "", at: Date(),
                                type: type, sessionID: sessionID),
                     pid: supervisor)
    return 0
}
