import Foundation

// SERVING ONE PENDING REQUEST, which is the whole of what a poll tick does about `tally session
// send` and `tally session clear`.
//
// Split from SessionInput.swift at that file's size cap, along the seam its own MARK already drew:
// that file decides WHETHER a line may be carried out (the gate table, the wait, the refusal
// wording) and how a terminal write is performed; this one is the tick that takes such a decision,
// carries it out through the landing (SessionInputLanding.swift), publishes the answer and leaves
// the audit trail. Nothing here decides a gate, and nothing there touches a file.

/// What the input station did this tick, in the facts the loop around it has readers for.
///
/// A VALUE RATHER THAN THE TYPED LINE ALONE since the clear boundary existed (2026-08-18): a landing
/// has two endings now, and a caller that only asked "what was typed" would read the move as
/// "nothing happened" - which is precisely the tick where the child is about to be replaced.
struct SessionInputAction: Equatable {
    /// The line that reached the terminal, and nothing on any other branch. What DELIVERY means:
    /// the receipt, the knock that must not speak over it, and this supervisor's record of having
    /// typed all read this.
    var typed: String?
    /// What this tick's landing means for the window repick beside it.
    ///
    /// TWO SIGNALS BECAUSE THEY ANSWER TWO QUESTIONS, which is the correction of 2026-08-19 (codex
    /// review of 002c176). "Did the line land" and "may this session now be restarted onto another
    /// account" were one field, and the repick is a RELAUNCH: it kills the child a minute or so
    /// after the clear, and the child is where the composer and its kill buffer live. So a `/clear`
    /// typed into a session that may be holding an unsent draft closed a window and then, quietly,
    /// took the draft with it - the one copy of it, since a stash lives in the process being killed
    /// (Phase A measured that a relaunch ends the kill buffer outright).
    ///
    /// THE RULE IS THE ONE `sessionClearMovesAccounts` ALREADY STATES, applied to the other door: a
    /// session suspected of holding a draft is not restarted away from it. The repick is the same
    /// move a minute later, so exempting it would leave the rule true only of the ending that
    /// happens to be synchronous.
    ///
    /// IT KEYS ON `suspected` RATHER THAN ON WHETHER A STASH RAN, and the two differ in exactly one
    /// place: a `blocked` session is not stashed at all (its composer is behind a dialog) and its
    /// draft is sitting in that composer, where a SIGTERM ends it just the same. A stashed draft is
    /// in the child's kill buffer, which the same SIGTERM ends, so both readings point one way.
    var repick: SessionInputRepick = .untouched
    /// The account a `tally session clear` chose to reopen this session on instead of typing. The
    /// loop turns it into this tick's relaunch, and into this tick's answer to "is the child about
    /// to be replaced" - which is what stops the knock beside it from typing into a child that is
    /// already being terminated (Supervisor.swift, where both are set together).
    var moveTo: Snapshot.Account?
}

/// What one landing tells the window repick to do, in the three answers it has.
///
/// THREE RATHER THAN TWO, which is the correction of 2026-08-19 (codex review of e5bfd13). Saying
/// "do not arm" is not the same as saying "this session must not be restarted", and the gap between
/// them is a standing arm: `WindowRepickState.arm` ignores a nil line and leaves everything it was
/// already holding, so a clear that carried a draft would land INSIDE an arm left by an earlier one
/// - and that earlier arm is waiting for exactly the event this clear is about to produce, a
/// conversation id that changes. The next tick reads `landed`, the relaunch is taken, and the child
/// holding the draft goes. Not arming was never the invariant; the invariant is that at the moment
/// a suspected draft's clear lands, this session is not in a restartable state.
enum SessionInputRepick: Equatable {
    /// Nothing this tick did concerns the repick. What a wait, a refusal, an ordinary send and a
    /// clear-boundary move all say: the state is left exactly as it was, armed or not.
    case untouched
    /// A window closed and nothing suggests a draft: arm on this line, which is what the repick
    /// filters for a clear and ignores otherwise.
    case arm(String)
    /// A window closed while this session may be holding an unsent draft: drop any standing arm,
    /// including one an earlier clear left.
    ///
    /// WHY A CLEAR AND NOT EVERY LINE TYPED INTO A SUSPECTED DRAFT, which is the boundary to hold
    /// on to. What makes this cancellation legitimate is that THIS line is itself the window-close
    /// the standing arm is waiting for: it is about to change the conversation id, which is the one
    /// fact that fires a repick. An ordinary send changes nothing that arm reads, so cancelling on
    /// it would disarm a preventive move for a reason that has nothing to do with it - and that arm
    /// belongs to a window that closed while nobody was mid-draft, and expires in a minute by
    /// itself.
    case cancel
}

// MARK: - The tick

/// Serve this session's pending `tally session send`, if there is one to serve.
///
/// The whole of it lives here rather than in the poll loop for the reason `syncSessionState` does:
/// Supervisor.swift is over its size cap, so the loop hands over the state it has already decided
/// this tick and everything else happens on this side.
///
/// `state` is THIS TICK'S reading rather than the file's, and the call site is immediately after
/// `syncSessionState` for that reason: the gate has to judge the session as it is now, not as it was
/// two seconds ago - the whole feature turns on noticing the moment a turn ends.
///
/// `relaunchPlanned` is this tick's own answer to "is the child about to be terminated", handed
/// down rather than looked up: only the poll loop knows, and it knows before it acts
/// (`sessionInputDecision` carries the whole reasoning). No default, for the reason stated there.
///
/// `inject` is injectable so the suite can drive every branch without a terminal, and `agents` with
/// it: what a `/clear` costs is read off this session's roster at the instant the line lands
/// (`landSessionInput`), and a suite must be able to say what that roster held.
///
/// `clearBoundary` is the account question a `tally session clear` earns the right to ask at that
/// same instant: it answers with the account this session should reopen on, or nil to type as
/// normal. IT HAS A DEFAULT, unlike `relaunchPlanned` two paragraphs up, and the difference is what
/// forgetting it costs: a caller that leaves this out declines every move, which is the behaviour
/// that shipped before it existed, while a caller that leaves out `relaunchPlanned` types into a
/// child that is being killed and reports it delivered.
///
/// RETURNS WHAT THIS TICK DID, in the three fields that have readers (`SessionInputAction`). A
/// `/clear` reaching a composer is the moment a session's window closes, which is the cheapest
/// moment in its life to leave a dying account, and `WindowRepickState.arm` is what waits for it. It
/// is armed on a line that was TYPED rather than one that was requested - a request that waited,
/// expired or was refused closed no window - and through `repick` rather than through `typed`,
/// because that repick ends the child a minute later and a session that may hold an unsent draft is
/// not restarted away from it: such a clear CANCELS any standing arm rather than merely declining to
/// add one (`SessionInputRepick`).
///
/// `turnEnded` is a QUESTION RATHER THAN AN ANSWER, and that is what keeps this feature free: it
/// reads a file and the tail of a transcript (SessionTurnEnd.swift), and it is asked only after the
/// line below has established that there is a request to serve at all. On the overwhelming majority
/// of ticks there is none and nothing is read.
///
/// `draftSuspected` is whether somebody has a half-written prompt in that composer, and what it
/// decides is whether this session may be RESTARTED away from it: synchronously, when a `tally
/// session clear` answers itself by reopening the child on another account (SessionClear.swift), and
/// a minute later through the window repick above. It reaches nothing that is typed
/// (SessionInputDraft.swift carries the 2026-08-20 removal). It has NO DEFAULT, on the terms
/// `relaunchPlanned` has none: a caller that forgot it would let a preventive move kill the child
/// holding somebody's prompt and report the line delivered.
@discardableResult
func applySessionInput(_ state: inout SessionInputState, session: SupervisedState,
                       quiet: SessionQuiet, turnEnded: () -> Bool, keyboardIdle: Bool,
                       relaunchPlanned: Bool, draftSuspected: Bool, waitingOnPerson: Bool,
                       dir: URL = sessionInputDir,
                       log: URL = sessionInputLog, now: Date = Date(),
                       agents: (String) -> Int? = { readSessionAgents(pid: $0)?.reportable },
                       clearBoundary: () -> Snapshot.Account? = { nil },
                       inject: (String, SessionInputDraftGuard) -> SessionInputInjection = {
                           injectSessionInput($0, draft: $1)
                       }) -> SessionInputAction {
    let pid = state.sessionKey
    // Read once, and nothing to decide without one: every branch below is about a request, so the
    // absent case is answered here rather than in each of them.
    guard let request = readSessionInputRequest(sessionKey: pid, dir: dir) else {
        return SessionInputAction()
    }
    let outcome: SessionInputOutcome
    var detail: String?
    /// The line that reached the terminal, set on the one branch where that happened.
    var typed: String?
    /// …and what that means for the window repick: arm on it, leave it alone, or cancel a standing
    /// arm because this line closes a window while a draft may be in the child a repick would kill
    /// (`SessionInputRepick` carries the whole reasoning).
    var repick = SessionInputRepick.untouched
    /// How many subagents that line took with it, when it was a line that clears the context and
    /// this session's roster could be believed.
    var killed: Int?
    /// The account a clear-boundary move chose instead of typing, on the one branch where that
    /// happened.
    var moveTo: Snapshot.Account?
    /// What this landing was allowed to do about a draft in that composer, and what it therefore has
    /// to say about it in the log. Decided before the landing rather than inside it, because the
    /// account question reads the same value (SessionInputLanding.swift).
    let draft = sessionInputDraftGuard(dialog: waitingOnPerson, suspected: draftSuspected)
    /// Whether this landing went to the terminal at all, which is what the draft line below turns
    /// on: a refused write may still have got the stash out before it failed, and that is precisely
    /// the case whose draft is sitting in a kill buffer nobody has been told about, while a landing
    /// that moved the session never went near that composer.
    var touchedComposer = false
    switch sessionInputDecision(request: request, servedEpoch: state.servedEpoch, state: session,
                                quiet: quiet, turnEnded: turnEnded(), keyboardIdle: keyboardIdle,
                                relaunchPlanned: relaunchPlanned, now: now) {
    // NOTHING IS WRITTEN ON EITHER, which is what makes a wait a wait: the request stays on disk
    // exactly as it was, no answer appears for a caller to read, and `servedEpoch` does not move.
    // Every one of those happens below this return.
    case .ignore, .wait:
        // The hold the wait carries is not written anywhere on purpose: it is this tick's reading
        // and the next tick decides again from scratch, so recording it would be publishing a
        // reason that may already be false. It reaches the caller through the refusal, which is
        // taken at the moment the wait ends.
        return SessionInputAction()
    case .refuse(let refusal, let why):
        outcome = refusal
        detail = why
    case .inject(let asked):
        // THE ONE PLACE A LINE IS CARRIED OUT, gathered into a function of its own rather than
        // performed here (SessionInputLanding.swift states what else that buys). It has two
        // endings and this switch is the whole of the difference between them here.
        let landing = landSessionInput(asked, sessionKey: pid, state: session, draft: draft,
                                       agents: agents, boundary: clearBoundary, inject: inject)
        // ONE READING OF WHAT IT COST, taken from the landing rather than re-derived per branch:
        // "a write the terminal refused ended nothing" is a rule, and a rule spelled once here and
        // again in a pattern below is two rules waiting to disagree.
        killed = landing.agents
        // AND WHETHER IT WENT TO THE TERMINAL AT ALL, taken from the landing for the same reason
        // and in the same place: both endings that typed leave the same draft line, and reading
        // that off two of the arms below is two copies of one rule.
        if case .typed = landing { touchedComposer = true }
        switch landing {
        // THE ONE WRITE THAT SENT NOTHING LEADS, so the arm under it can be everything else: a
        // terminal that refused a byte BEFORE the Return.
        case .typed(.failed(let code), _):
            outcome = .failedTTY
            detail = "errno \(code): \(String(cString: strerror(code)))"
        // AND THE OTHER SIDE OF IT: every byte got out, so the conversation has the line. There is
        // no third ending any more - a plan used to continue past the Return to put a draft back,
        // and a Ctrl-Y the terminal refused there was a DELIVERY that this switch had to serve as
        // one, because reporting it as a failure had a caller send a line the conversation already
        // had (codex review of 1f69cf9). Nothing is pressed after the Return since 2026-08-20
        // (SessionInputDraft.swift).
        case .typed:
            outcome = .submitted
            typed = asked.text
            // THE ONE PLACE THE TWO SIGNALS PART. Everything about delivery is above this line;
            // this is about what may be done to the child AFTERWARDS, and a draft is a reason not
            // to restart it (`SessionInputRepick`). A suspected draft under a line that closes the
            // window cancels rather than merely declines to arm: this line is itself the event a
            // standing arm is waiting for.
            if !draft.suspected {
                repick = .arm(asked.text)
            } else if sessionInputClearsContext(asked.text) {
                repick = .cancel
            }
            detail = killed.map(sessionInputAgentsNote)
        case .moved(let target, _):
            // NOTHING WAS TYPED, and `typed` stays nil for a reason that is not cosmetic: it arms
            // the window repick (`WindowRepickState.arm`), whose whole job is to move a session
            // AFTER a clear it observed. A move that armed it would leave a second mover waiting to
            // move the session again, and the relaunch below is already the move.
            outcome = .movedAccount
            detail = sessionClearMovedDetail(to: target, agents: killed)
            moveTo = target
        }
    }
    // THE ANSWER FIRST, then the request file. The caller is polling for the answer, so writing it
    // first means there is never a moment where the request has vanished and nothing has replaced
    // it - which the caller could only read as "still waiting", right up to its timeout.
    //
    // AND THE STAMP BEFORE BOTH, WHETHER OR NOT THE ANSWER LANDS. Both orders were weighed, because
    // the wrong one is the only way this feature types a line twice:
    //
    //   - Advancing it here records the fact that cannot be undone: the bytes are on the terminal,
    //     or the refusal has been decided. Holding it back until the answer is published would
    //     leave the request stamped newer than the served epoch, so the NEXT tick would decide the
    //     same request again and type the same line into a conversation that already has it.
    //   - The opposite failure - a stamp that moves over a request nothing was done about - cannot
    //     arise here: `.ignore` and `.wait` return above without touching any of this, so every
    //     branch that reaches this line has either injected the text or consumed the request with a
    //     refusal that is about to be published.
    //
    // So a lost answer costs the caller its wait and nothing more, and it is not silent: the audit
    // line below records that the text DID land, which is the sentence somebody needs when a
    // session turns out to have been typed into twice by a caller that retried (codex review of
    // 18b3174).
    state.servedEpoch = request.epoch
    // THE CALLER'S OWN WAIT RIDES BACK ON THE ANSWER, copied rather than decided here: it says for
    // how long this receipt is somebody's to collect, and the only end that knows is the end that
    // is waiting (`SessionInputRequest.waitSeconds`). A request from a CLI that predates the field
    // carries nil and the answer says nil, which reads as the longest wait, exactly as before.
    let lostReceipt = writeSessionInputResult(
        SessionInputResult(epoch: request.epoch, outcome: outcome.rawValue, detail: detail,
                           waitSeconds: request.waitSeconds),
        sessionKey: pid, dir: dir)
    // Unlinked only when the file still holds the request that was SERVED, the rule
    // `PendingSwitchConsumption.commit` states: injection takes seconds, and a second `tally session
    // send` written in that window is a newer stamp at the same path. An unconditional unlink would
    // delete an instruction nobody has carried out; leaving it means the next tick serves it,
    // because `servedEpoch` records the epoch that was served rather than "whatever is pending".
    if readSessionInputRequest(sessionKey: pid, dir: dir)?.epoch == request.epoch {
        clearSessionInputRequest(sessionKey: pid, dir: dir)
    }
    appendSessionInputLine(sessionInputLogLine(pid: pid, outcome: outcome.rawValue,
                                               text: request.text, now: now),
                           to: log)
    // AND WHAT THE LINE COST, on a line of its own beside it (the shape `receipt-lost` uses, and for
    // the same reason: the served line's business is what was typed). This is the one consequence of
    // a send that nobody standing at the address will read - the caller of a `/clear` is the session
    // being cleared, and it has left by the time its line lands (SessionInputCommand.swift). So the
    // log is where "my agents died" gets its answer.
    if let killed {
        appendSessionInputLine(sessionInputAgentsKilledLine(pid: pid, count: killed, now: now),
                               to: log)
    }
    // AND WHAT BECAME OF WHATEVER WAS ALREADY IN THAT COMPOSER, which has the same reader as the
    // line above and for the same reason: the person who left a draft there is not the caller, and
    // by the time they come back the only account of it is this file. Written only where a write was
    // attempted (a move typed nothing) and only where the stash ran at all - a blocked session's
    // composer is behind its dialog, so nothing was touched and there is nothing to explain.
    if touchedComposer {
        appendSessionInputDraftLines(pid: pid, draft: draft, now: now, to: log)
    }
    // AFTER the served line, so the two read in the order they happened: what was typed, and then
    // that nobody was told about it.
    if let lostReceipt {
        appendSessionInputLine(sessionInputReceiptLostLine(pid: pid, outcome: outcome.rawValue,
                                                          epoch: request.epoch,
                                                          failure: lostReceipt, now: now),
                               to: log)
    }
    return SessionInputAction(typed: typed, repick: repick, moveTo: moveTo)
}
