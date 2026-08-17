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
let windowRepickQuietSeconds: TimeInterval = 5

/// The line that closes a window. Exactly `/clear`, trimmed.
///
/// `/compact` deliberately does NOT count. It keeps the conversation, so the restart it would open
/// is not free: everything this feature rests on is that the session being moved is empty.
func isWindowClearCommand(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespaces) == "/clear"
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

    /// Arm on the line that was actually typed into the terminal, which is what the input gate
    /// returns and nothing else: a request that waited, expired or was refused typed nothing, so
    /// there is no window to wait for.
    mutating func arm(typed: String?, transcript: String?, now: Date = Date()) {
        guard let typed, isWindowClearCommand(typed) else { return }
        leaving = transcript
        typedAt = now
    }

    mutating func disarm() {
        leaving = nil
        typedAt = nil
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
                      mode: String, carryable: Bool, fuseAllows: Bool,
                      quarantine: [String: (model: String?, until: Date)] = [:],
                      loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                      now: Date = Date()) -> Snapshot.Account? {
    // The gates that cost nothing first, so a tick that could not move this session anyway never
    // pays for the snapshot read behind `loaded` (the reason that argument is `@autoclosure`, which
    // `rebalanceMove` states in full).
    guard mode != "manual", carryable, fuseAllows,
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
                         keyboardIdle: (TimeInterval) -> Bool,
                         provider: String, account: Snapshot.Account, primaryModel: String?,
                         mode: String, launchArgs: [String], fuseAllows: Bool,
                         quarantine: [String: (model: String?, until: Date)] = [:],
                         loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                         now: Date = Date(), dir: URL = rebalanceDir) {
    guard plan == nil else { return }
    // The window's own gates, asked only once the clear has landed, so the ordinary tick pays for
    // none of it. `carryable` is a statement AFTER the quiet reading rather than an argument beside
    // it, because the locate this depends on happens inside `isQuiet`.
    if windowRepickLanded(&repick, transcript: watcher.transcriptSessionID, now: now),
       watcher.isQuiet(windowRepickQuietSeconds), keyboardIdle(windowRepickQuietSeconds) {
        let carried = carryableSession(launchArgs: launchArgs,
                                       sessionLocated: watcher.file != nil)
        if let moveTo = windowRepickMove(provider: provider, account: account,
                                         primaryModel: primaryModel, mode: mode,
                                         carryable: carried, fuseAllows: fuseAllows,
                                         quarantine: quarantine, loaded: loaded(), now: now) {
            warn("window cleared on \(account.label), nearly dry: reopening on \(moveTo.label) "
                + "(\(pickReason(moveTo, primaryModel: primaryModel)))")
            plan = RelaunchPlan(target: moveTo, reason: "window-repick", countsFuse: true)
            return
        }
    }
    let quiet = watcher.isQuiet(followIdleSeconds) && keyboardIdle(followIdleSeconds)
    let carryable = carryableSession(launchArgs: launchArgs, sessionLocated: watcher.file != nil)
    guard let moveTo = rebalanceMove(provider: provider, account: account,
                                     primaryModel: primaryModel, mode: mode, isQuiet: quiet,
                                     carryable: carryable, fuseAllows: fuseAllows,
                                     quarantine: quarantine, loaded: loaded(), now: now,
                                     dir: dir) else { return }
    warn("\(account.label) nearly dry, moving to \(moveTo.label) before the wall "
        + "(\(pickReason(moveTo, primaryModel: primaryModel)))")
    plan = RelaunchPlan(target: moveTo, reason: "rebalance", countsFuse: true)
}

/// Whether this session's window has demonstrably closed, dropping the arm when it has instead run
/// out. The one caller wants a Bool, and the disarm is the reason it is not a pure function: a
/// `/clear` that never reached a composer must leave nothing behind that could fire later off some
/// unrelated fork.
private func windowRepickLanded(_ repick: inout WindowRepickState, transcript: String?,
                                now: Date) -> Bool {
    switch windowRepickReadiness(repick, transcript: transcript, now: now) {
    case .idle, .waiting:
        return false
    case .expired:
        repick.disarm()
        return false
    case .landed:
        return true
    }
}
