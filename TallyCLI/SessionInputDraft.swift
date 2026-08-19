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
// THE SHAPE, and the reason it is three acts rather than a fourth gate:
//
//     [(Ctrl-K Ctrl-U) × sessionInputStashRounds]  payload  CR  [Ctrl-Y]
//
// Claude Code's composer keeps a kill buffer (it says so itself: `Ctrl+Y to paste deleted text`), so
// the draft can be moved out of the way and put back rather than waited for. Refusing to type while
// a composer MIGHT hold something would be the other answer, and it is worse in both directions: the
// supervisor cannot see the composer, so the refusal would have to be permanent (a session whose
// owner left a draft in it would never be typed into again), and the case this feature exists for is
// exactly the hand-over that must land.
//
// MEASURED, 2026-08-19, on real Claude Code sessions in a pty sandbox (twelve cases in Phase A,
// four more in Phase B, judged on the session's own screen;
// docs/plans/reports-20260819/draft-stash-report.md carries the matrix): the kill keys ACCUMULATE
// into one buffer that a single Ctrl-Y restores whole and in order; kills onto an empty composer are
// harmless; the buffer survives `/clear`, so the restore can ride the tail of the same injection
// rather than waiting for a fact channel; a slash popup and a permission dialog are both unharmed by
// any of these keys.
//
// AND THE ONE ASYMMETRY THE WHOLE DESIGN TURNS ON (Phase A case A4, re-measured in Phase B against
// the round below): a stash onto an EMPTY composer does not empty the kill buffer, so an
// unconditional Ctrl-Y at the end pastes back whatever was killed minutes ago into a composer
// somebody deliberately left empty. So the stash is unconditional and
// the RESTORE is not: it asks `sessionInputDraftSuspected` below, and every uncertainty in that
// answer is resolved towards NOT restoring. The two mistakes do not cost the same. A restore that
// does not happen leaves the draft in the kill buffer with Claude Code's own hint on screen saying
// how to get it back; a restore that should not have happened puts text nobody meant to type into a
// composer, which is how an unauthorised prompt gets written.

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

/// Paste what was killed: the byte a Ctrl-Y is (0x19).
let sessionInputRestoreByte: UInt8 = 0x19

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

/// How long to wait after Return before pasting the draft back.
///
/// The restore is the tail of the SAME injection rather than a later tick, which is what the
/// measurement bought: at 30ms after the Return, and again at 400ms, the draft came back whole into
/// a session that had just run `/clear` (cases A3b/A3c). Doing it here rather than through a fact
/// channel removes a delayed state machine and every race in it - a pending restore that a second
/// request overtakes, that a relaunch outlives, that a timeout has to give up on.
///
/// 800ms rather than the 30ms that was green, because what was measured was a small conversation:
/// `/clear` on a session at 10% of its context redraws faster than one at 90%, and the cost of being
/// generous is 0.8s of a poll tick on the rare tick that types at all.
let sessionInputRestorePause: TimeInterval = 0.800

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
/// at it (the keyboard gate ahead of this already asks for five), and the direction it errs in is the
/// cheap one: a draft begun within two seconds of the last prompt is not restored, and its owner gets
/// it back with Ctrl-Y.
let sessionInputDraftGrace: TimeInterval = 2

/// Whether that composer probably holds something its owner has not sent.
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
/// performed). Without it, a second `/clear` into a session that has produced no user turn since the
/// first would read its own footprints as a draft and yank whatever the kill buffer held - which is
/// case A4 arriving through the front door.
///
/// PASTED TEXT IS A NAMED BLIND SPOT rather than an oversight. A paste is one read and one stamp, so
/// it is a lone stamp, and lone stamps are the shape terminal chatter has; counting them would put
/// stale kill-buffer text into composers all day to save a draft that arrived without fingers. It is
/// stated in the plan document as a limitation, and its cost is the recoverable one.
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
/// restarted away from it) while the terminal write asks about the ACTIONS. Deriving both from one
/// value is what stops those two readers from ever disagreeing about the same instant.
struct SessionInputDraftGuard: Equatable {
    /// That composer probably holds an unsent draft (`sessionInputDraftSuspected`).
    var suspected: Bool
    /// The composer is the thing this line reaches, so the kill buffer keys mean something.
    var touching: Bool

    /// Nothing is stashed and nothing is restored: what every injection did before this existed, and
    /// what a caller with no draft reading to offer gets.
    static let none = SessionInputDraftGuard(suspected: false, touching: false)

    /// Move whatever is in the composer out of the way first. Unconditional wherever the composer is
    /// the target, because it is harmless where there is nothing to move (cases A4, A6).
    var stash: Bool { touching }
    /// …and put it back afterwards, which is the half that has to be earned.
    var restore: Bool { touching && suspected }
}

/// The guard for a landing into a session in this state.
///
/// `blocked` TOUCHES NOTHING, and it is the one row that is about the session rather than about the
/// draft. A blocked session is sitting on a dialog - a permission request, a plan approval - and its
/// composer is behind that dialog: both keys were measured inert there (case A7), and the draft is
/// already safe, since answering the dialog gives the composer back untouched (case A7e). So a
/// stash that would find nothing is not performed, and a restore that could only paste something
/// older is not either.
func sessionInputDraftGuard(state: SupervisedState, suspected: Bool) -> SessionInputDraftGuard {
    SessionInputDraftGuard(suspected: suspected, touching: state != .blocked)
}

// MARK: - The keystrokes, as a value

/// One thing an injection does to the terminal: a byte, the pause after it, or the moment the line
/// stopped being undoable.
///
/// A PLAN RATHER THAN A LOOP, so the whole sequence is assertable without a terminal. What this
/// feature can get wrong is an ORDER (a Return before the stash, a restore before the send) and an
/// order is invisible to a test that can only see the text it was asked to type: the suite drives
/// the writer through `/dev/null` and can prove it fails, not what it would have written.
enum SessionInputStep: Equatable {
    case press(UInt8)
    case wait(TimeInterval)
    /// The Return has gone: the conversation has the line, and everything after this is the draft
    /// going back into a composer the send emptied.
    ///
    /// A MARKER IN THE PLAN RATHER THAN A BYTE THE WRITER LOOKS FOR, because the byte it would have
    /// to look for is 13 and a payload is free to contain one (`session send` takes arbitrary text).
    /// Matching on the value would move this boundary to whatever the caller happened to type, and
    /// the consequence of getting it wrong in that direction is the defect this marker exists to
    /// end: a delivered line reported as failed, and sent again by whoever believed the report.
    case sent
}

/// Every byte one injection puts on the terminal, in order.
///
/// THE ORDER IS THE CORRECTNESS, and each boundary in it was measured rather than reasoned:
///
///   - the stash goes FIRST, so the payload starts from an empty line whatever was in it;
///   - the Return goes after the submit pause, because a TUI filters its menus between keystrokes
///     and a Return that arrives mid-filter picks the wrong entry (SessionInput.swift carries that
///     measurement, and the Codex one that disagrees with it);
///   - the restore goes LAST, after the Return, which is what makes it safe: the draft comes back
///     into a composer that has already been emptied by the send, so nothing this supervisor typed
///     and nothing the person typed can be joined into one prompt.
func sessionInputInjectionPlan(text: String, draft: SessionInputDraftGuard,
                               gap: TimeInterval = sessionInputByteGap,
                               pause: TimeInterval = sessionInputSubmitPause,
                               restorePause: TimeInterval = sessionInputRestorePause)
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
    // THE RETURN, AND THE MARKER THAT SAYS IT HAS GONE. The marker is emitted whether or not a
    // restore follows, because what it records is a fact about the conversation rather than a step
    // of the draft machinery: past this point the line is somebody's turn, and any later failure is
    // a failure of the putting-back rather than of the sending.
    plan += [.wait(pause), .press(sessionInputReturnByte), .sent]
    if draft.restore {
        plan += [.wait(restorePause), .press(sessionInputRestoreByte)]
    }
    return plan
}
