import Foundation

// LEAVING A DYING ACCOUNT AT THE MOMENT A WINDOW CLOSES, and the two preventive movers this file
// runs in the order they must be asked.
//
// WHY A SECOND PREVENTIVE MOVER AT ALL. The idle rebalance next door (Rebalance.swift) is the
// standing offer: a session on a nearly dry account moves to a healthy sibling at an idle moment of
// its own choosing. Its gate is the full "left alone" bar, 120 seconds of silence across the
// transcript, the subagents, the open tool call and the keyboard, plus one move per account per
// window cycle across supervisors. On a machine running one or two sessions that bar arrives
// constantly. On a heavy day it never does: measured on this machine 2026-08-17, `~/.tally/handoff
// .log` holds 29 rebalances in its whole life and the most recent is 2026-08-06, eleven days of
// nothing, while four sessions rode the main account into the wall inside one minute (16:33) and a
// running executor died with the child that was handed off. Placement, in other words, happens at
// launch and then never again for exactly the sessions that need it most.
//
// THE MOMENT THIS ADDS. A conversation that has just been cleared is empty. There is no turn to
// interrupt, no context to reload, and no work to lose, so the restart that the rebalance has to
// justify against a 120 second bar costs nothing at all here. That is the same argument the reload
// ride already makes from the other side (Reload.swift: "a restart that is happening anyway also
// carries a session off an account that is nearly dry"), one step further: this restart is not
// happening anyway, it is simply free. A `/clear` is also the natural boundary of the owner's own
// working rhythm - it is what closes a context window and opens the next one - so re-asking "where
// should this session run" there is re-asking it once per unit of work rather than once per launch.
//
// THE EVIDENCE THAT THE WINDOW REALLY CLOSED, which is the whole of the risk. A `/clear` typed by
// `tally session send` can fail to clear anything: the line is typed into a terminal, and a session
// sitting on a prompt takes it as the answer to that prompt instead. Relaunching then would restart
// a live conversation for no reason. So nothing is planned on the strength of having TYPED the
// line. What arms this is the typing; what fires it is Claude Code itself reporting that it is in a
// DIFFERENT conversation (TranscriptIdentity.swift): the status line hands its own `session_id`
// back on every render, "within a render of a `/clear`", and the supervisor adopts it at the top of
// every tick. A line that was eaten by a prompt moves nothing, so the id does not change, so this
// never fires. That channel is a fact rather than a guess, which is the property the fork join-key
// family cost four incidents to buy, and it is deliberately the ONLY one consulted here: the fork
// scan's own answer for a cleared session is `unresolved` (a transcript with no turn in it cannot
// be told from a sibling tab, TranscriptFork.swift), and admitting a guess beside a fact would put
// back exactly what the fact channel removed.
//
// THE EVIDENCE THAT THE WINDOW IS STILL OPEN, which is the other half of the same risk and was
// missing at first (codex review of 01799d5). Landing is a one-off event and the gates after it are
// not: a tick that lands but finds the session noisy plans nothing and leaves the arm up, so the
// window stays armed for its whole minute while the person who cleared it types their next prompt,
// runs a turn and settles down to read the answer. Five seconds of that reading satisfies the quiet
// gate, which only ever answers "has anything been written in the last five seconds", and the
// restart is taken against a conversation with a live turn in it: the exact accident this feature
// exists to avoid, self-inflicted. So the arm is dropped as soon as that window shows a turn in it
// (`noteLanded`), which is a different question from how recent the last write is, and the only one
// that separates an empty window from a used one.
//
// AND THAT ANSWER COMES OUT OF THE TRANSCRIPT ITSELF rather than out of its mtime, which is the
// same choice the landing evidence above makes. An mtime can only be compared against a baseline,
// the baseline is taken on the first tick that sees the landing, and everything written before that
// tick is therefore invisible to it - a prompt submitted in the two seconds it takes the report to
// arrive, or in any tick the station skipped, is absorbed into the baseline and the window reads as
// untouched while a turn is running in it (codex review of 4d7288a). What that turn LEFT in the file
// is there whichever tick asks. The mtime stays as a second signal for the one thing the contents
// cannot see past, a tail window filled by an enormous tool result; the two are a union, so either
// one refusing refuses.
//
// WHAT THE RELAUNCH THEN DOES is the ordinary handoff, unchanged: `performHandoff` locates the live
// file, which by then IS the cleared transcript the report named, copies it to the target account
// and resumes it there. Nothing new is plumbed, and nothing about the empty conversation makes that
// path special - a cap handoff landing on a session in the same state resumes the same file today.
//
// THE COST OF THE CHANNEL, stated rather than hidden: a machine whose Claude Code does not run
// Tally's status line has no report, so nothing here ever fires and the session stays where it is.
// That is the safe direction, it is the same direction every other obstacle in the preventive
// family answers in, and the feature it disables is a convenience.

/// How long the moment a `/clear` opens is worth waiting for, measured from the line being typed.
///
/// It has to cover the report arriving (a render, then one 2s poll) and then a quiet moment, and it
/// has to be short, because what it bounds is the risk on the other side: once somebody comes back
/// to a cleared session and starts working in it, the window is no longer free and the ordinary
/// rebalance owns the question again. A minute is many times the few seconds the report takes and
/// well inside the span in which a cleared session is still nobody's.
let windowRepickWindow: TimeInterval = 60

/// How still the session has to be before the restart is taken.
///
/// NOT the 120s "left alone" bar the rebalance holds, and the difference is the point: that bar
/// exists so a restart never cuts a turn or takes a half-written prompt with it, and the whole
/// premise here is that there is no turn - the conversation was cleared seconds ago and has nothing
/// in it. What is left to protect is a person typing their next prompt into the composer, and the
/// keyboard is the instrument that answers that directly. 5s is the bar every other gate in this
/// repo asks its smallest question at (`reloadNowIdleSeconds`, `sessionInputKeyboardQuietSeconds`).
///
/// The residual is the one `reloadNowIdleSeconds` states about itself: a prompt typed, then thought
/// about for six seconds, is a composer this can still take. Against that, the window above closes
/// after a minute, so the exposure is one minute per cleared session rather than a standing one.
///
/// That residual is the COMPOSER and nothing more. A prompt that was actually sent has written to
/// the transcript, and a window that has been written to is not this mover's any more whatever this
/// bar says (`WindowRepickState.noteLanded`).
let windowRepickQuietSeconds: TimeInterval = 5

/// The line that closes a window.
///
/// NAMED ONCE FOR THREE READERS: this file's arm, the input gate's reading of what a landing costs
/// (`sessionInputClearsContext`), and the command that queues one (`runSessionClear`). Three
/// literals is how one of them comes to mean something slightly different from the others.
let windowClearCommand = "/clear"

/// Whether a line closes a window. Exactly `/clear`, trimmed.
///
/// `/compact` deliberately does NOT count. It keeps the conversation, so the restart it would open
/// is not free: everything this feature rests on is that the session being moved is empty.
func isWindowClearCommand(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespaces) == windowClearCommand
}

/// What one supervised session remembers between the `/clear` being typed and the window it opens.
/// In memory and per CHILD, like the keyboard history and the drift monitor beside it: a relaunch
/// replaces the conversation, so anything armed against the old one is answered by the restart.
struct WindowRepickState: Equatable {
    /// The conversation the session was in when the line was typed. The move OFF it is the
    /// evidence, so this is compared rather than read: nil is a legitimate value (a session with no
    /// transcript bound yet), and any reported id differs from it.
    private(set) var leaving: String?
    /// When the line was typed, and the only field that says whether anything is armed at all.
    private(set) var typedAt: Date?
    /// The conversation the clear landed in, and what its transcript's last write was at the moment
    /// this supervisor FIRST saw it there. One value or none, because half of it says nothing:
    /// mtimes belong to the file they were read from.
    private(set) var landing: Landing?

    struct Landing: Equatable {
        let transcript: String
        let writtenAt: Date
    }

    /// Arm on the line that was actually typed into the terminal, which is what the input gate
    /// returns and nothing else: a request that waited, expired or was refused typed nothing, so
    /// there is no window to wait for.
    ///
    /// EVERY FIELD, INCLUDING THE ONE THIS ARM HAS NOT LOOKED AT YET. A second `/clear` inside one
    /// child is an ordinary thing (two windows in a working hour), and a `landing` left over from
    /// the first names a conversation this one has already left: the id comparison in `noteLanded`
    /// would then fail on the new window's very first tick and disarm it, so the second window could
    /// never take the free move. Two mutating entry points writing different halves of one state is
    /// the shape that produces that, so this writes all of it.
    mutating func arm(typed: String?, transcript: String?, now: Date = Date()) {
        guard let typed, isWindowClearCommand(typed) else { return }
        leaving = transcript
        typedAt = now
        landing = nil
    }

    /// Whether the conversation the clear landed in is still the empty one this move rests on,
    /// dropping the arm for good when it is not.
    ///
    /// WHY THE TRANSCRIPT'S CONTENTS AND NOT ITS SILENCE. The quiet gate beside this one asks
    /// whether anything has been written in the last five seconds, which is a question about the
    /// present: a window that was cleared, worked in for a turn and then left to be read answers
    /// "quiet" to it, and the restart taken there kills a live conversation. What is being asked
    /// here is whether that window HAS BEEN USED, which is a fact standing in the file itself
    /// (`clearedWindow(of:)`), so it is read from there.
    ///
    /// THE MTIME IS THE SECOND SIGNAL AND NOT THE FIRST, which is the correction this carries
    /// (codex review of 4d7288a). Baselining alone had a hole in front of it: the baseline is taken
    /// on the first tick that sees the landing, so a prompt submitted in the couple of seconds
    /// between the clear landing and that tick is absorbed INTO the baseline, and a model request
    /// that has not answered yet writes nothing else - no unmatched `tool_use` for `openToolCall` to
    /// find, nothing for the 5s bar to notice. The window then read as untouched while a turn was
    /// running in it. The contents cannot be absorbed that way: what a prompt leaves behind is
    /// there whichever tick asks, which also closes the same hole where a tick is SKIPPED (a
    /// higher-priority relaunch takes the station's early return, and the baseline is built late).
    ///
    /// The mtime is kept for the one case the contents cannot cover: a tool result larger than the
    /// tail window pushes the messages out of view (`openTurnTailBytes`, 1,567 such results on this
    /// machine), and a file that has moved since the landing says so regardless. The two are a union
    /// rather than a choice, so either one refusing is a refusal.
    ///
    /// AMBIGUITY NEVER ADVANCES ANYTHING. A window that cannot be read decides neither way: no
    /// baseline is taken, nothing is disarmed, and the tick simply does not move this session. What
    /// that costs is a free move; what it buys is that no reading this cannot make becomes a
    /// relaunch.
    ///
    /// It is a disarm rather than a wait because the premise is gone rather than postponed: a window
    /// somebody is working in is the ordinary rebalance's to move, at the full 120s "left alone" bar
    /// it holds for exactly this case.
    mutating func noteLanded(in transcript: String, window: WindowRepickWindow) -> Bool {
        switch window {
        case .used:
            disarm()
            return false
        case .unreadable:
            // Neither evidence nor its absence: the arm stands, and a later tick answers, or the
            // window runs out on its own.
            return false
        case .empty(let writtenAt):
            guard let landing else {
                landing = Landing(transcript: transcript, writtenAt: writtenAt)
                return true
            }
            // A SECOND MOVE IS NOT A QUIETER WINDOW. A conversation that has forked or cleared again
            // is not the file this baseline describes, and two files' mtimes cannot be compared at
            // all, so there is nothing here that can call that window empty.
            guard landing.transcript == transcript, writtenAt <= landing.writtenAt else {
                disarm()
                return false
            }
            return true
        }
    }

    mutating func disarm() {
        leaving = nil
        typedAt = nil
        landing = nil
    }

    /// Take what one input-station tick said about this session (`SessionInputRepick`).
    ///
    /// THE THREE ANSWERS ARE NOT TWO, and this method exists because the difference is invisible at
    /// the call site otherwise (codex review of e5bfd13). `arm` ignores a line that is not a clear
    /// and leaves everything it holds, which is right for "nothing happened here" and wrong for
    /// "this session must not be restarted": a clear typed over a suspected draft lands inside any
    /// arm an earlier clear left, and that arm is waiting for precisely the conversation change this
    /// clear is about to produce. So the cancelling answer reaches `disarm`, not a nil `arm`.
    mutating func apply(_ signal: SessionInputRepick, transcript: String?, now: Date = Date()) {
        switch signal {
        case .untouched:
            break
        case .arm(let typed):
            arm(typed: typed, transcript: transcript, now: now)
        case .cancel:
            disarm()
        }
    }
}

/// Where a session is between typing `/clear` and the window it opens. Pure, so the whole table is
/// assertable without a terminal, a transcript or a snapshot.
enum WindowRepickReadiness: Equatable {
    /// Nothing was typed, so there is nothing to wait for.
    case idle
    /// Typed, and Claude Code still reports the conversation it was in: either the clear has not
    /// been rendered yet, or the line went somewhere that was not the composer. Both look the same
    /// from here, and the window below is what tells them apart in the end.
    case waiting
    /// The wait ran out. Nothing was reported, so nothing is assumed.
    case expired
    /// Claude Code reports a different conversation: the clear happened, and the session it is in
    /// now is empty.
    case landed
}

/// Which of those this tick is in. `transcript` is the conversation the watcher is bound to AFTER
/// the tick's own adoption has run (`adoptReportedTranscript`, Supervisor.swift), which is what
/// makes this a report rather than a guess.
///
/// A session that is bound to NOTHING is `waiting`, never `landed`: an id that vanished says the
/// watcher lost its file, and "different from what it was" is not the same claim as "here is where
/// the conversation is now".
func windowRepickReadiness(_ state: WindowRepickState, transcript: String?,
                           now: Date = Date()) -> WindowRepickReadiness {
    guard let typedAt = state.typedAt else { return .idle }
    guard now.timeIntervalSince(typedAt) <= windowRepickWindow else { return .expired }
    guard let transcript, transcript != state.leaving else { return .waiting }
    return .landed
}

/// The account a session whose window has just closed should reopen on, or nil to stay put.
///
/// The gates, in the order they bite. Every one of them is the same gate the rebalance holds, for
/// the same reason, with ONE deliberate exception stated below:
///  - `steering`: the fleet is not set to observe only. A cleared window is free to move and still
///    nobody's to move when the launch policy says Tally never picks (AutoSteering.swift).
///  - `mode`: a pinned session is where the user said it runs. Quota reasoning never overrides it.
///  - `carryable`: whether moving this session can lose a conversation (`carryableSession`). A
///    cleared session is located by definition, so this is really only the `--print` refusal, and
///    it is asked anyway because a mover that has not thought about it is the bug itself.
///  - `fuseAllows`: automatic moves share one budget with cap recoveries, three per ten minutes per
///    session. A session being restarted a fourth time has a problem no move will cure.
///  - the account is not comfortable: the same 5% line the launch pick, the cap handoff, the idle
///    rebalance and the dry-pool alert all draw (`accountIsComfortable`). Deliberately not a second
///    threshold of its own, and deliberately not "move to the best account every window" - this is
///    opportunistic, so a comfortable account is left exactly where it is.
///  - a comfortable sibling exists, chosen by the same `capHandoffTarget` every other mover uses.
///
/// THE EXCEPTION IS THE CROSS-SUPERVISOR CLAIM, and leaving it out is a decision rather than an
/// omission. The rebalance takes one move per account per WINDOW CYCLE machine-wide, because every
/// session re-reads the same picture on every 2s tick and would otherwise stampede onto the one
/// healthy sibling. That reasoning does not carry: this fires on a discrete event that costs
/// somebody a whole unit of work, not on a tick, so it cannot repeat while a drought lasts. Reusing
/// the claim would actively break it - a weekly drought runs for days, so the FIRST session to
/// clear its window would take the account's one move and every session that cleared afterwards
/// would be refused for the rest of the drought, which is precisely the "eleven days of nothing"
/// this feature exists to answer. What is left is the launch pick's own residual, in the launch
/// pick's own shape: several sessions clearing inside one snapshot refresh read the same numbers
/// and choose the same sibling. That sibling is comfortable by the gate above, which is more than
/// can be said for the account they are all leaving.
func windowRepickMove(provider: String, account: Snapshot.Account, primaryModel: String?,
                      mode: String, steering: Bool, carryable: Bool, fuseAllows: Bool,
                      quarantine: [String: (model: String?, until: Date)] = [:],
                      loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                      now: Date = Date()) -> Snapshot.Account? {
    // The gates that cost nothing first, so a tick that could not move this session anyway never
    // pays for the snapshot read behind `loaded` (the reason that argument is `@autoclosure`, which
    // `rebalanceMove` states in full).
    guard steering, mode != "manual", carryable, fuseAllows,
          let field = liveMoveField(provider: provider, account: account,
                                    primaryModel: primaryModel, quarantine: quarantine,
                                    loaded: loaded(), now: now),
          !accountIsComfortable(field.current, primaryModel: primaryModel, now: now)
    else { return nil }
    return capHandoffTarget(field.candidates, primaryModel: primaryModel, now: now)
}

// MARK: - The tick's preventive station

/// The two preventive movers, asked in one place and in the order that matters.
///
/// THE ORDER IS A RULE, not a preference. The rebalance's last gate is the cross-supervisor claim,
/// and asking it is a side effect: an account gets one rebalance per window cycle, spent by
/// whichever supervisor asks first. So the FREE move is offered first. Reversed, a session whose
/// window had just closed could find its account's one claim already spent on the ordinary path,
/// and the cheapest restart in the session's life would be the one that did not happen.
///
/// AND THE SAME RULE REACHES A THIRD MOVER THAT IS NOT IN THIS FUNCTION. The turn-boundary move
/// (TurnBoundaryMove.swift) shares that one claim and runs LATER in the tick. So
/// `turnBoundaryPending` stands the rebalance down while a reported boundary has not been ruled on,
/// which puts the ladder back in its intended order - free repick, then the turn boundary, then the
/// rebalance - without moving a station the tick's other priorities are arranged around.
///
/// HOW LONG THAT STAND-DOWN LASTS, said accurately because the first version of this note said "at
/// most one poll" and that was simply untrue (codex review of d21f2e0). It lasts until the boundary
/// is RULED ON, and the station deliberately does not rule on one while a gate that is about the
/// WORLD is refusing - a pinned session, one waiting on a person, somebody typing, a suspected
/// draft, a spent fuse, a roster naming live subagents - because every one of those can lift on its
/// own and the boundary should still be usable when it does. Those states last as long as they last.
///
/// WHAT MAKES THAT HARMLESS IS THAT EVERY ONE OF THEM IS ALSO A GATE THE REBALANCE HOLDS, so the
/// tick it is stood down on is a tick it would have refused anyway:
///
///   a plan already made     both movers here are behind the same `plan == nil` guard
///   observe-only, pinned    `rebalanceAllowedForSession` refuses on `steering` and `mode`
///   blocked                 the same, on `blocked` - added 2026-08-20 for exactly this reason
///   somebody typing         the rebalance wants 120s of keyboard silence, this one wants 5s
///   suspected draft         `guard !draftSuspected` above, which covers both movers here
///   not carryable, no fuse  `rebalanceAllowedForSession` again, the same two terms
///   live subagents          a written-to `subagents/` directory makes `isQuiet` false for 600s
///
/// THE SUBAGENT ROW IS THE ONE THAT IS NOT AN EXACT MATCH, and it errs the safe way: the roster is
/// a roll call and `isQuiet` is an mtime, so an agent that hangs without writing for ten minutes is
/// live to the first and gone to the second. On those ticks the stand-down carries the stricter
/// witness's answer to the rebalance, which is a restart NOT taken out from under a work package.
///
/// THE ONE RESIDUAL, so this table is not read for more than it says: a roster that has not yet
/// caught up with its own boundary also holds the stand-down, and that state is NOT one the
/// rebalance refuses. It is bounded by `turnBoundaryRosterGrace` (five seconds), it cannot arise at
/// all on a session whose hook is the current one (HookAgents.swift publishes the roster first),
/// and past the grace the boundary is spent and the rebalance is handed straight back.
///
/// Both are gated on `plan == nil` through this one guard: everything above them in the tick is
/// repairing something, and neither of these repairs anything.
///
/// `watcher` is asked for its quiet reading BEFORE `carryable` reads `watcher.file`, as statements
/// rather than as an argument list. The supervisor used to rely on Swift evaluating arguments in
/// source order for exactly this, with a comment explaining the hazard at each call site; written
/// out here the order is the code's rather than the language's, and the hazard is gone.
///
/// `loaded` is the snapshot read, `@autoclosure` for the reason `rebalanceMove` states: nearly
/// every tick reaches this station and nearly none of them gets past the cheap gates behind it, so
/// a plain default argument would read and decode `~/.tally/snapshot.json` every two seconds per
/// session for an answer that is thrown away. It is forwarded to both movers, so the one tick where
/// the repick asks and declines pays for two reads; that tick needs an armed `/clear` to exist at
/// all, which is rarer by orders of magnitude than the read it would be saving.
func applyProactiveMoves(plan: inout RelaunchPlan?, repick: inout WindowRepickState,
                         watcher: inout TranscriptWatcher,
                         keyboardIdle: (TimeInterval) -> Bool, draftSuspected: Bool,
                         provider: String, account: Snapshot.Account, primaryModel: String?,
                         mode: String, steering: Bool, blocked: Bool, launchArgs: [String],
                         fuseAllows: Bool, turnBoundaryPending: Bool,
                         quarantine: [String: (model: String?, until: Date)] = [:],
                         loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                         now: Date = Date(), dir: URL = rebalanceDir) {
    guard plan == nil else { return }
    // The window's own gates, asked only once the clear has landed, so the ordinary tick pays for
    // none of it. `carryable` is a statement AFTER the quiet reading rather than an argument beside
    // it, because the locate this depends on happens inside `isQuiet`.
    //
    // The id and the window reading are taken as a PAIR off the file the tick adopted, before
    // `isQuiet` can relocate the watcher under them: what the reading says ("this window holds a
    // turn", "this is its mtime") is a statement about that id, and a file the id never named would
    // be judged against a baseline belonging to another. Taken as a statement rather than inside the
    // condition below so that the draft gate can stand between the two without changing either: what
    // this reading does to the arm (baseline it, drop it when the window has been used or run out)
    // is bookkeeping about a window, and a draft is no reason to stop keeping it.
    let landed = windowRepickLanded(&repick, transcript: watcher.transcriptSessionID,
                                    window: clearedWindow(of: watcher.file), now: now)
    // THE FOURTH GATE, AND IT COVERS BOTH MOVERS (2026-08-19). Everything under this line is a
    // RELAUNCH nobody asked for, and a relaunch ends the composer and the kill buffer of the child
    // it replaces - so a session that may be holding an unsent draft is not moved by either of them.
    // This is the same invariant the input station holds when a clear LANDS (`SessionInputRepick`),
    // at the other end of the same minute: without it, a draft typed in a window that was cleared
    // cleanly is killed by the arm that clear left, which is the identical defect through a
    // different door.
    //
    // A DELAY RATHER THAN A CANCELLATION, which is the whole of why it sits here and not in the
    // arm: nothing is consumed, nothing is disarmed, and this station is asked again on every tick,
    // so the move happens as soon as the draft reading clears - a new user turn, or this supervisor
    // typing (`sessionInputDraftSuspected`). No timeout of its own, deliberately: a second clock
    // over the same invariant is a second answer to "does this session hold a draft", and the
    // repick's own minute already ends an arm nobody could act on.
    guard !draftSuspected else { return }
    if landed, watcher.isQuiet(windowRepickQuietSeconds), keyboardIdle(windowRepickQuietSeconds) {
        let carried = carryableSession(launchArgs: launchArgs,
                                       sessionLocated: watcher.file != nil)
        if let moveTo = windowRepickMove(provider: provider, account: account,
                                         primaryModel: primaryModel, mode: mode,
                                         steering: steering,
                                         carryable: carried, fuseAllows: fuseAllows,
                                         quarantine: quarantine, loaded: loaded(), now: now) {
            warn("window cleared on \(account.label), nearly dry: reopening on \(moveTo.label) "
                + "(\(pickReason(moveTo, primaryModel: primaryModel)))")
            plan = RelaunchPlan(target: moveTo, reason: "window-repick", countsFuse: true)
            return
        }
    }
    // The one tick a reported turn boundary is still undecided belongs to the mover that rules on
    // it, because the two share this account's one claim per window cycle (see the note above).
    guard !turnBoundaryPending else { return }
    let quiet = watcher.isQuiet(followIdleSeconds) && keyboardIdle(followIdleSeconds)
    let carryable = carryableSession(launchArgs: launchArgs, sessionLocated: watcher.file != nil)
    guard let moveTo = rebalanceMove(provider: provider, account: account,
                                     primaryModel: primaryModel, mode: mode, steering: steering,
                                     blocked: blocked, isQuiet: quiet,
                                     carryable: carryable, fuseAllows: fuseAllows,
                                     quarantine: quarantine, loaded: loaded(), now: now,
                                     dir: dir) else { return }
    warn("\(account.label) nearly dry, moving to \(moveTo.label) before the wall "
        + "(\(pickReason(moveTo, primaryModel: primaryModel)))")
    plan = RelaunchPlan(target: moveTo, reason: "rebalance", countsFuse: true)
}

/// Whether this session's window has demonstrably closed AND is still open, dropping the arm when
/// it has instead run out or been used. The one caller wants a Bool, and the disarms are the reason
/// it is not a pure function: a `/clear` that never reached a composer must leave nothing behind
/// that could fire later off some unrelated fork, and a window somebody has started working in must
/// leave nothing behind at all.
///
/// `window` is that transcript read (`clearedWindow(of:)`), `@autoclosure` so only a tick that has
/// actually landed pays for the tail: an armed window is rare and an unarmed one is every other
/// tick, which would otherwise read a file for an answer nobody asks for.
private func windowRepickLanded(_ repick: inout WindowRepickState, transcript: String?,
                                window: @autoclosure () -> WindowRepickWindow,
                                now: Date) -> Bool {
    switch windowRepickReadiness(repick, transcript: transcript, now: now) {
    case .idle, .waiting:
        return false
    case .expired:
        repick.disarm()
        return false
    case .landed:
        // `.landed` is reached only with a bound transcript (`windowRepickReadiness` answers
        // `waiting` for a session bound to nothing), so this names the file that was read.
        guard let transcript else { return false }
        return repick.noteLanded(in: transcript, window: window())
    }
}
