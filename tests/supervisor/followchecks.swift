import Foundation

// Follow adoption: deciding whether a launch-default change is a real change for THIS session.
//
// Regression for the 2026-07-27 false positive. The loop's baseline (`followedModel`/
// `followedEffort`) records what FOLLOW set, and the fallback profile and the safeguard restore
// rewrite the launch args without touching it on purpose, so their own change never reads as a
// Settings change. Once the user then set Settings to the pair one of those rewrites had already
// put on the command line, follow compared against the stale baseline, announced "adopting when
// this session goes idle", and spent a relaunch that changed nothing.

func runFollowChecks() {
    // 1. The plain already-satisfied case: the args carry exactly what the policy now asks for.
    check("args already carrying the desired pair need no adoption",
          followAlreadySatisfied(desiredModel: "opus", desiredEffort: "xhigh",
                                 launchArgs: ["--resume", "abc", "--model", "opus",
                                              "--effort", "xhigh"]))

    // 2. Alias equivalence, the reason the comparison cannot be string equality: Settings holds the
    //    alias the user typed, while a safeguard restore writes the full id from the transcript.
    check("an alias in Settings matches the full id on the command line",
          followAlreadySatisfied(desiredModel: "opus", desiredEffort: "high",
                                 launchArgs: ["--model", "claude-opus-4-8", "--effort", "high"]))
    check("and a different family is still a real change",
          !followAlreadySatisfied(desiredModel: "fable", desiredEffort: "high",
                                  launchArgs: ["--model", "claude-opus-4-8", "--effort", "high"]))

    // 3. One notch of depth apart is a genuine change - the whole point of following effort.
    check("a different effort is a real change",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: "xhigh",
                                  launchArgs: ["--model", "opus", "--effort", "high"]))

    // 4. Clearing effort in Settings against args that carry it: adopting REMOVES the flag, so this
    //    is a change even though the model side agrees.
    check("no declared effort against args carrying one is a real change",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: nil,
                                  launchArgs: ["--model", "opus", "--effort", "high"]))
    check("and the mirror image is too - adopting would ADD the flag",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: "high",
                                  launchArgs: ["--model", "opus"]))

    // 5. Neither side declaring anything is agreement, not a change; one side alone is a change.
    check("neither side declaring a model or an effort is satisfied",
          followAlreadySatisfied(desiredModel: nil, desiredEffort: nil, launchArgs: ["--continue"]))
    check("no declared model against args carrying one is a real change",
          !followAlreadySatisfied(desiredModel: nil, desiredEffort: nil,
                                  launchArgs: ["--model", "opus"]))
    check("a declared model against args carrying none is a real change",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: nil,
                                  launchArgs: ["--continue"]))
    check("an empty model string is not treated as a declaration that matches",
          !followAlreadySatisfied(desiredModel: "", desiredEffort: nil,
                                  launchArgs: ["--model", "opus"]))

    // 6. Round trip: the same args that make one pair satisfied must still let the NEXT genuine
    //    Settings change through. Silencing the false positive must not silence following itself.
    let settled = ["--resume", "abc", "--model", "opus", "--effort", "xhigh"]
    check("the pair the session runs is satisfied",
          followAlreadySatisfied(desiredModel: "opus", desiredEffort: "xhigh", launchArgs: settled))
    check("and a later real change against the same args is not",
          !followAlreadySatisfied(desiredModel: "opus", desiredEffort: "high", launchArgs: settled))

    // The round trip is only real if the satisfied branch also re-points the baseline: leaving it
    // stale would silence this Settings change and every later one against the same pair. The
    // branch cannot be reached without spawning a child, so the source carries the invariant (the
    // same approach as the follow dead-end check in reloadchecks.swift).
    // The adoption now has a file of its own, so the block IS the file: no boundary markers to
    // drift, and the same invariant asserted over the same code.
    let block = (try? String(contentsOfFile: "TallyCLI/FollowAdoption.swift", encoding: .utf8)) ?? ""
    check("the follow adoption source is readable for the baseline check", !block.isEmpty)
    check("the follow block consults the args, not just its own baseline",
          block.contains("followAlreadySatisfied("))
    var baselineComesFirst = false
    if let rebaseline = block.range(of: "state.adopt(model: desired.0, effort: desired.1)"),
       let firstQueue = block.range(of: "else if state.pendingSince == nil") {
        baselineComesFirst = rebaseline.lowerBound < firstQueue.lowerBound
    }
    check("and the satisfied branch re-points the baseline before the queueing path",
          baselineComesFirst)
    // MARK: - 28. The adoption's five paths, exercised rather than inspected

    // Being a function instead of a block inside the poll loop is what makes this possible at all:
    // before the split every one of these branches needed a spawned child to reach, so the whole
    // decision was covered by source assertions and nothing else.
    let followNow = Date(timeIntervalSince1970: 1_800_000_000)
    func followAccount(_ id: String, model: Double = 90) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: followNow.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: followNow.addingTimeInterval(100 * 3600),
                         modelResetsAt: followNow.addingTimeInterval(100 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil,
                         isStale: false, error: nil)
    }
    let here = followAccount("A")
    // A transcript that has been silent for hours, so only the keyboard and the debounce decide.
    let followDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-follow-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: followDir, withIntermediateDirectories: true)
    let followFile = followDir.appendingPathComponent("session.jsonl")
    try! "{}".write(to: followFile, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9999)],
                                           ofItemAtPath: followFile.path)
    var followWatcher = TranscriptWatcher(projectDir: followDir, file: followFile, since: launch)

    func adopt(state: inout FollowState, plan: inout RelaunchPlan?,
               model: String? = "fable", effort: String? = "xhigh", mode: String = "auto",
               following: Bool = true, steering: Bool = true, launchArgs: [String] = [],
               keyboardIdle: @escaping (TimeInterval) -> Bool = { _ in true },
               fleet: [Snapshot.Account] = [followAccount("A")],
               snapshotProblem: String? = nil) {
        applyFollowAdoption(
            plan: &plan, state: &state, following: following,
            policy: LaunchPolicy(mode: mode, model: model, effort: effort),
            account: here, providerID: "claude", steering: steering, launchArgs: launchArgs,
            quarantine: [:],
            watcher: &followWatcher, keyboardIdle: keyboardIdle,
            snapshot: { (Snapshot(version: 2, generatedAt: Date(), accounts: fleet),
                         snapshotProblem) })
    }

    // Path 1: already satisfied. The baseline is re-pointed and nothing is queued or planned.
    var satisfied = FollowState(launchArgs: ["--model", "fable", "--effort", "xhigh"])
    var satisfiedPlan: RelaunchPlan?
    adopt(state: &satisfied, plan: &satisfiedPlan)
    check("an unchanged pair plans nothing", satisfiedPlan == nil)
    check("and queues nothing", !satisfied.queuedNotice && satisfied.pendingSince == nil)
    check("and re-points the baseline", satisfied.followedModel == "fable")

    // Path 2: a real change starts the debounce clock rather than acting on the first sighting.
    var pending = FollowState(launchArgs: ["--model", "opus"])
    var pendingPlan: RelaunchPlan?
    adopt(state: &pending, plan: &pendingPlan)
    check("a new pair starts the debounce instead of adopting", pendingPlan == nil)
    check("and records what it is waiting on", pending.pendingModel == "fable")
    check("with the clock started", pending.pendingSince != nil)

    // Path 3: folding into a relaunch this tick already planned. No waiting, no second SIGTERM.
    var folding = FollowState(launchArgs: ["--model", "opus"])
    var foldPlan: RelaunchPlan? = RelaunchPlan(target: here, reason: "cap", countsFuse: true)
    adopt(state: &folding, plan: &foldPlan)          // first tick: starts the clock
    adopt(state: &folding, plan: &foldPlan)          // second: a plan exists, so it folds at once
    check("an existing plan takes the new pair with it", foldPlan?.followFolded == true)
    check("and keeps its own reason and target",
          foldPlan?.reason == "cap" && foldPlan?.target.id == "A")
    check("the fold carries the model", foldPlan?.model == "fable")

    // Path 4: standing on its own, so it waits for a quiet keyboard. This is the gate the
    // 2026-07-28 burst tracker exists to keep openable at all.
    var typing = FollowState(launchArgs: ["--model", "opus"])
    var typingPlan: RelaunchPlan?
    adopt(state: &typing, plan: &typingPlan, keyboardIdle: { _ in false })   // starts the clock
    // The debounce is put behind us deliberately, so the keyboard is the ONLY term left that can
    // hold this back. Without that the assertion passes for the wrong reason: the tick right after
    // the clock starts is inside the debounce floor anyway, and would report "held" with the
    // keyboard check deleted entirely.
    typing.pendingSince = Date().addingTimeInterval(-followDebounce - 1)
    adopt(state: &typing, plan: &typingPlan, keyboardIdle: { _ in false })
    check("a busy keyboard alone holds the adoption back", typingPlan == nil)
    check("and says so once, in the badge", typing.queuedNotice)
    adopt(state: &typing, plan: &typingPlan)
    check("and it lands once the keyboard goes still", typingPlan?.reason == "follow")
    check("on an account that can serve the new model", typingPlan?.target.id == "A")

    // Path 5: THE DEAD END, and the thing it must not do. No account can serve the new model, so
    // the adoption gives up - and leaves the tick alive, because a `tally reload` queued behind it
    // has to be handled by the blocks that run after this one (2026-07-25: it was not).
    var stuck = FollowState(launchArgs: ["--model", "opus"])
    var stuckPlan: RelaunchPlan?
    adopt(state: &stuck, plan: &stuckPlan, fleet: [])
    stuck.pendingSince = Date().addingTimeInterval(-followDebounce - 1)
    adopt(state: &stuck, plan: &stuckPlan, fleet: [])
    check("a dead end plans no relaunch", stuckPlan == nil)
    check("and records itself for the badge", stuck.deadEnd)
    // The invariant the label used to carry: giving up must not consume the pending pair either,
    // or the change would be silently lost the moment an account frees up.
    check("and keeps waiting on the same pair", stuck.pendingModel == "fable")
    check("without re-pointing the baseline as though it had adopted",
          stuck.followedModel == "opus")
    // An account appearing clears the dead end and the adoption goes through.
    adopt(state: &stuck, plan: &stuckPlan)
    check("and it adopts as soon as an account can serve the model", stuckPlan?.reason == "follow")
    check("with the dead-end badge cleared", !stuck.deadEnd)

    // Manual mode never moves account: the pin means "this one", so the re-pick is the incumbent.
    var pinned = FollowState(launchArgs: ["--model", "opus"])
    var pinnedPlan: RelaunchPlan?
    adopt(state: &pinned, plan: &pinnedPlan, mode: "manual", fleet: [])
    pinned.pendingSince = Date().addingTimeInterval(-followDebounce - 1)
    adopt(state: &pinned, plan: &pinnedPlan, mode: "manual", fleet: [])
    check("a pinned session adopts on its own account, with no fleet to consult",
          pinnedPlan?.target.id == "A")

    // A snapshot too old to trust decides nothing about WHERE, the rule the cap handoff and the idle
    // rebalance both hold to: a pick made on hours-old quota is how a session lands somewhere worse
    // than it started. It still decides that the adoption happens - a Settings change that silently
    // does nothing is the defect this whole file is a regression for - so the session comes back on
    // the account it is already on, carrying the new pair.
    let temptingSibling = followAccount("B")
    var stale = FollowState(launchArgs: ["--model", "opus"])
    var stalePlan: RelaunchPlan?
    adopt(state: &stale, plan: &stalePlan, fleet: [temptingSibling],
          snapshotProblem: "snapshot is 40m old")
    stale.pendingSince = Date().addingTimeInterval(-followDebounce - 1)
    adopt(state: &stale, plan: &stalePlan, fleet: [temptingSibling],
          snapshotProblem: "snapshot is 40m old")
    check("a stale snapshot moves the session nowhere", stalePlan?.target.id == "A")
    check("but the launch default is adopted all the same", stalePlan?.model == "fable")
    check("and it is not recorded as a dead end", !stale.deadEnd)
    // Guard the premise: with the SAME fleet and a trustworthy snapshot, the sibling is where this
    // session would have gone, so the check above is about the staleness and nothing else.
    var fresh = FollowState(launchArgs: ["--model", "opus"])
    var freshPlan: RelaunchPlan?
    adopt(state: &fresh, plan: &freshPlan, fleet: [temptingSibling])
    fresh.pendingSince = Date().addingTimeInterval(-followDebounce - 1)
    adopt(state: &fresh, plan: &freshPlan, fleet: [temptingSibling])
    check("the same fleet on a fresh snapshot does move it", freshPlan?.target.id == "B")

    // The round trip that makes the injection position matter. Tally injects the policy pair into
    // the launch args; `FollowState` then reads them back to learn what this session already runs.
    // Appended after a `--` the flag is invisible to that reader (it stops at the marker), so the
    // baseline came up empty, every tick compared "nothing" against the configured default, and the
    // session queued an adoption for a setting nobody had changed - a relaunch that would have
    // changed nothing, on a session whose prompt was meanwhile growing a copy of the flag per pass.
    let injected = injectingOptions(["--", "summarise this"], ["--model", "fable"])
    check("the injected pair lands where the launch args are read",
          FollowState(launchArgs: injected).followedModel == "fable")
    check("and the prompt is carried through unchanged",
          injected.suffix(2) == ["--", "summarise this"])
    // Which is the whole point: with the pair visible, an unchanged policy is a no-op.
    var injectedState = FollowState(launchArgs: injected)
    var injectedPlan: RelaunchPlan?
    adopt(state: &injectedState, plan: &injectedPlan, model: "fable", effort: nil)
    check("so an unchanged default plans no relaunch", injectedPlan == nil)
    check("and queues nothing", !injectedState.queuedNotice && injectedState.pendingSince == nil)
    // The old shape, kept as the guard on the premise: appended past the marker it is unreadable.
    check("appended after the prompt it would have been invisible",
          FollowState(launchArgs: ["--", "summarise this", "--model", "fable"]).followedModel == nil)

    // The full round trip a Settings change actually takes on a session whose launch carried a
    // prompt: the plan rewrites the launch args, the child runs them, and the NEXT tick reads them
    // back to learn what it is running. Appended past the `--`, every step of that failed at once -
    // claude parsed the old pairing, the reader saw nothing, and the baseline had already been
    // re-pointed, so no later tick could notice. That is the one shape that never self-corrects.
    let launched = injectingOptions(["--", "summarise this"], ["--model", "fable"])
    var switched = RelaunchPlan(target: here, reason: "follow", countsFuse: false)
    switched.model = "opus"
    switched.effort = "xhigh"
    let after = planLaunchArgs(launched, plan: switched)
    check("a relaunch puts the new pair in front of the prompt",
          after == ["--model", "opus", "--effort", "xhigh", "--", "summarise this"])
    check("and the next tick reads the new model back",
          FollowState(launchArgs: after).followedModel == "opus")
    check("and the new effort with it",
          FollowState(launchArgs: after).followedEffort == "xhigh")
    check("the prompt survives the rewrite word for word",
          Array(after.suffix(2)) == ["--", "summarise this"])
    // Which closes the loop: the pair the plan applied is the pair the session reports, so an
    // unchanged policy on the next tick plans nothing rather than adopting forever.
    var afterSwitch = FollowState(launchArgs: after)
    var afterSwitchPlan: RelaunchPlan?
    adopt(state: &afterSwitch, plan: &afterSwitchPlan, model: "opus", effort: "xhigh")
    check("so the tick after the switch is a no-op", afterSwitchPlan == nil)
    check("with nothing queued", !afterSwitch.queuedNotice && afterSwitch.pendingSince == nil)
    // The old flag is replaced, not accumulated: a session relaunched twice carries one pair.
    let twice = planLaunchArgs(after, plan: switched)
    check("a second relaunch does not stack a second pair",
          twice == ["--model", "opus", "--effort", "xhigh", "--", "summarise this"])

    // Opted out (`--no-follow`, or a hand-typed --model): nothing is read and nothing is written.
    var optedOut = FollowState(launchArgs: ["--model", "opus"])
    var optedOutPlan: RelaunchPlan?
    adopt(state: &optedOut, plan: &optedOutPlan, following: false)
    check("an opted-out session plans nothing", optedOutPlan == nil)
    check("and its state is untouched",
          optedOut.pendingSince == nil && optedOut.followedModel == "opus")
    try? FileManager.default.removeItem(at: followDir)
}
