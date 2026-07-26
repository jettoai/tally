import Foundation

// The idle rebalance, split out for file size. Top-level statements can only live in main.swift, so
// these run as one function it calls; the harness (`check`, `failures`) and the fixed `launch` date
// are shared from there.
//
// The behaviour under test: the smart pick used to apply at launch and at cap handoff only, so a
// session placed well an hour ago rode its account all the way down (five sessions on an account
// whose flagship window was spent while a sibling held 77%, 2026-07-26). A session that is idle now
// makes the same move the cap handoff would make later, before the wall rather than after it.

func runRebalanceChecks() {
    // MARK: - 26. Which sessions move, and where to

    /// An account whose flagship window is the interesting one: session and weekly stay healthy, so
    /// `model` alone decides whether the account reads as dying for a fable session.
    func acct(_ id: String, model: Double, modelResetHours: Double = 100,
              provider: String = "claude", stale: Bool = false,
              error: String? = nil) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: provider, label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelResetsAt: launch.addingTimeInterval(modelResetHours * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil,
                         isStale: stale, error: error)
    }
    let dying = acct("A", model: 3)          // under the nearly-dry line, hours from resetting
    let healthy = acct("B", model: 77)
    let alsoDry = acct("C", model: 2)
    let primary = "fable"

    func target(mode: String = "auto", isQuiet: Bool = true, fuseAllows: Bool = true,
                already: Bool = false, current: Snapshot.Account = dying,
                candidates: [Snapshot.Account] = [healthy]) -> Snapshot.Account? {
        rebalanceTarget(mode: mode, isQuiet: isQuiet, fuseAllows: fuseAllows,
                        alreadyThisCycle: already, current: current, candidates: candidates,
                        primaryModel: primary, now: launch)
    }

    // The move this whole feature exists for.
    check("a dying account with a comfortable sibling moves at idle", target()?.id == "B")
    check("and it picks the healthiest sibling, not merely an eligible one",
          target(candidates: [alsoDry, healthy])?.id == "B")

    // Nothing to prevent: the session stays where it is.
    check("a comfortable account is left alone", target(current: acct("A", model: 40)) == nil)
    check("an account exactly on the nearly-dry line is dry enough to move",
          target(current: acct("A", model: nearlyDryPercent))?.id == "B")
    check("a hair above the line is not", target(current: acct("A", model: nearlyDryPercent + 0.1))
          == nil)
    // The comfort gate's imminent-reset exemption carries in for free: a window minutes from
    // refilling is a full window, and restarting a session to escape it would be pure churn.
    check("a spent window about to reset is not a dying account",
          target(current: acct("A", model: 3, modelResetHours: 0.1)) == nil)

    // Nowhere better to be. The handoff policy answers the same way (`requiringComfortable` keeps
    // nothing), and a proactive move to an equally spent account is churn for its own sake.
    check("no comfortable sibling means stay put", target(candidates: [alsoDry]) == nil)
    check("no sibling at all means stay put", target(candidates: []) == nil)

    // A pin is a statement about WHERE the session runs, so quota reasoning never overrides it. The
    // cap handoff already refuses to move a pinned session (`CapAction.waitPinned`); a convenience
    // must not do what a repair will not.
    check("a pinned session is never rebalanced", target(mode: "manual") == nil)

    // Non-urgent by construction: this is a convenience, so it may never cost a keystroke or cut a
    // turn. The bar is the full "left alone" one (transcript, subagents, open tool call, keyboard).
    check("a session in use is not moved", target(isQuiet: false) == nil)

    // MARK: - 26b. The two guardrails

    // The recovery fuse, shared with cap recoveries: a session already moved three times in ten
    // minutes has a systemic problem that a fourth move will not cure.
    let fuseT0 = launch
    var fuse = RecoveryFuse(max: 3, window: 600)
    check("a fresh fuse lets a rebalance through", target(fuseAllows: fuse.allows(now: fuseT0))?.id
          == "B")
    for _ in 0 ..< 2 { _ = fuse.allows(now: fuseT0); fuse.record(now: fuseT0) }
    check("two automatic moves spent still leaves room",
          target(fuseAllows: fuse.allows(now: fuseT0))?.id == "B")
    fuse.record(now: fuseT0)
    check("the fourth automatic move is refused", target(fuseAllows: fuse.allows(now: fuseT0)) == nil)
    check("and the fuse itself is what refuses it", !fuse.allows(now: fuseT0))
    check("once the window has passed it is allowed again",
          target(fuseAllows: fuse.allows(now: fuseT0.addingTimeInterval(601)))?.id == "B")

    // One move per account per window cycle, shared across supervisors: without it the five sessions
    // on one dying account all read the same picture on the same tick and stampede onto the one
    // healthy sibling.
    check("an account already rebalanced this cycle is left alone", target(already: true) == nil)

    // MARK: - 26c. The cycle key

    // Derived from the BINDING window's reset time, in whole seconds: the same derivation the app's
    // per-cycle dedup uses (DryPoolLogic.resetKey, via ResetHintLogic), so a record survives
    // sub-second jitter in a reported reset without reading as a new cycle, and re-arms by itself
    // when the window that made the account dry actually refills.
    let modelResetsAt = launch.addingTimeInterval(100 * 3600)
    check("the key names the binding window's reset",
          rebalanceCycleKey(dying, primaryModel: primary, now: launch)
          == String(Int(modelResetsAt.timeIntervalSince1970.rounded())))
    check("sub-second jitter is not a new cycle",
          rebalanceCycleKey(acct("A", model: 3, modelResetHours: 100 + 0.4 / 3600),
                            primaryModel: primary, now: launch)
          == rebalanceCycleKey(dying, primaryModel: primary, now: launch))
    // The binding window is the emptiest one, not a fixed one: an account whose SESSION window is
    // the spent one is bound by that reset, and that is the cycle its record belongs to.
    var sessionBound = acct("A", model: 90)
    sessionBound.sessionRemaining = 2
    check("a session-bound account keys off the session reset",
          rebalanceCycleKey(sessionBound, primaryModel: primary, now: launch)
          == String(Int(launch.addingTimeInterval(4 * 3600).timeIntervalSince1970.rounded())))
    // With no cycle to name there is nothing to dedup against, and an un-deduped rebalance is the
    // stampede the record exists to prevent, so both of these mean "do not move".
    var noReset = acct("A", model: 3)
    noReset.modelResetsAt = nil
    check("a binding window with no known reset has no cycle",
          rebalanceCycleKey(noReset, primaryModel: primary, now: launch) == nil)
    var noWindows = acct("A", model: 3)
    (noWindows.sessionRemaining, noWindows.weeklyRemaining, noWindows.modelRemaining) = (nil, nil, nil)
    check("an account reporting no windows has no cycle",
          rebalanceCycleKey(noWindows, primaryModel: primary, now: launch) == nil)

    // MARK: - 26d. The shared record

    let recordDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-\(UUID().uuidString)")
    let cycleOne = "1800000000", cycleTwo = "1800360000"
    check("an account that has never been rebalanced is not blocked",
          !rebalancedThisCycle("acct-1", cycle: cycleOne, dir: recordDir))
    recordRebalance("acct-1", cycle: cycleOne, dir: recordDir)
    check("the account it names is blocked for that cycle",
          rebalancedThisCycle("acct-1", cycle: cycleOne, dir: recordDir))
    check("another account is not", !rebalancedThisCycle("acct-2", cycle: cycleOne, dir: recordDir))
    check("and the window resetting re-arms it: a new cycle is a fresh opportunity",
          !rebalancedThisCycle("acct-1", cycle: cycleTwo, dir: recordDir))
    recordRebalance("acct-1", cycle: cycleTwo, dir: recordDir)
    check("which then blocks in its turn",
          rebalancedThisCycle("acct-1", cycle: cycleTwo, dir: recordDir))
    check("and the old cycle no longer does",
          !rebalancedThisCycle("acct-1", cycle: cycleOne, dir: recordDir))
    // An id with a slash must not write one file and read another (the quarantine's rule next door).
    recordRebalance("team/acct", cycle: cycleOne, dir: recordDir)
    check("an id with a slash round-trips through the record",
          rebalancedThisCycle("team/acct", cycle: cycleOne, dir: recordDir))
    try? FileManager.default.removeItem(at: recordDir)

    // MARK: - 26e. One tick's decision against the live picture

    let moveDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
    func snapshot(_ accounts: [Snapshot.Account]) -> Snapshot {
        Snapshot(version: 2, generatedAt: launch, accounts: accounts)
    }
    func move(_ accounts: [Snapshot.Account], problem: String? = nil, mode: String = "auto",
              isQuiet: Bool = true, fuseAllows: Bool = true,
              quarantine: [String: (model: String?, until: Date)] = [:],
              on: Snapshot.Account = dying) -> (target: Snapshot.Account, cycle: String)? {
        rebalanceMove(provider: "claude", account: on, primaryModel: primary, mode: mode,
                      isQuiet: isQuiet, fuseAllows: fuseAllows, quarantine: quarantine,
                      loaded: (snapshot(accounts), problem), now: launch, dir: moveDir)
    }
    check("a tick with a dying account and a healthy sibling answers with the sibling",
          move([dying, healthy])?.target.id == "B")
    check("and with the cycle the caller must record",
          move([dying, healthy])?.cycle == rebalanceCycleKey(dying, primaryModel: primary,
                                                             now: launch))
    // The account the loop carries was fixed at LAUNCH, and after a self-update exec it has no
    // quota fields at all, so the numbers have to come from the snapshot. This is that case: the
    // struct passed in claims nothing, and the snapshot's copy of it is what is dying.
    let carried = Snapshot.Account(id: "A", provider: "claude", label: "A", launchHome: "/tmp/A",
                                   sessionRemaining: nil, weeklyRemaining: nil, modelRemaining: nil,
                                   sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                                   modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                                   error: nil)
    check("the live snapshot decides, not the account struct the session was launched with",
          move([dying, healthy], on: carried)?.target.id == "B")
    // A snapshot too old to trust answers nothing, exactly as the cap handoff refuses to pick a
    // target on stale numbers.
    check("a stale snapshot moves nobody", move([dying, healthy], problem: "snapshot is 40m old")
          == nil)
    check("an account missing from the snapshot moves nobody",
          move([healthy], on: dying) == nil)
    check("a quarantined sibling is not a target",
          move([dying, healthy],
               quarantine: ["B": (model: primary, until: launch.addingTimeInterval(600))]) == nil)
    check("a sibling on another provider is not a target",
          move([dying, acct("codex-1", model: 77, provider: "codex")]) == nil)
    check("an errored sibling is not a target", move([dying, acct("B", model: 77, error: "boom")])
          == nil)
    check("a stale-flagged sibling is not a target", move([dying, acct("B", model: 77, stale: true)])
          == nil)
    check("a pinned session still moves nobody here", move([dying, healthy], mode: "manual") == nil)
    check("a session in use still moves nobody here", move([dying, healthy], isQuiet: false) == nil)
    check("a spent fuse still moves nobody here", move([dying, healthy], fuseAllows: false) == nil)
    // The per-cycle record is consulted through this path too, which is the one the loop uses.
    let liveCycle = rebalanceCycleKey(dying, primaryModel: primary, now: launch)!
    recordRebalance("A", cycle: liveCycle, dir: moveDir)
    check("an account already moved this cycle is refused on the live path too",
          move([dying, healthy]) == nil)
    try? FileManager.default.removeItem(at: moveDir)

    // MARK: - 26f. The loop wiring

    // The decision is reachable in a test; its placement in the tick is not, so the source carries
    // it (the technique the follow dead end, the fuse carry, and the self-update fold all use).
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the rebalance checks", !loop.isEmpty)
    func at(_ needle: String) -> Int? {
        loop.range(of: needle).map { loop.distance(from: loop.startIndex, to: $0.lowerBound) }
    }
    check("the tick asks for a proactive move", loop.contains("rebalanceMove("))
    check("it only asks when nothing else is already relaunching",
          loop.contains("if plan == nil, let move = rebalanceMove("))
    check("it waits for the full left-alone bar, transcript and keyboard alike",
          loop.contains("watcher.isQuiet(followIdleSeconds) && keyboardIdleNow(followIdleSeconds)"))
    check("the move counts against the recovery fuse",
          loop.contains("RelaunchPlan(target: move.target, reason: \"rebalance\", countsFuse: true)"))
    check("and the cycle is recorded so no sibling supervisor repeats it",
          loop.contains("recordRebalance(account.id, cycle: move.cycle)"))
    check("the user is told what is happening and why",
          loop.contains("nearly dry, moving to") && loop.contains("before the wall"))
    // Placement: last of the account moves (every other one is repairing something), and it goes
    // through the shared plan, which is what makes a pending self-update fold into its restart.
    if let rebalance = at("// Idle rebalance:"), let fallback = at("// Fallback profile:"),
       let selfUpdate = at("// The app updated under this supervisor"),
       let execution = at("// Execute the tick's one relaunch") {
        check("the rebalance is considered after every repair path", fallback < rebalance)
        check("and before the self-update, so a pending upgrade folds into its restart",
              rebalance < selfUpdate)
        check("it plans a relaunch rather than performing one", rebalance < execution)
    } else {
        // A missing marker is the block being gone, which is a failure to report rather than a
        // crash: these run against whatever the source says, including a source that lost the block.
        check("the rebalance block and its neighbours were found in the tick", false)
    }
}
