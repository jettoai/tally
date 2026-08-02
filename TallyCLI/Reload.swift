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
/// The badge says "reload at idle" the moment a request is held back, and for a session genuinely
/// in use that is the whole story a minute later. A wait that outlives five minutes is a different
/// thing: either the session really has been busy that long, or a gate is stuck open-ended, which is
/// what the keyboard gate did on a chattering terminal for as long as such sessions ran
/// (KeyboardIdle.swift). So past this line the badge names what is holding it, and the answer to
/// "did my reload get lost" is on screen rather than in a debugging session.
let reloadStillWaitingAfter: TimeInterval = 300

/// What is currently being said about a queued request. Per request: a newer stamp starts it over,
/// so a second `tally reload` gets its own badge and its own five minute line.
///
/// The badge lives here rather than in the poll loop because this is the only place that knows both
/// that the request is still waiting AND which gate is holding it; the loop reads `badge` at the end
/// of the tick and ranks it against everything else pending (PendingNotice.swift). An empty state
/// (`epoch == nil`) is the whole signal for "nothing is queued", so it is reset the moment the
/// request is served, folded, or found to be stale.
struct ReloadWait: Equatable {
    /// The stamp being waited on, nil when nothing is queued.
    var epoch: Int?
    var since: Date?
    var reminded = false
    /// What the status line shows while this request waits, and the long form beside it.
    var pending: PendingBadge?
}

/// How the badge for a queued request reads, and how that changes once the wait grows long.
enum ReloadWaitNote: Equatable {
    case silent
    /// This request is being held back: raised the first tick it happens.
    case queued
    /// The wait has crossed `reloadStillWaitingAfter`: the badge upgrades once, and stays there.
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

/// Which gate is holding the request, in the two lengths its two homes need: a couple of words for
/// the status line, which shares its row with the quota meters, and the full phrase for the notice
/// file's `detail`. One function rather than two so the short and long forms cannot come to describe
/// different gates.
///
/// Takes the components `reloadQuiet` was just given rather than recomputing any of them, and tests
/// them in that same order, so the name is the gate that actually decided.
///
/// The transcript arm is one Bool covering a live turn, an unanswered tool call, and a subagent
/// still writing (TranscriptWatcher.isQuiet), so its long form names all of what it might be rather
/// than picking one.
struct ReloadWaitReason: Equatable {
    let short: String
    let full: String
}

func reloadWaitReason(transcriptQuiet: Bool, keyboardQuiet: Bool, hasTranscript: Bool,
                      childAge: TimeInterval, bar: TimeInterval) -> ReloadWaitReason {
    if !transcriptQuiet {
        return ReloadWaitReason(short: "session busy",
                                full: "session or a subagent still writing")
    }
    if !keyboardQuiet { return ReloadWaitReason(short: "keyboard", full: "keyboard active") }
    if !hasTranscript, childAge < bar {
        return ReloadWaitReason(short: "starting up", full: "no transcript yet")
    }
    // Unreachable from the caller, and deliberately not a crash. It is only asked on the `.queued`
    // branch, which means `reloadQuiet` said no, which means one of the three arms above is the one
    // that said it: the branches are that expression negated, term for term. This is what to show
    // if a fourth term is ever added to the gate and not to this list.
    return ReloadWaitReason(short: "in use", full: "session in use")
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
///
/// `repick` offers the account this session should come back on instead, or nil to keep the one it
/// is on. The supervisor wires it to the idle rebalance, so a restart that is happening anyway also
/// carries a session off an account that is nearly dry - the same move, at the one moment it is
/// free. It is a CLOSURE and not a value because asking is not free and not idempotent: it reads the
/// snapshot and, when it answers, has already taken the account's one claim for this drought. Asking
/// on a tick that then does not relaunch would spend that claim on nothing, which is why the
/// rebalance asks it last (Rebalance.swift) and why this asks it only on the branch that restarts.
func applyReloadRequest(plan: inout RelaunchPlan?, epoch: inout Int, notice: inout ReloadWait,
                        account: Snapshot.Account, watcher: inout TranscriptWatcher,
                        childAge: TimeInterval, keyboardIdle: (TimeInterval) -> Bool,
                        request requested: ReloadRequest? = readReloadRequest(),
                        repick: () -> Snapshot.Account? = { nil },
                        now: Date = Date()) {
    guard let request = requested else {
        // The request file went away (deleted by hand, or a home that got cleaned out) while one was
        // queued against it. Nothing is pending any more, and a badge saying otherwise would outlive
        // the thing it describes.
        notice = ReloadWait()
        return
    }
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
    // Served, absorbed, or nothing to do: whichever it is, nothing is queued now, so the badge goes.
    // `.relaunch` still speaks on the terminal, and only it: the child is about to be terminated, so
    // there is no TUI left for the line to land in the middle of (PendingNotice.swift).
    case .none:
        notice = ReloadWait()
    case .fold:
        notice = ReloadWait()
        epoch = request.epoch
    case .relaunch:
        notice = ReloadWait()
        epoch = request.epoch
        // Reaching here means the session is idle by the reload's own bar and the child is about
        // to be terminated regardless, which makes this the cheapest moment in a session's life
        // to also leave a dying account: the restart the idle rebalance normally has to justify
        // on its own is already paid for. That holds for `--now`'s short bar too - the 120s bar
        // the rebalance waits for exists to avoid CAUSING a restart, and there is none to cause
        // here, only one to aim.
        //
        // Branching on whether the account actually CHANGED rather than on whether `repick`
        // answered, because the reason is not just a log tag: a pending cap recovery is carried
        // across a relaunch only for "reload" (`capCarriedAcrossRelaunch`), on the grounds that a
        // reload comes back on the same account and the cap is therefore still this session's
        // problem. Tag a move as a reload and the next child inherits a cap belonging to an
        // account it is no longer on.
        if let moveTo = repick(), moveTo.id != account.id {
            warn("reload requested → restarting on \(moveTo.label), " +
                 "leaving \(account.label) before the wall")
            plan = RelaunchPlan(target: moveTo, reason: "rebalance", countsFuse: true)
        } else {
            warn("reload requested → restarting this session")
            plan = RelaunchPlan(target: account, reason: "reload", countsFuse: false)
        }
    case .queued:
        switch reloadWaitNote(state: &notice, epoch: request.epoch, now: now) {
        case .silent:
            break
        case .queued:
            notice.pending = PendingBadge("reload at idle")
        case .stillWaiting:
            let reason = reloadWaitReason(transcriptQuiet: transcriptQuiet,
                                          keyboardQuiet: keyboardQuiet,
                                          hasTranscript: hasTranscript, childAge: childAge, bar: bar)
            notice.pending = PendingBadge("reload waiting (\(reason.short))",
                                          detail: "reload still waiting after 5m (\(reason.full))")
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
