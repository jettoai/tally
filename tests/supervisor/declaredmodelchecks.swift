import Foundation

// B-4551 step 3: what a session is MEANT to run (the declaration) is kept apart from what its child
// was spawned to run (the execution). The declaration never reads the child's args, so a relaunch we
// rewrote cannot be mistaken for it; every relaunch we execute leaves a record of what it put the
// child on, so the next child's model is explained instead of read as quota.

func runDeclaredModelChecks() {
    let sonnet = "claude-sonnet-5-5", opus = "claude-opus-5-5"
    let account = Snapshot.Account(
        id: "claude:A", provider: "claude", label: "A", launchHome: "/tmp/A",
        sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: 0, sessionResetsAt: nil,
        weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
        isStale: false, error: nil)
    let sibling = Snapshot.Account(
        id: "claude:B", provider: "claude", label: "B", launchHome: "/tmp/B",
        sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: 90, sessionResetsAt: nil,
        weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
        isStale: false, error: nil)
    let fleet = { (Snapshot(version: 2, generatedAt: Date(), accounts: [account, sibling]), nil as String?) }
    let policy = LaunchPolicy(mode: "auto", model: "sonnet", fallbackModel: "opus", effort: "high",
                              fallbackEffort: "high")
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-declared-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("session.jsonl")
    try! "{}".write(to: file, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9999)],
                                           ofItemAtPath: file.path)
    func watcher(serving model: String?) -> TranscriptWatcher {
        var w = TranscriptWatcher(projectDir: dir, file: file, since: launch)
        w.lastModel = model
        return w
    }
    func plan(_ reason: String, model: String?) -> RelaunchPlan {
        RelaunchPlan(target: account, reason: reason, countsFuse: false, model: model)
    }
    /// The relaunch execution point (Supervisor.swift): the args the next child runs, then the record
    /// that they are ours. The source check below pins that the loop does the same two things.
    func applyRelaunch(args: [String], plan: RelaunchPlan, sessionPin: SessionModelPin,
                       ledger: inout ModelGapLedger, at: Date) -> [String] {
        let next = planLaunchArgs(args, plan: plan, sessionPin: sessionPin)
        ledger.noteRelaunch(reason: plan.reason, model: plan.model, at: at)
        return next
    }
    /// One tick of the attribution exactly as the supervisor calls it: declared from the pin, the
    /// typed flag and the policy; executing from the args the current child was spawned with.
    func tick(_ state: inout SessionModelState, args: [String], serving: String?, spawned: TimeInterval,
              typed: String? = nil) -> ModelGapAttribution {
        tickModelGap(state: &state, handledCapacityKeys: [], reasserted: false,
                     watcher: watcher(serving: serving), driftActive: false, typedModel: typed,
                     policyModel: "sonnet", projectDeclares: false,
                     executing: launchPrimaryModel(args, providerID: "claude"),
                     spawnedAt: launch.addingTimeInterval(spawned), quotaEvidence: { false },
                     writeLog: false, now: launch.addingTimeInterval(spawned + 5))
    }
    /// What the supervisor hands the movers for this tick, and whether either plans anything.
    func moversPlan(_ gap: ModelGapAttribution, serving: String?) -> Bool {
        var w = watcher(serving: serving)
        var rescue: RelaunchPlan?
        applyDegradationRescue(plan: &rescue, watcher: &w, gap: gap, policy: policy, account: account,
                               providerID: "claude", primaryModel: gap.declared, quarantine: [:],
                               steering: true, fuseAllows: true, snapshot: fleet)
        var applied = false
        var profile: RelaunchPlan?
        applyFallbackProfile(plan: &profile, applied: &applied, watcher: &w, gap: gap, policy: policy,
                             account: account, primaryModel: gap.declared)
        return rescue != nil || profile != nil
    }

    // MARK: S-B: the fallback rewrote the args, then /clear brought the declared model back

    var state = SessionModelState(sessionKey: "s3-sb", dir: dir)
    var args = ["--model", "sonnet"]
    check("before anything: the child serves what it was declared",
          tick(&state, args: args, serving: sonnet, spawned: 0).cause == .none)
    args = applyRelaunch(args: args, plan: plan("fallback", model: "opus"), sessionPin: state.pin,
                         ledger: &state.gap, at: launch.addingTimeInterval(10))
    check("the fallback profile put the child on opus", launchPrimaryModel(args, providerID: "claude") == "opus")
    let onOpus = tick(&state, args: args, serving: opus, spawned: 12)
    check("the new child serving opus is our own rewrite, and nobody acts on it",
          onOpus.cause == .executionRewrite(reason: "fallback", model: "opus",
                                            at: launch.addingTimeInterval(10))
              && onOpus.owner == .nobody && !moversPlan(onOpus, serving: opus))
    check("…and what it was declared is still sonnet, not the opus the args now say",
          onOpus.declared == "sonnet" && onOpus.executing == "opus"
              && sessionPrimaryModel(pin: state.pin, launchArgs: args, providerID: "claude",
                                     policy: policy) == "opus")
    let afterClear = tick(&state, args: args, serving: sonnet, spawned: 12)
    check("S-B: /clear and sonnet is serving again: no gap, and neither mover plans",
          afterClear.cause == .none && afterClear.owner == .nobody
              && !moversPlan(afterClear, serving: sonnet))
    check("control: the same sonnet answer read against the rewritten args is a degradation to cure",
          moversPlan(attributeModelGap(declared: "opus", source: .app, executing: "opus",
                                       facts: ModelGapFacts(observed: sonnet), ledger: ModelGapLedger(),
                                       quotaEvidence: { true }, now: launch),
                     serving: sonnet))

    // MARK: the safeguard restore's new child

    var restored = SessionModelState(sessionKey: "s3-sg", dir: dir)
    var restoredArgs = ["--model", "sonnet"]
    _ = tick(&restored, args: restoredArgs, serving: sonnet, spawned: 0)
    restoredArgs = applyRelaunch(args: restoredArgs, plan: plan("safeguard", model: "opus"),
                                 sessionPin: restored.pin, ledger: &restored.gap,
                                 at: launch.addingTimeInterval(20))
    let newChild = tick(&restored, args: restoredArgs, serving: opus, spawned: 22)
    check("a safeguard restore's new child (its flag filtered out by `since`) is an execution rewrite",
          newChild.cause == .executionRewrite(reason: "safeguard", model: "opus",
                                              at: launch.addingTimeInterval(20))
              && !moversPlan(newChild, serving: opus))
    var forgotten = SessionModelState(sessionKey: "s3-sg2", dir: dir)
    _ = tick(&forgotten, args: ["--model", "sonnet"], serving: sonnet, spawned: 0)
    let unrecorded = tick(&forgotten, args: planLaunchArgs(["--model", "sonnet"],
                                                           plan: plan("safeguard", model: "opus")),
                          serving: opus, spawned: 22)
    check("control: the same child with no record of the rewrite is read as quota, and the movers act",
          unrecorded.cause == .unexplained(quotaEvidence: false) && moversPlan(unrecorded, serving: opus))

    // MARK: I4: what clears the record

    func kept(_ reason: String, model: String? = nil) -> Bool {
        var ledger = ModelGapLedger()
        _ = applyRelaunch(args: ["--model", "sonnet"], plan: plan("fallback", model: "opus"),
                          sessionPin: SessionModelPin(), ledger: &ledger, at: launch)
        _ = applyRelaunch(args: ["--model", "opus"], plan: plan(reason, model: model),
                          sessionPin: SessionModelPin(), ledger: &ledger, at: launch)
        return ledger.rewrite != nil
    }
    check("a relaunch that says nothing about the model keeps the record (move, cap, switch, update)",
          ["degraded", "cap", "switch", "self-update", "pin", "reload"].allSatisfy { kept($0) })
    check("a relaunch that restates the declaration spends it (follow, tally model)",
          !kept("follow", model: "sonnet") && !kept("model", model: "sonnet"))
    check("the newer rewrite replaces the older one",
          { () -> Bool in
              var ledger = ModelGapLedger()
              _ = applyRelaunch(args: [], plan: plan("fallback", model: "opus"),
                                sessionPin: SessionModelPin(), ledger: &ledger, at: launch)
              _ = applyRelaunch(args: [], plan: plan("safeguard", model: "haiku"),
                                sessionPin: SessionModelPin(), ledger: &ledger,
                                at: launch.addingTimeInterval(9))
              return ledger.rewrite == ModelGapLedger.Rewrite(reason: "safeguard", model: "haiku",
                                                              at: launch.addingTimeInterval(9))
          }())
    check("a person's /model adopted as the pin spends the record too",
          { () -> Bool in
              var ledger = ModelGapLedger()
              _ = applyRelaunch(args: [], plan: plan("fallback", model: "opus"),
                                sessionPin: SessionModelPin(), ledger: &ledger, at: launch)
              ledger.noteDeclarationAdopted()
              return ledger.rewrite == nil
          }())

    // MARK: I8 and the two readings, as source

    let attribution = (try? String(contentsOfFile: "TallyCLI/ModelGapAttribution.swift", encoding: .utf8)) ?? ""
    let supervisor = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let adoption = (try? String(contentsOfFile: "TallyCLI/SessionModel.swift", encoding: .utf8)) ?? ""
    func call(_ opening: String, until closing: String) -> String {
        guard let start = supervisor.range(of: opening),
              let end = supervisor.range(of: closing, range: start.upperBound ..< supervisor.endIndex)
        else { return "" }
        return String(supervisor[start.lowerBound ..< end.upperBound])
    }
    check("I8: the declaration is taken from the pin, the typed flag and the policy, in that order",
          attribution.contains("let declared = state.pin.model ?? typedModel ?? policyModel"))
    check("I8: nothing in the attribution file reads the args of the current child",
          !attribution.contains("launchArgs") && !attribution.contains("launchPrimaryModel(")
              && !attribution.contains("sessionPrimaryModel("))
    check("the movers are handed the declaration, never the execution",
          call("applyDegradationRescue(plan:", until: "reserves: reserves)").contains("gap.declared")
              && call("applyFallbackProfile(plan:", until: "gap.declared ?? effectivePrimary)")
                  .contains("gap.declared"))
    let scoring = ["drought.observe(", "observeCapHit(", "applyProactiveMoves(", "applyTurnBoundaryMove(",
                   "applyQuotaKnock(", "windowRepickMove("]
    check("the account-scoring readers keep reading the model the child runs",
          scoring.allSatisfy {
              let text = call($0, until: "effectivePrimary")
              return text.contains("effectivePrimary") && !text.contains("gap.declared")
          })
    let pair = "sessionPin: sessionModelState.pin)\n"
        + String(repeating: " ", count: 16)
        + "sessionModelState.gap.noteRelaunch(reason: plan.reason, model: plan.model, at: Date())"
    check("the relaunch execution point writes the args and then the record, once",
          supervisor.components(separatedBy: "sessionModelState.gap.noteRelaunch(").count == 2
              && supervisor.contains(pair))
    check("an adopted /model spends the record where the pin is set",
          adoption.contains("state.pin.model = observed; state.gap.noteDeclarationAdopted()"))
}
