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

/// What this session is expected to RUN, in precedence order: the pin it carries, then the command
/// line it was launched with, then the configured default.
///
/// The pin leads, and that is new. It used to be the command line, which was true while only a
/// relaunch could change the pair - a `tally model` rewrites the argv on its way past. A native
/// `/model` adopted from the transcript changes nothing about the argv (the session is ALREADY
/// running the new model; restarting it would be a no-op), so a reader that asked the command line
/// would go on believing the session runs what it was launched with, and the degradation rescue
/// would go on "curing" the difference.
func sessionPrimaryModel(pin: SessionModelPin, launchArgs: [String], providerID: String,
                         policy: LaunchPolicy) -> String? {
    pin.model ?? launchPrimaryModel(launchArgs, providerID: providerID) ?? policy.model
}

/// Take the model the user chose with Claude Code's OWN `/model` and make it this session's pin.
/// True when it did, which is the tick's cue to say so.
///
/// WHY ADOPT RATHER THAN RESCUE. The transcript cannot tell the two apart on its own: "the serving
/// model is not the one we expect" is what a quota degradation looks like AND what a person
/// changing the model looks like. Read as a degradation, the response was to move the session to
/// another account and relaunch it from the argv - which put the old model back, so the next
/// `/model` went round again (geo session 7cfa11a4, 2026-08-06; the owner's question was "why is
/// the native one not supported"). The `/model` event is the one signal that separates them, and
/// with it the right answer is the opposite of a rescue: the user's choice IS the instruction, so
/// it joins the layer that already means "this conversation runs this", and everything downstream -
/// the follow standing down, `--auto` releasing it, the pair riding the next relaunch and the
/// self-update exec - is the machinery `tally model` already built.
///
/// AND IT DOES NOT RELAUNCH. The session is already serving the chosen model; restarting it would
/// interrupt a conversation to arrive where it already is. The argv catches up at the next relaunch
/// something else asks for, which is exactly what a pin is for.
///
/// THE OBSERVATION MUST POST-DATE THE COMMAND. `lastModel` is the model that served the last answer
/// WRITTEN DOWN, so between the `/model` and the next turn it still holds the old one: adopting
/// then would pin the model the user just moved away from. Requiring the newest main-chain event to
/// be no older than the command is what makes this wait for the first answer that can confirm it.
///
/// KNOWN LIMIT, deliberately not guessed at: choosing "default" in that picker is not something we
/// can recognise, because the line it prints in that case has never been seen here and inventing a
/// shape for it would put a guess in the one place this function exists to remove one. A session
/// pinned this way is released the way every other pin is, with `tally model auto`.
@discardableResult
func adoptNativeModelChoice(state: inout SessionModelState, follow: inout FollowState,
                            watcher: TranscriptWatcher, primaryModel: String?,
                            launchArgs: [String], now: Date = Date(),
                            log: URL = handoffLog) -> Bool {
    guard let commandAt = watcher.lastModelCommandAt,
          // ONE EVENT, ONE ADOPTION. The marker lives as long as the child, so without this the
          // condition below stays true for every later disagreement - a real quota fallback
          // included, which would then be adopted as the user's choice and the rescue would never
          // fire again. The next adoption needs a NEWER `/model`, exactly as the next request needs
          // a newer stamp.
          commandAt > (state.servedModelCommandAt ?? .distantPast),
          let observed = watcher.lastModel,
          let observedAt = watcher.lastMainChainEventAt, observedAt >= commandAt
    else { return false }
    // CONSUMED HERE, BEFORE ANYTHING IS JUDGED. "The event has been served" and "the service
    // changed something" are two questions, and the stamp belongs to the first: a `/model` that
    // re-picked what the session was already running left it unconsumed, so the next genuine quota
    // fallback on that child still satisfied "a /model happened, newer than the stamp" and was
    // adopted as the user's choice - which is the very failure the stamp was added to close,
    // reached through the one path that skipped it (review of 62335b8).
    state.servedModelCommandAt = commandAt
    // TWO AXES, JUDGED SEPARATELY. The picker can keep the model and move only the depth, and that
    // is a real thing to do: reading "the model still agrees" as "nothing happened" threw the parsed
    // effort away, so the child ran xhigh and the next relaunch put high back (caught in review of
    // c914b41). Judged, but adopted TOGETHER - one command is one choice, and it is consumed once.
    let movedModel = !modelsAgree(primaryModel, observed) && !modelsAgree(state.pin.model, observed)
    let chosenEffort = watcher.lastModelCommandEffort
    let runningEffort = state.pin.effort ?? flagValue(launchArgs, "--effort")
    let movedEffort = chosenEffort.map { $0.lowercased() != runningEffort?.lowercased() } ?? false
    guard movedModel || movedEffort else { return false }
    if movedModel { state.pin.model = observed }
    if movedEffort { state.pin.effort = chosenEffort }
    follow.adopt(model: state.pin.model ?? flagValue(launchArgs, "--model"),
                 effort: state.pin.effort ?? flagValue(launchArgs, "--effort"))
    let pinned = [state.pin.model, state.pin.effort].compactMap { $0 }.joined(separator: "/")
    // NOT `warn`, and this is the one place on the model axis where that matters. The supervisor and
    // the child share a tty, so stderr lands wherever the cursor is; every other message here
    // precedes a relaunch, which redraws the screen from nothing, and this adoption deliberately
    // performs none. Printed, it wrapped across the live TUI's input box and shoved the prompt
    // around it (owner screenshot, 2026-08-07). The status line is where a message with no
    // tear-down behind it belongs (PendingNotice.swift states the rule this broke).
    //
    // The badge is short because it shares a line with the quota meters, and it does not repeat the
    // pair: the status line renders what the session runs already. What the user cannot see anywhere
    // else is that this is a PIN rather than a degradation, and how to undo it - which is what the
    // badge names and the detail spells out.
    // Stamped with its kind so the image on the other side of a self-update can recognise it: the
    // exec keeps the pid and starts this state from nothing, so a notice raised moments earlier
    // lives only in `<pid>.notice` and the new process's first honest "nothing is pending" would
    // unlink it - the badge gone before the user ever looked (review, 2026-08-07). Same shape, same
    // reason, as the cancelled switch one axis over (`adoptCancellation`).
    state.adopted = PendingBadge("/model pinned", detail: "adopted what you chose with `/model` as "
        + "this session's pin: it runs \(pinned) until `tally model auto` releases it, and is no "
        + "longer read as a degradation", kind: modelAdoptionNoticeKind)
    // Stamped with the event that CONFIRMED the choice, never with the poll that noticed it. The
    // expiry asks whether the user has typed since; a poll timestamp is later than the prompt they
    // have already sent, so the badge outlived the turn it belonged to by one (review, 2026-08-07).
    state.adoptedAt = observedAt
    // And a durable line, because the badge is gone the moment the user types: without it the one
    // event that changes what a session runs without restarting it would leave no trace at all.
    logSessionModelAdoption(pair: pinned, sessionID: watcher.file?.deletingPathExtension()
        .lastPathComponent, now: now, log: log)
    return true
}

/// The audit line a `/model` adoption leaves in the shared handoff log (grep `model-pin=adopted`),
/// beside the relaunches and drift episodes of the same session. Pure and separate from the append
/// below so the format is testable: this is the only durable record of an event that changes what a
/// session runs and restarts nothing.
func sessionModelAdoptionLine(pair: String, sessionID: String?, now: Date) -> String {
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    return "\(ISO8601DateFormatter().string(from: now)) session=\(sid) model-pin=adopted "
        + "pair=\(pair) source=/model\n"
}

func logSessionModelAdoption(pair: String, sessionID: String?, now: Date,
                             log: URL = handoffLog) {
    appendHandoffLine(sessionModelAdoptionLine(pair: pair, sessionID: sessionID, now: now), to: log)
}

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
