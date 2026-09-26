import Foundation

// The audit lines cap resume leaves in `~/.tally/logs/input.log`, split out of CapResume.swift at
// the size cap. The station decides; this file only spells what it decided.

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
