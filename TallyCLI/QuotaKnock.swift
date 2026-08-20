import Darwin
import Foundation

// THE ADVISORY KNOCK, performed: the poll-tick station that reads the fleet, decides whether this
// session is owed the sentence (QuotaKnockLogic.swift holds every rule about that) and types it
// into the session's own composer.
//
// IT TYPES THROUGH THE SAME DOOR `tally session send` DOES, gates included. `sessionInputHold` is
// asked exactly as the request path asks it, and a hold of any kind means this tick says nothing
// and the next one decides again: a line typed into a conversation mid-turn interleaves with what
// it is writing, a line typed while somebody is at the keyboard interleaves with what they are
// typing, and a line typed into a child this tick is about to SIGTERM is lost while looking sent
// (SessionInput.swift argues each of them where the table lives). Nothing here is a second gate and
// nothing here bypasses one.
//
// IT PRODUCES NO `RelaunchPlan`, for the reason the input station gives: it writes bytes and
// returns. The session decides what to do about them, which is the whole feature - the movers next
// door (Rebalance.swift, WindowRepick.swift) act on a session that is doing nothing, and this one
// exists for the session that is busy, where an automatic restart is the wrong answer and a fact is
// the right one.
//
// IT NEVER SPEAKS OVER THE INPUT STATION. A tick that has just typed a `tally session send` line
// has already spent this terminal's turn, so the knock waits: two lines typed into one composer in
// one tick is one prompt with two instructions in it.
//
// WHAT IT COSTS ON AN ORDINARY TICK: one comparison. The reading behind it is taken at most every
// `quotaKnockInterval`, and the snapshot read is behind that, so a session that never approaches the
// line pays for a clock check every two seconds and a file read every thirty.

/// The audit word this leaves in the input log. Its own outcome rather than `submitted`, because
/// the question that log answers is "what typed into my session, and when": a line nobody asked for
/// is exactly the entry a reader needs to be able to tell from one they did ask for.
let quotaKnockOutcome = "quota-knock"

/// And the word when the terminal refused the write, on the same terms.
let quotaKnockFailedOutcome = "quota-knock-failed"

/// The line a refused write leaves (grep `input=quota-knock-failed`). Its own shape rather than the
/// served one, for the reason `sessionInputReceiptLostLine` is its own line: nothing was typed, so
/// the field a reader wants is not the text but the errno, and the two that happen are told apart by
/// nothing else (ENXIO is a supervisor with no controlling terminal, EINVAL a kernel that has
/// retired this ioctl).
func quotaKnockFailureLine(pid: String, code: Int32, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=\(quotaKnockFailedOutcome) "
        + "errno=\(code) failed=\(String(cString: strerror(code)))\n"
}

/// One poll tick's advisory knock: nil on almost every tick, and otherwise the line that was typed.
///
/// THE ORDER OF THE GATES IS WHAT KEEPS THIS FREE, and it is not the order they are argued in:
///
///  - what costs nothing comes first (a line already typed this tick, a planned relaunch, the
///    interval since the last reading), so the ordinary tick stops here;
///  - then the fleet reading, which is one `~/.tally/snapshot.json` read;
///  - then whether this session is OWED the sentence, which is pure;
///  - and only then the input gate, which reads a file and a transcript tail through `turnEnded`.
///
/// The last two are in that order deliberately. Asking the gate first would mean paying for it on
/// every reading, and asking the arm to mark itself spent before the gate had a say would spend the
/// drought's one sentence on a tick that typed nothing: `observe` answers without recording, and
/// `spend` records at the moment the bytes are on their way.
///
/// A HELD KNOCK IS NOT A LOST ONE. Nothing is written when the gate holds, so the next reading
/// (thirty seconds later, or immediately for a forced one) asks again, and it keeps asking for as
/// long as the account stays under the line. There is no expiry, unlike a `tally session send`,
/// because there is no caller waiting for an answer.
///
/// `counting` is how many sessions share this account, taken from the live roster rather than by a
/// scan of this file's own (`supervisedSessionCount`, SessionContext.swift). A closure so it is
/// asked only when a sentence is actually being built, and so the suite can answer it without a
/// state directory.
///
/// `loaded` is the snapshot read, `@autoclosure` for the reason `rebalanceMove` states in full: a
/// plain default argument is evaluated at the call site, on every tick, for an answer the gates
/// above throw away.
///
/// `draftSuspected` RIDES THE SAME DOOR AS EVERYTHING ELSE HERE, and it has to: this station types a
/// whole sentence and presses Return, so a half-written prompt underneath it would be sent as part
/// of the knock - the exact defect the draft guard exists for, arriving through the one writer
/// nobody requested. The reading is taken once per tick and handed to both stations
/// (SessionInputDraft.swift).
@discardableResult
func applyQuotaKnock(_ state: inout QuotaKnockState, pid: String, provider: String,
                     account: Snapshot.Account, primaryModel: String?, typedAlready: Bool,
                     session: SupervisedState, quiet: SessionQuiet, turnEnded: () -> Bool,
                     keyboardIdle: Bool, relaunchPlanned: Bool, draftSuspected: Bool,
                     quarantine: [String: (model: String?, until: Date)] = [:],
                     counting: (String) -> Int = {
                         supervisedSessionCount(onAccount: $0, liveSupervisors())
                     },
                     loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                     now: Date = Date(), log: URL = sessionInputLog,
                     inject: (String, SessionInputDraftGuard) -> SessionInputInjection = {
                         injectSessionInput($0, draft: $1)
                     }) -> String? {
    guard !typedAlready, !relaunchPlanned, state.due(now: now) else { return nil }
    // The live picture, narrowed exactly as every mover narrows it (this provider, eligible for the
    // model actually running, not this account, nothing quarantined): the sentence names where there
    // is room, so it must not name somewhere a handoff would refuse to go. A snapshot too old to
    // trust answers nothing here for the reason it answers nothing there - advice built on
    // hours-old numbers is worse than silence.
    guard let field = liveMoveField(provider: provider, account: account,
                                    primaryModel: primaryModel, quarantine: quarantine,
                                    loaded: loaded(), now: now),
          let binding = bindingWindow(field.current, primaryModel: primaryModel, now: now)
    else {
        // THE READING HAPPENED EVEN THOUGH NOTHING CAME OF IT, and saying so is what keeps the
        // interval real: a machine with Tally.app closed answers nothing here, and this used to
        // leave `checkedAt` unset, so the next tick two seconds later read and decoded the snapshot
        // again, forever (codex review of c12a1df).
        state.noteChecked(now: now)
        return nil
    }
    let owed = state.observe(
        account: field.current.id,
        cycle: rebalanceCycleKey(field.current, primaryModel: primaryModel, now: now),
        remaining: effectiveRemaining(comfortWindow(binding), now: now), now: now)
    guard owed || state.forced else { return nil }
    guard sessionInputHold(state: session, quiet: quiet, turnEnded: turnEnded(),
                           keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned) == nil
    else { return nil }
    guard let line = quotaKnockMessage(
        account: field.current,
        alternative: capHandoffTarget(field.candidates, primaryModel: primaryModel, now: now),
        sessions: counting(field.current.id), primaryModel: primaryModel,
        limit: sessionInputMaxBytes, now: now) else { return nil }
    // Spent BEFORE the write, the rule `applySessionInput` states about its served stamp: past this
    // line the bytes are on the terminal or the write has failed, and a failure that repeats every
    // reading is the one way this types the same sentence into a conversation twice.
    state.spend()
    // The same protection the requested line gets, decided from the same reading: a sentence nobody
    // asked for is the last thing that should cost somebody their draft.
    let draft = sessionInputDraftGuard(state: session, suspected: draftSuspected)
    let written = inject(line, draft)
    switch written {
    case .done:
        appendSessionInputLine(sessionInputLogLine(pid: pid, outcome: quotaKnockOutcome,
                                                  text: line, now: now), to: log)
    case .failed(let code):
        appendSessionInputLine(quotaKnockFailureLine(pid: pid, code: code, now: now), to: log)
    }
    // AFTER the line that says what was typed, the order the served path uses: what was typed, and
    // then where what was already there has gone.
    appendSessionInputDraftLines(pid: pid, draft: draft, now: now, to: log)
    return written.sent ? line : nil
}
