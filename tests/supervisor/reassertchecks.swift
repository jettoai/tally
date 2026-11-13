import Foundation

// #623: a fallback rewrote `--model sonnet` to `--model opus` and nothing ever put it back, even after
// the project profile was written again. Replayed here with the args of the supervisor that stayed on
// opus (expense, 2026-11-13 21:29): the pure functions only, no child, no claude, no home directory.

func runReassertChecks() {
    let sample = ["--resume", "5f26028c-8607-4272-a9cd-027841add1bf", "--dangerously-skip-permissions",
                  "--model", "sonnet", "--fallback-model", "opus", "--effort", "high"]
    let policy = LaunchPolicy(mode: "auto", model: "sonnet", fallbackModel: "opus", effort: "high",
                              fallbackEffort: "high")
    let account = Snapshot.Account(
        id: "claude:A", provider: "claude", label: "A", launchHome: "/tmp/A",
        sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: 90, sessionResetsAt: nil,
        weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
        isStale: false, error: nil)
    func count(_ args: [String], _ flag: String, _ value: String) -> Int {
        zip(args, args.dropFirst()).filter { $0 == flag && $1 == value }.count
    }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-reassert-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("session.jsonl")
    try! "{}".write(to: file, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9999)],
                                           ofItemAtPath: file.path)
    var watcher = TranscriptWatcher(projectDir: dir, file: file, since: launch)
    watcher.lastModel = "claude-opus-5-5"

    func follow(_ state: inout FollowState, _ args: [String], following: FollowAxes = .both,
                policy: LaunchPolicy = policy) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        for _ in 0 ..< 2 {
            applyFollowAdoption(plan: &plan, state: &state, following: following, policy: policy,
                                account: account, providerID: "claude", steering: true,
                                launchArgs: args, quarantine: [:], watcher: &watcher,
                                keyboardIdle: { _ in true },
                                snapshot: { (Snapshot(version: 2, generatedAt: Date(), accounts: [account]), nil) })
            state.pendingSince = state.pendingSince.map { _ in Date().addingTimeInterval(-followDebounce - 1) }
        }
        return plan
    }

    // 1. The fallback rewrites the model, as it did at 21:29.
    var fallbackPlan: RelaunchPlan?
    var applied = false
    applyFallbackProfile(plan: &fallbackPlan, applied: &applied, watcher: &watcher, driftActive: false,
                         policy: policy, account: account, primaryModel: "sonnet")
    let onOpus = fallbackPlan.map { planLaunchArgs(sample, plan: $0) } ?? []
    check("the fallback profile puts the session on opus",
          fallbackPlan?.reason == "fallback" && count(onOpus, "--model", "opus") == 1)

    // 2. Nothing restated: the fallback stays (the existing behaviour, kept).
    var state = FollowState(launchArgs: sample)
    check("a profile that was not written again leaves the fallback in place",
          follow(&state, onOpus) == nil && !state.reasserted)

    // 3. The profile is written again, to the SAME value: the session goes back to sonnet, once.
    state.reasserted = true
    let back = follow(&state, onOpus)
    let restored = back.map { planLaunchArgs(onOpus, plan: $0) } ?? []
    check("a restated profile moves the session back with a follow relaunch",
          back?.reason == "follow" && back?.model == "sonnet")
    check("the child then has exactly one --model sonnet, no opus, and the fallback flag kept",
          count(restored, "--model", "sonnet") == 1 && restored.filter { $0 == "--model" }.count == 1
              && count(restored, "--fallback-model", "opus") == 1 && !state.reasserted)
    check("and once it is back the next tick plans nothing", follow(&state, restored) == nil)

    // 4. Every relaunch that names no pair folds the restated profile in; without the restatement none do.
    for reason in ["cap", "switch", "reload", "rebalance", "degraded", "self-update"] {
        var folding = FollowState(launchArgs: sample)
        var plan = RelaunchPlan(target: account, reason: reason, countsFuse: false)
        check("\(reason): a fallback in effect is not folded back without a restatement",
              !foldFollowIntoRelaunch(&plan, state: &folding, following: .both, policy: policy,
                                      launchArgs: onOpus))
        folding.reasserted = true
        check("\(reason): a restated profile is folded in",
              foldFollowIntoRelaunch(&plan, state: &folding, following: .both, policy: policy,
                                     launchArgs: onOpus)
                  && count(planLaunchArgs(onOpus, plan: plan), "--model", "sonnet") == 1
                  && !folding.reasserted)
    }

    // 5. A pinned session (`tally model`, native /model) is gated out by the caller: nothing moves.
    var pinned = FollowState(launchArgs: sample)
    pinned.reasserted = true
    check("a pinned session ignores a restatement",
          follow(&pinned, onOpus, following: FollowAxes.both.gated(by: false)) == nil)

    // 6. A typed --model holds its axis; the effort axis still follows the restated profile.
    let typed = ["--model", "opus", "--effort", "low"]
    var held = FollowState(launchArgs: typed)
    held.reasserted = true
    let heldPlan = follow(&held, typed, following: FollowAxes(model: false, effort: true))
    check("a typed model survives a restatement while the effort follows",
          heldPlan.map { planLaunchArgs(typed, plan: $0) } == ["--model", "opus", "--effort", "high"])
    var heldBoth = FollowState(launchArgs: typed)
    heldBoth.reasserted = true
    check("with both axes held nothing is planned", follow(&heldBoth, typed, following: .none) == nil)

    // 7. The launch record keeps only what was typed.
    check("a following session records neither injected axis",
          typedLaunchArgs(sample, following: .both)
              == ["--resume", "5f26028c-8607-4272-a9cd-027841add1bf", "--dangerously-skip-permissions",
                  "--fallback-model", "opus"])
    check("a typed model is kept while a following effort is dropped",
          typedLaunchArgs(["--model", "opus", "--effort", "high"], following: FollowAxes(model: false, effort: true))
              == ["--model", "opus"])
    check("a session following nothing records its args as they are",
          typedLaunchArgs(sample, following: .none) == sample)
    let recordDir = dir.appendingPathComponent("state")
    publishSessionLaunch(provider: "claude", args: typedLaunchArgs(sample, following: .both), cwd: "/tmp",
                         pid: "6231", resumed: false, dir: recordDir)
    let recorded = SessionLaunchRecord.read(pid: "6231", dir: recordDir, isLive: { _ in true })
    check("the record read back has the resume and no model or effort",
          // The allow-list drops the permission and fallback flags with or without this change.
          recorded?.args == ["--resume", "5f26028c-8607-4272-a9cd-027841add1bf"])
    let unstripped = SessionLaunchRecord.current(provider: "claude", args: sample, cwd: "/tmp", environment: [:])
    check("the allow-list alone would have kept the injected pair (what the strip is for)",
          unstripped.args.contains("--model") && unstripped.args.contains("--effort"))

    // 8. The profile file: a write is noticed even when the value did not change.
    let policies = dir.appendingPathComponent("project-policies.json")
    let key = "/tmp/reassert-project"
    // What `tally project set` stamps on the entry it writes; a counter keeps two writes within one
    // clock tick apart. `restate: false` rewrites the file around this session's entry and leaves it as it was.
    var written = 0.0
    func write(_ model: String?, restate: Bool = true, otherProject: String? = nil, codexModel: String? = nil) {
        if restate { written += 1 }
        var doc = ProjectPolicyFile()
        doc.projects[key] = ["claude": ProjectPolicy(model: model, effort: "high", writtenAt: written)]
        if let codexModel { doc.projects[key]?["codex"] = ProjectPolicy(model: codexModel, writtenAt: written + 100) }
        if let otherProject { doc.projects["/tmp/other-project"] = ["claude": ProjectPolicy(model: otherProject, writtenAt: written + 200)] }
        try! saveProjectPolicies(doc, to: policies)
    }
    func touch(_ seconds: TimeInterval) {
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(seconds)],
                                               ofItemAtPath: policies.path)
    }
    write("sonnet")
    var stamp = ProjectPolicyStamp(url: policies)
    var project = ProjectPolicy(model: "sonnet", effort: "high")
    var noted = FollowState(launchArgs: sample)
    noteProjectReasserted(stamp: &stamp, project: &project, state: &noted, providerID: "claude", key: key,
                          url: policies)
    check("an untouched file is not a restatement", !noted.reasserted)
    write("sonnet")
    touch(5)
    noteProjectReasserted(stamp: &stamp, project: &project, state: &noted, providerID: "claude", key: key,
                          url: policies)
    check("the same value written again is a restatement", noted.reasserted && project.model == "sonnet")
    noted.reasserted = false
    noteProjectReasserted(stamp: &stamp, project: &project, state: &noted, providerID: "claude", key: key,
                          url: policies)
    check("and is noticed once", !noted.reasserted)
    write("opus")
    touch(10)
    noteProjectReasserted(stamp: &stamp, project: &project, state: &noted, providerID: "claude", key: key,
                          url: policies)
    check("a changed value is re-read into the loop's copy", noted.reasserted && project.model == "opus")
    noted.reasserted = false
    // The file is one for the whole machine: a write that leaves this session's own entry alone is
    // not the user restating this session's profile, whichever project or provider it was for.
    write("opus", restate: false, otherProject: "opus")
    touch(12)
    noteProjectReasserted(stamp: &stamp, project: &project, state: &noted, providerID: "claude", key: key,
                          url: policies)
    check("another project's profile written is not a restatement here", !noted.reasserted)
    write("opus", restate: false, otherProject: "opus", codexModel: "opus")
    touch(13)
    noteProjectReasserted(stamp: &stamp, project: &project, state: &noted, providerID: "claude", key: key,
                          url: policies)
    check("this project's other provider written is not a restatement here either", !noted.reasserted)
    write("opus", otherProject: "opus", codexModel: "opus")
    touch(14)
    noteProjectReasserted(stamp: &stamp, project: &project, state: &noted, providerID: "claude", key: key,
                          url: policies)
    check("this session's own entry written again among them still is", noted.reasserted)
    noted.reasserted = false
    try! "{not json".write(to: policies, atomically: true, encoding: .utf8)
    touch(15)
    noteProjectReasserted(stamp: &stamp, project: &project, state: &noted, providerID: "claude", key: key,
                          url: policies)
    check("an unreadable file is neither a restatement nor a cleared profile",
          !noted.reasserted && project.model == "opus")
    try! FileManager.default.removeItem(at: policies)
    noteProjectReasserted(stamp: &stamp, project: &project, state: &noted, providerID: "claude", key: key,
                          url: policies)
    check("a removed file clears the copy and restates",
          noted.reasserted && project.model == nil && project.effort == nil)

    // 9. The wiring: the supervisor reads the stamp before the policy it lays over, and records typed args.
    let source = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the tick notices a restated profile before it reads the effective policy",
          (source.range(of: "noteProjectReasserted(stamp: &projectStamp")?.lowerBound ?? source.startIndex)
              < (source.range(of: "let fleetPolicy = effectivePolicy(appPolicy")?.lowerBound ?? source.startIndex)
              && source.contains("noteProjectReasserted(stamp: &projectStamp"))
    check("the launch record is written from the typed args only",
          source.contains("args: typedLaunchArgs(args, following: follow)"))
}
