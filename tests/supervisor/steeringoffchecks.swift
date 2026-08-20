import Foundation

// OBSERVE ONLY, MEANT LITERALLY: a fleet whose launch policy is `off` never moves a running session
// between accounts.
//
// The app has described that mode to the user as "Tally never steers a launch (a dashboard, nothing
// more)" since it shipped, and until this suite existed the promise was kept in one place - the PATH
// shim - while the supervisor went on handing sessions off, rebalancing them, reopening them on a
// sibling when a window closed and moving them at a `tally session clear`. This is the population of
// entry paths (AutoSteering.swift lists it) with one direction asserted per path: under `off`,
// nothing moves, and nothing is CONSUMED either (a refusal that spends the account's claim for the
// drought would be a second bug wearing the first one's clothes).
//
// Every check has its control beside it. A gate that only ever refuses is indistinguishable from a
// mover that was broken already, which is what the positive half of each pair is here to rule out.

func runSteeringOffChecks() {
    // MARK: - 35. The reading itself

    check("auto steers", supervisorMaySteerAccounts(appMode: "auto"))
    check("manual steers too, and lands on the pin", supervisorMaySteerAccounts(appMode: "manual"))
    check("off does not", !supervisorMaySteerAccounts(appMode: launchModeOff))
    check("the mode that means observe only is spelled the way the app writes it",
          launchModeOff == "off")
    // A mode nothing writes is not `off`, so it steers. Fail-OPEN here rather than closed, and
    // deliberately: this reading is asked of a decoded document whose default is `auto`
    // (`LaunchPolicy`), so an unknown word can only come from a build newer than this one, and
    // refusing to steer for it would silently disable every mover on an upgrade.
    check("an unknown mode is not observe-only", supervisorMaySteerAccounts(appMode: "sideways"))

    // WHY THE APP'S POLICY AND NOT THE ONE THE TICK HANDS THE MOVERS. Both overlays turn their
    // pin into `manual`, so a policy read through either can no longer say `off` at all - the
    // reading has to be taken from the document the user set.
    var offFleet = LaunchPolicy()
    offFleet.mode = launchModeOff
    let pinnedProject = ProjectPolicy(model: nil, effort: nil, accountID: "B")
    check("a project pin over an off fleet no longer reads as off",
          effectivePolicy(offFleet, project: pinnedProject).mode == "manual")
    check("…which is exactly why the gate is asked of the app's own policy",
          !supervisorMaySteerAccounts(appMode: offFleet.mode))
    check("a session pin does the same to it",
          sessionPolicy(offFleet, sessionPin: "C").mode == "manual")

    // MARK: - 35a. The fixtures every mover below is judged against

    /// A dying account: session and weekly healthy, so the flagship window alone decides.
    func acct(_ id: String, model: Double) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil,
                         isStale: false, error: nil)
    }
    let dying = acct("A", model: 3)
    let healthy = acct("B", model: 77)
    let primary = "fable"
    var scratch: [URL] = []
    func claimDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-steering-off-\(UUID().uuidString)")
        scratch.append(dir)
        return dir
    }
    /// Whether anything in a claim directory names this drought - the second half of every refusal
    /// below. Not moving is only half of "nothing happened": a mover that declined AFTER taking the
    /// account's one move of the cycle would leave every other supervisor unable to move for the
    /// rest of the drought, which is a worse failure than the one this gate exists to fix.
    func claimTaken(_ dir: URL, on account: Snapshot.Account = dying) -> Bool {
        let cycle = rebalanceCycleKey(account, primaryModel: primary, now: launch) ?? "-"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .contains { $0.hasSuffix(".\(cycle)") }
    }

    // MARK: - 35b. Path 1, the cap handoff

    // The decision first: observe-only outranks every other answer, including the pin, because it
    // is the only one that is not about this cap at all.
    let capOff = capRecoveryAction(steering: false, mode: "auto", fuseAllows: true,
                                   snapshotStale: false, hasTarget: true)
    check("a cap on an observe-only fleet does not hand off", capOff == .waitSteeringOff)
    check("…and the same board hands off when the fleet steers",
          capRecoveryAction(steering: true, mode: "auto", fuseAllows: true, snapshotStale: false,
                            hasTarget: true) == .handoff)
    check("…it outranks the pin, the fuse, a stale snapshot and an empty field",
          capRecoveryAction(steering: false, mode: "manual", fuseAllows: false,
                            snapshotStale: true, hasTarget: false) == .waitSteeringOff)
    // The badge has to say what ended the wait, because nothing else will: this is the one waiting
    // state that no amount of quota returning can lift.
    check("…and the badge names the setting and the way out",
          capOff.waitingNote == "staying put (launches are set to observe only; "
              + "move it with `tally account`)")

    // End to end through the real station, with a sibling that would obviously be taken.
    func capTick(steering: Bool) -> (plan: RelaunchPlan?, pending: PendingCapRecovery?) {
        var plan: RelaunchPlan?
        var pending: PendingCapRecovery? = PendingCapRecovery(
            cappedAccountID: "A", cappedAt: launch, primaryModel: primary, recoveryResetsAt: nil,
            nextRetry: .distantPast, reason: "")
        applyCapHandoff(plan: &plan, pendingCap: &pending, account: dying, providerID: "claude",
                        fleet: LaunchPolicy(), steering: steering, sessionPin: nil,
                        quarantine: [:], fuseAllows: true, now: launch,
                        loaded: (Snapshot(version: 2, generatedAt: launch,
                                          accounts: [dying, healthy]), nil))
        return (plan, pending)
    }
    let cappedOff = capTick(steering: false)
    check("the cap station plans no move for an observe-only fleet", cappedOff.plan == nil)
    check("…and the same tick moves when it steers", capTick(steering: true).plan?.target.id == "B")
    // The cap is REMEMBERED rather than dropped: the session is capped whatever the policy says, so
    // the badge, the retry and the recovery clearing all have to go on describing it.
    check("…while the pending cap is kept, so the session still says what happened",
          cappedOff.pending != nil)
    check("…with the observe-only reason on it",
          cappedOff.pending?.reason == capOff.waitingNote)

    // MARK: - 35c. Path 2, the degradation rescue

    func rescueTick(steering: Bool) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        var watcher = TranscriptWatcher(projectDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-steering-rescue-\(UUID().uuidString)"),
                                        since: launch.addingTimeInterval(-60), resumeID: nil)
        watcher.lastModel = "claude-haiku-4-5"
        applyDegradationRescue(plan: &plan, watcher: &watcher, driftActive: false,
                               policy: LaunchPolicy(), account: acct("A", model: 1),
                               providerID: "claude", primaryModel: primary, quarantine: [:],
                               steering: steering, fuseAllows: true,
                               snapshot: { (Snapshot(version: 2, generatedAt: launch,
                                                     accounts: [acct("A", model: 1), healthy]),
                                            nil) })
        return plan
    }
    let rescued = rescueTick(steering: true)
    check("a degraded session on an observe-only fleet is not rescued to a sibling",
          rescueTick(steering: false) == nil)
    check("…and is when the fleet steers", rescued?.target.id == "B")
    check("…tagged as the rescue it is", rescued?.reason == "degraded")

    // MARK: - 35d. Path 3, the idle rebalance (and Path 4, the reload's ride on it)

    check("the shared cheap gate refuses an observe-only fleet",
          !rebalanceAllowedForSession(steering: false, mode: "auto", blocked: false,
                                      agentsWorking: false, isQuiet: true,
                                      carryable: true, fuseAllows: true))
    check("…and allows one that steers",
          rebalanceAllowedForSession(steering: true, mode: "auto", blocked: false,
                                     agentsWorking: false, isQuiet: true,
                                     carryable: true, fuseAllows: true))
    check("the rebalance decision answers nothing for it",
          rebalanceTarget(steering: false, mode: "auto", blocked: false, agentsWorking: false,
                          isQuiet: true, carryable: true,
                          fuseAllows: true, current: dying, candidates: [healthy],
                          primaryModel: primary, now: launch) == nil)
    check("…and answers the sibling when it steers",
          rebalanceTarget(steering: true, mode: "auto", blocked: false, agentsWorking: false,
                          isQuiet: true, carryable: true,
                          fuseAllows: true, current: dying, candidates: [healthy],
                          primaryModel: primary, now: launch)?.id == "B")
    let rebalanceOffDir = claimDir()
    check("the whole rebalance move refuses",
          rebalanceMove(provider: "claude", account: dying, primaryModel: primary, mode: "auto",
                        steering: false, blocked: false, agentsWorking: false, isQuiet: true,
                        carryable: true, fuseAllows: true,
                        loaded: (Snapshot(version: 2, generatedAt: launch,
                                          accounts: [dying, healthy]), nil),
                        now: launch, dir: rebalanceOffDir) == nil)
    check("…and spends no claim doing it, so the drought's one move is still there",
          !claimTaken(rebalanceOffDir))
    let rebalanceOnDir = claimDir()
    check("…while a steering fleet moves and takes it",
          rebalanceMove(provider: "claude", account: dying, primaryModel: primary, mode: "auto",
                        steering: true, blocked: false, agentsWorking: false, isQuiet: true,
                        carryable: true, fuseAllows: true,
                        loaded: (Snapshot(version: 2, generatedAt: launch,
                                          accounts: [dying, healthy]), nil),
                        now: launch, dir: rebalanceOnDir)?.id == "B"
          && claimTaken(rebalanceOnDir))

    // MARK: - 35e. Path 5, the window repick (and Path 6, the clear-boundary move on it)

    func repick(steering: Bool) -> Snapshot.Account? {
        windowRepickMove(provider: "claude", account: dying, primaryModel: primary, mode: "auto",
                         steering: steering, carryable: true, fuseAllows: true,
                         loaded: (Snapshot(version: 2, generatedAt: launch,
                                           accounts: [dying, healthy]), nil),
                         now: launch)
    }
    let repickOff = repick(steering: false)
    check("a cleared window does not reopen elsewhere on an observe-only fleet", repickOff == nil)
    check("…and does when the fleet steers", repick(steering: true)?.id == "B")
    // The clear-boundary move is that same decision asked at the landing, so a nil there is a
    // `/clear` that is TYPED rather than one that moves - which is what the command promises when
    // it cannot move the session.
    check("…so a clear-boundary landing plans nothing either",
          clearBoundaryPlan(repickOff, from: dying, primaryModel: primary) == nil)

    // MARK: - 35f. Path 7, the launch-default follow

    // TWO STATIONS ON A REAL CLOCK, and that is a property of what they call rather than of what
    // they are: `incumbentSeededBest` (and `sessionModelTarget` through it) take no `now`, so their
    // hysteresis is scored against the wall clock. Fixtures pinned to this suite's fixed `launch`
    // would have both accounts' windows resetting months out, every rate would round to nothing,
    // and no challenger could clear the margin - a green refusal that proved nothing.
    let realNow = Date()
    func liveAcct(_ id: String, model: Double) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 95, weeklyRemaining: 95, modelRemaining: model,
                         sessionResetsAt: realNow.addingTimeInterval(2 * 3600),
                         weeklyResetsAt: realNow.addingTimeInterval(3 * 3600),
                         modelResetsAt: realNow.addingTimeInterval(2 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil,
                         isStale: false, error: nil)
    }
    let liveDying = liveAcct("A", model: 3)
    let liveHealthy = liveAcct("B", model: 77)

    // NOT A REFUSAL, and this is the half of `off` that would be easy to get wrong: the Settings
    // change is the user's instruction and it still lands. Only the account re-pick is Tally's own,
    // and that is what stops.
    func followTick(steering: Bool) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        var state = FollowState(launchArgs: [])
        var watcher = TranscriptWatcher(projectDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-steering-follow-\(UUID().uuidString)"),
                                        since: launch.addingTimeInterval(-600), resumeID: nil)
        var policy = LaunchPolicy()
        policy.model = "fable"
        policy.effort = "xhigh"
        // Two passes: the first records the desired pair and starts the debounce, the second is
        // past it and adopts.
        for _ in 0 ..< 2 {
            applyFollowAdoption(plan: &plan, state: &state, following: true, policy: policy,
                                account: liveDying, providerID: "claude", steering: steering,
                                launchArgs: [], quarantine: [:], watcher: &watcher,
                                keyboardIdle: { _ in true },
                                snapshot: { (Snapshot(version: 2, generatedAt: realNow,
                                                      accounts: [liveDying, liveHealthy]), nil) })
            // Past the debounce on the same wall clock the adoption reads.
            state.pendingSince = realNow.addingTimeInterval(-followDebounce - 60)
        }
        return plan
    }
    let adoptedOff = followTick(steering: false)
    check("an observe-only fleet still adopts a launch-default change",
          adoptedOff?.model == "fable")
    check("…on the account the session is already on", adoptedOff?.target.id == "A")
    check("…while a steering fleet takes the change to a better account",
          followTick(steering: true)?.target.id == "B")

    // MARK: - 35g. Path 8, `tally model`

    // Same shape one axis over, and expressed the same way: the instruction lands, the account is
    // not re-picked. `sessionModelTarget` is the decision, and `accountPinned` is the reading the
    // tick folds the observe-only answer into.
    let modelSnapshot = Snapshot(version: 2, generatedAt: realNow,
                                 accounts: [liveDying, liveHealthy])
    let modelOff = sessionModelTarget(accountPinned: true, incumbent: liveDying,
                                      providerID: "claude", model: primary,
                                      snapshot: modelSnapshot, problem: nil, excluding: [])
    check("a `tally model` on an observe-only fleet runs the pair where the session stands",
          modelOff.target.id == "A")
    check("…and is not reported as a dry pool, because nothing was refused", !modelOff.dryPool)
    check("…while a steering fleet re-picks for it",
          sessionModelTarget(accountPinned: false, incumbent: liveDying, providerID: "claude",
                             model: primary, snapshot: modelSnapshot, problem: nil,
                             excluding: []).target.id == "B")

    // MARK: - 35h. The wiring, which no value assertion can reach

    // The tick lives in a `while true` inside a process that spawns children, so the source carries
    // these - the technique the rebalance, the follow dead end and the self-update fold all use.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the steering checks", !loop.isEmpty)
    check("the tick reads the gate from the APP's policy, before either overlay",
          loop.contains("let appPolicy = launchPolicy(provider.id)")
              && loop.contains("effectivePolicy(appPolicy, project: project)")
              && loop.contains("supervisorMaySteerAccounts(appMode: appPolicy.mode)"))
    // ONE READING FOR EVERY MOVER. A gate spelled once per station is a gate that can come to
    // disagree with itself about one file, which is the failure this whole file is about.
    check("…exactly once",
          loop.components(separatedBy: "supervisorMaySteerAccounts(").count == 2)
    // And it reaches every station that can pick an account. Read off the calls rather than the
    // file, because `steering:` is a word that appears in nine places for eight different reasons.
    func call(_ opening: String, until closing: String) -> String {
        guard let start = loop.range(of: opening),
              let end = loop.range(of: closing, range: start.upperBound ..< loop.endIndex)
        else { return "" }
        return String(loop[start.upperBound ..< end.upperBound])
    }
    check("the cap station is handed it",
          call("applyCapHandoff(plan: &plan,", until: "reserves: reserves)")
              .contains("steering: steering"))
    check("the degradation rescue is handed it",
          call("applyDegradationRescue(plan: &plan,", until: "reserves: reserves)")
              .contains("steering: steering"))
    check("the preventive station is handed it",
          call("applyProactiveMoves(plan: &plan,", until: "reserves: reserves)")
              .contains("steering: steering"))
    check("the directives station is handed it, for the follow and the model re-picks",
          call("applySessionDirectives(plan: &plan,", until: "keyboardIdle: { keyboard.idle($0) })")
              .contains("steering: steering"))
    check("the reload's ride on the rebalance is handed it",
          call("repick: {", until: "reserves: reserves)").contains("steering: steering"))
    check("the clear-boundary landing is handed it",
          call("clearBoundary: {", until: "reserves: reserves)").contains("steering: steering"))
    check("and the turn-boundary station is handed it",
          call("applyTurnBoundaryMove(plan: &plan,", until: "reserves: reserves)")
              .contains("steering: steering"))
    // The two stations where `off` reads as a pin rather than as a refusal say so in the fold
    // itself, so a later edit cannot drop the term while leaving the parameter in place.
    let directives = (try? String(contentsOfFile: "TallyCLI/SessionDirectives.swift",
                                  encoding: .utf8)) ?? ""
    check("`tally model` folds observe-only into the account-already-spoken-for reading",
          directives.contains("accountPinned: !steering"))
    let follow = (try? String(contentsOfFile: "TallyCLI/FollowAdoption.swift", encoding: .utf8)) ?? ""
    check("the follow adoption reads it as a pin on its re-pick branch",
          follow.contains("if !steering || policy.mode == \"manual\" {"))

    for dir in scratch { try? FileManager.default.removeItem(at: dir) }
}
