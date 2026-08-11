import Foundation

// What one poll tick DOES about a `tally model` request (SessionModel.swift): when it relaunches,
// what pair the relaunch carries, which account it lands on, and the two pieces of state a served
// request has to move that are not obviously its business - the session pin it records, and the
// launch-default baseline it re-points.
//
// The fixtures (`switchAccount`, `idleWatcher`, `midTurnWatcher`) are shared with switchchecks.swift,
// which owns the account axis.

func runModelTickChecks() {
    let onA = switchAccount("A", label: "Claude 1")
    let roomier = switchAccount("B", label: "Claude 2")
    let fleetOf = { (accounts: [Snapshot.Account]) in
        { (Snapshot(version: 2, generatedAt: Date(), accounts: accounts), String?.none) }
    }
    let tickDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-model-tick-\(UUID().uuidString)")

    /// One tick, with everything the decision reads injected. Returns what it planned, and hands
    /// back the state so a second tick can be run against it.
    func tick(_ state: inout SessionModelState, follow: inout FollowState,
              request: ModelRequest?, policy: LaunchPolicy, launchArgs: [String],
              watcher: inout TranscriptWatcher, accountPinned: Bool = false,
              fleet: [Snapshot.Account] = [], on: Snapshot.Account? = nil,
              childAge: TimeInterval = 600, keyboardIdle: Bool = true,
              planned: RelaunchPlan? = nil)
        -> (plan: RelaunchPlan?, record: PendingModelConsumption?) {
        var planning = TickPlan(planned)
        var record: PendingModelConsumption?
        applySessionModel(plan: &planning, state: &state, record: &record, follow: &follow,
                          policy: policy, account: on ?? onA, providerID: "claude",
                          launchArgs: launchArgs, accountPinned: accountPinned, quarantine: [:],
                          watcher: &watcher, childAge: childAge, keyboardIdle: { _ in keyboardIdle },
                          dir: tickDir, request: request,
                          snapshot: fleet.isEmpty ? { (nil, "no snapshot") } : fleetOf(fleet))
        return (planning.plan, record)
    }

    var fleetDefault = LaunchPolicy()
    fleetDefault.model = "fable"
    fleetDefault.effort = "high"

    // MARK: - 33a. A pin: what it plans, and what it leaves behind

    var pinState = SessionModelState(sessionKey: "5501", servedEpoch: 100, dir: tickDir)
    var pinFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    var idle = idleWatcher("model-pin")
    let pinned = tick(&pinState, follow: &pinFollow,
                      request: ModelRequest(epoch: 200, model: "opus", effort: "xhigh"),
                      policy: fleetDefault, launchArgs: ["--model", "fable", "--effort", "high"],
                      watcher: &idle, fleet: [onA])
    check("a pin plans a relaunch carrying the pair that was asked for",
          pinned.plan?.model == "opus" && pinned.plan?.effort == "xhigh")
    check("…tagged as its own reason, and never against the recovery fuse",
          pinned.plan?.reason == "model" && pinned.plan?.countsFuse == false)
    // The follow adoption runs AFTER this on the same tick and would otherwise fold the FLEET's pair
    // onto the plan, overwriting the pair the user just chose. The pin that stands follow down is
    // not recorded until the execution point, so within this tick the flag is what protects it.
    check("…and already folded, so the follow cannot overwrite it this tick",
          pinned.plan?.followFolded == true)
    check("the pin is not recorded while planning: a stood-down tick must leave the request pending",
          !pinState.isPinned && pinState.servedEpoch == 100 && pinned.record != nil)
    // THE BASELINE. `applyFollowAdoption` does nothing while the desired pair equals the baseline,
    // so a pin that did not re-point it would leave follow believing this session still runs the
    // fleet default - and the next Settings change would adopt "no change" over a pinned session.
    check("the launch-default baseline is re-pointed to the pinned pair",
          pinFollow.followedModel == "opus" && pinFollow.followedEffort == "xhigh")
    check("…and any adoption queued against the old one is dropped",
          pinFollow.pendingSince == nil && !pinFollow.queuedNotice)
    // The execution point is where it becomes true, which is what makes the whole thing survivable.
    pinned.record?.commit(&pinState)
    check("committing records the pin and the stamp",
          pinState.pin == SessionModelPin(model: "opus", effort: "xhigh")
              && pinState.servedEpoch == 200 && pinState.isPinned)

    // MARK: - 33b. Naming one axis leaves the other exactly as it was

    var oneAxis = SessionModelState(sessionKey: "5502", servedEpoch: 0, dir: tickDir)
    var oneFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "xhigh"])
    var idle2 = idleWatcher("model-oneaxis")
    let partial = tick(&oneAxis, follow: &oneFollow,
                       request: ModelRequest(epoch: 300, model: "opus", effort: nil),
                       policy: fleetDefault,
                       launchArgs: ["--model", "fable", "--effort", "xhigh"],
                       watcher: &idle2, fleet: [onA])
    // THE NON-OBVIOUS PART. "Leave the effort alone" cannot be expressed by planning no effort:
    // `planLaunchArgs` REMOVES both flags before injecting what the plan carries, so a plan naming
    // one axis strips the other. The effort the session is already running is read off its command
    // line and named again, and the property that matters is the resulting argv.
    check("a model-only pin still names the effort the session is already running",
          partial.plan?.model == "opus" && partial.plan?.effort == "xhigh")
    check("…which is what actually keeps it on the command line",
          partial.plan.map { planLaunchArgs(["--model", "fable", "--effort", "xhigh"], plan: $0) }
              == ["--model", "opus", "--effort", "xhigh"])
    // The baseline has to describe what the session will RUN, which is the pinned model beside the
    // effort it kept - not the half the request named.
    check("the baseline records the pair the session ends up on, not half of it",
          oneFollow.followedModel == "opus" && oneFollow.followedEffort == "xhigh")
    partial.record?.commit(&oneAxis)
    check("only the axis that was named is pinned",
          oneAxis.pin == SessionModelPin(model: "opus", effort: nil) && oneAxis.isPinned)

    // MARK: - 33c. The release plans its own way back

    // `applyFollowAdoption`'s first branch does nothing when the desired pair equals the baseline,
    // so a release that only cleared state would be a no-op: the session would keep running the
    // pinned pair for ever while reporting that it follows the default. The release therefore plans
    // the relaunch itself, back to the effective policy pair.
    var releaseState = SessionModelState(sessionKey: "5503", servedEpoch: 0,
                                         pin: SessionModelPin(model: "opus", effort: "xhigh"),
                                         dir: tickDir)
    var releaseFollow = FollowState(launchArgs: ["--model", "opus", "--effort", "xhigh"])
    var idle3 = idleWatcher("model-release")
    let released = tick(&releaseState, follow: &releaseFollow,
                        request: ModelRequest(epoch: 400, model: modelAutoRequest, effort: nil),
                        policy: fleetDefault, launchArgs: ["--model", "opus", "--effort", "xhigh"],
                        watcher: &idle3, fleet: [onA])
    check("a release plans a relaunch back to the policy pair",
          released.plan?.model == "fable" && released.plan?.effort == "high")
    check("…and re-points the baseline there, so the follow takes over from the right place",
          releaseFollow.followedModel == "fable" && releaseFollow.followedEffort == "high")
    released.record?.commit(&releaseState)
    check("…and the pin is gone", !releaseState.isPinned && releaseState.pin.isEmpty)

    // A policy that names NOTHING has to take the pinned flags off the command line. "nil leaves the
    // axis alone" cannot say that, which would leave the session on the pair it was just released
    // from while every surface reported it as following the default.
    var bareState = SessionModelState(sessionKey: "5504", servedEpoch: 0,
                                      pin: SessionModelPin(model: "opus"), dir: tickDir)
    var bareFollow = FollowState(launchArgs: ["--model", "opus"])
    var idle4 = idleWatcher("model-release-bare")
    let bare = tick(&bareState, follow: &bareFollow,
                    request: ModelRequest(epoch: 500, model: modelAutoRequest, effort: nil),
                    policy: LaunchPolicy(), launchArgs: ["--model", "opus"],
                    watcher: &idle4, fleet: [onA])
    check("a release to a default that names nothing still plans a relaunch",
          bare.plan != nil && bare.plan?.model == nil && bare.plan?.clearsAxes == true)
    check("…and that relaunch really removes the flag",
          bare.plan.map { planLaunchArgs(["--model", "opus", "--continue"], plan: $0) }
              == ["--continue"])

    // Releasing a session that is already running the policy pair changes nothing and relaunches
    // nothing - but it must still clear the pin, or the follow stays stood down for ever.
    var settledState = SessionModelState(sessionKey: "5505", servedEpoch: 0,
                                         pin: SessionModelPin(model: "fable", effort: "high"),
                                         dir: tickDir)
    var settledFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    var idle5 = idleWatcher("model-release-settled")
    let settled = tick(&settledState, follow: &settledFollow,
                       request: ModelRequest(epoch: 600, model: modelAutoRequest, effort: nil),
                       policy: fleetDefault, launchArgs: ["--model", "fable", "--effort", "high"],
                       watcher: &idle5, fleet: [onA])
    check("a release that changes nothing restarts nothing", settled.plan == nil)
    check("…and is consumed on the spot, pin cleared, with no execution point to wait for",
          settledState.servedEpoch == 600 && !settledState.isPinned && settled.record == nil)
    // Same rule the other way: pinning the pair the session already runs records the pin without a
    // restart. Without this, `tally model <what I am running>` would be the one way to ask for a pin
    // and not get one.
    var samePin = SessionModelState(sessionKey: "5506", servedEpoch: 0, dir: tickDir)
    var sameFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    var idle6 = idleWatcher("model-same")
    let same = tick(&samePin, follow: &sameFollow,
                    request: ModelRequest(epoch: 700, model: "fable", effort: "high"),
                    policy: fleetDefault, launchArgs: ["--model", "fable", "--effort", "high"],
                    watcher: &idle6, fleet: [onA])
    check("pinning the pair already running restarts nothing but does pin it",
          same.plan == nil && samePin.isPinned && samePin.servedEpoch == 700)

    // MARK: - 33d. The stamp, and the turn

    var servedState = SessionModelState(sessionKey: "5507", servedEpoch: 800, dir: tickDir)
    var servedFollow = FollowState(launchArgs: [])
    var idle7 = idleWatcher("model-served")
    check("a stamp this supervisor has already served is nothing at all",
          tick(&servedState, follow: &servedFollow,
               request: ModelRequest(epoch: 800, model: "opus", effort: nil), policy: fleetDefault,
               launchArgs: [], watcher: &idle7, fleet: [onA]).plan == nil)
    check("…and neither is no request", tick(&servedState, follow: &servedFollow, request: nil,
                                             policy: fleetDefault, launchArgs: [], watcher: &idle7,
                                             fleet: [onA]).plan == nil)
    // The command's main caller is the agent inside the session, running it as a tool call - so at
    // the moment the request lands the session is by definition mid-turn. It waits, and says so.
    var busyState = SessionModelState(sessionKey: "5508", servedEpoch: 0, dir: tickDir)
    var busyFollow = FollowState(launchArgs: [])
    var busy = midTurnWatcher("model-busy")
    let held = tick(&busyState, follow: &busyFollow,
                    request: ModelRequest(epoch: 900, model: "opus", effort: nil),
                    policy: fleetDefault, launchArgs: [], watcher: &busy, fleet: [onA])
    check("a session mid-turn holds the change rather than cutting the answer short",
          held.plan == nil && held.record == nil && busyState.servedEpoch == 0)
    check("…and the wait is on the status line, not on the terminal the child is drawing",
          busyState.waiting?.badge == sessionModelWaitingBadge)
    check("…naming the pair that is coming",
          busyState.waiting?.detail?.contains("opus") == true)
    // The gate is the switch's, whole: a session with no transcript yet falls back to the child-age
    // floor, so a request cannot restart a conversation that has only just started and has nothing
    // to resume.
    check("with no transcript to judge by, a young child holds the change",
          !reloadQuiet(transcriptQuiet: true, hasTranscript: false, childAge: 1,
                       bar: manualMoveIdleSeconds))
    check("…and an old enough one lets it through",
          reloadQuiet(transcriptQuiet: true, hasTranscript: false, childAge: 600,
                      bar: manualMoveIdleSeconds))

    // MARK: - 33d2. …and the badge names the wait it is actually in

    // The bar is three terms and only the first is a turn, so one "waiting for turn end" was a
    // promise the other two sources could not keep: this session is idle by the transcript, nothing
    // is streaming, and what holds the change is the person still typing (the account axis was
    // carrying the same defect, 232c42a). Asserted through a whole tick, so what is pinned is the
    // badge a supervisor would raise rather than a wording function called by hand.
    var typingState = SessionModelState(sessionKey: "5509", servedEpoch: 0, dir: tickDir)
    var typingFollow = FollowState(launchArgs: [])
    var idleTyping = idleWatcher("model-typing")
    let typed = tick(&typingState, follow: &typingFollow,
                     request: ModelRequest(epoch: 1000, model: "opus", effort: nil),
                     policy: fleetDefault, launchArgs: [], watcher: &idleTyping, fleet: [onA],
                     keyboardIdle: false)
    check("a prompt being typed holds the change, and says the keyboard is what holds it",
          typed.plan == nil && typingState.waiting?.badge == sessionModelTypingBadge)
    check("…naming no turn, because there is none running",
          typingState.waiting?.detail?.contains("a prompt is being typed") == true
              && typingState.waiting?.detail?.contains("this turn ends") == false)
    check("…and still naming the pair that is coming",
          typingState.waiting?.detail?.contains("opus") == true)

    // The third source: a child that started moments ago has written no transcript at all, so the
    // gate holds on the child's age. There is not even a conversation yet for a turn to end in.
    var startingState = SessionModelState(sessionKey: "5510", servedEpoch: 0, dir: tickDir)
    var startingFollow = FollowState(launchArgs: [])
    var starting = startupWatcher("model-startup")
    let young = tick(&startingState, follow: &startingFollow,
                     request: ModelRequest(epoch: 1100, model: "opus", effort: nil),
                     policy: fleetDefault, launchArgs: [], watcher: &starting, fleet: [onA],
                     childAge: 1)
    check("a session with no transcript yet holds the change on the child's age",
          young.plan == nil && startingState.waiting?.badge == sessionModelStartupBadge)
    check("…with the long form saying there is no turn to end",
          startingState.waiting?.detail?.contains("written no turn yet") == true
              && startingState.waiting?.detail?.contains("this turn ends") == false)
    // …and the same session a moment later is a change rather than a wait: the badge described a
    // state that ends on its own, which is what makes it honest.
    check("the same request fires once the child is old enough",
          tick(&startingState, follow: &startingFollow,
               request: ModelRequest(epoch: 1100, model: "opus", effort: nil),
               policy: fleetDefault, launchArgs: [], watcher: &starting, fleet: [onA],
               childAge: 9999).plan?.reason == "model")

    // TWO GATES SHUT AT ONCE, the same case the account axis carries: the gate reports the first
    // term that said no, so a young session being typed into reports the keyboard while the startup
    // term holds the change as well. "It takes effect once the keyboard is quiet" named a moment at
    // which nothing would happen, and the second tick here is that moment (codex review of 1f0c1a6).
    var gatedState = SessionModelState(sessionKey: "5513", servedEpoch: 0, dir: tickDir)
    var gatedFollow = FollowState(launchArgs: [])
    var gatedShut = startupWatcher("model-both-shut")
    let onBoth = ModelRequest(epoch: 1200, model: "opus", effort: nil)
    check("a young session being typed into holds the change",
          tick(&gatedState, follow: &gatedFollow, request: onBoth, policy: fleetDefault,
               launchArgs: [], watcher: &gatedShut, fleet: [onA], childAge: 1,
               keyboardIdle: false).plan == nil)
    check("…and names the keyboard, which is the term the gate reports",
          gatedState.waiting?.badge == sessionModelTypingBadge)
    check("…describing what holds it rather than promising when it lifts",
          gatedState.waiting?.detail?.contains("a prompt is being typed here") == true
              && gatedState.waiting?.detail?.contains("once the keyboard is quiet") == false)
    check("the keyboard going quiet does not release a change the other term still holds",
          tick(&gatedState, follow: &gatedFollow, request: onBoth, policy: fleetDefault,
               launchArgs: [], watcher: &gatedShut, fleet: [onA], childAge: 1,
               keyboardIdle: true).plan == nil)
    check("…and the badge has moved on to the term that is holding it now",
          gatedState.waiting?.badge == sessionModelStartupBadge)

    // THE FOUR ARE FOUR, one wording per gate rather than one gate wearing four names. Asked of the
    // whole enum rather than of the three a tick can reach: a term added to `QuietGate` and not
    // worded here would be a model change that says nothing about what it is waiting for.
    check("no two sources say the same thing",
          Set([sessionModelWaitingBadge, sessionModelTypingBadge, sessionModelStartupBadge,
               sessionModelIdleBadge]).count == 4)
    check("the gate has exactly the four terms these badges answer", QuietGate.allCases.count == 4)
    for gate in QuietGate.allCases {
        let wait = sessionModelWait(gate: gate,
                                    pair: SessionModelPin(model: "opus", effort: "xhigh"))
        check("\(gate): names the pair that is coming once it lifts",
              wait.detail?.contains("opus/xhigh") == true)
        check("\(gate): fits the row beside the quota meters", wait.badge.count <= 24)
        check("\(gate): says model, so the row says which axis is waiting",
              wait.badge.hasPrefix("model: "))
    }

    // MARK: - 33e. Which account the new model lands on

    // Changing the model changes which accounts can serve it, so an unpinned session re-picks.
    check("an unpinned session re-picks for the new model",
          sessionModelTarget(accountPinned: false, incumbent: onA, providerID: "claude",
                             model: "opus",
                             snapshot: Snapshot(version: 2, generatedAt: Date(),
                                                accounts: [onA, roomier]),
                             problem: nil, excluding: [onA.id]).target.id == roomier.id)
    // An account chosen BY HAND outranks it: that instruction says WHERE, this one says WHAT.
    check("an account pinned by hand is not re-picked",
          sessionModelTarget(accountPinned: true, incumbent: onA, providerID: "claude",
                             model: "opus",
                             snapshot: Snapshot(version: 2, generatedAt: Date(),
                                                accounts: [onA, roomier]),
                             problem: nil, excluding: [onA.id]).target.id == onA.id)
    // Numbers too old to trust move nobody, the rule every other mover here follows. Staying is not
    // refusing - the model change still happens, on this account.
    let stale = sessionModelTarget(accountPinned: false, incumbent: onA, providerID: "claude",
                                   model: "opus", snapshot: nil, problem: "snapshot is 74m old",
                                   excluding: [])
    check("a snapshot too old to trust leaves the account alone, and is not a dry pool",
          stale.target.id == onA.id && !stale.dryPool)
    // DELIBERATELY THE OPPOSITE OF THE FOLLOW ADOPTION'S DEAD END. A follow with nowhere to land
    // waits, because the FLEET default changed and stalling one session over it costs nothing
    // anybody asked for. This is a person typing an instruction about their own conversation, and
    // holding it looks exactly like the command having done nothing.
    let dry = sessionModelTarget(accountPinned: false, incumbent: onA, providerID: "claude",
                                 model: "opus",
                                 snapshot: Snapshot(version: 2, generatedAt: Date(), accounts: []),
                                 problem: nil, excluding: [])
    check("nowhere can serve it: the session stays put and the caller is told to say so",
          dry.target.id == onA.id && dry.dryPool)
    var dryState = SessionModelState(sessionKey: "5510", servedEpoch: 0, dir: tickDir)
    var dryFollow = FollowState(launchArgs: [])
    var idle9 = idleWatcher("model-dry")
    let anyway = tick(&dryState, follow: &dryFollow,
                      request: ModelRequest(epoch: 1100, model: "opus", effort: nil),
                      policy: fleetDefault, launchArgs: [], watcher: &idle9, fleet: [])
    check("…and the tick goes ahead with it rather than waiting for quota",
          anyway.plan?.model == "opus" && anyway.plan?.target.id == onA.id)

    // MARK: - 33e2. A switch and a model change in the same tick

    // THE DEFECT THIS SECTION EXISTS FOR. `applyManualMoves` runs first and may already have chosen
    // an account; this station used to REBUILD the plan around an account of its own, throwing that
    // decision away while the execution point went on committing the switch's pin - a child on one
    // account with the state recording another, and a phantom pin blocking every later automatic
    // move (caught in review of 9ea3ea9). The two instructions COMPOSE: "run this conversation over
    // there" and "run it on opus" are both honoured by one restart.
    let switched = RelaunchPlan(target: roomier, reason: "switch", countsFuse: false)
    var bothState = SessionModelState(sessionKey: "5511", servedEpoch: 0, dir: tickDir)
    var bothFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    var idle10 = idleWatcher("model-with-switch")
    let both = tick(&bothState, follow: &bothFollow,
                    request: ModelRequest(epoch: 1200, model: "opus", effort: "xhigh"),
                    policy: fleetDefault, launchArgs: ["--model", "fable", "--effort", "high"],
                    watcher: &idle10, fleet: [onA, roomier], planned: switched)
    check("the account the switch chose survives the model change",
          both.plan?.target.id == roomier.id)
    check("…and the pair the model change asked for rides that same relaunch",
          both.plan?.model == "opus" && both.plan?.effort == "xhigh")
    check("…on the switch's own audit tag, since it owns the move",
          both.plan?.reason == "switch" && both.plan?.countsFuse == false)
    check("…still guarded from the follow adoption that runs after it",
          both.plan?.followFolded == true)
    check("…and the request is served, so it is not asked for a second time",
          both.record != nil)
    // Folding rides the relaunch that is happening anyway, so it does not wait for a quiet moment
    // of its own: the SIGTERM is already coming.
    var busyBoth = SessionModelState(sessionKey: "5512", servedEpoch: 0, dir: tickDir)
    var busyBothFollow = FollowState(launchArgs: [])
    var midTurn = midTurnWatcher("model-with-switch-busy")
    check("a fold does not wait for the session to go quiet",
          tick(&busyBoth, follow: &busyBothFollow,
               request: ModelRequest(epoch: 1300, model: "opus", effort: nil),
               policy: fleetDefault, launchArgs: [], watcher: &midTurn, fleet: [onA, roomier],
               planned: switched).plan?.model == "opus")
    // The type is what enforces it: a station handed a `TickPlan` can add axes and cannot replace
    // what is in it, so the mistake cannot be made again by writing the assignment back.
    var sealed = TickPlan(switched)
    sealed.propose(RelaunchPlan(target: onA, reason: "model", countsFuse: false))
    check("a proposal made over an existing plan is ignored, not honoured",
          sealed.plan?.target.id == roomier.id && sealed.plan?.reason == "switch")
    sealed.foldAxes(model: "haiku", effort: nil, clearsAxes: false)
    check("…while folding reaches it", sealed.plan?.model == "haiku")
    var empty = TickPlan()
    empty.foldAxes(model: "haiku", effort: nil, clearsAxes: false)
    let foldedNothing = empty.plan == nil
    empty.propose(RelaunchPlan(target: onA, reason: "model", countsFuse: false))
    check("with nothing planned, folding changes nothing and proposing takes",
          foldedNothing && empty.plan?.reason == "model")

    // MARK: - 33f. What the pair means, read off a request

    // A release ignores the command line entirely: the point of `auto` is to stop having an
    // opinion, so both axes come from the layers below.
    check("a release resolves to the policy pair",
          sessionModelPair(ModelRequest(epoch: 1, model: modelAutoRequest, effort: nil),
                           policy: fleetDefault, launchArgs: ["--effort", "xhigh"])
              == SessionModelPin(model: "fable", effort: "high"))
    check("a pin naming both axes is exactly those two",
          sessionModelPair(ModelRequest(epoch: 1, model: "opus", effort: "max"),
                           policy: fleetDefault, launchArgs: [])
              == SessionModelPin(model: "opus", effort: "max"))
    // A model-only pin takes its effort from the COMMAND LINE, not from the policy: the session may
    // have been launched with a `--effort` nobody has changed since, and that is the thing being
    // left alone.
    check("a model-only pin keeps the effort the args carry",
          sessionModelPair(ModelRequest(epoch: 1, model: "opus", effort: nil),
                           policy: fleetDefault, launchArgs: ["--effort", "xhigh"]).effort
              == "xhigh")
    check("…and with none on the command line it names none, whatever the policy says",
          sessionModelPair(ModelRequest(epoch: 1, model: "opus", effort: nil),
                           policy: fleetDefault, launchArgs: []).effort == nil)
    // Which axis was PINNED is a different question from which pair will run, and it is the one
    // `auto` and the three-layer reading are answered from.
    check("the recorded pin holds only the axes the request named",
          ModelRequest(epoch: 1, model: "opus", effort: nil).pin == SessionModelPin(model: "opus")
              && ModelRequest(epoch: 1, model: modelAutoRequest, effort: nil).pin.isEmpty)

    // MARK: - 33g. A request that VANISHES takes its badge with it

    // The badge is documented as re-derived every tick from live state, and it was not: with the
    // request file gone, the early return at the top of the tick was the only path left, so this
    // axis's wait badge stayed on the status line for the rest of the conversation, describing
    // an instruction that no longer existed anywhere (QA, 2026-08-07: still on screen an hour after
    // the file was removed). The ways a request disappears without being served are ordinary - a
    // sweep of a session whose pid the OS reused, a user clearing `~/.tally`, a build rolled back.
    var strandedState = SessionModelState(sessionKey: "5590", servedEpoch: 100, dir: tickDir)
    strandedState.waiting = PendingBadge(sessionModelWaitingBadge, detail: "asked for opus")
    var strandedFollow = FollowState(launchArgs: [])
    var strandedWatcher = idleWatcher("model-stranded")
    _ = tick(&strandedState, follow: &strandedFollow, request: nil, policy: fleetDefault,
             launchArgs: [], watcher: &strandedWatcher)
    check("a tick with no request left clears the badge that described one",
          strandedState.waiting == nil)
    // Narrowly: a request that EXISTS and was already served is not this case. Its badge was
    // cleared by the serve that served it, and clearing it again here would be a second answer to
    // one question - and would wipe a badge a later station had just raised.
    var staleRequestState = SessionModelState(sessionKey: "5591", servedEpoch: 300, dir: tickDir)
    staleRequestState.waiting = PendingBadge(sessionModelWaitingBadge, detail: "asked for opus")
    var staleRequestFollow = FollowState(launchArgs: [])
    var staleRequestWatcher = idleWatcher("model-served")
    _ = tick(&staleRequestState, follow: &staleRequestFollow,
             request: ModelRequest(epoch: 200, model: "opus", effort: nil), policy: fleetDefault,
             launchArgs: [], watcher: &staleRequestWatcher)
    check("…while an already-served request leaves the badge alone",
          staleRequestState.waiting != nil)

    try? FileManager.default.removeItem(at: tickDir)
}
