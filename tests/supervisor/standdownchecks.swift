import Foundation

// Standing a planned relaunch down at the execution point (the unresolved-fork hold) and giving the
// planners back what planning cost them.
//
// Planning is not a pure decision: by the time a plan exists its owner has already written the
// bookkeeping that says "this is handled". Dropping the plan alone therefore does not defer the
// work, it loses it. Proven on `tally reload`, whose served epoch is recorded as the relaunch is
// planned: a stood-down tick left the stamp consumed, so every later tick read the request as one
// this supervisor had already served and the reload never happened again for the life of the
// session - silently, because nothing was queued any more either.

/// A session whose transcript has been silent for hours: every idle gate says yes, so the planners
/// below reach their decision and the probe is about what happens after it.
private func standDownWatcher(_ label: String) -> TranscriptWatcher {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-standdown-\(label)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("session.jsonl")
    try! "{}\n".write(to: file, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9999)],
                                           ofItemAtPath: file.path)
    return TranscriptWatcher(projectDir: dir, file: file, since: Date().addingTimeInterval(-600))
}

private let standDownAccount = Snapshot.Account(
    id: "A", provider: "claude", label: "A", launchHome: "/tmp/A", sessionRemaining: 90,
    weeklyRemaining: 90, modelRemaining: 90, sessionResetsAt: nil, weeklyResetsAt: nil,
    modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
    error: nil)

func runStandDownChecks() {
    // MARK: - 30. The reload the first version of this hold swallowed

    // The sequence is the real one, three ticks of it: the request arrives while the user is
    // typing (queued, badge up), the session goes idle and the reload is planned (stamp consumed,
    // badge down), and the execution point then finds a `/clear` and stands the restart down.
    var watcher = standDownWatcher("reload")
    var epoch = 100
    var notice = ReloadWait()
    var follow = FollowState(launchArgs: [])
    var fallbackApplied = false
    let request = ReloadRequest(epoch: 101, immediate: false)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    var busyPlan: RelaunchPlan?
    applyReloadRequest(plan: &busyPlan, epoch: &epoch, notice: &notice, account: standDownAccount,
                       watcher: &watcher, childAge: 9999, keyboardIdle: { _ in false },
                       request: request, now: t0)
    check("a request that arrives on a busy session is queued", busyPlan == nil && epoch == 100)
    check("with a badge saying so", notice.pending == PendingBadge("reload at idle"))

    // The tick that plans: everything the planners may commit is read BEFORE the first of them runs.
    let committed = TickCommitments(reloadEpoch: epoch, reloadNotice: notice, followState: follow,
                                    fallbackApplied: fallbackApplied)
    var plan: RelaunchPlan?
    applyReloadRequest(plan: &plan, epoch: &epoch, notice: &notice, account: standDownAccount,
                       watcher: &watcher, childAge: 9999, keyboardIdle: { _ in true },
                       request: request, now: t0.addingTimeInterval(2))
    check("an idle session plans the reload", plan?.reason == "reload")
    check("and planning consumes the stamp as it goes", epoch == 101)
    check("taking the badge down with it", notice.pending == nil)

    // The execution point finds a transcript it cannot place yet, so this relaunch does not happen.
    check("a reload is held by an unresolved fork",
          relaunchHeldByUnresolvedFork(reason: plan!.reason, unresolvedFork: true))
    committed.restore(reloadEpoch: &epoch, reloadNotice: &notice, followState: &follow,
                      fallbackApplied: &fallbackApplied)
    check("standing down gives the stamp back", epoch == 100)
    check("and the badge with it, because the wait is on again",
          notice.pending == PendingBadge("reload at idle"))

    // The next tick, with its own plan: the request must be planned again. Without the restore
    // above this is where it vanished - `reloadDecision` reads 101 against a captured 101 and
    // answers `.none`, on this tick and on every one after it.
    var nextPlan: RelaunchPlan?
    applyReloadRequest(plan: &nextPlan, epoch: &epoch, notice: &notice, account: standDownAccount,
                       watcher: &watcher, childAge: 9999, keyboardIdle: { _ in true },
                       request: request, now: t0.addingTimeInterval(4))
    check("the next tick plans the reload again rather than believing it served it",
          nextPlan?.reason == "reload")
    check("and consumes the stamp then", epoch == 101)

    // MARK: - 31. The same for the fallback profile's one-shot flag

    // `applyFallbackProfile` fires at most once per SESSION, so its flag is set as the plan is made.
    // A stood-down tick that kept the flag would spend the session's single fallback on a relaunch
    // that never happened, leaving it on the model it fell back to at the wrong depth for good.
    var fallbackWatcher = standDownWatcher("fallback")
    fallbackWatcher.lastModel = "claude-haiku-4"
    let policy = LaunchPolicy(model: "claude-fable-5", fallbackModel: "haiku",
                              fallbackEffort: "medium")
    var applied = false
    var epoch2 = 0
    var notice2 = ReloadWait()
    var follow2 = FollowState(launchArgs: [])
    let before = TickCommitments(reloadEpoch: epoch2, reloadNotice: notice2, followState: follow2,
                                 fallbackApplied: applied)
    var fallbackPlan: RelaunchPlan?
    applyFallbackProfile(plan: &fallbackPlan, applied: &applied, watcher: &fallbackWatcher,
                         driftActive: false, policy: policy, account: standDownAccount,
                         primaryModel: "claude-fable-5")
    check("a degraded session plans the fallback profile", fallbackPlan?.reason == "fallback")
    check("and spends its one shot as it plans", applied)
    check("a fallback is held by an unresolved fork",
          relaunchHeldByUnresolvedFork(reason: fallbackPlan!.reason, unresolvedFork: true))
    before.restore(reloadEpoch: &epoch2, reloadNotice: &notice2, followState: &follow2,
                   fallbackApplied: &applied)
    check("standing down gives the one shot back", !applied)
    var laterPlan: RelaunchPlan?
    applyFallbackProfile(plan: &laterPlan, applied: &applied, watcher: &fallbackWatcher,
                         driftActive: false, policy: policy, account: standDownAccount,
                         primaryModel: "claude-fable-5")
    check("so the next tick applies the profile instead of living without it",
          laterPlan?.reason == "fallback")

    // MARK: - 32. The follow adoption's baseline, and what is deliberately NOT rolled back

    // The follow fold commits its baseline while folding onto a plan somebody else made, which it
    // does WITHOUT a quiet gate of its own - so it is the one planner a stand-down can catch even
    // outside the sub-tick race. Whole-value restore, so what was said about the wait goes back too.
    var followState = FollowState(launchArgs: [])
    followState.pendingModel = "claude-fable-5"
    followState.pendingSince = t0
    let followBefore = TickCommitments(reloadEpoch: 0, reloadNotice: ReloadWait(),
                                       followState: followState, fallbackApplied: false)
    followState.followedModel = "claude-fable-5"     // what the fold commits
    followState.pendingSince = nil
    var scratchEpoch = 0
    var scratchNotice = ReloadWait()
    var scratchFallback = false
    followBefore.restore(reloadEpoch: &scratchEpoch, reloadNotice: &scratchNotice,
                         followState: &followState, fallbackApplied: &scratchFallback)
    check("standing down puts the adopted baseline back",
          followState.followedModel == nil && followState.pendingSince == t0)

    // The transcript scan is deliberately outside all of this: a cap event is drained from the byte
    // stream exactly once, so rolling it back would delete a cap rather than defer it. Cap plans are
    // exempt from the hold for the same reason, which is what keeps the two rules consistent.
    check("a cap handoff is never stood down, so its consumed scan is never in question",
          !relaunchHeldByUnresolvedFork(reason: "cap", unresolvedFork: true))
    let standDownSource = (try? String(contentsOfFile: "TallyCLI/StandDown.swift",
                                       encoding: .utf8)) ?? ""
    check("the stand-down source is readable from the suite", !standDownSource.isEmpty)
    check("and it records why the rebalance claim is left alone rather than restored",
          standDownSource.contains("Rebalance.swift"))

    // MARK: - 33. The wiring: capture before the planners, restore on the stand-down

    // Both halves have to be in the tick, in that order, or the restore gives back a value the
    // planners had already overwritten.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the stand-down checks", !loop.isEmpty)
    func at(_ needle: String) -> Int? {
        loop.range(of: needle).map { loop.distance(from: loop.startIndex, to: $0.lowerBound) }
    }
    if let capture = at("let committed = TickCommitments("),
       let firstPlanner = at("// Cap recovery has top priority"),
       let restore = at("committed.restore("),
       let execution = at("// Execute the tick's one relaunch") {
        check("the tick captures its commitments before any planner runs", capture < firstPlanner)
        check("and hands them back at the execution point", execution < restore)
    } else {
        check("the capture and the restore were both found in the tick", false)
    }
}
