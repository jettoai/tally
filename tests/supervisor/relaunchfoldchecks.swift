import Foundation

// B-1091: a relaunch that names no pair of its own (a self-update, a switch, a cap handoff, a
// reload) runs the effective model/effort as of NOW, not the pair the previous child carried.
//
// The failing sample: ~/.claude declares `claude-opus-5-5 / medium` over an app default of
// `opus / high`. The PM session was launched while the profile still said high, so its child args
// carry `--effort high`, and every later restart copied them forward untouched, because the project
// profile had also switched the follow off (`--no-follow`).

func runRelaunchFoldChecks() {
    let sample = ["--resume", "6d14659e-0000-0000-0000-000000000000",
                  "--dangerously-skip-permissions", "--model", "claude-opus-5-5",
                  "--fallback-model", "opus", "--effort", "high"]
    let mediumProject = ProjectPolicy(model: "claude-opus-5-5", effort: "medium")
    let policy = effectivePolicy(LaunchPolicy(mode: "auto", model: "opus", effort: "high"),
                                 project: mediumProject)
    let target = Snapshot.Account(
        id: "claude:.claude3", provider: "claude", label: "albert", launchHome: "/h",
        sessionRemaining: nil, weeklyRemaining: nil, modelRemaining: nil, sessionResetsAt: nil,
        weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil,
        resetCreditsAvailable: nil, isStale: false, error: nil)
    func count(_ args: [String], _ flag: String, _ value: String) -> Int {
        zip(args, args.dropFirst()).filter { $0 == flag && $1 == value }.count
    }

    // T1. Every reason that names no pair lands the effective one, in one restart.
    for reason in ["self-update", "reload", "switch", "cap"] {
        var state = FollowState(launchArgs: sample)
        var plan = RelaunchPlan(target: target, reason: reason, countsFuse: false)
        let folded = foldFollowIntoRelaunch(&plan, state: &state, following: true, policy: policy,
                                            launchArgs: sample)
        let next = planLaunchArgs(sample, plan: plan)
        check("a \(reason) relaunch folds the effective pair in", folded)
        check("…so the child runs --effort medium and no longer high",
              count(next, "--effort", "medium") == 1 && !next.contains("high"))
        check("…with one --model, and the resume and fallback kept",
              count(next, "--model", "claude-opus-5-5") == 1
                  && next.filter { $0 == "--model" }.count == 1
                  && count(next, "--resume", "6d14659e-0000-0000-0000-000000000000") == 1
                  && count(next, "--fallback-model", "opus") == 1)
        check("…and the baseline moves with it, so the next tick plans nothing",
              state.followedEffort == "medium" && state.followedModel == "claude-opus-5-5")
    }

    // T2. A hand-typed --effort high is not following: nothing changes.
    var handState = FollowState(launchArgs: sample)
    var handPlan = RelaunchPlan(target: target, reason: "self-update", countsFuse: false)
    check("a session that is not following is not folded",
          !foldFollowIntoRelaunch(&handPlan, state: &handState, following: false, policy: policy,
                                  launchArgs: sample))
    check("…and keeps its hand-typed --effort high", planLaunchArgs(sample, plan: handPlan) == sample)

    // T3. A plan that names a pair of its own, or releases one, is more specific.
    var ownState = FollowState(launchArgs: sample)
    var ownPlan = RelaunchPlan(target: target, reason: "fallback", countsFuse: false,
                               model: "sonnet")
    check("a plan naming its own model is left alone",
          !foldFollowIntoRelaunch(&ownPlan, state: &ownState, following: true, policy: policy,
                                  launchArgs: sample)
              && ownPlan.model == "sonnet" && ownPlan.effort == nil)
    var releaseState = FollowState(launchArgs: sample)
    var releasePlan = RelaunchPlan(target: target, reason: "model", countsFuse: false)
    releasePlan.clearsAxes = true
    check("a release is left alone",
          !foldFollowIntoRelaunch(&releasePlan, state: &releaseState, following: true,
                                  policy: policy, launchArgs: sample)
              && releasePlan.model == nil && releasePlan.effort == nil)

    // T4. The fallback rewrote the args without moving the baseline on purpose: a relaunch while it
    //     is in effect must not quietly undo it.
    let fallbackArgs = ["--resume", "x", "--model", "sonnet", "--effort", "medium"]
    var fallbackState = FollowState(launchArgs: sample)
    fallbackState.adopt(model: "claude-opus-5-5", effort: "medium")
    var fallbackPlan = RelaunchPlan(target: target, reason: "cap", countsFuse: false)
    check("a fallback in effect is not folded back",
          !foldFollowIntoRelaunch(&fallbackPlan, state: &fallbackState, following: true,
                                  policy: policy, launchArgs: fallbackArgs)
              && planLaunchArgs(fallbackArgs, plan: fallbackPlan) == fallbackArgs)

    // T5. An alias already served by the full id: no restart change, but the baseline is re-pointed.
    let aliasArgs = ["--model", "claude-opus-4-8", "--effort", "high"]
    var aliasState = FollowState(launchArgs: aliasArgs)
    var aliasPlan = RelaunchPlan(target: target, reason: "switch", countsFuse: false)
    check("an alias the args already serve is not folded",
          !foldFollowIntoRelaunch(&aliasPlan, state: &aliasState, following: true,
                                  policy: LaunchPolicy(model: "opus", effort: "high"),
                                  launchArgs: aliasArgs)
              && aliasPlan.model == nil)
    check("…but the baseline adopts it", aliasState.followedModel == "opus")

    // T6. The first child of a self-update image re-derives the pair before it spawns.
    var resumedState = FollowState(launchArgs: sample)
    let resumed = resumedLaunchArgs(sample, state: &resumedState, following: true,
                                    policy: policy, target: target)
    check("a self-update image's first child runs --effort medium",
          count(resumed, "--effort", "medium") == 1 && !resumed.contains("high"))
    var resumedHandState = FollowState(launchArgs: sample)
    check("…unless the session is not following",
          resumedLaunchArgs(sample, state: &resumedHandState, following: false, policy: policy,
                            target: target) == sample)

    // T7. The exec contract marks a hand opt-out, so the new build never mistakes it for a project's.
    let handArgv = selfUpdateArgv(binary: "/t", id: "a", label: "A", home: "/h", follow: false,
                                  args: ["--resume", "x"])
    let handParsed = parseResuperviseArgs(Array(handArgv.dropFirst(2)))
    check("a hand opt-out is written with its marker",
          handArgv.contains("--no-follow") && handArgv.contains(resuperviseHandOptOutFlag))
    check("…parsed back as one", handParsed.handOptOut && !handParsed.follow
              && handParsed.childArgs == ["--resume", "x"])
    check("…and never overwritten by a project that declares a pair",
          resupervisedFollow(handParsed, project: mediumProject, environmentAllows: true) == .none)
    check("a following session writes no marker (T10)",
          !selfUpdateArgv(binary: "/t", id: "a", label: "A", home: "/h", follow: true, args: [])
              .contains(resuperviseHandOptOutFlag))

    // T8. An argv from a build before the marker: the failing sample's own supervisor.
    let legacy = parseResuperviseArgs(["--id", "claude:.claude3", "--label", "albert", "--home",
                                       "/h", "--no-follow", "--session-pin", "claude:.claude3",
                                       "--"] + sample)
    check("an unmarked --no-follow in a project that declares a pair follows",
          resupervisedFollow(legacy, project: mediumProject, environmentAllows: true) == .both)
    check("…in a project that declares none stays opted out",
          resupervisedFollow(legacy, project: ProjectPolicy(), environmentAllows: true) == .none)
    check("…and the environment opt-out wins either way",
          resupervisedFollow(legacy, project: mediumProject, environmentAllows: false) == .none)
    check("an old --follow is taken as written",
          resupervisedFollow(parseResuperviseArgs(["--home", "/h", "--follow"]),
                             project: ProjectPolicy(), environmentAllows: true) == .both)

    // T9. The whole chain for the failing sample: one upgrade, one restart, medium.
    var chainState = FollowState(launchArgs: legacy.childArgs)
    let chain = resumedLaunchArgs(
        legacy.childArgs, state: &chainState,
        following: resupervisedFollow(legacy, project: mediumProject, environmentAllows: true),
        policy: policy, target: target)
    check("the failing sample's PM lands on --effort medium after one upgrade",
          count(chain, "--effort", "medium") == 1 && !chain.contains("high"))

    // T11-T13. The call sites, asserted from source: the loop needs a live child to run.
    let mainSource = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let entry = (try? String(contentsOfFile: "TallyCLI/SelfUpdate.swift", encoding: .utf8)) ?? ""
    check("the fold checks can read their sources",
          !mainSource.isEmpty && !loop.isEmpty && !entry.isEmpty)
    let decisionSource = (try? String(contentsOfFile: "TallyCLI/LaunchDecision.swift",
                                      encoding: .utf8)) ?? ""
    let executor = (try? String(contentsOfFile: "TallyCLI/CodexSupervisor.swift", encoding: .utf8)) ?? ""
    func follows(_ args: [String]) -> FollowAxes {
        launchIntent(providers[0], args: args, accountFlag: nil, stdoutIsTTY: true,
                     environment: [:]).follow
    }
    check("a project profile no longer opts the session out of following",
          executor.contains("follow: decision.follow") && follows([]) == .both
              && follows(["--model", "x"]) == FollowAxes(model: false, effort: true)
              && follows(["--effort", "high"]) == FollowAxes(model: true, effort: false)
              && follows(["--model", "x", "--effort", "high"]) == .none
              && follows(["--no-follow"]) == .none
              && !mainSource.contains("project.model == nil && project.effort == nil")
              && !decisionSource.contains("project.model == nil && project.effort == nil"))
    let fold = loop.range(of: "foldEffectiveFollow(&plan")
    let apply = loop.range(of: "launchArgs = planLaunchArgs(launchArgs, plan: plan")
    let restore = loop.range(of: "committed.restore(")
    check("the relaunch point folds after the hold and before the args are rewritten",
          fold != nil && apply != nil && restore != nil
              && restore!.lowerBound < fold!.lowerBound && fold!.lowerBound < apply!.lowerBound)
    check("a self-update image re-derives its first child's args",
          loop.contains("launchArgs = resumedLaunchArgs(launchArgs"))
    check("the resupervise entry point reads the follow through the legacy inference",
          entry.contains("resupervisedFollow(parsed, project:"))

    // T14. Issue #14: `--model X` typed, the default effort injected at launch, then the default
    //      effort goes away. Every relaunch used to keep `--effort high` for the life of the session.
    let typedModel = "opus[1m]"
    let sessionID = "6d14659e-0000-0000-0000-000000000000"
    let typedIntent = launchIntent(providers[0], args: ["--model", typedModel], accountFlag: nil,
                                   stdoutIsTTY: true, environment: [:])
    let launched = applyLaunchDefaults(typedIntent.passthrough, policy: LaunchPolicy(effort: "high"),
                                       providerID: "claude")
    check("the typed model launch carries the injected effort", count(launched, "--effort", "high") == 1)
    check("…and follows on the effort axis only",
          typedIntent.follow == FollowAxes(model: false, effort: true))
    let noEffort = LaunchPolicy(effort: nil)
    let resumeArgs = relaunchArgs(launched, sessionID: sessionID, sameAccount: true)
    let wanted = ["--resume", sessionID, "--model", typedModel]
    var fixState = FollowState(launchArgs: launched)
    var fixPlan = RelaunchPlan(target: target, reason: "cap", countsFuse: false)
    check("a cap relaunch folds the dropped default effort",
          foldFollowIntoRelaunch(&fixPlan, state: &fixState, following: typedIntent.follow,
                                 policy: noEffort, launchArgs: launched))
    let fixed = planLaunchArgs(resumeArgs, plan: fixPlan)
    check("…and the child runs the typed model verbatim with no --effort", fixed == wanted)
    var viaResumedState = FollowState(launchArgs: launched)
    check("a self-update image's first child does the same",
          resumedLaunchArgs(resumeArgs, state: &viaResumedState, following: typedIntent.follow,
                            policy: noEffort, target: target) == wanted)
    // The exec contract in the middle: what the old supervisor writes is what the new image reads.
    let viaArgv = selfUpdateArgv(binary: "/t", id: "a", label: "A", home: "/h",
                                 follow: typedIntent.follow, args: resumeArgs)
    let viaParsed = parseResuperviseArgs(Array(viaArgv.dropFirst(2)))
    let viaFollow = resupervisedFollow(viaParsed, project: ProjectPolicy(), environmentAllows: true)
    var viaContractState = FollowState(launchArgs: launched)
    check("the contract carries the axis across the self-update exec",
          viaFollow == typedIntent.follow && !viaArgv.contains("--follow"))
    check("…so the image's first child runs the typed model with no --effort",
          resumedLaunchArgs(viaParsed.childArgs, state: &viaContractState, following: viaFollow,
                            policy: noEffort, target: target) == wanted)

    // T15. The held model never moves, whatever the default becomes.
    var heldState = FollowState(launchArgs: launched)
    var heldPlan = RelaunchPlan(target: target, reason: "reload", countsFuse: false)
    foldFollowIntoRelaunch(&heldPlan, state: &heldState, following: typedIntent.follow,
                           policy: LaunchPolicy(model: "sonnet", effort: "medium"),
                           launchArgs: launched)
    let heldNext = planLaunchArgs(resumeArgs, plan: heldPlan)
    check("a changed default moves the effort and leaves the typed model",
          count(heldNext, "--model", typedModel) == 1 && count(heldNext, "--effort", "medium") == 1
              && heldNext.filter { $0 == "--model" }.count == 1)
    check("…and the baseline keeps the typed model", heldState.followedModel == typedModel
              && heldState.followedEffort == "medium")
}
