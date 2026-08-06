import Foundation

// The self-update fold, split out of reloadchecks.swift for file size. Top-level statements can only
// live in main.swift, so these run as one function it calls; the harness (`check`, `failures`) and
// the fixed `launch` date are shared from there.
//
// The behaviour under test: an app update pending on a session that is ALREADY restarting rides
// along on that restart. Before this, the upgrade deferred whenever any other reason relaunched the
// child, and then had to earn a fresh idle window from scratch - the user paid two visible restarts
// minutes apart (handoff.log, session c80ebeb2, 2026-07-26: a cap handoff to Claude 2 at 06:34:12Z,
// the supervisor self-update at 06:36:14Z).

func runSelfUpdateFoldChecks() {
    // MARK: - 24. A pending upgrade folds into the relaunch a plan is already making

    func foldAccount(_ id: String, home: String) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: home,
                         sessionRemaining: nil, weeklyRemaining: nil, modelRemaining: nil,
                         sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                         modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                         error: nil)
    }
    // The two accounts of the incident: the session was launched on Claude and the cap handoff moved
    // it to Claude 2, so the upgrade that folds into that handoff must land on the SECOND home.
    let leftHome = "/Users/x/.claude"
    let movedToHome = "/Users/x/.claude2"
    let movedTo = foldAccount("acct-2", home: movedToHome)

    func fold(captured: String? = "0.25.0", installed: String? = "0.26.0", attempted: String? = nil,
              home: String? = movedToHome, binary: String? = "/bin/ls")
        -> (target: String, binary: String, home: String)? {
        selfUpdateFold(captured: captured, attempted: attempted, home: home,
                       installed: installed, binary: binary)
    }

    // 24a. What folds, and onto which account.
    check("a due update folds into a plan's restart", fold()?.target == "0.26.0")
    check("and it carries the home of the account the plan moves TO",
          fold()?.home == movedToHome)
    check("never the home the session is leaving", fold()?.home != leftHome)
    check("it hands back the executable it checked", fold()?.binary == "/bin/ls")

    // 24b. No update due: the plan's restart happens on the build we have, exactly as before.
    check("no fold when the installed build is the one we are running",
          fold(captured: "0.26.0", installed: "0.26.0") == nil)
    check("an older installed build is never folded in (the exec is one-way)",
          fold(captured: "0.26.0", installed: "0.25.0") == nil)
    check("no installed version at all (mid-install, or no bundle) folds nothing",
          fold(installed: nil) == nil)
    check("a dev build with no captured version never folds", fold(captured: nil) == nil)
    check("a version we cannot parse stays put here too", fold(installed: "0.26.0-beta") == nil)
    check("no executable to exec means no fold this tick", fold(binary: nil) == nil)
    check("no home to pass means no fold at all", fold(home: nil) == nil)

    // 24c. The two WAITING gates do not apply to a fold. They exist to protect a restart that would
    // not otherwise happen; the child is being terminated either way here, so there is no idle
    // moment left to wait for and no loop for the uptime floor to brake. Same inputs, opposite
    // answers - which is the entire point.
    func standalone(isQuiet: Bool, uptime: TimeInterval) -> String? {
        selfUpdateDue(captured: "0.25.0", attempted: nil, isQuiet: isQuiet, relaunchPlanned: false,
                      uptime: uptime, home: movedToHome,
                      installed: "0.26.0", binary: "/bin/ls")?.target
    }
    check("a lone upgrade still waits for a quiet session",
          standalone(isQuiet: false, uptime: 300) == nil)
    check("but a fold takes a busy session, because the child is restarting regardless",
          fold()?.target == "0.26.0")
    check("a lone upgrade still waits out the loop-safety floor",
          standalone(isQuiet: true, uptime: selfUpdateMinUptime - 1) == nil)
    check("and the fold does not re-count that floor after a handoff reset the child's age",
          fold() != nil)
    check("a lone upgrade on an idle, long-lived session is unchanged",
          standalone(isQuiet: true, uptime: 300) == "0.26.0")

    // 24d. Loop safety survives the fold: the target an exec already tried is never tried again, so
    // an exec that fails cannot make every following relaunch chase the same unreachable build.
    check("a target a previous exec already tried is not folded in again",
          fold(attempted: "0.26.0") == nil)
    check("but a genuinely newer build still folds", fold(attempted: "0.25.5")?.target == "0.26.0")
    // The other half of that guarantee is structural: recording and exec'ing live in one function,
    // so no caller can do the second without the first.
    var attempted: String?
    execPlannedSelfUpdate(nil, attempted: &attempted, target: movedTo, follow: true,
                          recoveries: [], args: ["--resume", "abc"])
    check("nothing to fold leaves the attempt record untouched", attempted == nil)

    // 24e. The one piece of state a fold used to refuse to risk. A reload restarting a session that
    // is still waiting for a sibling to free up hands the pending cap to the next child, and
    // in-memory state does not survive the exec, so the fold stood the upgrade down and left it to
    // the next idle tick. It rides the argv now (section 32, capselfupdatechecks.swift), so the
    // refusal is gone and the fold happens whatever the relaunch is carrying.
    let capped = PendingCapRecovery(cappedAccountID: "acct-1", cappedAt: launch,
                                    primaryModel: "fable", recoveryResetsAt: nil,
                                    nextRetry: launch, reason: "waiting")
    check("a reload that carries a pending cap folds the upgrade in", fold()?.target == "0.26.0")
    check("and what it carries is handed to the exec rather than dropped",
          selfUpdateArgv(binary: "/usr/local/bin/tally", id: "acct-1", label: "A",
                         home: movedToHome, follow: true,
                         pendingCap: capCarriedAcrossRelaunch(capped, reason: "reload"),
                         args: []).contains(resupervisePendingCapFlag))
    check("a cap handoff carries nothing, so its exec carries nothing either",
          !selfUpdateArgv(binary: "/usr/local/bin/tally", id: "acct-1", label: "A",
                          home: movedToHome, follow: true,
                          pendingCap: capCarriedAcrossRelaunch(capped, reason: "cap"),
                          args: []).contains(resupervisePendingCapFlag))

    // 24f. The exec argv a fold produces: the plan's target and the plan's rewritten args, so the
    // new build resumes the same conversation where the handoff has just put it.
    let foldT0 = Date(timeIntervalSince1970: 1_800_000_000)
    var foldFuse = RecoveryFuse(max: 3, window: 600)
    for _ in 0 ..< 2 { _ = foldFuse.allows(now: foldT0); foldFuse.record(now: foldT0) }
    foldFuse.record(now: foldT0)   // the cap handoff this fold is riding on, recorded by the plan
    let carried = foldFuse.carried(now: foldT0)
    check("the restart the fold rides on is itself counted against the fuse", carried.count == 3)
    let argv = selfUpdateArgv(binary: "/usr/local/bin/tally", id: movedTo.id, label: movedTo.label,
                              home: fold()!.home, follow: true, recoveries: carried,
                              args: ["--resume", "abc", "--model", "fable"])
    check("the folded exec argv names the account the plan moved to", argv.contains(movedToHome))
    check("and not the one it left", !argv.contains(leftHome))
    check("the conversation is pinned by id, not left to a re-pick",
          argv.contains("--resume") && argv.contains("abc"))
    let ridden = parseResuperviseArgs(Array(argv.dropFirst(2)))
    check("the fuse still rides across a folded exec",
          ridden.recoveries == [foldT0, foldT0, foldT0])
    check("the home survives the folded round trip", ridden.home == movedToHome)
    check("so do the child args", ridden.childArgs == ["--resume", "abc", "--model", "fable"])
    var afterFold = RecoveryFuse(max: 3, window: 600, recovered: ridden.recoveries, now: foldT0)
    check("so the new build cannot hand the session a fresh recovery budget",
          !afterFold.allows(now: foldT0))

    // 24g. The args a plan's relaunch runs with, now shared by the respawn and the folded exec: the
    // new build must receive exactly what the child would have been given.
    check("a plan with no pairing leaves the resumed args untouched",
          planLaunchArgs(["--resume", "abc", "--model", "fable"],
                         plan: RelaunchPlan(target: movedTo, reason: "cap", countsFuse: true))
          == ["--resume", "abc", "--model", "fable"])
    check("a follow adoption replaces the pairing",
          planLaunchArgs(["--resume", "abc", "--model", "fable", "--effort", "xhigh"],
                         plan: RelaunchPlan(target: movedTo, reason: "follow", countsFuse: false,
                                            model: "opus", effort: "high"))
          == ["--resume", "abc", "--model", "opus", "--effort", "high"])
    check("the fallback profile's extra flags follow its pairing",
          planLaunchArgs(["--resume", "abc", "--model", "fable"],
                         plan: RelaunchPlan(target: movedTo, reason: "fallback", countsFuse: false,
                                            model: "sonnet", effort: "medium",
                                            extraArgs: ["--append-system-prompt", "x"]))
          == ["--resume", "abc", "--model", "sonnet", "--effort", "medium",
              "--append-system-prompt", "x"])

    // MARK: - 24h. The loop wiring

    // Neither end of the fold can be reached without spawning a child, so the source carries the
    // invariants (the same technique the follow dead end and the fuse carry use). Run from the repo
    // root (run-supervisor-tests.sh cds there), and a missing file FAILS rather than quietly passing.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from this suite", !loop.isEmpty)
    func at(_ needle: String, in haystack: String) -> Int? {
        haystack.range(of: needle).map { haystack.distance(from: haystack.startIndex,
                                                           to: $0.lowerBound) }
    }
    if let blockStart = loop.range(of: "// Execute the tick's one relaunch") {
        let block = String(loop[blockStart.lowerBound...])
        check("the plan's execution asks whether a pending update can ride along",
              block.contains("selfUpdateFold("))
        check("it asks against the account the plan moves to",
              block.contains("home: plan.target.launchHome"))
        // What the relaunch decided to hand on is what the exec is handed: one decision, so a
        // failed exec (which falls through to the respawn reading the same variable) and a
        // successful one cannot leave the session waiting for different things.
        check("and the cap the relaunch carries is handed to the exec, not dropped",
              block.contains("pendingCap: carriedCap"))
        check("the decision itself is still the relaunch's",
              block.contains("carriedCap = capCarriedAcrossRelaunch(pendingCap, reason: plan.reason)"))
        let decided = at("selfUpdateFold(", in: block)
        let killed = at("performHandoff(", in: block)
        let rewritten = at("launchArgs = planLaunchArgs(", in: block)
        let exec = at("execPlannedSelfUpdate(", in: block)
        check("the fold is decided before the child is terminated",
              decided != nil && killed != nil && decided! < killed!)
        check("the account switch happens before the exec, so a failed exec cannot lose it",
              killed != nil && exec != nil && killed! < exec!)
        check("the plan's args are rewritten before the exec is handed them",
              rewritten != nil && exec != nil && rewritten! < exec!)
        check("the exec is handed the plan's target, not the account left behind",
              block.contains("target: plan.target"))
        check("and the live fuse", block.contains("recoveries: fuse.carried()"))
        check("the rewritten args are what the new build receives",
              block.contains("args: launchArgs"))
    } else {
        check("the plan execution block was found", false)
    }
    // One exec site: a lone upgrade now plans its restart like every other reason and falls through
    // to the same block, so the "which account, which args, which fuse" answer cannot drift between
    // two copies.
    check("a lone upgrade plans its restart like any other reason",
          loop.contains("RelaunchPlan(target: account, reason: \"self-update\""))
    check("and the loop replaces the process in exactly one place",
          loop.range(of: "execSelfUpdate(") == nil)

    // Recording the attempt before exec'ing is now structural rather than a caller's discipline.
    let helper = (try? String(contentsOfFile: "TallyCLI/SelfUpdate.swift", encoding: .utf8)) ?? ""
    check("the self-update source is readable from this suite", !helper.isEmpty)
    if let helperStart = helper.range(of: "func execPlannedSelfUpdate(") {
        let body = String(helper[helperStart.lowerBound...])
        let record = at("attempted = upgrade.target", in: body)
        let call = at("execSelfUpdate(to:", in: body)
        check("a fold records the attempt before it execs, so a failed exec cannot loop",
              record != nil && call != nil && record! < call!)
    } else {
        check("the folded exec helper was found", false)
    }

    // MARK: - 25. The status line stops asking for something that happens by itself

    // Since 0.26.0 the supervisor replaces itself at the next idle moment (or on the next relaunch
    // it is making anyway, which is what the fold above adds), so "restart after update" described a
    // manual step that no longer exists.
    check("the outdated note describes what is already under way",
          SupervisionStatus.outdated.note == "supervisor updating at next idle")
    check("it no longer instructs the user to restart anything",
          SupervisionStatus.outdated.note?.contains("restart") == false)
    check("and it stays short enough for a status line",
          (SupervisionStatus.outdated.note?.count ?? 999) <= 40)
    // `unknown` still asks, and must: a supervisor too old to stamp its version is also too old to
    // self-update, so only the user can end that session.
    check("an unknown supervisor still asks for a restart",
          SupervisionStatus.unknown.note?.contains("restart") == true)
    check("a healthy supervisor still says nothing", SupervisionStatus.ok.note == nil)
}
