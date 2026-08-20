import Foundation

// LEAVING A DYING ACCOUNT AT THE END OF A TURN, which is the moment a BUSY session has and the two
// preventive movers next door cannot reach.
//
// WHY A THIRD ONE. The idle rebalance (Rebalance.swift) waits for the full "left alone" bar: 120
// seconds of silence across the transcript, the subagents, the open tool call and the keyboard. The
// window repick (WindowRepick.swift) waits for a `/clear`. On a quiet machine the first arrives
// constantly; on a heavy day neither arrives at all, and the sessions that most need moving are
// exactly the ones that never stop working. Measured on this machine 2026-08-17: `~/.tally/
// handoff.log` holds 29 rebalances in its whole life, the most recent eleven days earlier, while
// four sessions rode the main account into the wall inside one minute and a running executor died
// with the child that was then handed off. This is the third rung of the ladder the owner asked
// for - a 15% advisory knock, this 5% floor, and the cap handoff behind both - and it is the rung
// that does not depend on a model reading a reminder.
//
// THE MOMENT IT ADDS is the boundary between two turns. That is the same trade a load balancer
// makes when it drains a connection: the request in flight is never cut, and the move happens in
// the gap after it. Nothing here interrupts anything, because everything here waits for Claude Code
// itself to say the turn is over (`SessionTurnEnd.swift`) - a fact on a public hook, not a guess
// from silence. A session with the hooks uninstalled has no such record, this never fires for it,
// and the 120s rebalance decides alone exactly as it did.
//
// WHAT IT COSTS, stated rather than hidden: a cross-account relaunch re-prefills the conversation
// on the new account, because the prompt cache does not travel. That is the same bill the cap
// handoff pays, one turn earlier, and the thing it buys is that the turn which would otherwise have
// hit the wall is served instead of refused.
//
// ONE DECISION PER BOUNDARY, which is what keeps a 2s poll affordable. A turn boundary is a
// discrete event with an instant on it, so this rules on each one at most once and remembers which
// (`TurnBoundaryState`). The exception is a gate that is about the WORLD rather than about the
// boundary - somebody typing, a plan already made for this tick, subagents still writing - where
// nothing is recorded and the next tick asks again. That is what makes "the turn ended but a
// subagent is still running, so move on a later tick" a wait rather than a refusal, which is the
// 2026-07-25 lesson (a fan-out died with the child a non-urgent relaunch replaced) restated for a
// mover that fires while work is in flight far more often than any of its neighbours.
//
// AND IT SHARES THE REBALANCE'S CLAIM rather than taking one of its own, which is the opposite of
// what the window repick chose and for the opposite reason. A `/clear` is a discrete act of the
// owner's, so a repick cannot repeat while a drought lasts and a claim would only starve every
// session that cleared second. A turn boundary arrives every few minutes on every busy session, so
// without the cross-supervisor claim the four sessions above would read one snapshot and stampede
// onto the one healthy sibling - the 02:22 storm the claim was written for, through a new door. The
// price is stated plainly: one session per account per window cycle moves this way, and the rest
// wait for their own account's next cycle or for the cap handoff. Two movers, one claim, so a
// drought can never hand out two moves for one account.

/// The audit tag a turn-boundary move is logged under, and the reason it is not `rebalance`: the
/// two are measured against each other (does moving at a turn boundary reach the sessions the idle
/// bar never does?), and a shared tag would make that question unanswerable from the log.
let turnBoundaryReason = "turn-boundary"

/// What one supervised session remembers about turn boundaries it has already ruled on.
///
/// In memory and per CHILD, like the window repick's arm and the keyboard history beside it: a
/// relaunch replaces the conversation, and a boundary recorded against the old one describes a turn
/// that ended in another process (`turnEndStillStands` refuses it anyway, on the same dimension).
struct TurnBoundaryState: Equatable {
    /// The boundary this station has already decided about, by the instant the hook stamped on it.
    /// Compared rather than counted: two boundaries are the same boundary when they carry the same
    /// instant, and `SessionTurnEnd.at` is written from the event rather than from a file's mtime,
    /// so nothing can forge a new one by touching a file.
    private(set) var decided: Date?

    /// Record that this boundary has been ruled on, whichever way it went. Called only once the
    /// answer cannot change by waiting - see the header - so a gate that is about the world leaves
    /// this alone and the next tick asks again.
    mutating func decide(_ at: Date) { decided = at }
}

/// Whether this session has a reported turn boundary that the station has not yet ruled on.
///
/// ITS OTHER READER IS THE REBALANCE, and that is the whole reason this is a function rather than a
/// line inside the station. The preventive station runs earlier in the tick than this one (it needs
/// nothing the board produces, and this needs the board's blocked reading), so the rebalance would
/// otherwise reach the shared claim first and spend this account's one move of the cycle on the
/// slower of the two movers. Standing the rebalance down for the one tick a boundary is undecided
/// restores the order the ladder is meant to have: the free window repick asks first, this asks
/// second, the rebalance last. It cannot starve the rebalance either, because a boundary this
/// station declines is recorded as decided on that same tick.
func turnBoundaryPending(_ state: TurnBoundaryState, event: SessionTurnEnd?) -> Bool {
    guard let event else { return false }
    return state.decided != event.at
}

// MARK: - The gates

/// The gates that need nothing but what the caller already holds - no snapshot, no transcript, no
/// filesystem - in the order they bite. One definition for both readers below, on the same terms as
/// `rebalanceAllowedForSession`: the station asks them to decide whether to pay for anything else,
/// and `turnBoundaryTarget` asks them again so the decision is complete on its own.
///
///  - `steering`: the fleet is not set to observe only (AutoSteering.swift).
///  - `mode`: a pinned session runs where the user said it runs, and quota reasoning never
///    overrides that - the same first gate every preventive mover holds.
///  - `blocked`: a prompt is on screen (a permission request, a plan awaiting approval, a
///    question), and a relaunch would answer it by destroying it with no trace for the person who
///    was about to decide. The same row `sessionClearMovesAccounts` holds for the same reason, and
///    the one gate here that has nothing to do with quota.
///  - `keyboardIdle`: nobody has typed in that terminal for `sessionInputKeyboardQuietSeconds`.
///  - `draftSuspected`: and nothing suggests a half-written prompt is sitting in the composer. Both
///    are needed and neither is the other: the first is about the last five seconds, the second is
///    about a burst that happened before them and was never sent (SessionInputDraft.swift). A
///    relaunch ends the composer AND the kill buffer of the child it replaces, so this mover holds
///    the same invariant the preventive station holds for its two.
///  - `carryable`: moving this session cannot lose a conversation (`carryableSession`). Asked
///    because a mover that has not thought about it is the bug itself, and because the print class
///    it excludes must never be restarted at all.
///  - `fuseAllows`: automatic moves share one budget with cap recoveries, three per ten minutes per
///    session. A session being restarted a fourth time has a problem no move cures.
func turnBoundaryAllowedForSession(steering: Bool, mode: String, blocked: Bool, keyboardIdle: Bool,
                                   draftSuspected: Bool, carryable: Bool,
                                   fuseAllows: Bool) -> Bool {
    steering && mode != "manual" && !blocked && keyboardIdle && !draftSuspected && carryable
        && fuseAllows
}

/// The account a session whose turn has just ended should move to, or nil to stay put. Pure, so the
/// whole table is assertable without a snapshot, a transcript or a claim directory.
///
/// The three facts the free gates above cannot answer, in the order this asks them:
///
///  - `agentsIdle`: this session's Claude Code reports no subagent working. A relaunch is a SIGTERM
///    and a subagent dies with the child that dispatched it, with its work gone and no error
///    anywhere (2026-07-25), so this is the gate that must never be softened. It reads the roster
///    Claude Code's own hooks publish rather than the 600s mtime heuristic beside it, because the
///    same `Stop` that reported this boundary carried the roll call it is folded from
///    (HookAgents.swift) - the roster is exact at precisely the instant this asks - and because the
///    heuristic would refuse for ten minutes after a fan-out genuinely finished, which on a heavy
///    day is most of the day.
///  - `turnEnded`: the boundary still describes this session RIGHT NOW - it names this
///    conversation, it was left by this child, and nothing has been written since
///    (`turnEndStillStands`). Every way it can be wrong is refused there rather than here.
///  - `toolCallOpen`: no tool call this conversation opened is still outstanding. Belt to the
///    braces above - an unanswered `tool_use` is an assistant event newer than the boundary, so
///    `turnEnded` has already said no - and it is asked anyway because the two read different
///    things out of the file and the cost of the second is one tail scan on a tick that is about to
///    restart the child.
///
/// Then the quota question, which is the same one every other preventive mover asks and is
/// deliberately NOT a threshold of this mover's own: the account is not comfortable (the 5% line
/// the launch pick, the cap handoff, the idle rebalance and the dry-pool alert all draw), and a
/// comfortable sibling exists, chosen by the same `capHandoffTarget`. One line across the product
/// is the point; moving earlier than that is a one-constant change and belongs to whoever owns the
/// policy, exactly as Rebalance.swift says.
///
/// `claim` is last because it is the only gate with a side effect: asked earlier it would spend
/// this account's one move of the cycle on a tick that then declines to move.
func turnBoundaryTarget(steering: Bool, mode: String, blocked: Bool, keyboardIdle: Bool,
                        draftSuspected: Bool, carryable: Bool, fuseAllows: Bool,
                        agentsIdle: Bool, turnEnded: Bool, toolCallOpen: Bool,
                        current: Snapshot.Account, candidates: [Snapshot.Account],
                        primaryModel: String?, now: Date = Date(),
                        claim: () -> Bool = { true }) -> Snapshot.Account? {
    guard turnBoundaryAllowedForSession(steering: steering, mode: mode, blocked: blocked,
                                        keyboardIdle: keyboardIdle,
                                        draftSuspected: draftSuspected, carryable: carryable,
                                        fuseAllows: fuseAllows),
          agentsIdle, turnEnded, !toolCallOpen,
          !accountIsComfortable(current, primaryModel: primaryModel, now: now),
          let target = capHandoffTarget(candidates, primaryModel: primaryModel, now: now),
          claim()
    else { return nil }
    return target
}

// MARK: - The facts this mover reads for itself

/// Whether this session's Claude Code reports no subagent working.
///
/// FAIL-CLOSED IN BOTH DIRECTIONS THAT MATTER: no roster at all (the hooks are not installed, or
/// the file cannot be read) and a roster whose count cannot be believed (`reportable` is nil below
/// `agentCensusClaudeVersion`, where edge events drift upward with nothing to correct them) both
/// answer NO. What that costs is this mover on those machines, where the rebalance still stands;
/// what it buys is that no session is ever restarted out from under a work package on the strength
/// of a count nobody vouches for.
func turnBoundaryAgentsIdle(pid: String, dir: URL = supervisorStateDir) -> Bool {
    readSessionAgents(pid: pid, dir: dir)?.reportable == 0
}

/// Whether a tool call this conversation opened is still outstanding.
///
/// Read from the transcript rather than from the tick's cached scan (`openScanCache`), and that is
/// forced rather than chosen: the cache is filled by `boundFileQuietness`, which returns `.busy`
/// before it ever scans when the file has moved inside its 30 second bar - which is every tick a
/// turn has just ended on. Reading the cache here would therefore find nothing exactly when this
/// mover asks, and a fail-closed reading of that would turn the feature off altogether.
///
/// A file that cannot be read answers YES (a call is open), the direction every other obstacle in
/// this family answers in: not moving costs a preventive move, moving on evidence we do not have
/// costs a live turn.
func turnBoundaryToolCallOpen(_ file: URL?, now: Date = Date()) -> Bool {
    guard let file, let tail = transcriptTail(of: file) else { return true }
    return openTurnHoldsSession(openedAt: openToolCall(inTail: tail)?.startedAt, now: now)
}

// MARK: - The tick's station

/// The turn-boundary mover, asked once per tick.
///
/// WHERE THE `decide` CALLS ARE IS THE DESIGN, and the rule behind them is one question: can this
/// answer change while the boundary stands?
///
///   - A plan already made, a gate about the world (pinned, blocked, typing, draft, fuse, agents
///     still writing): yes, so nothing is recorded and the next tick asks again. This is what makes
///     a session whose subagents outlive its turn move on a LATER tick rather than never.
///   - The boundary itself no longer standing, or a tool call open: no. `turnEndStillStands` is
///     false because something newer than this instant is in the transcript, and nothing takes that
///     back, so the boundary is spent. Recording it is also what stops this from reading the tail
///     of a busy conversation on every 2s poll.
///   - The quota question answering "stay": no, in the sense that matters. The account is
///     comfortable, or nothing better exists, or another supervisor holds the cycle - and a session
///     sitting still long enough for any of those to change is a session the idle rebalance owns at
///     its own 120s bar. Re-asking every two seconds until the next turn would buy nothing and cost
///     a snapshot decode per poll.
///
/// It says so on the terminal, like the window repick, and for the same reason: this is a restart
/// the person in front of it did not ask for, and an unexplained one reads as a crash. Safe to
/// print here because the message precedes a tear-down (PendingNotice.swift states that rule).
func applyTurnBoundaryMove(plan: inout RelaunchPlan?, state: inout TurnBoundaryState,
                           event: SessionTurnEnd?, steering: Bool, provider: String,
                           account: Snapshot.Account, primaryModel: String?, mode: String,
                           blocked: Bool, keyboardIdle: Bool, draftSuspected: Bool,
                           carryable: Bool, fuseAllows: Bool,
                           agentsIdle: @autoclosure () -> Bool,
                           turnEnded: @autoclosure () -> Bool,
                           toolCallOpen: @autoclosure () -> Bool,
                           quarantine: [String: (model: String?, until: Date)] = [:],
                           // `@autoclosure` for the reason `rebalanceMove` states in full: the
                           // gates above throw nearly every tick away, and a plain default argument
                           // would read and decode `~/.tally/snapshot.json` before this function
                           // was entered. The three facts above are deferred the same way, so a
                           // tick that is pinned, typed into or mid-turn reads no file at all.
                           loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                           now: Date = Date(), dir: URL = rebalanceDir) {
    guard plan == nil, let event, state.decided != event.at else { return }
    guard turnBoundaryAllowedForSession(steering: steering, mode: mode, blocked: blocked,
                                        keyboardIdle: keyboardIdle,
                                        draftSuspected: draftSuspected, carryable: carryable,
                                        fuseAllows: fuseAllows) else { return }
    // The roster first, because it is one small file against the transcript tail below it, and
    // because it is the one refusal that is expected to lift on its own: the head has finished
    // speaking and the work it dispatched has not.
    guard agentsIdle() else { return }
    guard turnEnded(), !toolCallOpen() else {
        state.decide(event.at)
        return
    }
    state.decide(event.at)
    // THE LIVE PICTURE, and the last thing this pays for. `liveMoveField` is shared with the
    // rebalance and the window repick rather than copied: the three movers differ in WHEN they fire
    // and in nothing else about which siblings exist or which windows count, and a second copy of
    // that narrowing is exactly how they would come to disagree. A snapshot too old to trust
    // answers nothing, the rule the cap handoff applies for the same reason - moving a session on
    // hours-old numbers is how it lands somewhere worse than it started. An account whose binding
    // window names no reset has no cycle to claim, and an unclaimed move is the stampede the claim
    // exists to prevent, so that stays put too.
    //
    // The three facts go in as literals because the guards above have just established them, which
    // is the one thing to keep in step if a gate ever moves: `turnBoundaryTarget` is the complete
    // table and asks all of them again, so what is written here is an answer rather than an
    // assumption only as long as it sits below those guards.
    guard let field = liveMoveField(provider: provider, account: account,
                                    primaryModel: primaryModel, quarantine: quarantine,
                                    loaded: loaded(), now: now),
          let cycle = rebalanceCycleKey(field.current, primaryModel: primaryModel, now: now),
          let moveTo = turnBoundaryTarget(
              steering: steering, mode: mode, blocked: blocked, keyboardIdle: keyboardIdle,
              draftSuspected: draftSuspected, carryable: carryable, fuseAllows: fuseAllows,
              agentsIdle: true, turnEnded: true, toolCallOpen: false,
              current: field.current, candidates: field.candidates, primaryModel: primaryModel,
              now: now, claim: { claimRebalanceCycle(account.id, cycle: cycle, dir: dir) })
    else { return }
    warn("\(account.label) nearly dry, moving to \(moveTo.label) at the end of this turn "
        + "(\(pickReason(moveTo, primaryModel: primaryModel)))")
    plan = RelaunchPlan(target: moveTo, reason: turnBoundaryReason, countsFuse: true)
}
