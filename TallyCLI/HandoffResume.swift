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
// THE ANSWER IS A FRESH WINDOW, NOT A WAIT. Deferring the move would leave the session on the
// account it was told to leave for as long as the other head runs, which for a cap handoff is a
// session that cannot work at all; and resuming anyway is the fork this exists to prevent. So the
// conversation is left with the head that has it, and this session starts a new window on the
// target account - the same thing `tally session clear` asks for, reached by a different road.

/// Whether resuming `conversation` would put a SECOND head on it: somebody else in this directory
/// is writing it right now.
///
/// nil is not a conversation, and answers no: a session with no transcript yet has nothing to fork,
/// and `performHandoff` already treats that as a fresh start on the target.
func resumeForksConversation(_ conversation: String?, liveElsewhere: Set<String>) -> Bool {
    guard let conversation else { return false }
    return liveElsewhere.contains(conversation)
}

/// What the terminal is told: which conversation was left behind, and what starts instead.
///
/// The id is cut to the eight characters every other surface in this system shows, so the line can
/// be matched against a handoff log entry and a status line by eye.
func secondHeadNotice(conversation: String, target: String) -> String {
    "another session here is still writing conversation \(conversation.prefix(8)), so this one "
        + "starts a fresh window on \(target) rather than a second head on that conversation"
}

/// And the audit line, in the shape the rest of this log is written in (`unresolvedForkHoldLine`).
func secondHeadHoldLine(conversation: String, pid: String, cwd: String,
                        now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) session=\(conversation.prefix(8)) "
        + "resume=declined reason=second-head cwd=\(cwd)\n"
}

/// Say it on both surfaces at once, so a handoff cannot report one and not the other.
///
/// The terminal is allowed here for the reason the pin-cleared notice beside this one is allowed:
/// the child is already gone and the next has not been spawned, which is the only window in a
/// supervisor's life that nothing is drawing into (PendingNotice.swift).
func noteSecondHead(conversation: String, target: String, pid: String, cwd: String, log: URL) {
    warn(secondHeadNotice(conversation: conversation, target: target))
    appendHandoffLine(secondHeadHoldLine(conversation: conversation, pid: pid, cwd: cwd), to: log)
}
