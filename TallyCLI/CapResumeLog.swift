import Foundation

// The audit lines cap resume leaves in `~/.tally/logs/input.log`, and the sentence it types, split
// out of CapResume.swift at the size cap. The station decides; this file only spells what it decided.

/// The word for an arm that was raised (grep `input=cap-resume-armed`). Without it an arm that is
/// later lost leaves no trace at all: 2026-09-26 had to be reconstructed from a version number.
let capResumeArmedOutcome = "cap-resume-armed"

/// The line a dropped arm leaves. Pure, and shaped like the other entries in that log: the stamp,
/// the session, what kind of record this is, and why.
func capResumeDropLine(pid: String, why: CapResumeDrop, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=\(capResumeDroppedOutcome) "
        + "reason=\(why.word)\n"
}

/// The line a raised arm leaves: which conversation, and the wall it is about.
func capResumeArmedLine(pid: String, offer: CapResumeState.Offer, now: Date = Date()) -> String {
    let stamp = ISO8601DateFormatter()
    return "\(stamp.string(from: now)) pid=\(pid) input=\(capResumeArmedOutcome) "
        + "conversation=\(offer.conversation.prefix(8)) cappedAt=\(stamp.string(from: offer.at))\n"
}

/// Arm, and say so when an arm was actually raised. The comparison is on the offer itself, so a
/// call that re-arms nothing (same wall, a guard refusing) writes nothing.
func armCapResume(_ state: inout CapResumeState, pid: String, log: URL = sessionInputLog,
                  now: Date = Date(), reason: String, fresh: Bool, cappedAt: Date?,
                  answeredAt: Date?, conversation: String?, from: Snapshot.Account,
                  to: Snapshot.Account, userTurnAt: Date?, caughtUp: Bool) {
    let before = state.offer
    state.arm(reason: reason, fresh: fresh, cappedAt: cappedAt, answeredAt: answeredAt,
              conversation: conversation, from: from, to: to, userTurnAt: userTurnAt,
              caughtUp: caughtUp)
    if let offer = state.offer, offer != before {
        appendSessionInputLine(capResumeArmedLine(pid: pid, offer: offer, now: now), to: log)
    }
}

/// The line typed into the session that has just been moved off a capped account.
///
/// Names both accounts because both are the news: which one ran out (so the reader knows why their
/// turn died) and which one they are on now (so a decision to stop instead of carrying on is made
/// against the right window). Names them through `quotaKnockName`, which is the one rule in this
/// repo for what may go on a terminal's input queue as an account name: a label is free text from a
/// rename popover, and a newline in the middle of this sentence would submit half of it as a prompt
/// and type the rest into whatever came up next.
///
/// `limit` is the channel's byte budget, held here the way `quotaKnockMessage` holds its own: the
/// names are clipped to a budget of their own first, and whatever is left is cut to the limit, so
/// the guarantee is measured rather than reasoned about.
func capResumeMessage(from: Snapshot.Account, to: Snapshot.Account,
                      limit: Int = sessionInputMaxBytes) -> String {
    let line = "\(capResumeMarker) \(quotaKnockName(from)) hit its usage limit and cut a turn "
        + "short, and this session is now on \(quotaKnockName(to)). "
        + "Continue the work that was interrupted."
    return keystrokeClipped(line, bytes: limit)
}
