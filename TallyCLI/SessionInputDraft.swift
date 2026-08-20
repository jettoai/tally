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
//     [(Ctrl-K Ctrl-U) × sessionInputStashRounds]  payload  CR
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
/// What that costs now is an account move that was not taken. What it cost while a Ctrl-Y hung off
/// the same answer was somebody's composer.
///
/// PASTED TEXT IS THE NAMED BLIND SPOT IN THE OTHER DIRECTION rather than an oversight. A paste is
/// one read and one stamp, so it is a lone stamp, and lone stamps are the shape terminal chatter
/// has. It is stated in the plan document as a limitation, and a session moved away from a pasted
/// draft loses it exactly as one moved away from a typed one would.
func sessionInputDraftSuspected(burstAt: Date?, userTurnAt: Date?, injectedAt: Date?,
                                grace: TimeInterval = sessionInputDraftGrace) -> Bool {
    guard let burstAt else { return false }
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

/// The guard for a landing into a session in this state.
///
/// `blocked` TOUCHES NOTHING, and it is the one row that is about the session rather than about the
/// draft. A blocked session is sitting on a dialog - a permission request, a plan approval - and its
/// composer is behind that dialog: the kill keys were measured inert there (case A7), and the draft
/// is already safe, since answering the dialog gives the composer back untouched (case A7e). So a
/// stash that would find nothing is not performed.
func sessionInputDraftGuard(state: SupervisedState, suspected: Bool) -> SessionInputDraftGuard {
    SessionInputDraftGuard(suspected: suspected, touching: state != .blocked)
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
    for byte in Array(text.utf8) {
        plan += [.press(byte), .wait(gap)]
    }
    // AND THE RETURN, which ends the plan: past this byte the line is somebody's turn, and there is
    // nothing left for this supervisor to do to that composer.
    plan += [.wait(pause), .press(sessionInputReturnByte)]
    return plan
}
