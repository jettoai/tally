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
//
// AND IT SHARES THE CLAIM'S ONE EXEMPTION with it (2026-08-20): an account with no effective
// remaining left at all (`accountIsSpent`) is moved off without asking for the claim, by this
// mover on the same terms as by the idle one. Rebalance.swift carries the whole argument. Sharing
// it is not a convenience here, it is the same requirement that made the claim shared in the first
// place: two movers that disagreed about when the claim is required would let one of them hold a
// session on a spent account precisely because the other had already left one.

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
///    the one gate here that has nothing to do with quota. The caller passes
///    `SessionTick.waitingOnPerson` rather than the board's `blocked`, which also covers the soft
///    `idle_prompt` fired a minute after any turn - a turn boundary is exactly when that notice is
///    about to arrive, so the word would veto this mover as reliably as it vetoed the rebalance
///    (codex review of e52a436).
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
/// this account's one move of the cycle on a tick that then declines to move. It is not asked at
/// all once the account is spent (`accountIsSpent`), the one exemption, shared with the idle
/// rebalance and argued in full there: what justifies refusing is that the cap handoff will make
/// the move later, and an account with nothing left has no turn for a cap to land in.
func turnBoundaryTarget(steering: Bool, mode: String, blocked: Bool, keyboardIdle: Bool,
                        draftSuspected: Bool, carryable: Bool, fuseAllows: Bool,
                        agentsIdle: Bool, turnEnded: Bool, toolCallOpen: Bool,
                        current: Snapshot.Account, candidates: [Snapshot.Account],
                        primaryModel: String?, reserves: AccountReserves = .none,
                        now: Date = Date(),
                        claim: () -> Bool = { true }) -> Snapshot.Account? {
    guard turnBoundaryAllowedForSession(steering: steering, mode: mode, blocked: blocked,
                                        keyboardIdle: keyboardIdle,
                                        draftSuspected: draftSuspected, carryable: carryable,
                                        fuseAllows: fuseAllows),
          agentsIdle, turnEnded, !toolCallOpen,
          !accountIsComfortable(current, primaryModel: primaryModel, reserves: reserves, now: now),
          let target = capHandoffTarget(candidates, primaryModel: primaryModel,
                                        reserves: reserves, now: now),
          // Short-circuits, so an exempt move does not ignore the claim's answer: it never asks
          // and takes no record (`claimRebalanceCycle` says why that is the property that matters).
          accountIsSpent(current, primaryModel: primaryModel, reserves: reserves, now: now)
              || claim()
    else { return nil }
    return target
}

// MARK: - The facts this mover reads for itself

/// What this session's agent roster says about ONE turn boundary. Three answers, because the two
/// that used to be one behave in opposite ways (codex review of d21f2e0, P2).
enum TurnBoundaryAgents: Equatable {
    /// The roster describes this boundary and names nobody: the move may go ahead.
    case idle
    /// Ask again on a later tick. Either it names somebody still working - the head has finished
    /// speaking and the work it dispatched has not - or it has not caught up with this boundary
    /// yet and still may. The first of those has no deadline: a roll call is not overruled by an
    /// inference about how long a subagent has gone without writing (see `turnBoundaryAgents`).
    case retry
    /// Nothing here is ever going to answer for this boundary. The caller must SPEND the boundary
    /// rather than hold it: an undecided one stands the idle rebalance down on every tick
    /// (`turnBoundaryPending`), so holding here would take a preventive move away from exactly the
    /// machines that have no turn-boundary evidence to replace it with.
    case unavailable
}

/// How long a boundary waits for the roster of its own hook run to land before giving up on it.
///
/// The current hook publishes the roster BEFORE the boundary (HookAgents.swift), so on this build
/// the wait is never entered at all. It is here for the pair that can still be running side by
/// side: a supervisor from this build watching a session whose `tally hook-agents` is the previous
/// one, which writes the boundary first and the roster up to `agentRosterLockAttempts *
/// agentRosterLockPause` (a quarter of a second) later. Five seconds is twenty times that bound,
/// and past it the roster is not late - it is a roster whose hook run died between its two writes,
/// which no amount of waiting repairs.
let turnBoundaryRosterGrace: TimeInterval = 5

/// Whether a roster stamped at `updatedAt` describes a boundary at `boundary`.
///
/// AT THE ROSTER'S OWN RESOLUTION, which is what makes this a real test rather than a coin flip.
/// `writeSessionAgents` encodes with a plain `ISO8601DateFormatter` (whole seconds); the boundary
/// is encoded with the fractional one (`encodeFractionalInstant`, SessionTurnEnd.swift). Handed the
/// SAME instant, as one hook run now does, the two documents therefore come back as 12:00:00 and
/// 12:00:00.750, and a bare `>=` would read the roster it just wrote as too old and refuse every
/// move this feature exists to make. So the boundary is compared at the second it falls in.
///
/// THE RESIDUAL, stated at its real size rather than at a flattering one (review of e52a436, B13
/// corrected the first version of this paragraph, which understated it four-fold). On a session
/// running the PREVIOUS hook - boundary first, roster up to a quarter of a second later - a roster
/// written by any other event inside the same whole second as the turn end passes this test without
/// carrying that boundary's roll call. The trigger is not only a `SubagentStop`: a `SubagentStart`
/// or the previous `Stop` landing in that second does it too, and the blind spot is as wide as one
/// whole second rather than the "sub-second" this used to claim.
///
/// What the roll call adds over the edge events is background tasks that were never announced, so
/// what is exposed is that one class, in that one second, on an out-of-date hook. It is narrowed to
/// nearly nothing - not to nothing - once that session's Claude Code runs the current
/// `tally hook-agents`, which puts the roster on disk before the boundary: the roster lock is
/// fail-open (`withAgentRosterLock` writes anyway when it cannot take it), so two hook runs racing
/// can still publish a roster that carries no roll call and is stamped in the same second.
///
/// THE ROOT FIX AND WHY IT IS NOT TAKEN HERE: give the roster the fractional clock the boundary
/// already uses. `readSessionAgents` decodes with a plain `ISO8601DateFormatter`, which does not
/// accept fractional seconds, so a roster written that way is unreadable to every build now
/// installed - including the APP target, whose session cards would lose their agent count until it
/// was updated. That is a schema change rather than an addition, and this feature is not worth one.
func rosterCoversBoundary(updatedAt: Date, boundary: Date) -> Bool {
    updatedAt >= Date(timeIntervalSince1970: boundary.timeIntervalSince1970.rounded(.down))
}

/// What this session's Claude Code says about the work in flight at `boundary`.
///
/// `record` is this child's own roster and nothing else: `currentGenerationRoster` has already
/// dropped a roster left by a previous child, one this Claude Code cannot vouch for, and the case
/// where there is no roster at all (AgentRoster.swift states why that test is structural). All
/// three arrive here as nil and answer `unavailable`, which moves nothing.
///
/// THE THREE ANSWERS SPLIT ON ONE QUESTION: could waiting change this? That distinction is about
/// the REBALANCE rather than about this mover - a boundary held open stands it down through
/// `turnBoundaryPending`, a boundary spent releases it - so `unavailable` is reserved for the
/// readings no later tick can improve.
///
/// THE BINDING TO THE BOUNDARY IS THE POINT (codex review of d21f2e0, P1). Read without it, a
/// roster is just "the last thing the hooks said" - and the last thing they said may be the
/// PREVIOUS turn's roll call, taken before this turn dispatched anything. Trusting an empty one of
/// those is a SIGTERM into a live fan-out, which is the one thing this mover may never do.
///
/// A ROLL CALL IS NOT OVERRULED BY AN MTIME, which is the correction this carries (codex review of
/// 388fc84) and it reverses what the previous version did. That version arbitrated a roster naming
/// workers against `subagentIdleSeconds` of silence under `subagents/`, so a subagent sitting
/// inside one long tool call - an eight-minute build, a fifteen-minute package, both ordinary here
/// - was declared gone after ten minutes of writing nothing, the boundary was spent, and the next
/// tick's rebalance reached the same conclusion from the same mtime and restarted the child on top
/// of work the roster was still naming. The roster is a ROLL CALL from Claude Code itself and the
/// mtime is an INFERENCE about it; an inference may not overrule the census it is an inference
/// about. So a current-generation roster that names workers answers `retry` for as long as it says
/// so, with no clock of its own.
///
/// AND THAT UNBOUNDED WAIT COSTS NOTHING, which is what makes it safe to have no clock: the
/// rebalance the stand-down defers now reads the same roster and refuses on the same fact
/// (`rebalanceAllowedForSession`), so the ticks this holds are ticks it would have declined
/// anyway. What ends the wait is the work ending: a `SubagentStop` or the next `Stop` rewrites the
/// roster, and the tick after that moves the session. What bounds a roster inflated by a subagent
/// that crashed is the roll call every turn boundary carries.
func turnBoundaryAgents(_ record: SessionAgentsRecord?, boundary: Date,
                        now: Date = Date()) -> TurnBoundaryAgents {
    guard let record, let working = record.reportable else { return .unavailable }
    guard rosterCoversBoundary(updatedAt: record.updatedAt, boundary: boundary) else {
        return now.timeIntervalSince(boundary) <= turnBoundaryRosterGrace ? .retry : .unavailable
    }
    return working == 0 ? .idle : .retry
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
///     still writing, a roster that has not caught up): yes, so nothing is recorded and the next
///     tick asks again. This is what makes a session whose subagents outlive its turn move on a
///     LATER tick rather than never.
///   - A roster that will never answer for this boundary (none, or one this Claude Code cannot
///     vouch for): no, and the answer will not improve, so the boundary is spent. Holding it would
///     hold the idle rebalance with it.
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
/// `agents` IS HANDED BOTH THE BOUNDARY AND THIS STATION'S OWN `now`, rather than being left to
/// take a clock reading of its own. The grace and the subagent window are judged against it, and a
/// station whose gates are decided on two different instants is the thing the hook side spent this
/// same package writing down as a rule ("ONE INSTANT FOR THE WHOLE RUN", HookAgents.swift).
///
/// It says so on the terminal, like the window repick, and for the same reason: this is a restart
/// the person in front of it did not ask for, and an unexplained one reads as a crash. Safe to
/// print here because the message precedes a tear-down (PendingNotice.swift states that rule).
func applyTurnBoundaryMove(plan: inout RelaunchPlan?, state: inout TurnBoundaryState,
                           event: SessionTurnEnd?, steering: Bool, provider: String,
                           account: Snapshot.Account, primaryModel: String?, mode: String,
                           blocked: Bool, keyboardIdle: Bool, draftSuspected: Bool,
                           carryable: Bool, fuseAllows: Bool,
                           agents: (Date, Date) -> TurnBoundaryAgents,
                           turnEnded: @autoclosure () -> Bool,
                           toolCallOpen: @autoclosure () -> Bool,
                           quarantine: [String: (model: String?, until: Date)] = [:],
                           reserves: AccountReserves = .none,
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
    //
    // THE TWO WAYS OF NOT KNOWING ARE NOT ONE. `retry` leaves the boundary standing, so the next
    // tick asks again and a fan-out that ends is moved a moment later. `unavailable` spends it,
    // because on that machine no later tick will answer differently - and a boundary that is never
    // spent stands the idle rebalance down on every tick through `turnBoundaryPending`, which would
    // take the 120s preventive move away from precisely the sessions that have no turn-boundary
    // evidence to replace it with (codex review of d21f2e0, P2).
    switch agents(event.at, now) {
    case .idle: break
    case .retry: return
    case .unavailable:
        state.decide(event.at)
        return
    }
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
    // exists to prevent, so that stays put too - unless the account is SPENT, which asks for no
    // claim and therefore needs no cycle to name (the key is read inside the claim for that
    // reason).
    //
    // The three facts go in as literals because the guards above have just established them, which
    // is the one thing to keep in step if a gate ever moves: `turnBoundaryTarget` is the complete
    // table and asks all of them again, so what is written here is an answer rather than an
    // assumption only as long as it sits below those guards.
    guard let field = liveMoveField(provider: provider, account: account,
                                    primaryModel: primaryModel, quarantine: quarantine,
                                    loaded: loaded(), now: now)
    else { return }
    let cycle = rebalanceCycleKey(field.current, primaryModel: primaryModel, now: now)
    guard let moveTo = turnBoundaryTarget(
        steering: steering, mode: mode, blocked: blocked, keyboardIdle: keyboardIdle,
        draftSuspected: draftSuspected, carryable: carryable, fuseAllows: fuseAllows,
        agentsIdle: true, turnEnded: true, toolCallOpen: false,
        current: field.current, candidates: field.candidates, primaryModel: primaryModel,
        reserves: reserves, now: now,
        claim: { cycle.map { claimRebalanceCycle(account.id, cycle: $0, dir: dir) } ?? false })
    else { return }
    warn("\(account.label) nearly dry, moving to \(moveTo.label) at the end of this turn "
        + "(\(pickReason(moveTo, primaryModel: primaryModel)))")
    plan = RelaunchPlan(target: moveTo, reason: turnBoundaryReason, countsFuse: true)
}
