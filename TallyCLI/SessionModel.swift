import Foundation

// `tally model <model> [effort]` - run THIS conversation on that pair, and keep running it there.
//
// The third scope on the model axis, and the one that was missing. A `--model` typed at launch is
// decided once and can only be changed by ending the conversation; the fleet default in Settings is
// followed by every session at once; a project profile belongs to the repository. None of them can
// say "this conversation, from here on" - which is the thing a person actually wants halfway through
// a session that has turned out to need more (or less) than they started it with.
//
// It is the account axis's `tally switch` with the axis swapped, deliberately and almost line for
// line: a request file addressed to one supervisor (ModelRequest.swift), a decision on the poll tick
// against the same quiet gate, a pin held for the life of the session, `--auto` to release, and the
// state carried across the self-update exec (ResuperviseContract.swift). Where the two differ is
// stated at the difference.
//
// WHY IT CANNOT BE `/model`. Claude Code's own command changes the model of the running child, and
// the supervisor relaunches that child from ITS OWN argv - a cap handoff, a reload, an idle
// rebalance, a self-update. Every one of those puts the argv's `--model` back, so a `/model` choice
// silently expires at the next restart the session was going to have anyway. Anything that means to
// outlive a relaunch has to be written where the relaunch reads.

/// One poll tick's handling of a `tally model` request. Deliberate, so no fuse - the user asked for
/// this restart, exactly as they do for a `tally switch`.
///
/// Placed between the manual moves and the cap handoff: it yields to a `tally switch` typed in the
/// same window (an account instruction is about WHERE, this is about WHAT, and where wins the
/// tick), and it outranks every automatic reason to relaunch, which is what the priority order this
/// sits in already means.
///
/// `accountPinned` is whether something has already decided which account this session runs on - a
/// `tally switch` pin, a project pin, the app's pin. `follow` comes in `inout` because a pin has to
/// re-point the launch-default baseline as it lands; the reasoning for that is at `sessionModelPair`
/// below. `request`, `snapshot` and `now` are injected so the whole decision is reachable in a test
/// without a home directory, a snapshot or a child, the shape `applyFollowAdoption` already uses.
func applySessionModel(plan: inout TickPlan, state: inout SessionModelState,
                       record: inout PendingModelConsumption?, follow: inout FollowState,
                       policy: LaunchPolicy, account: Snapshot.Account, providerID: String,
                       launchArgs: [String], accountPinned: Bool,
                       quarantine: [String: (model: String?, until: Date)],
                       watcher: inout TranscriptWatcher, childAge: TimeInterval,
                       keyboardIdle: (TimeInterval) -> Bool,
                       dir: URL = modelRequestDir,
                       request: ModelRequest?,
                       snapshot loadSnapshotting: () -> (Snapshot?, String?) = loadSnapshot) {
    // No request, or one this supervisor has already served. Answered before anything else costs a
    // snapshot read or a transcript tail, the same reason `applySwitchRequest` answers it twice.
    guard let request, request.epoch > state.servedEpoch else { return }
    let pair = sessionModelPair(request, policy: policy, launchArgs: launchArgs)

    /// Everything a served request owes whether or not it relaunches: the pin, the consumed stamp,
    /// and the follow baseline. The baseline is the half that is easy to miss - see below.
    func serve(consumingNow: Bool) {
        follow.adopt(model: pair.model, effort: pair.effort)
        state.waiting = nil
        let consumption = PendingModelConsumption(epoch: request.epoch, pin: request.pin, dir: dir)
        if consumingNow { consumption.commit(&state) } else { record = consumption }
    }

    // The args already carry the pair this asks for: `tally model opus` in a session already running
    // opus, or an `--auto` releasing back to a default the session never left. There is nothing to
    // interrupt, so this does not wait for a quiet moment either - the same settlement
    // `tally switch --auto` makes when it moves nothing.
    if followAlreadySatisfied(desiredModel: pair.model, desiredEffort: pair.effort,
                              launchArgs: launchArgs) {
        serve(consumingNow: true)
        return
    }
    // FOLD, NEVER REBUILD. A `tally switch` typed in the same window has already decided this
    // tick's account (SessionDirectives.swift runs it first), and building a plan of our own around
    // an account of our own choosing would throw that decision away while the execution point went
    // on committing the switch's pin: the child comes up on one account with the state recording
    // another, and that phantom pin then blocks every later automatic move.
    //
    // The two axes COMPOSE - "run this conversation over there" and "run it on opus" are both
    // honoured by one restart - and folding is what makes them compose. The type is what enforces
    // it (`TickPlan`, SupervisorRuntime.swift): this station cannot replace a plan it did not make.
    //
    // AHEAD OF THE QUIET GATE, deliberately: the relaunch is happening either way, so there is no
    // idle moment left to wait for and waiting would only mean the pair missed the restart it could
    // have ridden. `applyFollowAdoption` folds on the same terms, for the same reason.
    guard !plan.isPlanned else {
        plan.foldAxes(model: pair.model, effort: pair.effort, clearsAxes: request.isRelease)
        warn(sessionModelNotice(pair, movingTo: nil, released: request.isRelease))
        serve(consumingNow: false)
        return
    }
    guard reloadQuiet(transcriptQuiet: watcher.isQuiet(manualMoveIdleSeconds),
                      hasTranscript: watcher.file != nil, childAge: childAge,
                      bar: manualMoveIdleSeconds,
                      keyboardQuiet: keyboardIdle(manualMoveIdleSeconds)) else {
        // The only wait there is, and it is at most the rest of the turn that asked. Held as a badge
        // rather than said on the terminal, because the child is drawing this very turn there
        // (PendingNotice.swift: only a message that precedes a tear-down may use it).
        state.waiting = PendingBadge(
            sessionModelWaitingBadge,
            detail: "`tally model` asked for \(sessionModelDescription(pair)); it takes effect "
                + "when this turn ends")
        return
    }
    let (snapshot, problem) = loadSnapshotting()
    let (target, dryPool) = sessionModelTarget(
        accountPinned: accountPinned, incumbent: account, providerID: providerID,
        model: pair.model, snapshot: snapshot, problem: problem,
        excluding: quarantinedAccounts(forPrimary: pair.model, sessionLocal: quarantine))
    if dryPool {
        // DELIBERATELY THE OPPOSITE OF THE FOLLOW ADOPTION'S DEAD END, which holds the change and
        // waits for an account to free up (FollowAdoption.swift). That is right there: a follow is
        // the FLEET default having changed, and stalling one session over it costs nothing anybody
        // asked for. This is a person typing an instruction about their own conversation, and
        // holding it looks exactly like the command having done nothing - so it happens, on the
        // account the session is already on, and the reason it may be slow is said out loud.
        let named = pair.model ?? "that model"
        warn("no \(providerID) account has quota to spare for \(named) right now - running it on "
            + "\(target.label) anyway, as you asked")
    } else {
        warn(sessionModelNotice(pair, movingTo: target.id == account.id ? nil : target.label,
                                released: request.isRelease))
    }
    plan.propose(RelaunchPlan(target: target, reason: "model", countsFuse: false,
                              model: pair.model, effort: pair.effort,
                              // A release back to a default that names nothing has to TAKE the
                              // pinned flags off the command line, which "nil means leave it alone"
                              // cannot say.
                              clearsAxes: request.isRelease,
                              // The follow adoption runs after this and would otherwise fold the
                              // FLEET's pair onto this plan, overwriting the pair the user just
                              // chose. The pin that stands this session's follow down is not
                              // recorded until the execution point (a stand-down must leave the
                              // request pending), so within this tick the flag is what protects it.
                              followFolded: true))
    serve(consumingNow: false)
}

/// What the supervisor publishes about this session's axes: what the user PINNED, what the command
/// line ASKS FOR, and what has actually been SEEN serving it.
///
/// THREE READINGS, NOT ONE, because they answer three different questions and come apart in normal
/// use. The pin is empty for most sessions. The command line is what was asked for - the launcher's
/// injection, a flag the user typed, a quota fallback's rewrite - and it is an INTENT: it does not
/// move when a safeguard falls the session back, when the server degrades the model mid-turn, or
/// when the user types Claude Code's own `/model`, all of which change what answers the next turn
/// while every argv word stays put. `observed` is the only one of the three that is a measurement.
///
/// Two rounds of this feature got it wrong in the same direction and it is worth naming the shape:
/// first the layers were reported as though they were the session (fixed in f17fb2c), then the argv
/// was (this). Both times the value at hand was easier to reach than the value being asked about.
func publishedSessionAxes(pin: SessionModelPin, launchArgs: [String],
                          observed: String?) -> SessionAxes {
    SessionAxes(pinnedModel: pin.model, pinnedEffort: pin.effort, observedModel: observed,
                runningModel: flagValue(launchArgs, "--model"),
                runningEffort: flagValue(launchArgs, "--effort"))
}

/// What the user is told on the terminal when the change lands: the pair, the account it lands on
/// when that is somewhere new, and the way back out. One function because the change lands by two
/// routes - folded onto a relaunch someone else planned, or on one of its own - and the difference
/// between those is not something the person reading the line has any use for.
func sessionModelNotice(_ pair: SessionModelPin, movingTo label: String?,
                        released: Bool) -> String {
    "this session runs \(sessionModelDescription(pair)) from here on"
        + (label.map { ", on \($0)" } ?? "")
        + (released ? " (following the project profile and the fleet default again)"
           : "; `tally model --auto` to follow the default again")
}

/// The status-line badge a queued model change leaves. A constant because the wording is asserted in
/// a test and read by a person on the same line, and a copy of it drifting in one of the two would
/// assert nothing.
let sessionModelWaitingBadge = "model: waiting for turn end"

/// The pair as a person reads it. `default` for an axis nobody names, the word the follow adoption
/// already uses for the same absence.
func sessionModelDescription(_ pair: SessionModelPin) -> String {
    "\(pair.model ?? "default")/\(pair.effort ?? "default")"
}

/// What the session will RUN once this request is served: the pair the relaunch carries, the pair
/// the follow baseline records, and the pair the already-satisfied test compares against - one
/// answer, because they are one question.
///
/// BOTH AXES ARE ALWAYS NAMED, and that is the non-obvious part. `tally model opus` deliberately
/// leaves the effort alone, so the temptation is to plan a relaunch that names only the model. It
/// would not work: `planLaunchArgs` REMOVES both `--model` and `--effort` before injecting what the
/// plan carries (SupervisorRuntime.swift), so a plan naming one axis strips the other. The effort
/// the session is already running is therefore read off its command line and named again. Which
/// axis the user actually PINNED is a different question, recorded separately (`ModelRequest.pin`),
/// and that is what `--auto` and the three-layer reading are answered from.
///
/// THE BASELINE IS THE HALF THAT IS EASY TO MISS. `applyFollowAdoption` does nothing at all while
/// the desired pair equals `followedModel`/`followedEffort`, so a pin that did not re-point those
/// would leave the follow believing this session still runs the fleet default - and the first
/// Settings change after that would adopt "no change" and stand the baseline back up under a pinned
/// session. Re-pointing here makes the pin the thing follow compares against, and the release
/// re-points it to the policy pair it is going back to.
func sessionModelPair(_ request: ModelRequest, policy: LaunchPolicy,
                      launchArgs: [String]) -> SessionModelPin {
    // A release goes to whatever the layers below now say, both axes together: the point of `auto`
    // is to stop having an opinion, not to keep half of one. An axis no layer names comes back nil,
    // and `clearsAxes` is what turns that into "take the flag off" rather than "leave it alone".
    guard !request.isRelease else {
        return SessionModelPin(model: policy.model, effort: policy.effort)
    }
    return SessionModelPin(model: request.model,
                           effort: request.effort ?? flagValue(launchArgs, "--effort"))
}

/// Which account this session runs the new model on, and whether nothing can serve it.
///
/// Pure, so the three rules are testable without a fleet on disk. They are, in order:
///
///   - An account chosen BY HAND stays chosen. A `tally switch` pin, a project pin or the app's pin
///     all reach here as `accountPinned`, and all outrank this: that instruction says WHERE the
///     session runs and this one says WHAT it runs there, so they compose rather than compete.
///   - Otherwise the account is re-picked FOR THE NEW MODEL, through the same incumbent-seeded pick
///     the follow adoption uses. Changing the model changes which accounts can serve it - a drained
///     flagship window rules an account out for fable and not for opus - so a model change that kept
///     the account would be half a decision.
///   - Numbers too old to trust move nobody, the rule the cap handoff and the idle rebalance also
///     follow. Staying is not refusing: the model change still happens, on this account.
func sessionModelTarget(accountPinned: Bool, incumbent: Snapshot.Account, providerID: String,
                        model: String?, snapshot: Snapshot?, problem: String?,
                        excluding: Set<String>) -> (target: Snapshot.Account, dryPool: Bool) {
    guard !accountPinned else { return (incumbent, false) }
    guard problem == nil, let snapshot else { return (incumbent, false) }
    guard let repick = incumbentSeededBest(providerID: providerID, in: snapshot,
                                           incumbentID: incumbent.id, primaryModel: model,
                                           excluding: excluding) else {
        return (incumbent, true)
    }
    return (repick, false)
}
