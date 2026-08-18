import Foundation

// THE ADVISORY KNOCK, decided: when a session is told that the account under it is running out, and
// what that sentence says. The tick that acts on this decision is next door (QuotaKnock.swift), the
// same split `ResetHintLogic` keeps from its notifier and for the same reason: everything here is
// pure, so the whole table is assertable without a snapshot, a terminal or a supervisor.
//
// WHY A SENTENCE RATHER THAN A MOVE. The idle rebalance (Rebalance.swift) already carries a session
// off a dying account, and the window repick takes that move at the cheapest moment a session has.
// Both of them need the session to be IDLE, which is the one thing a session in the middle of a
// work package is not, so the sessions that ride an account into the wall are precisely the ones
// those movers leave alone. What such a session needs is not a restart mid-package, it is the fact:
// so this says the fact into its own composer and lets the conversation decide what to do with it -
// finish the package and switch accounts, or wait the reset out.
//
// WHY 15% RATHER THAN THE 5% EVERY MOVER DRAWS. A move is still worth taking at 5% because nothing
// is lost by taking it late; advice at 5% is worth nothing, because there is no runway left to act
// on. This line is the runway rather than the wall, and it is deliberately EARLIER than the movers'
// line rather than a second opinion about when an account is dry: at 15% no mover has fired yet, and
// by the time one does the session has already been told why it is about to be moved.
//
// WHAT THE SENTENCE HAS TO CARRY for the reader to decide anything: which window is binding and how
// long until it refills (waiting is only a plan when the reset is close), how many sessions are on
// that account (three conversations sharing one window drain it three times as fast, so "wait for
// the reset" stops being a plan), and where else there is room. Everything in it is quoted from the
// same functions the account picks quote (`windowReason`, `pickReason`), so the advice and the move
// can never describe the fleet differently.

/// The line an account's binding window has to fall to before its sessions are told.
///
/// Effective remaining rather than the raw percentage (`effectiveRemaining`), the reading every
/// other gate here weighs: a window resetting in five minutes is a full window, and telling a
/// session to wrap up over one would be advice against the user's own interest.
let quotaKnockPercent = 15.0

/// Back above this inside the same cycle and the knock re-arms.
///
/// The shape `ResetHintLogic` uses (5 to fire, 30 to re-arm) rather than a second hysteresis of its
/// own. A window that has climbed back over 30% is not the drought that was announced, and the next
/// time it drains is a fresh piece of news rather than a repeat of the old one. Between the two
/// lines nothing changes, which is the whole point of the gap: an account hovering at 14% and 16%
/// says its sentence once.
let quotaKnockRearmPercent = 30.0

/// How often the reading behind this is taken at all.
///
/// The poll loop runs every 2 seconds and the app republishes the snapshot every minute or two, so
/// asking on every tick would read and decode the same file thirty times for one new number. Thirty
/// seconds is far below the rate the numbers move at and far above the rate the tick runs at, and
/// what it bounds is the only cost this feature has on an ordinary tick.
let quotaKnockInterval: TimeInterval = 30

/// How much of an account label the sentence carries.
///
/// Labels are free text the user edits, and every byte of this line is 30ms of the poll loop's own
/// time (`sessionInputByteGap`), so the sentence has to be bounded by construction rather than by
/// hoping. The fleet this is written for labels accounts "Claude" and "Claude 2".
let quotaKnockLabelLimit = 24

/// Whether this supervisor was asked to knock once on its next eligible tick, whatever the quota
/// says (`TALLY_QUOTA_KNOCK_FORCE=1`).
///
/// A DEVELOPMENT FLAG IN THE SHAPE THIS CLI ALREADY USES for the others it has (`TALLY_AUTO_HANDOFF`,
/// `TALLY_AUTO_FOLLOW`): an environment variable read once, at start-up, by the process it steers.
/// It exists because the alternative way to see this feature work is to burn an account down to 15%,
/// and what it fires is the REAL sentence built from the REAL snapshot - it forces the moment, never
/// the content, so what a reader sees is what a drought would have sent them.
func quotaKnockForceRequested() -> Bool {
    guard let raw = getenv("TALLY_QUOTA_KNOCK_FORCE") else { return false }
    return String(cString: raw) == "1"
}

/// Whether two cycle keys name the same drought, including the case neither names one.
///
/// nil is a legitimate key here and it means "this account publishes no reset time", which is a
/// state an account can sit in for as long as the app has not read one. Two nils are therefore the
/// same drought - one sentence, not one per tick - and a nil beside a real key is not, because a
/// window that has started reporting a reset is news the account did not have before. Anything else
/// is the CLI's one same-drought rule (`namesSameDrought`, Rebalance.swift), tolerance included: a
/// reported reset drifts by a minute between polls without the window having moved at all.
func quotaKnockSameCycle(_ one: String?, _ other: String?) -> Bool {
    switch (one, other) {
    case (nil, nil): return true
    case (let a?, let b?): return namesSameDrought(a, b)
    default: return false
    }
}

/// What one supervised session remembers about the knock between ticks. In memory and per session,
/// like `SessionInputState` and `ManualMoveState` beside it: every session on the account is meant
/// to hear this, so there is nothing to serialize across supervisors and no claim to take. A
/// supervisor restarted mid-drought says it once more, which is the honest cost of holding this in
/// memory and is stated rather than defended against.
///
/// Held per SESSION rather than per child, so a relaunch does not re-announce a drought the
/// conversation has already been told about. A relaunch that MOVES accounts re-arms this by itself:
/// the new account's binding window is a different cycle.
struct QuotaKnockState: Equatable {
    /// The drought the flag below belongs to, keyed as the rebalance keys its claim.
    private(set) var cycleKey: String?
    /// Whether this drought's sentence has been sent.
    private(set) var fired = false
    /// When the reading was last taken, which is what `quotaKnockInterval` is measured from.
    private(set) var checkedAt: Date?
    /// The one forced knock a development flag asks for, spent by the first one that is sent.
    private(set) var forced: Bool

    init(forced: Bool = quotaKnockForceRequested()) { self.forced = forced }

    /// Whether this tick takes a reading at all. A forced knock does not wait out the interval:
    /// what it is for is somebody watching a terminal for it.
    func due(now: Date) -> Bool {
        guard !forced, let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= quotaKnockInterval
    }

    /// Fold one reading in, and answer whether this session is owed the sentence.
    ///
    /// IT DOES NOT MARK THE SENTENCE SENT, which is the whole reason this is not one function with
    /// the send. The composer may be busy at the moment the account crosses the line, and a flag
    /// raised there would spend the announcement on a tick that typed nothing: the sending side
    /// calls `spend()` when the bytes are actually on their way, and until then this keeps
    /// answering yes.
    ///
    /// The re-arm is applied before the answer rather than after, so an account that refilled past
    /// `quotaKnockRearmPercent` and drained again inside one cycle (a weekly window under a
    /// session window that reset) is a fresh drought to this.
    mutating func observe(cycle: String?, remaining: Double, now: Date) -> Bool {
        checkedAt = now
        if !quotaKnockSameCycle(cycleKey, cycle) { fired = false }
        cycleKey = cycle
        if remaining > quotaKnockRearmPercent { fired = false }
        return remaining <= quotaKnockPercent && !fired
    }

    /// The sentence is on its way: this drought is spoken for, and a forced knock is spent.
    ///
    /// Called when the injection is ATTEMPTED rather than when it succeeds, the rule
    /// `applySessionInput` states about its own served stamp: by then the bytes are on the terminal
    /// or the write has failed, and the failure that repeats every tick is the one that would
    /// re-type the line into the conversation that already has it.
    mutating func spend() {
        fired = true
        forced = false
    }
}

/// The label as the sentence carries it, clipped to `quotaKnockLabelLimit` characters.
func quotaKnockName(_ label: String) -> String {
    label.count <= quotaKnockLabelLimit ? label
        : String(label.prefix(quotaKnockLabelLimit)) + "\u{2026}"
}

/// How many conversations are sharing this window, or nothing at all when the count is zero.
///
/// ZERO IS NOT PRINTED, because it cannot be true: the session being typed into is on that account
/// by construction, so a zero is a reading that failed (a supervisor whose sidecar could not be
/// read) rather than an empty account. Saying "0 sessions on it" to the one session on it is the
/// kind of sentence that makes a reader distrust the rest of the line.
private func quotaKnockSessionsClause(_ sessions: Int) -> String {
    guard sessions > 0 else { return "" }
    return ", \(sessions) session\(sessions == 1 ? "" : "s") on it"
}

/// The line typed into the session, or nil when there is nothing to say (an account reporting no
/// windows at all, which is a reading rather than a drought).
///
/// `limit` is the byte budget the caller keeps, handed in rather than read here so this file stays
/// free of the session-input channel: the caller is the one that pays for those bytes
/// (`sessionInputMaxBytes` is 200 of them, at 30ms each). Over budget, the alternative account is
/// what goes, because it is the one clause a reader can get for themselves (`tally status`), and
/// what stays is the news and the advice. The short form is bounded by construction - two clipped
/// labels cannot reach the budget - so a long label costs the sentence its detail rather than its
/// existence.
func quotaKnockMessage(account: Snapshot.Account, alternative: Snapshot.Account?, sessions: Int,
                       primaryModel: String?, limit: Int, now: Date = Date()) -> String? {
    guard let binding = bindingWindow(account, primaryModel: primaryModel, now: now) else {
        return nil
    }
    let head = "[tally] account \(quotaKnockName(account.label)) is running low: "
        + windowReason(binding, now: now) + quotaKnockSessionsClause(sessions) + "."
    guard let alternative else {
        // Nothing comfortable anywhere is a different instruction, and it is the honest one: moving
        // to an equally spent account buys minutes and costs a restart, which is the same answer
        // `capHandoffTarget` gives by returning nothing.
        return head + " No account has headroom; consider pausing until the reset."
    }
    let advice = " Wrap up and switch accounts, or wait for the reset."
    let full = head + " Best alternative: \(quotaKnockName(alternative.label)) "
        + "(\(pickReason(alternative, primaryModel: primaryModel, now: now)))." + advice
    return full.utf8.count <= limit ? full : head + advice
}
