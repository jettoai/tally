import Foundation

// WHAT THE PERSON WAS TYPING WHEN THE LINE LANDED, and how it survives it.
//
// THE COLLISION THIS EXISTS FOR, reported by Albert 2026-08-19: `tally session clear` typed `/clear`
// into a composer that already held a half-written prompt. TIOCSTI appends to the terminal's input
// queue, so the composer read `…his draft/clear`, the Return sent all of it as one prompt, the draft
// was gone and nothing was cleared. Every gate in SessionInput.swift was working as designed - the
// keyboard gate asks whether somebody is typing NOW, and somebody who typed six seconds ago and
// stopped to think is not typing now. A composer holds text long after the fingers stop.
//
// THE SHAPE, and the reason it is two acts rather than a fourth gate:
//
//     [(Ctrl-K Ctrl-U) × sessionInputStashRounds]  ESC[200~ payload ESC[201~  CR
//
// and, where the composer is NOT what the line reaches (a session on a dialog), neither the stash
// nor the paste applies and the payload is typed one key at a time, which is an authorisation
// boundary rather than a style: `sessionInputInjectionPlan` carries the measurement.
//
// Claude Code's composer keeps a kill buffer and says so on screen (`Ctrl+Y to paste deleted text`),
// so the draft can be moved out of the way and its owner can put it back with one key rather than
// this line waiting for them. Refusing to type while a composer MIGHT hold something would be the
// other answer, and it is worse in both directions: the supervisor cannot see the composer, so the
// refusal would have to be permanent (a session whose owner left a draft in it would never be typed
// into again), and the case this feature exists for is exactly the hand-over that must land.
//
// MEASURED, 2026-08-19, on real Claude Code sessions in a pty sandbox (twelve cases in Phase A,
// four more in Phase B, judged on the session's own screen;
// docs/plans/reports-20260819/draft-stash-report.md carries the matrix): the kill keys ACCUMULATE
// into one buffer that a single Ctrl-Y restores whole and in order; kills onto an empty composer are
// harmless (Phase A cases A4 and A6, which is why the stash below is unconditional); a slash popup
// and a permission dialog are both unharmed by any of these keys. Those are the rows the stash still
// stands on. The rest of that matrix was about putting the draft back automatically, which this file
// no longer does.
//
// NOTHING IS PUT BACK AUTOMATICALLY, and that is the 2026-08-20 removal. The tail of this sequence
// used to be a Ctrl-Y, asked for by `sessionInputDraftSuspected` below, and twice that day it fired
// on a composer nobody had typed into: two supervisor injections (a quota knock and a `/clear`)
// landed, `draft-stashed rounds=12` and `draft-restored` went into the log, and text appeared in a
// composer its owner had left empty.
//
// THE EVIDENCE CHANNEL CANNOT CARRY THAT DECISION, which is why the answer was to remove the act
// rather than to tighten the question. This supervisor has no master side of the pty, so a run of
// keystroke timestamps is the whole of what it has, and bytes that are not fingers arrive on it as
// keystrokes: Claude Code's TUI turns mouse reporting on, so somebody scrolling back through a
// conversation writes a burst that is indistinguishable from typing, and an IME composing a word is
// the same shape (named as blind spot #1 in the report).
//
// SO THE ASYMMETRY THE DESIGN ALWAYS TURNED ON NOW ARGUES THE OTHER WAY, on the same two sentences
// it always did. A restore that does not happen leaves the draft in the kill buffer with Claude
// Code's own hint on screen saying how to get it back, and its owner presses one key. A restore that
// should not have happened puts text nobody meant to type into a composer, which is how an
// unauthorised prompt gets written. Only the first of those is a mistake this file can still make.
//
// `sessionInputDraftSuspected` STAYS, and the account question is why. A session that may be holding
// a draft is not RESTARTED away from it (`sessionClearMovesAccounts`, and `SessionInputRepick` for
// the same rule a minute later), because a SIGTERM takes the composer and the kill buffer with the
// child. Being wrong there costs a preventive account move; being wrong about a Ctrl-Y cost somebody
// a prompt they never wrote.

/// Kill to the END of the line: the byte a Ctrl-K is (0x0B).
///
/// HALF OF A STASH, AND THE HALF NOBODY EXPECTS TO NEED. Ctrl-U kills backwards from the cursor, so
/// a draft whose author left the cursor in the middle of it - moved back to fix a word, then walked
/// away - keeps everything to the RIGHT of that cursor through any number of presses, and the
/// payload is typed in FRONT of the remnant. Measured 2026-08-19 on a live composer: a three-line
/// draft with the cursor six characters from the end, stashed with twelve Ctrl-U presses and then
/// given a payload, read `PAYLOAD three` and would have been sent as that. With this key ahead of
/// each Ctrl-U the same case leaves the composer empty and the payload alone.
let sessionInputStashKillByte: UInt8 = 0x0B

/// Kill to the start of the line: the byte a Ctrl-U is (0x15).
let sessionInputStashByte: UInt8 = 0x15

/// How many times the pair above is pressed before the payload.
///
/// ONE ROUND IS NOT ENOUGH AND THE SUPERVISOR CANNOT COUNT THE LINES. The kills are per LINE, so a
/// two-line draft needs three rounds (the second line's text, the join, the first line) - 2N-1 for N
/// lines, measured at N=2 and N=3 and covered whole at N=6. Nothing here can see the composer, so
/// the number is fixed rather than derived, and the two errors are not symmetric: too few leaves a
/// remnant the payload is appended to, which IS the bug; too many spends 30ms per key on kills that
/// find nothing, and measured empty kills neither break the accumulation nor drag anything older
/// into it (Phase A case A5d, and at this constant's own value in Phase B).
///
/// Twelve rounds cover a six-line draft and cost 0.72s. These bytes are control characters and are
/// deliberately NOT counted against `sessionInputMaxBytes`: that limit bounds what a caller may type
/// into somebody's conversation, and this is the supervisor getting its own way in.
let sessionInputStashRounds = 12

/// How much newer than the last thing that could have caused it a keyboard burst has to be before it
/// is read as somebody's unsent draft.
///
/// TWO STAMPS ARE COMPARED AGAINST FACTS THAT ARRIVE AT ALMOST THE SAME INSTANT, which is what this
/// margin is for. The Return that sends a prompt is itself a keystroke, so the burst that ends with
/// it and the transcript event it produces are the same moment recorded by two clocks, and whichever
/// lands a millisecond later would otherwise decide the answer. Likewise the child reading the bytes
/// this supervisor just injected stamps the terminal a moment AFTER the write returned.
///
/// Two seconds is far below the gap that separates a person who stopped typing from one who is still
/// at it (the keyboard gate ahead of this already asks for five), and it errs towards NOT suspecting
/// a draft: a burst begun within two seconds of the last prompt does not hold off the preventive
/// account move, which is the one thing this answer still decides.
let sessionInputDraftGrace: TimeInterval = 2

/// How long a keyboard burst goes on meaning somebody is at that composer NOW.
///
/// THE QUESTION IS IN THE PRESENT TENSE, and until 2026-09-02 the function below answered a
/// different one. `burstAt` only moves forward, and so do the two facts that can put a burst behind
/// a cause, so an answer of "yes" could be taken back by a newer prompt or a newer injection and by
/// nothing else: time was not a cause. In a session nobody is in, neither of those ever arrives. A
/// prompt needs the person this answer claims is there, and an injection needs a station that is
/// standing down on this very answer, so the latch closed and stayed closed for the life of the
/// child.
///
/// WHAT THAT COST, read off `~/.tally/handoff.log` and `~/.tally/logs/input.log` on 2026-09-02: two
/// sessions sat on accounts reading 0% for 59 and 37 minutes with `movers-blocked=draft-suspected`
/// as the ONLY named blocker, and each was freed the way this whole family exists to prevent, by a
/// person coming back, typing, and hitting the wall. In that log `draft-suspected` names 21 of 25
/// blocked droughts, and every line where it stands alone is a session on an account with nothing
/// left.
///
/// THE SELF-CONTRADICTION IS THE PROOF OF THE MISSING BOUND, and the log wrote it down rather than
/// anybody having to reason it out: the same audit line omitted `session-busy`, which is
/// `keyboard.idle(followIdleSeconds)` answering that the terminal had been still for two minutes,
/// and named `draft-suspected`, which is this function answering that somebody was typing. One
/// `lastBurstAt`, one tick, two opposite readings, because the keyboard gate bounds that evidence
/// and this one did not bound it at all.
///
/// FIFTEEN MINUTES, which is the number `sessionInputQueuedLife` already carries for the
/// neighbouring question of how long a line is still meant for the conversation in front of it,
/// taken as a SCALE rather than derived from it: the two questions are different and tying them
/// would let a change to one silently answer the other. What it has to be longer than is
/// `followIdleSeconds`, or the contradiction above is still expressible inside one tick; what it
/// has to be shorter than is the time somebody stays away from a desk, and it errs long. The cost
/// is stated plainly rather than defended: a draft left for fifteen minutes in a terminal nothing
/// else stamped can now be carried off by a preventive relaunch, and the kill buffer it was stashed
/// into dies with the child.
let sessionInputDraftLife: TimeInterval = 900

/// Whether that composer probably holds something its owner has not sent.
///
/// WHAT IT STILL DECIDES, since the removal above: whether this session may be RESTARTED onto
/// another account, synchronously at the clear boundary (`sessionClearMovesAccounts`) or a minute
/// later through the window repick (`SessionInputRepick`). A relaunch ends the child, and the child
/// is where the composer and its kill buffer live, so a draft in it has no copy anywhere else.
/// Nothing this answer says reaches the terminal any more.
///
/// EVIDENCE, NOT OBSERVATION. Nothing here can read a composer: the supervisor shares the terminal
/// but has no master side of it, and the screen is not a source either - Claude Code paints dimmed
/// suggestions into the composer that look exactly like a line somebody typed (Phase A, blind spot
/// 6). So the question is answered from two facts it does have: the terminal was stamped by a RUN of
/// keystrokes (`KeyboardActivity` calls that a burst, and a lone stamp deliberately does not count -
/// terminal chatter arrives alone), and no prompt has been sent since.
///
/// `injectedAt` is when this supervisor last typed into this composer itself, and it is not
/// optional politeness: injected bytes are read by the child off the same terminal and arrive as a
/// burst indistinguishable from typing (SessionInput.swift says so where the injection is
/// performed). Without it, every line this supervisor types would leave the session looking drafty
/// to the next tick, and the preventive move would be declined for the rest of that session's life.
///
/// A BURST IS NOT ONLY FINGERS, which is the limit that ended the restore on 2026-08-20 (see the
/// header) and is stated here because it is this function's limit rather than the caller's: mouse
/// reporting and an IME both write runs of bytes onto that terminal, and this answer counts them.
/// What it cost while a Ctrl-Y hung off the same answer was somebody's composer. WHAT IT COSTS NOW
/// is no longer the single account move the 2026-08-20 note recorded: three preventive movers hold
/// on this answer with no bound of their own (`WindowRepick`, `Rebalance`, `TurnBoundaryMove`) and
/// the automatic resume after a wall waits on it too (`CapResume`), so a false yes is a session
/// parked on a spent account until somebody comes back and a resume line that arrives late or not
/// at all. That is why the answer is bounded from 2026-09-02 (`sessionInputDraftLife`): the limit
/// stated here is unchanged, and what changed is how long a reading taken through it stands.
///
/// PASTED TEXT IS THE NAMED BLIND SPOT IN THE OTHER DIRECTION rather than an oversight. A paste is
/// one read and one stamp, so it is a lone stamp, and lone stamps are the shape terminal chatter
/// has. It is stated in the plan document as a limitation, and a session moved away from a pasted
/// draft loses it exactly as one moved away from a typed one would.
func sessionInputDraftSuspected(burstAt: Date?, userTurnAt: Date?, injectedAt: Date?,
                                grace: TimeInterval = sessionInputDraftGrace,
                                life: TimeInterval = sessionInputDraftLife,
                                now: Date = Date()) -> Bool {
    // NO BURST, OR ONE TOO OLD TO BE ABOUT THE PRESENT, in one guard because they are one answer:
    // this function says somebody is at that composer, and evidence of that has to be recent as
    // well as uncontradicted (`sessionInputDraftLife` carries the incident and the number).
    guard let burstAt, now.timeIntervalSince(burstAt) < life else { return false }
    // EVERY KNOWN CAUSE OF A BURST THAT IS NOT A DRAFT, in one list rather than as a chain of ifs:
    // the burst has to be clear of all of them, and a cause this build does not know about is a
    // cause that is missing from this array rather than one hidden in a condition.
    for cause in [userTurnAt, injectedAt].compactMap({ $0 }) {
        guard burstAt.timeIntervalSince(cause) > grace else { return false }
    }
    return true
}

/// What one injection may do about the draft: the evidence, and whether this session's composer is
/// something the kill buffer keys reach at all.
///
/// TWO FIELDS RATHER THAN TWO BOOLEANS DECIDED SEPARATELY, because the account question next door
/// asks about the EVIDENCE (`sessionClearMovesAccounts`: a session that may hold a draft is not
/// restarted away from it) while the terminal write asks about the ACTION. Deriving both from one
/// value is what stops those two readers from ever disagreeing about the same instant.
///
/// THE EVIDENCE NO LONGER REACHES THE TERMINAL, since 2026-08-20 (see the header): `suspected` is
/// read by the account question alone, and what gets typed is decided by `touching` and nothing
/// else. The two fields are kept together anyway, because they are one reading of one instant and
/// splitting them is how the two readers would come to disagree.
struct SessionInputDraftGuard: Equatable {
    /// That composer probably holds an unsent draft (`sessionInputDraftSuspected`).
    var suspected: Bool
    /// The composer is the thing this line reaches, so the kill buffer keys mean something.
    var touching: Bool

    /// Nothing is stashed: what every injection did before this existed, and what a caller with no
    /// draft reading to offer gets.
    static let none = SessionInputDraftGuard(suspected: false, touching: false)

    /// Move whatever is in the composer out of the way first, and leave it in the kill buffer for
    /// whoever put it there. Unconditional wherever the composer is the target, because it is
    /// harmless where there is nothing to move (cases A4, A6).
    var stash: Bool { touching }
}

/// The guard for a landing into a session with, or without, a dialog in front of its composer.
///
/// A DIALOG TOUCHES NOTHING, and it is the one row that is about the session rather than about the
/// draft. A session on a dialog - a permission request, a plan approval, an open question - has its
/// composer behind it: the kill keys were measured inert there (case A7), and the draft is already
/// safe, since answering the dialog gives the composer back untouched (case A7e). So a stash that
/// would find nothing is not performed, and the payload is typed rather than pasted, which is an
/// authorisation boundary rather than a style (`sessionInputInjectionPlan` carries the measurement).
///
/// WHAT A CALLER PASSES IS `SessionTick.waitingOnPerson`, NEVER `state == .blocked`, and until
/// 2026-09-05 this function asked the second of those itself. It is the regression the movers had
/// fixed a fortnight earlier, arriving here (SessionStateSync.swift carries the codex review of
/// e52a436): Claude Code fires `idle_prompt` about sixty seconds after it stops speaking, and
/// `supervisedSessionState` folds that SOFT wait into `blocked` for a session that is otherwise
/// quiet. So on every machine with the notification hook installed, an ordinary idle session read
/// as a dialog. Nothing was stashed in a composer that was sitting right there, and every line
/// landing in it was typed one key at a time: at `sessionInputByteGap` a 200-byte payload is six
/// seconds of a poll loop that cannot tick, which is exactly the stall the paste was introduced to
/// end. Only a HARD wait puts something in front of that composer, and `waitingOnPerson` is the
/// reading that says so.
func sessionInputDraftGuard(dialog: Bool, suspected: Bool) -> SessionInputDraftGuard {
    SessionInputDraftGuard(suspected: suspected, touching: !dialog)
}

// MARK: - The keystrokes, as a value

/// One thing an injection does to the terminal: a byte, or the pause after it.
///
/// A PLAN RATHER THAN A LOOP, so the whole sequence is assertable without a terminal. What this
/// feature can get wrong is an ORDER (a Return before the stash, a payload typed into a composer
/// that was never emptied) and an order is invisible to a test that can only see the text it was
/// asked to type: the suite drives the writer through `/dev/null` and can prove it fails, not what
/// it would have written.
///
/// THERE IS NO MARKER FOR THE RETURN ANY MORE, and its absence is the same fact as the tail this
/// sequence lost on 2026-08-20: a plan used to continue past the Return to put a draft back, so the
/// writer had to know which side of it a refused byte was on. Nothing follows the Return now, so a
/// write either sent the line or did not.
enum SessionInputStep: Equatable {
    case press(UInt8)
    case wait(TimeInterval)
}

/// Every byte one injection puts on the terminal, in order.
///
/// THE ORDER IS THE CORRECTNESS, and each boundary in it was measured rather than reasoned:
///
///   - the stash goes FIRST, so the payload starts from an empty line whatever was in it;
///   - the payload is ONE PASTE, with no waits of its own, WHEN THE COMPOSER IS WHAT IT REACHES,
///     because a paste is a single edit rather than a run of keystrokes (`sessionInputPasteStart`
///     carries the 2026-09-05 measurement, and the 4.4 seconds a typed line used to cost); a
///     dialog is typed at instead, for the reason the branch below states at length;
///   - the Return goes after the submit pause, because a TUI filters its menus between keystrokes
///     and a Return that arrives mid-filter picks the wrong entry (SessionInput.swift carries that
///     measurement, and the Codex one that disagrees with it);
///   - and the Return goes LAST. Nothing this plan does can put text into a composer after the send
///     has emptied it, which is the whole of the 2026-08-20 removal in one line of code.
func sessionInputInjectionPlan(text: String, draft: SessionInputDraftGuard,
                               gap: TimeInterval = sessionInputByteGap,
                               pause: TimeInterval = sessionInputSubmitPause)
    -> [SessionInputStep] {
    var plan: [SessionInputStep] = []
    if draft.stash {
        // FORWARD THEN BACKWARD, in that order and per round: the kill to the end of the line takes
        // what a cursor left in the middle of a draft would otherwise shelter, and the kill to the
        // start takes the rest and joins the line above. Reversing them would put the payload's line
        // ahead of the remnant on every draft whose author was mid-edit.
        for _ in 0 ..< sessionInputStashRounds {
            plan += [.press(sessionInputStashKillByte), .wait(gap),
                     .press(sessionInputStashByte), .wait(gap)]
        }
    }
    let payload = Array(text.utf8)
    if !payload.isEmpty {
        if draft.touching {
            // THE MARKERS ARE PART OF THE PAYLOAD OR THERE IS NO PAYLOAD, which is why they are
            // added here rather than unconditionally: an empty send is a Return pressed on a prompt
            // that sits on its default (`injectSessionInput` says so where the case is argued), and
            // an empty paste is a pair of escape sequences asking a composer to do nothing, which
            // is a thing to go wrong for no gain.
            plan += (sessionInputPasteStart + payload + sessionInputPasteEnd).map { .press($0) }
        } else {
            // A DIALOG IS TYPED AT, NEVER PASTED INTO, and this branch is an authorisation boundary
            // rather than a performance choice. `touching` is false exactly when the composer is
            // NOT what this line reaches, which is a session waiting on a PERSON: a permission
            // request, a plan approval, an open question, and never the soft `idle_prompt` the
            // board also calls blocked (`sessionInputDraftGuard` carries that correction). A
            // chooser reads KEYS: a paste is one edit event, so the answer is swallowed by the
            // dialog layer and never picks anything. The Return that follows then activates
            // whatever was highlighted, and what is highlighted is the first option.
            //
            // MEASURED 2026-09-05, twice, on a real Bash permission dialog in a pty sandbox: a
            // pasted `4` (No) left no trace in the composer or the transcript and the Return ran
            // the command (`tool_result err=False`), while the same `4` typed one key at a time
            // refused it (`err=True`, "The user doesn't want to proceed with this tool use"). So
            // the failure is not "the answer did not land": it is that the more a caller means NO,
            // the more certainly YES happens. The only shape of request that can say no is exactly
            // the one this branch protects.
            //
            // The cost is what a dialog answer is: an option number, one or two bytes, so 30ms or
            // 60ms. Nothing a person waits on, and `.none` (a caller with no reading to offer)
            // takes this branch too, which is the safe direction for an answer nobody vouched for.
            plan += payload.flatMap { [SessionInputStep.press($0), .wait(gap)] }
        }
    }
    // AND THE RETURN, which ends the plan: past this byte the line is somebody's turn, and there is
    // nothing left for this supervisor to do to that composer.
    plan += [.wait(pause), .press(sessionInputReturnByte)]
    return plan
}
