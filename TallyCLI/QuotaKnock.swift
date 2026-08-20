import Darwin
import Foundation

// THE ADVISORY KNOCK, performed: the poll-tick station that reads the fleet, decides whether this
// session is owed the sentence (QuotaKnockLogic.swift holds every rule about that) and gets it in
// front of the conversation.
//
// TWO CHANNELS, AND THE SESSION'S OWN HARNESS DECIDES WHICH. Where the app has registered the knock
// hooks in this account's settings.json, the sentence is FILED (QuotaKnockNotice.swift): one small
// file the session's own Claude Code claims on its next prompt or tool call, and hands the model as
// context. Where it has not, the sentence is TYPED into the composer, which is what this station has
// always done and remains the whole feature on a machine with no integration installed.
//
// THE FILED CHANNEL IS THE ONE THIS FEATURE WANTED. Typing may only happen into a composer nobody
// else is using, so every gate below holds for a conversation mid-turn - which is the one state the
// session this exists for is actually in (QuotaKnockLogic.swift argues why an advisory is for the
// busy session and a move is for the idle one). A file interleaves with nothing, so the filed
// channel skips those gates rather than inheriting them: they are about keystrokes, and there are
// none.
//
// WHEN IT TYPES, IT TYPES THROUGH THE SAME DOOR `tally session send` DOES, gates included.
// `sessionInputHold` is asked exactly as the request path asks it, and a hold of any kind means
// this tick says nothing and the next one decides again: a line typed into a conversation mid-turn
// interleaves with what it is writing, a line typed while somebody is at the keyboard interleaves
// with what they are typing, and a line typed into a child about to be SIGTERMed looks sent and is
// lost (SessionInput.swift argues each of them where the table lives). Nothing here is a second
// gate and nothing here bypasses one.
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

/// The word for a knock this tick FILED rather than typed (grep `input=quota-knock-filed`): the
/// sentence is on disk and the session's own hook run is what will deliver it
/// (QuotaKnockNotice.swift). Its own outcome beside the typed one, because the two answer different
/// questions afterwards - `quota-knock` is a sentence that reached a conversation, this one is a
/// sentence that was decided. What closes the pair is `quota-knock-delivered`, written by the hook.
let quotaKnockFiledOutcome = "quota-knock-filed"

/// And the word when the file could not be written, which is the filed channel's ENXIO.
let quotaKnockFileFailedOutcome = "quota-knock-file-failed"

/// The line a refused write leaves (grep `input=quota-knock-failed`). Its own shape rather than the
/// served one, for the reason `sessionInputReceiptLostLine` is its own line: nothing was typed, so
/// the field a reader wants is not the text but the errno, and the two that happen are told apart by
/// nothing else (ENXIO is a supervisor with no controlling terminal, EINVAL a kernel that has
/// retired this ioctl).
///
/// `outcome` is a parameter because the other channel refuses in exactly the same shape and for
/// exactly the same reasons: nothing reached the conversation, and the errno is the whole of what
/// separates the causes (EACCES is a state directory somebody narrowed, ENOSPC a full disk).
func quotaKnockFailureLine(pid: String, code: Int32, outcome: String = quotaKnockFailedOutcome,
                           now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=\(outcome) "
        + "errno=\(code) failed=\(String(cString: strerror(code)))\n"
}

/// One poll tick's advisory knock: nil on almost every tick, and otherwise the line that was TYPED.
///
/// NIL IS ALSO WHAT A FILED KNOCK ANSWERS, which is not a lost answer but the honest one: what this
/// return value feeds is the loop's record of when it last wrote to the composer
/// (`lastComposerWrite`, which the next tick's draft reading discounts), and a tick that filed a
/// file typed nothing at all. What happened is in the log and on disk.
///
/// THE ORDER OF THE GATES IS WHAT KEEPS THIS FREE, and it is not the order they are argued in:
///
///  - what costs nothing comes first (a line already typed this tick, a planned relaunch, the
///    interval since the last reading), so the ordinary tick stops here;
///  - then the fleet reading, which is one `~/.tally/snapshot.json` read;
///  - then whether this session is OWED the sentence, which is pure;
///  - then which channel this session has, which costs nothing at all here: the reading was taken
///    when this child was launched and is handed in (`quotaKnockFilingAvailable`);
///  - and only then the input gate, which reads a file and a transcript tail through `turnEnded` -
///    and which the filed channel does not ask at all.
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
/// (SessionInputDraft.swift). It says nothing about the filed channel, which touches no composer.
///
/// `filing` is whether THIS CHILD's Claude Code can be handed the sentence instead of having it
/// typed. The reading is taken once, when that child is launched, and handed in rather than taken
/// here (`quotaKnockFilingAvailable` argues why the moment is the whole of it). A closure so a
/// caller that computes it lazily still may, and defaulted to false so every caller that has not
/// been taught about the hooks keeps the behaviour it had.
@discardableResult
func applyQuotaKnock(_ state: inout QuotaKnockState, pid: String, provider: String,
                     account: Snapshot.Account, primaryModel: String?, typedAlready: Bool,
                     session: SupervisedState, quiet: SessionQuiet, turnEnded: () -> Bool,
                     keyboardIdle: Bool, relaunchPlanned: Bool, draftSuspected: Bool,
                     quarantine: [String: (model: String?, until: Date)] = [:],
                     reserves: AccountReserves = .none,
                     filing: () -> Bool = { false },
                     counting: (String) -> Int = {
                         supervisedSessionCount(onAccount: $0, liveSupervisors())
                     },
                     loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                     now: Date = Date(), log: URL = sessionInputLog,
                     dir: URL = supervisorStateDir,
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
          let binding = bindingWindow(field.current, primaryModel: primaryModel,
                                      reserves: reserves, now: now)
    else {
        // THE READING HAPPENED EVEN THOUGH NOTHING CAME OF IT, and saying so is what keeps the
        // interval real: a machine with Tally.app closed answers nothing here, and this used to
        // leave `checkedAt` unset, so the next tick two seconds later read and decoded the snapshot
        // again, forever (codex review of c12a1df).
        state.noteChecked(now: now)
        return nil
    }
    // WHAT THE ARM SAID BEFORE THIS READING, kept for one comparison below: `observe` folds the
    // re-arm in and answers only whether the sentence is owed, so this is the one place that can
    // tell a re-arm from an announcement that was never made.
    let announced = state.fired
    let owed = state.observe(
        account: field.current.id,
        cycle: rebalanceCycleKey(field.current, primaryModel: primaryModel, now: now),
        remaining: effectiveRemaining(comfortWindow(binding), now: now), now: now)
    // A RE-ARM TAKES BACK A SENTENCE NOBODY HAS BEEN TOLD YET. The typed channel has nothing to take
    // back (the bytes were on the terminal the moment they were written), but a filed one sits on
    // disk until the session's next prompt or tool call, which for an idle session may be an hour
    // away or never - and by then "your account is running low" describes a drought that ended, an
    // account this session has left, or a window that refilled. Unconditional because the file is
    // only ever there when this channel filed one: a machine that types costs one `unlink` that
    // answers ENOENT.
    if announced && !state.fired { clearQuotaKnockNotice(pid: pid, dir: dir) }
    guard owed || state.forced else { return nil }
    // WHICH CHANNEL, asked before the composer gate rather than after it, because the answer decides
    // whether that gate applies at all: it exists to keep keystrokes out of a composer somebody else
    // is using, and a filed sentence is not keystrokes. This is the whole of what the migration
    // buys - the mid-turn session, which every hold below refuses, is the session this feature was
    // written for.
    let filed = filing()
    guard filed || sessionInputHold(state: session, quiet: quiet, turnEnded: turnEnded(),
                                    keyboardIdle: keyboardIdle,
                                    relaunchPlanned: relaunchPlanned) == nil
    else { return nil }
    guard let line = quotaKnockMessage(
        account: field.current,
        alternative: capHandoffTarget(field.candidates, primaryModel: primaryModel,
                                      reserves: reserves, now: now),
        sessions: counting(field.current.id), primaryModel: primaryModel,
        limit: sessionInputMaxBytes, now: now) else { return nil }
    // Spent BEFORE the write, the rule `applySessionInput` states about its served stamp: past this
    // line the bytes are on the terminal or the write has failed, and a failure that repeats every
    // reading is the one way this types the same sentence into a conversation twice. The filed
    // channel is under the identical rule for the identical reason: a state directory that refuses
    // one write refuses the next one two seconds later.
    state.spend()
    if filed {
        let failure = writeQuotaKnockNotice(QuotaKnockNotice(message: line, at: now),
                                            pid: pid, dir: dir)
        appendSessionInputLine(
            failure.map { quotaKnockFailureLine(pid: pid, code: $0,
                                                outcome: quotaKnockFileFailedOutcome, now: now) }
                ?? sessionInputLogLine(pid: pid, outcome: quotaKnockFiledOutcome, text: line,
                                       now: now),
            to: log)
        // NOTHING WAS TYPED, so nothing is claimed to have been: the caller's `lastComposerWrite`
        // must not move for a tick that never touched the composer, or the next tick's draft reading
        // discounts keystrokes that really were somebody's (SessionInputDraft.swift).
        return nil
    }
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
