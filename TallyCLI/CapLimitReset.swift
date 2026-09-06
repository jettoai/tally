import Foundation

// ANSWERING A 5-HOUR WALL WITHOUT LEAVING THE ACCOUNT: the poll-tick stations that spend Claude's
// own once-a-week session-limit reset before the cap handoff moves the conversation somewhere else.
//
// WHY IT COMES AHEAD OF THE HANDOFF. A cap handoff is the expensive answer: it kills the child,
// copies the transcript into another account's tree and resumes it there, and the session comes
// back on a different account with a different quota picture. Clearing the wall in place costs one
// slash command and keeps the account, the conversation and the model. So when the wall is one a
// reset can clear, this is tried first and the handoff waits; when it is not, or when it fails,
// nothing changes and the handoff happens exactly as it always did.
//
// EVERY GATE IS A REFUSAL, and the ones that cannot be answered refuse. The credit is weekly and
// there is one of it: spending it on the wrong wall, on an account whose weekly limit is nearly
// gone anyway, or twice for one wall are all ways of turning the user's one card a week into
// nothing. So the table below answers no to anything it cannot establish - a nil scope, a nil
// weekly reading, a `used` record - with a single deliberate exception stated where it lives.
//
// IT TYPES THROUGH THE SAME DOOR EVERY OTHER COMPOSER WRITER USES, gates included
// (`sessionInputHold`, `sessionInputDraftGuard`): a line typed mid-turn interleaves with what the
// session is writing, one typed while somebody is at the keyboard interleaves with their prompt,
// and one typed at a DIALOG answers that dialog with rubbish, because a chooser reads keystrokes
// and drops a paste on the floor (memory `tally-paste-vs-dialog`). Nothing here is a second gate
// and nothing bypasses one.
//
// AND IT READS ITS OWN ANSWER OFF THE TRANSCRIPT, because there is nowhere else: `/limit-reset` is
// interactive-only, so what it did is whatever Claude Code printed. The watcher records that for
// every session whatever typed the line (LimitResetSignals.swift), so the wait ends on a signal
// newer than the injection, or when `capLimitResetAnswerWait` runs out.
//
// WHY IT IS TWO STATIONS AND NOT ONE, which is the shape of this file and worth stating plainly.
// The cap handoff is planned EARLY in a tick, before the session's own state has been read; the
// composer gates are decided LATE, after it. A single station would have to be in one of those two
// places, and both are wrong: early, it cannot tell whether the composer is free; late, the handoff
// has already planned the relaunch that makes typing pointless (`relaunchPlanned`), so the line
// would be refused every single time and the feature would never fire. So the tick asks the hold
// question where the handoff is decided (`capLimitResetHold`, which needs no reading of the
// session) and does the typing where every other composer writer types (`applyCapLimitReset`).

/// How long a typed `/limit-reset` is given to answer before the wait is abandoned and the handoff
/// proceeds.
///
/// TWENTY SECONDS, and the number is a budget rather than a measurement: nobody here can measure it
/// (no account in this fleet is in the rollout). What bounds it is what the wait COSTS - a capped
/// session sitting still - against what it buys, a local command answering in a TUI that is
/// otherwise idle. Ten poll ticks is generous for the second and barely noticeable for the first,
/// and running out is not a failure: the session hands off, which is what it would have done
/// immediately without this station.
let capLimitResetAnswerWait: TimeInterval = 20

/// How long the handoff is held for a cap that is a CANDIDATE but has not been typed at yet.
///
/// The gap this covers is a composer that is not free on the tick the wall lands: the session is
/// mid-turn, or somebody is typing. Bounded by the same budget as the answer, and bounded from the
/// CAP rather than from the first attempt, so a session whose composer never frees up hands off
/// twenty seconds late instead of never. Past it, this station stops asking for anything and the
/// handoff behaves exactly as it did before the feature existed.
let capLimitResetHoldWindow: TimeInterval = 20

/// How much of the weekly window has to be left before spending the reset is worth anything.
///
/// A CLEARED SESSION WALL IS WORTH NOTHING BEHIND A WEEKLY ONE. The reset clears the 5-hour window
/// and explicitly does not touch the weekly limit ("your weekly limit still applies"), so on an
/// account with 3% of its week left the session gets a few minutes and hits the next wall - having
/// spent the one credit that week had. Twenty per cent is the same order as the nearly-dry line the
/// launcher and the cap handoff already draw (`nearlyDryPercent` is 5, which is the "is there
/// ANYTHING left" bar); this is the "is there enough to be worth a credit" bar, and it is
/// deliberately the stricter of the two.
let capLimitResetWeeklyFloor: Double = 20

/// What this session remembers about answering its wall with a reset. In memory and per SESSION,
/// like `QuotaKnockState` and `CapResumeState` beside it: the arm is raised by the tick that sees a
/// cap and spent by a tick that may be a child or two later.
struct CapLimitResetState: Equatable {
    /// The cap instant this session has already answered with a reset attempt.
    ///
    /// EDGE-TRIGGERED ON THE CAP RATHER THAN LEVEL-TRIGGERED ON THE STATE, which is the difference
    /// between one attempt and one every two seconds: a pending cap PERSISTS while the handoff
    /// waits for a sibling, so a station keyed on "there is a cap" would re-type the line on every
    /// tick of that wait. Keyed on the cap's own instant, a second genuine wall gets its own
    /// attempt and the same wall never gets two.
    var attemptedCapAt: Date?
    /// When the line was typed, while its answer is still awaited. nil at every other moment.
    var injectedAt: Date?
}

/// The audit word this leaves in the input log (grep `input=limit-reset`). Its own outcome rather
/// than `submitted`, on the terms `quotaKnockOutcome` states: the log answers "what typed into my
/// session", and a line nobody asked for is exactly the entry a reader has to tell from one they
/// did ask for.
let capLimitResetOutcome = "limit-reset"

/// And the word when the terminal refused the write.
let capLimitResetFailedOutcome = "limit-reset-failed"

/// Whether this wall may be answered by spending the account's weekly reset. Pure, so the whole
/// table is assertable without a transcript, a snapshot or a terminal.
///
/// The parameters are the gates in the order the feature reasons about them, and each of them
/// refuses on `nil`:
///
///  - `scope`: only a 5-hour SESSION wall. A weekly wall is what the reset explicitly does not
///    clear, and a model-tier wall is a different window entirely. nil is a cap this build could
///    not name, or one handed over by an older build across a self-update.
///  - `enabled`: the user's switch (`LimitResetSettings.autoReset`).
///  - `state`: `available`, or `unknown`. THE ONE DELIBERATE EXCEPTION in this file, and it is
///    bought rather than assumed: `unknown` is what an account reads before anything has ever been
///    observed about it, which on the day this ships is every account on the machine, so refusing
///    it would mean the feature never fires until somebody happens to type the command by hand.
///    What it costs when the guess is wrong is one attempt of `capLimitResetAnswerWait`, after
///    which the session hands off as before AND the account's record is settled by the answer.
///    `used` and `notEnabled` are refused, which is what keeps that cost to once.
///  - `weeklyRemaining`: `capLimitResetWeeklyFloor` or better, and nil refuses - a snapshot that
///    cannot say how much of the week is left is not a licence to spend the week's one credit.
///    WHICH READING MAY ANSWER THAT is a question of its own, and `capLimitResetWeekly` below is
///    the whole of it: this table is handed a number that has already been vouched for.
///  - `alreadyAttempted`: one wall, one attempt.
func capLimitResetAllowed(scope: CapScope?, enabled: Bool, state: LimitResetState,
                          weeklyRemaining: Double?, alreadyAttempted: Bool) -> Bool {
    guard enabled, scope == .session, !alreadyAttempted else { return false }
    guard state == .available || state == .unknown else { return false }
    guard let weeklyRemaining, weeklyRemaining >= capLimitResetWeeklyFloor else { return false }
    return true
}

/// The weekly reading that may be spent against, or nil when the snapshot holds nothing that can
/// vouch for one. Given `loadSnapshot()`'s pair whole, because the second half of it is half the
/// answer.
///
/// A HELD-OVER NUMBER IS NOT A READING, and the gate above cannot tell the two apart: 60% left from
/// before the app stopped polling is spelled exactly like 60% read a moment ago, so the floor passes
/// on evidence nobody has and the account's one weekly credit is spent on a week that may be over
/// (review, 2026-09-06). Every guard here is one the rest of this binary already applies to a number
/// it is about to act on - `eligible` and `accountIsSpent` ask the same three of the row
/// (AccountPick.swift, AccountBinding.swift), and the cap handoff fifteen lines below this gate's
/// own call site asks the snapshot problem (`applyCapHandoff`) - and refusing on `nil` is this
/// file's rule rather than a new one.
///
/// THE FIVE:
///
///  - the loader's problem string: a document older than `snapshotMaxAge` describes an app that has
///    stopped publishing, and every number in it is whatever was true when it stopped;
///  - `error` and `isStale`: the row's own account-level failures;
///  - `lastRefreshFailed`: the LATEST round failed and these numbers are the last good ones held
///    over (`foldLastGood`), which the badge's debounce leaves looking fresh for a poll interval;
///  - `refreshedAt` within `snapshotMaxAge` of now, and nil refuses. This is the one the four above
///    cannot cover: the app rewrites the whole document from its cached accounts whenever a setting
///    changes (`republishSnapshot`), so `generatedAt` can be seconds old while every reading in it
///    is much older. Per-account and carried from the fetch itself, this stamp is the only thing
///    that can say otherwise, and an app too old to publish it cannot say at all.
///
/// NOT `accountReadingPostdatesCap`, which is the neighbouring question ("was this fetched AFTER the
/// wall") and the wrong one here: that path can wait `capStayEvidenceGrace`, two minutes, for a
/// reading that new, while this one has `capLimitResetHoldWindow` - twenty seconds - against a
/// refresh interval the user sets in minutes. Demanding it would not make this gate stricter, it
/// would switch the feature off. What is asked instead is that the reading be a reading: recent
/// enough to describe this week, and published by a fetch that actually happened.
func capLimitResetWeekly(_ loaded: (Snapshot?, String?), accountID: String,
                         now: Date = Date()) -> Double? {
    let (snapshot, problem) = loaded
    guard problem == nil,
          let row = snapshot?.accounts.first(where: { $0.id == accountID }),
          row.error == nil, !row.isStale, row.lastRefreshFailed != true,
          let fetched = row.refreshedAt,
          now.timeIntervalSince(fetched) <= snapshotMaxAge else { return nil }
    return row.weeklyRemaining
}

/// What the terminal says the first time Tally answers a wall this way, and only the first time.
///
/// SAID AT ALL because this is a write the user did not ask for and cannot undo: it spends a credit
/// their account gets once a week. Said ONCE because the alternative is a sentence on every wall
/// for the rest of the machine's life, and the switch that turns it off is named in it.
func capLimitResetFirstNotice(account: String) -> String {
    "session wall on \(account) → spending this week's `/limit-reset` to clear it instead of "
        + "moving the session (turn this off in Settings → Launch)"
}

/// What the terminal says when the reset landed and the session is staying where it is.
func capLimitResetClearedNotice(account: String) -> String {
    "session limit reset on \(account) → staying put"
}

// MARK: - Where the handoff is decided

/// Whether this tick's cap handoff must stand down while the weekly reset answers the wall, and the
/// whole of the WAITING half of this feature.
///
/// It runs where the handoff is planned, which is before the session's own state has been read, so
/// it asks nothing about the composer: everything here is about the cap, the account's record and
/// the clock. The typing happens later in the same tick (`applyCapLimitReset`).
///
/// THREE ANSWERS:
///
///  - an injection is outstanding and unanswered inside its wait: hold, and let nothing move the
///    session out from under a reset that may be about to land;
///  - an injection has been ANSWERED: settle it. A reset that landed clears the pending cap here
///    and the session stays put; every other answer leaves the cap exactly as it was, so the
///    handoff below this call hands the session on as it always did;
///  - no injection, but this cap is a candidate and is younger than `capLimitResetHoldWindow`: hold
///    so that the station below gets a composer to type into this tick. Past that window it stops
///    asking, which is what bounds a session whose composer never frees up.
///
/// `resetState`, `weeklyRemaining` and `settings` are closures for the reason `applyCapHandoff`
/// takes its snapshot as an `@autoclosure`: this runs on every 2s tick of every supervised session
/// and all three read a file. They are asked only once the cheap gates - is there a cap at all, is
/// it this account's, has this wall been answered already, is it still young enough to hold - have
/// said this cap is a candidate.
///
/// `clearQuarantine` is the OTHER record a landed reset falsifies, and it has no default for the
/// reason `applyCapLimitReset` states about its own duplicated gate: a call site that can forget it
/// is one that will, and what is forgotten is invisible from here (the account simply stops being
/// picked for ten minutes). It is handed the model window the wall belongs to, and both layers of
/// the record are the caller's to undo (`releaseQuarantine`, Quarantine.swift).
func capLimitResetHold(_ state: inout CapLimitResetState, pendingCap: inout PendingCapRecovery?,
                       accountID: String, accountLabel: String,
                       resetState: () -> LimitResetState,
                       observed: (outcome: LimitResetOutcome, at: Date)?,
                       weeklyRemaining: () -> Double?,
                       clearQuarantine: (String?) -> Void,
                       settings: () -> LimitResetSettings = { readLimitResetSettings() },
                       now: Date = Date(),
                       announce: (String) -> Void = { warn($0) }) -> Bool {
    if let injectedAt = state.injectedAt {
        if let observed, observed.at > injectedAt {
            state.injectedAt = nil
            // A RESET THAT LANDED ENDS THE CAP, and ends it here rather than leaving the handoff to
            // notice: the wall is gone, the account is the one this session was already on, and
            // nothing about the recovery describes anything that is still true. Every other answer
            // (already used, not available, this login cannot, not enabled) leaves the pending cap
            // standing, so the handoff below this call moves the session exactly as before.
            //
            // AND THE QUARANTINE GOES WITH IT, for the same sentence: that record says "this
            // account just capped for this model window", and the window it named has just been
            // reset. Left standing it keeps the account out of every automatic pick on the machine
            // - this session's next handoff and every launch anywhere - for the rest of
            // `capQuarantineTTL`, while the account it is steering around is the one with a fresh
            // 5-hour window (review, 2026-09-06). Cleared BEFORE the cap is dropped, because the
            // window it names is what the record is matched on.
            if case .reset = observed.outcome {
                if let pending = pendingCap { clearQuarantine(pending.primaryModel) }
                pendingCap = nil
                announce(capLimitResetClearedNotice(account: accountLabel))
            }
            return false
        }
        if now.timeIntervalSince(injectedAt) > capLimitResetAnswerWait {
            state.injectedAt = nil
            return false
        }
        return true
    }
    guard let pending = pendingCap, pending.cappedAccountID == accountID,
          state.attemptedCapAt != pending.cappedAt,
          now.timeIntervalSince(pending.cappedAt) <= capLimitResetHoldWindow else { return false }
    return capLimitResetAllowed(scope: pending.capScope, enabled: settings().autoReset,
                                state: resetState(), weeklyRemaining: weeklyRemaining(),
                                alreadyAttempted: false)
}

// MARK: - Where the line is typed

/// Type `/limit-reset` into this session's composer, if this tick is one where that may happen.
///
/// It runs beside the other composer writers, after the session's own state has been read, and it
/// holds every gate they hold. What it does NOT re-decide is whether this cap deserves a reset:
/// that was settled by `capLimitResetHold` a few stations earlier in the same tick, and the caller
/// hands the answer down as `holding` rather than letting two places spell one rule.
///
/// Returns the line that reached the terminal, or nil, on the terms every writer here reports: the
/// loop's `lastComposerWrite` moves for a tick that typed, and for no other.
@discardableResult
func applyCapLimitReset(_ state: inout CapLimitResetState, pendingCap: PendingCapRecovery?,
                        pid: String, accountLabel: String, holding: Bool, typedAlready: Bool,
                        session: SupervisedState, quiet: SessionQuiet, turnEnded: () -> Bool,
                        keyboardIdle: Bool, relaunchPlanned: Bool, draftSuspected: Bool,
                        waitingOnPerson: Bool,
                        settings: () -> LimitResetSettings = { readLimitResetSettings() },
                        now: Date = Date(), log: URL = sessionInputLog,
                        settingsURL: URL = limitResetSettingsURL,
                        announce: (String) -> Void = { warn($0) },
                        inject: (String, SessionInputDraftGuard) -> SessionInputInjection = {
                            injectSessionInput($0, draft: $1)
                        }) -> String? {
    // `holding` is this station's own decision from earlier in the tick; `injectedAt` being nil is
    // what tells "hold because a candidate is waiting for a composer" from "hold because a line is
    // already out there". Only the first is a tick that types.
    //
    // AND THE ONE-WALL-ONE-LINE RULE IS ENFORCED HERE AS WELL AS IN THE HOLD, which is not belt and
    // braces. This is the function that TYPES, and until 2026-09-06 the only thing standing between
    // a wall and a second `/limit-reset` was the caller's decision: a mutant that removed the hold's
    // own `attemptedCapAt` guard left this station typing the command on every tick for the whole
    // hold window after a refused write or a settled answer, and every assertion stayed green
    // (mutation run, 2026-09-06). A gate that can be forgotten at a call site is one that will be,
    // and the symptom here is a weekly credit spent several times over.
    guard holding, state.injectedAt == nil, let pending = pendingCap,
          state.attemptedCapAt != pending.cappedAt,
          !typedAlready, !relaunchPlanned, !waitingOnPerson else { return nil }
    // The composer gate last, because it reads a file and a transcript tail through `turnEnded` -
    // the order `applyQuotaKnock` states and for the same reason.
    guard sessionInputHold(state: session, quiet: quiet, turnEnded: turnEnded(),
                           keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned) == nil
    else { return nil }
    // MARKED BEFORE THE WRITE, the rule every station on this track keeps: past this line the bytes
    // are on the terminal or the write has failed, and a failure that repeats every two seconds is
    // the one way this types the same command into a conversation twice.
    state.attemptedCapAt = pending.cappedAt
    let held = settings()
    if !held.noticeShown {
        announce(capLimitResetFirstNotice(account: accountLabel))
        var told = held
        told.noticeShown = true
        writeLimitResetSettings(told, url: settingsURL)
    }
    let draft = sessionInputDraftGuard(dialog: waitingOnPerson, suspected: draftSuspected)
    let written = inject(limitResetCommand, draft)
    switch written {
    case .done:
        // A REFUSED WRITE STARTS NO WAIT. Nothing was typed, so no answer is coming, and the next
        // tick's hold falls through to the handoff - which is what the session would have done had
        // this station not existed.
        state.injectedAt = now
        appendSessionInputLine(sessionInputLogLine(pid: pid, outcome: capLimitResetOutcome,
                                                  text: limitResetCommand, now: now), to: log)
    case .failed(let code):
        appendSessionInputLine(quotaKnockFailureLine(pid: pid, code: code,
                                                     outcome: capLimitResetFailedOutcome, now: now),
                               to: log)
    }
    appendSessionInputDraftLines(pid: pid, draft: draft, now: now, to: log)
    return written.sent ? limitResetCommand : nil
}

// MARK: - The observer

/// Fold whatever this conversation has been told about its account's weekly reset into that
/// account's record, once per reading.
///
/// SEPARATE FROM THE TWO STATIONS ABOVE, and that separation is the whole design. They are about
/// answering a wall; this is about KNOWING, and the two have different scopes: the record belongs
/// to the ACCOUNT (the panel draws it, the button reads it, the next session's gate consults it),
/// while a wall belongs to one conversation. Keeping them apart is what makes the record right when
/// the line was typed by somebody's own hands, or by the panel's button, or by a sibling session -
/// none of which either station would ever hear about.
///
/// `folded` is the last reading written, so a signal sitting in the watcher (it holds the newest one
/// until another arrives) is written once rather than on every tick for the rest of the session.
func observeLimitReset(_ seen: (outcome: LimitResetOutcome, at: Date)?, folded: inout Date?,
                       accountID: String, now: Date = Date(), dir: URL = limitResetDir) {
    guard let seen, folded.map({ seen.at > $0 }) ?? true else { return }
    folded = seen.at
    guard let record = limitResetFold(readLimitReset(accountID: accountID, dir: dir),
                                      outcome: seen.outcome, now: now) else { return }
    writeLimitReset(record, accountID: accountID, dir: dir)
}
