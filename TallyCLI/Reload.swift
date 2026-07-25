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
func reloadQuiet(transcriptQuiet: Bool, hasTranscript: Bool, childAge: TimeInterval,
                 bar: TimeInterval) -> Bool {
    transcriptQuiet && (hasTranscript || childAge >= bar)
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
func applyReloadRequest(plan: inout RelaunchPlan?, epoch: inout Int, notice: inout Int?,
                        account: Snapshot.Account, watcher: inout TranscriptWatcher,
                        childAge: TimeInterval) {
    guard let request = readReloadRequest() else { return }
    let bar = reloadIdleBar(immediate: request.immediate)
    // `watcher.file` is only meaningful after `isQuiet` has run its locate, which the left-to-right
    // && guarantees; the child's age covers the pre-transcript window.
    let quiet = plan == nil && request.epoch > epoch
        && reloadQuiet(transcriptQuiet: watcher.isQuiet(bar), hasTranscript: watcher.file != nil,
                       childAge: childAge, bar: bar)
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
        if notice != request.epoch {
            warn("reload requested - restarting when this session goes idle")
            notice = request.epoch
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
    let live = liveSupervisorCount()
    if live == 0 {
        warn("no supervised sessions are running")
    } else {
        warn("reload requested: \(live) supervised session\(live == 1 ? "" : "s") "
            + "will restart when idle")
    }
    return 0
}
