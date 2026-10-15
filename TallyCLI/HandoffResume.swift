import Foundation

// Whether a handoff may RESUME the conversation it just ended, or would be starting a second head
// on one somebody else is still writing.
//
// The rule this asks about is not new. `liveConversations` (SwitchRequest.swift) was written for the
// 2026-07-29 incident in which two processes wrote one transcript and turns went missing, and every
// LAUNCH has consulted it since (`main.swift`). What no relaunch ever asked it was the same
// question about itself: `performHandoff` locates the file the conversation is in, copies it to the
// target account's home and resumes it, with nothing between that decision and the id it reads.
//
// Two ways a handoff reaches an id somebody else owns, both of them narrow and both of them seen in
// the code rather than imagined:
//
//   - `adoptRequestedTranscript` can bind this watcher to a SIBLING session's transcript. Its two
//     strongest refusals are skipped when the request carries no evidence of binding, and the one
//     that remains (`transcriptWatchedElsewhere`) rests on a publish a sibling has not made until
//     its conversation has had a turn with a usage reading in it. A directory with two young
//     sessions in it is exactly where that gap is.
//   - a resume that forked. The forced fork check above this decision follows the conversation to
//     the file it really moved to, and that file can be the one a sibling started.
//
// WHAT IT DOES NOT COVER, said plainly because the reported symptom is the case it does not: this
// supervisor's OWN child outliving the signal that ended it. Nothing published under this pid can
// witness that, since every one of those documents describes the session rather than the process,
// and the answer to it is not a refusal here but a kill that reaches the whole tree
// (HandoffKill.swift, run before this decision is taken).
//
// A TYPED SWITCH IS THE EXCEPTION (jettoai/tally#10): it is refused at request time while another head
// holds the conversation (`switchSecondHeadRefusal`), and held at plan time if the holder appears
// afterwards (SessionSwitch.swift), because the person asked for a continuation and the session can
// keep working where it is. What follows is the backstop for everything else.
//
// THE ANSWER IS A FORK, NOT A WAIT AND NOT AN EMPTY WINDOW (jettoai/tally#10). Deferring the move
// would leave the session on the account it was told to leave for as long as the other head runs,
// which for a cap handoff is a session that cannot work at all; and resuming the SAME file is the
// second writer this exists to prevent. A fresh window avoided the writer by dropping the whole
// conversation, which is what the issue reported. `--resume <id> --fork-session` keeps the history
// and writes a NEW file, so the head that holds the conversation keeps its file alone and this
// window starts on the target account with everything up to the fork point. The two then diverge,
// so nothing is typed into the fork on its own: work the move interrupted is for a person to carry
// on, in whichever head they choose. Only `tally session clear` still asks for an empty window.

/// Whether resuming `conversation` would put a SECOND head on it: somebody else in this directory
/// is writing it right now.
///
/// nil is not a conversation, and answers no: a session with no transcript yet has nothing to fork,
/// and `performHandoff` already treats that as a fresh start on the target.
func resumeForksConversation(_ conversation: String?, liveElsewhere: Set<String>) -> Bool {
    guard let conversation else { return false }
    return liveElsewhere.contains(conversation)
}

/// "(pid 90731, not supervised by Tally)", or "" when nobody is known to hold it.
func secondHeadHolderPhrase(_ holder: ConversationHolder?) -> String {
    guard let holder else { return "" }
    return holder.supervised ? "(the Tally session with pid \(holder.pid))"
        : "(pid \(holder.pid), not supervised by Tally)"
}

/// What the terminal is told when a move had to fork the conversation: which one, who still holds
/// it, and what that costs.
///
/// The id is cut to the eight characters every other surface in this system shows, so the line can
/// be matched against a handoff log entry and a status line by eye.
func secondHeadNotice(conversation: String, target: String,
                      holder: ConversationHolder? = nil) -> String {
    let who = secondHeadHolderPhrase(holder)
    return "continued on \(target) in a fork of conversation \(conversation.prefix(8)): it is still "
        + "open in another Claude Code here" + (who.isEmpty ? "" : " \(who)")
        + ", so this window carries its history under a new id. Work from here on is not shared "
        + "between the two. Subagents of the previous window ended with it."
}

/// And the audit line, in the shape the rest of this log is written in (`unresolvedForkHoldLine`).
/// `holder=` goes before `cwd=`, which stays last (SupervisorRuntime.swift).
func secondHeadHoldLine(conversation: String, pid: String, cwd: String, holder: String? = nil,
                        now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) session=\(conversation.prefix(8)) "
        + "resume=forked reason=second-head " + (holder.map { "holder=\($0) " } ?? "")
        + "cwd=\(cwd)\n"
}

/// Say it on both surfaces at once, so a handoff cannot report one and not the other.
///
/// The terminal is allowed here for the reason the pin-cleared notice beside this one is allowed:
/// the child is already gone and the next has not been spawned, which is the only window in a
/// supervisor's life that nothing is drawing into (PendingNotice.swift).
func noteSecondHead(conversation: String, target: String, pid: String, cwd: String, log: URL,
                    holder: ConversationHolder?) {
    warn(secondHeadNotice(conversation: conversation, target: target, holder: holder))
    appendHandoffLine(secondHeadHoldLine(conversation: conversation, pid: pid, cwd: cwd,
                                         holder: holder?.pid), to: log)
}

/// What the terminal says after a typed switch DID continue the conversation.
func switchResumedNotice(conversation: String, target: String) -> String {
    "resumed conversation \(conversation.prefix(8)) on \(target)"
}

/// The refusal a typed switch gets at request time when the conversation it is in is also open in
/// another head here: moving now would start an empty window instead of continuing it. nil when the
/// conversation is unknown (nothing to fork yet) or nobody else holds it.
func switchSecondHeadRefusal(conversation: String?, holders: [String: ConversationHolder],
                             target: String) -> String? {
    guard let conversation, let holder = holders[conversation] else { return nil }
    return "not switched: conversation \(conversation.prefix(8)) is also open in another Claude "
        + "Code in this directory \(secondHeadHolderPhrase(holder)). Moving now would start an "
        + "empty window on \(target) instead of continuing this conversation, so nothing was "
        + "queued. Exit that session, then run this again."
}

/// The conversation a switch request was typed into, as best the surface knows: Claude Code's own
/// prompt id (hook and picker surfaces), then the status line's report while the process that filed
/// it is still the one running, then the supervisor's publish. The report is fresher than the
/// publish after a `/clear` (SwitchRequest.swift).
func sessionConversation(promptID: String?, identity: TranscriptIdentity?,
                         published: String?) -> String? {
    if let promptID { return promptID }
    if let identity, processStamp(identity.claudeCode.pid) == identity.claudeCode {
        return identity.id
    }
    return published
}

/// The conversation a launch forks from, or nil when it forks nothing: `--fork-session` with the
/// `--resume` / `-r` it applies to. The watcher must never bind this file (the head that holds it
/// is writing it) and the first child must not be woken as a resume of it.
func forkParentID(_ launchArgs: [String]) -> String? {
    guard optionsOnly(launchArgs).contains("--fork-session") else { return nil }
    return flagValue(launchArgs, "--resume") ?? flagValue(launchArgs, "-r")
}

/// Whether a launch resumes a conversation in place. A fork starts a new conversation, so it does
/// not (`firstLaunchRestartNote` answers a fork the same way for a first launch).
func launchResumesConversation(_ launchArgs: [String]) -> Bool {
    !optionsOnly(launchArgs).contains("--fork-session")
        && ((flagValue(launchArgs, "--resume") ?? flagValue(launchArgs, "-r")) != nil
            || launchArgs.contains(where: continueFlags.contains))
}
