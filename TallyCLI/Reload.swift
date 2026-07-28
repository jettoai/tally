import Darwin
import Foundation

// `tally reload` - restart every supervised session so it comes back on edited configuration
// (Claude Code hooks, SessionStart, CLAUDE.md, skills), without visiting each terminal.
//
// Only the CHILD needs restarting: the supervisor itself reads none of that, and the conversation
// survives because the relaunch goes through the same resume path a cap handoff uses. The request
// is one file (~/.tally/reload) rather than a signal, so it needs no process list and no
// permissions: each supervisor reads it on its 2s poll tick and acts when the stamp is newer than
// the one it captured at startup. A session launched AFTER the request already runs the new
// configuration, and its captured stamp makes it ignore that request for good.
//
// The request file itself and the live-supervisor count live in ReloadRequest.swift: the app's
// Settings row performs the same action, and both targets compile that one implementation.

/// The short quiet bar `--now` asks for: the same 5s "no turn is streaming" proxy the urgent
/// recoveries use. Enough not to cut a response mid-stream, but it can land while the user is
/// typing the next prompt.
let reloadNowIdleSeconds: TimeInterval = 5

/// The quiet bar a request asks for: the follow adoption's 120s "this session has been left alone"
/// bar by default, the 5s streaming check with `--now`.
func reloadIdleBar(immediate: Bool) -> TimeInterval {
    immediate ? reloadNowIdleSeconds : followIdleSeconds
}

/// Whether the session is still enough for a request to take it. `isQuiet` answers TRUE when no
/// transcript has been located yet, which on its own would hand a request every session that has not
/// written a turn: a terminal opened moments ago, with the first prompt half typed into it, and the
/// bar the caller asked for never applied. Until a transcript exists the only evidence of "left
/// alone" is how long the child has been up, so the same bar is held against that instead.
///
/// `keyboardQuiet` is the same bar asked of the terminal rather than the file (KeyboardIdle.swift):
/// a prompt being typed writes nothing anywhere until it is submitted, so the transcript alone
/// calls a user mid-sentence idle and the relaunch takes the half-typed text. It defaults to TRUE,
/// which is both what a machine with no terminal reports and exactly the rule that stood before it
/// existed, so every caller that has no keyboard to consult keeps its old behaviour untouched.
func reloadQuiet(transcriptQuiet: Bool, hasTranscript: Bool, childAge: TimeInterval,
                 bar: TimeInterval, keyboardQuiet: Bool = true) -> Bool {
    transcriptQuiet && keyboardQuiet && (hasTranscript || childAge >= bar)
}

// MARK: - Saying that a queued request is still queued

/// How long a queued request waits before it says so a second time.
///
/// The first note ("restarting when this session goes idle") is printed the tick a request is held
/// back, and for a session genuinely in use that is the whole story a minute later. A wait that
/// outlives five minutes is a different thing: either the session really has been busy that long,
/// or a gate is stuck open-ended, which is what the keyboard gate did on a chattering terminal for
/// as long as such sessions ran (KeyboardIdle.swift). One line, once, so the answer to "did my
/// reload get lost" is on screen rather than in a debugging session.
let reloadStillWaitingAfter: TimeInterval = 300

/// What has already been said about a queued request. Per request: a newer stamp starts it over,
/// so a second `tally reload` gets its own first note and its own five minute line.
struct ReloadWait: Equatable {
    /// The stamp the notes below were printed for, nil before anything was queued.
    var epoch: Int?
    var since: Date?
    var reminded = false
}

/// What a queued request should print this tick, and the bookkeeping that keeps it to once each.
enum ReloadWaitNote: Equatable {
    case silent
    /// This request is being held back: said the first tick it happens.
    case queued
    /// The wait has crossed `reloadStillWaitingAfter`: said once, never repeated.
    case stillWaiting
}

func reloadWaitNote(state: inout ReloadWait, epoch: Int, now: Date = Date()) -> ReloadWaitNote {
    guard state.epoch == epoch else {
        state = ReloadWait(epoch: epoch, since: now)
        return .queued
    }
    guard !state.reminded, let since = state.since,
          now.timeIntervalSince(since) >= reloadStillWaitingAfter else { return .silent }
    state.reminded = true
    return .stillWaiting
}

/// Which gate is holding the request, named for the person reading the note. Takes the components
/// `reloadQuiet` was just given rather than recomputing any of them, and reports them in that same
/// order, so the name is the gate that actually decided.
///
/// The transcript arm is one Bool covering a live turn, an unanswered tool call, and a subagent
/// still writing (TranscriptWatcher.isQuiet), so it names all of what it might be rather than
/// picking one.
func reloadWaitReason(transcriptQuiet: Bool, keyboardQuiet: Bool, hasTranscript: Bool,
                      childAge: TimeInterval, bar: TimeInterval) -> String {
    if !transcriptQuiet { return "session or a subagent still writing" }
    if !keyboardQuiet { return "keyboard active" }
    if !hasTranscript, childAge < bar { return "no transcript yet" }
    // Unreachable from the caller, and deliberately not a crash. It is only asked on the `.queued`
    // branch, which means `reloadQuiet` said no, which means one of the three arms above is the one
    // that said it: the branches are that expression negated, term for term. This is what to print
    // if a fourth term is ever added to the gate and not to this list.
    return "session in use"
}

// MARK: - Supervisor-side decision

/// What one poll tick does about the reload request it just read.
enum ReloadDecision: Equatable {
    case none        // no request, or this supervisor already served this one
    case fold        // a relaunch is planned anyway: adopt the stamp and add nothing
    case relaunch    // restart the child now
    case queued      // requested, but the session is in use: wait for it to go idle
}

/// Pure decision so the bookkeeping is testable without a child: a request fires exactly once (it
/// must be strictly newer than the stamp this supervisor captured, and the caller records it when
/// the plan is made), an older or equal stamp is ignored, and a session mid-turn queues the request
/// instead of losing it.
///
/// ORDER IS PART OF THE CONTRACT: `relaunchPlanned` is answered BEFORE `isQuiet`, so a tick that is
/// already relaunching folds the request in (and the caller consumes the stamp) no matter how busy
/// the session is. Reversing that would return `.queued` for a mid-turn tick that is restarting the
/// child anyway, leaving the stamp unconsumed and buying a second restart minutes later.
func reloadDecision(captured: Int, requested: Int?, relaunchPlanned: Bool,
                    isQuiet: Bool) -> ReloadDecision {
    guard let requested, requested > captured else { return .none }
    if relaunchPlanned { return .fold }
    return isQuiet ? .relaunch : .queued
}

/// One poll tick's reload handling, applied to the supervisor's state: read the pending request and
/// either plan the relaunch, fold into a relaunch the tick already planned, or say once that the
/// request is waiting for this session to go idle.
///
/// The user edited hooks / skills / instructions and wants every supervised session to come back on
/// them. Restarting the CHILD is enough (the supervisor reads none of that), so this is a plain
/// same-account relaunch through the usual resume path: same conversation, no model or effort
/// change, and no fuse (a deliberate request, not a recovery). It waits on the same idle bar a
/// follow adoption uses, so a running turn is never interrupted. The supervisor calls it LAST on
/// purpose: any relaunch already planned this tick restarts the child anyway, so the request rides
/// along instead of queueing a second one.
/// `keyboardIdle` is the keyboard half of the bar, injected rather than read here: the supervisor
/// holds a `KeyboardActivity` fed on every tick (a burst is only visible across readings), and a
/// closure keeps this testable without manufacturing atimes on a real terminal.
func applyReloadRequest(plan: inout RelaunchPlan?, epoch: inout Int, notice: inout ReloadWait,
                        account: Snapshot.Account, watcher: inout TranscriptWatcher,
                        childAge: TimeInterval, keyboardIdle: (TimeInterval) -> Bool,
                        request requested: ReloadRequest? = readReloadRequest(),
                        now: Date = Date()) {
    guard let request = requested else { return }
    let bar = reloadIdleBar(immediate: request.immediate)
    // Held apart rather than folded into one expression so the note below can name the gate that
    // actually decided, without asking any of them a second time. Only read when a request could
    // act on them: `isQuiet` locates and tails the transcript, which is not free per tick.
    let pending = plan == nil && request.epoch > epoch
    // `watcher.file` is only meaningful after `isQuiet` has run its locate, hence the order here;
    // the child's age covers the pre-transcript window.
    let transcriptQuiet = pending && watcher.isQuiet(bar)
    let hasTranscript = watcher.file != nil
    let keyboardQuiet = pending && keyboardIdle(bar)
    let quiet = pending && reloadQuiet(transcriptQuiet: transcriptQuiet,
                                       hasTranscript: hasTranscript,
                                       childAge: childAge, bar: bar, keyboardQuiet: keyboardQuiet)
    switch reloadDecision(captured: epoch, requested: request.epoch,
                          relaunchPlanned: plan != nil, isQuiet: quiet) {
    case .none:
        break
    case .fold:
        epoch = request.epoch
    case .relaunch:
        warn("reload requested → restarting this session")
        plan = RelaunchPlan(target: account, reason: "reload", countsFuse: false)
        epoch = request.epoch
    case .queued:
        switch reloadWaitNote(state: &notice, epoch: request.epoch, now: now) {
        case .silent:
            break
        case .queued:
            warn("reload requested - restarting when this session goes idle")
        case .stillWaiting:
            let reason = reloadWaitReason(transcriptQuiet: transcriptQuiet,
                                          keyboardQuiet: keyboardQuiet,
                                          hasTranscript: hasTranscript, childAge: childAge, bar: bar)
            warn("reload still waiting after 5m (\(reason))")
        }
    }
}

// MARK: - CLI entry

/// `tally reload [--now]`: stamp the request and report how many sessions will act on it. Touches
/// no session directly (the supervisors do the work), so it returns at once and exits 0 even with
/// nothing running - an editor hook must not fail because no session is open. Unconfirmed on
/// purpose: typing the command IS the intent, where a button click is not (the app asks first).
func runReload(args: [String]) -> Int32 {
    var immediate = false
    for arg in args {
        guard arg == "--now" else {
            warn("unknown argument \(arg) - usage: tally reload [--now]")
            return 2
        }
        immediate = true
    }
    do {
        try writeReloadRequest(immediate: immediate)
    } catch {
        warn("cannot write \(reloadFile.path): \(error.localizedDescription)")
        return 1
    }
    switch currentReloadReadiness() {
    case .ready(let live):
        warn("reload requested: \(live) supervised session\(live == 1 ? "" : "s") "
            + "will restart when idle")
    case .nothingRunning:
        warn("no supervised sessions are running")
    case .legacyOnly(let count):
        // Sessions are running, they just cannot hear the request: say so rather than report the
        // literally-true zero, which reads as "nothing is running" to the person watching five.
        warn(reloadLegacyNotice(count))
    }
    return 0
}
