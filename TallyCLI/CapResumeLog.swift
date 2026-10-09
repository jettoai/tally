import Foundation

// The audit lines cap resume leaves in `~/.tally/logs/input.log`, the sentence it types and the
// anti-recursion budget, split out of CapResume.swift at the size cap.

/// The word for an arm that was raised (grep `input=cap-resume-armed`). Without it an arm that is
/// later lost leaves no trace at all: 2026-09-26 had to be reconstructed from a version number.
let capResumeArmedOutcome = "cap-resume-armed"

/// The line a dropped arm leaves. Pure, and shaped like the other entries in that log: the stamp,
/// the session, what kind of record this is, and why.
func capResumeDropLine(pid: String, why: CapResumeDrop, outcome: String = capResumeDroppedOutcome,
                       now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=\(outcome) "
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
                  to: Snapshot.Account, personTurnAt: Date?, caughtUp: Bool, owed: Bool = true,
                  requiresLiveWork: Bool = capResumeRequiresLiveWork) {
    let before = state.offer
    // An arm the owed gate alone refused says so (grep `cap-resume-skipped`): the same call with
    // the child counted as busy is what would have armed.
    if !owed, requiresLiveWork {
        var probe = state
        probe.arm(reason: reason, fresh: fresh, cappedAt: cappedAt, answeredAt: answeredAt,
                  conversation: conversation, from: from, to: to, personTurnAt: personTurnAt,
                  caughtUp: caughtUp)
        if probe.offer != before {
            appendSessionInputLine("\(ISO8601DateFormatter().string(from: now)) pid=\(pid) "
                                       + "input=\(capResumeSkippedOutcome) reason=no-live-work\n",
                                   to: log)
        }
    }
    // A wall the budget alone refused says so (grep `cap-resume-skipped reason=budget`): until
    // B-1360 that refusal was silent, and three unresumed walls took a log dig to attribute.
    // Only when the owed gate passes, as `arm`'s first guard says: a wall with no live work was
    // never going to be resumed, and it already left its own `reason=no-live-work` line.
    if owed || !requiresLiveWork,
       capResumeInterrupted(reason: reason, fresh: fresh, cappedAt: cappedAt,
                            answeredAt: answeredAt),
       caughtUp,
       state.refusedByBudget(conversation: conversation, personTurnAt: personTurnAt,
                             cappedAt: cappedAt) {
        appendSessionInputLine("\(ISO8601DateFormatter().string(from: now)) pid=\(pid) "
                                   + "input=\(capResumeSkippedOutcome) reason=budget\n", to: log)
    }
    state.arm(reason: reason, fresh: fresh, cappedAt: cappedAt, answeredAt: answeredAt,
              conversation: conversation, from: from, to: to, personTurnAt: personTurnAt,
              caughtUp: caughtUp, owed: owed, requiresLiveWork: requiresLiveWork)
    if let offer = state.offer, offer != before {
        appendSessionInputLine(capResumeArmedLine(pid: pid, offer: offer, now: now), to: log)
    }
}

/// The word for a cap resume the owed rule declined (B-5730, `capResumeRequiresLiveWork`).
let capResumeSkippedOutcome = "cap-resume-skipped"

// MARK: - The anti-recursion budget (split out of CapResume.swift at the size cap)

/// How many automatic resume lines one conversation may receive inside `capResumeBudgetWindow`
/// before a person has typed in it. Three, the count the recovery fuse allows per ten minutes
/// (`RecoveryFuse`), over a longer clock: a ladder of walls across a working afternoon is what the
/// fuse does not see, and 2026-10-07 showed its honest shape (one conversation walled twice in 59
/// minutes, B-1360).
let capResumeBudget = 3

/// The clock that budget runs on.
let capResumeBudgetWindow: TimeInterval = 2 * 60 * 60

/// Whether this wall may still have its line, the anti-recursion gate.
///
/// SCOPED TO THE CONVERSATION, because that is what can recur. Until B-1360 this was "a person has
/// typed since the last nudge", with the nudge kept per supervisor and the person read per child:
/// a supervisor that resumed once at 06:19 refused every later wall that day, through four /clears
/// and a self-update, because a fresh child has seen nobody and a cross-session message is not a
/// person (2026-10-07: three walls, waits of 8 minutes, 58 minutes and two hours).
///
/// A person's turn after the newest nudge resets the budget: the recursion this guards against is
/// a loop with nobody in it. `personTurnAt` is `lastPersonTurn` (AutomaticInput.swift): a turn
/// Tally's own typing accounts for (this line, a knock, a `tally session send`), or one from a
/// stretch the ledger knows nothing about, is not a person. Measured at the WALL, not the tick.
func capResumeWithinBudget(conversation: String, nudgedConversation: String?, nudges: [Date],
                           personTurnAt: Date?, at wall: Date, budget: Int = capResumeBudget,
                           window: TimeInterval = capResumeBudgetWindow) -> Bool {
    guard nudgedConversation == conversation, let last = nudges.last else { return true }
    if let personTurnAt, personTurnAt > last { return true }
    return nudges.filter { wall.timeIntervalSince($0) < window }.count < budget
}

extension CapResumeState {
    /// Whether `arm` would refuse this wall ONLY because the budget is spent (for the audit line).
    func refusedByBudget(conversation: String?, personTurnAt: Date?, cappedAt: Date?) -> Bool {
        guard let conversation, let cappedAt,
              capResumeFreshCap(cappedAt: cappedAt, lastCapAt: lastCapAt) else { return false }
        return !capResumeWithinBudget(conversation: conversation,
                                      nudgedConversation: nudgedConversation, nudges: nudges,
                                      personTurnAt: personTurnAt, at: cappedAt)
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

/// The three words a station on the cap resume door writes to `input.log`, so a second station can
/// share the door and its gates without its lines reading as a wall's (RestartWake.swift).
struct CapResumeOutcomes {
    let typed: String
    let failed: String
    let dropped: String
    static let cap = CapResumeOutcomes(typed: capResumeOutcome, failed: capResumeFailedOutcome,
                                       dropped: capResumeDroppedOutcome)
}
