import Foundation

// The idle rebalance, split out for file size. Top-level statements can only live in main.swift, so
// these run as one function it calls; the harness (`check`, `failures`) and the fixed `launch` date
// are shared from there.
//
// The behaviour under test: the smart pick used to apply at launch and at cap handoff only, so a
// session placed well an hour ago rode its account all the way down (five sessions on an account
// whose flagship window was spent while a sibling held 77%, 2026-07-26). A session that is idle now
// makes the same move the cap handoff would make later, before the wall rather than after it.

/// What 32 racing threads share while they pile up behind one barrier and then claim at once. Held
/// in a reference because the barrier has to be released AFTER the threads have captured it, which a
/// captured `var` cannot be (Swift warns, correctly, that they would be mutating a copy).
private final class ClaimRace {
    let gate = NSCondition()
    var ready = 0, done = 0, wins = 0, released = false
}

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
                current: Snapshot.Account = dying,
                candidates: [Snapshot.Account] = [healthy],
                claim: () -> Bool = { true }) -> Snapshot.Account? {
        rebalanceTarget(mode: mode, isQuiet: isQuiet, fuseAllows: fuseAllows,
                        current: current, candidates: candidates,
                        primaryModel: primary, now: launch, claim: claim)
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
    check("an account whose cycle another supervisor holds is left alone",
          target(claim: { false }) == nil)

    // The claim is the one gate with a side effect, so it is asked LAST. A tick that was never going
    // to move must not spend this account's one move of the cycle and leave it stuck until the
    // window resets.
    func claimAsked(mode: String = "auto", isQuiet: Bool = true, fuseAllows: Bool = true,
                    current: Snapshot.Account = dying,
                    candidates: [Snapshot.Account] = [healthy]) -> Bool {
        var asked = false
        _ = target(mode: mode, isQuiet: isQuiet, fuseAllows: fuseAllows, current: current,
                   candidates: candidates, claim: { asked = true; return true })
        return asked
    }
    check("a move that happens claims the cycle", claimAsked())
    check("a pinned session does not spend the cycle", !claimAsked(mode: "manual"))
    check("a session in use does not spend the cycle", !claimAsked(isQuiet: false))
    check("a spent fuse does not spend the cycle", !claimAsked(fuseAllows: false))
    check("a comfortable account does not spend the cycle",
          !claimAsked(current: acct("A", model: 40)))
    check("and neither does having nowhere better to go", !claimAsked(candidates: [alsoDry]))

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
    // The binding window is the emptiest one the COMFORT GATE sees, which is not always the emptiest
    // raw number: the gate counts a window resetting within ten minutes as already refilled
    // (`imminentResetGrace`). A session at 3% resetting in five minutes under a weekly at 4% is a
    // weekly drought, and the weekly's reset is the one that ends it. Keying off the session would
    // expire the claim five minutes later and move the same session a second time, mid-drought.
    var driedByWeekly = acct("A", model: 90, modelResetHours: 50)
    (driedByWeekly.sessionRemaining, driedByWeekly.weeklyRemaining) = (3, 4)
    driedByWeekly.sessionResetsAt = launch.addingTimeInterval(5 * 60)
    let weeklyCycle = String(Int(launch.addingTimeInterval(100 * 3600).timeIntervalSince1970
                                 .rounded()))
    check("a window minutes from resetting does not bind the cycle key",
          rebalanceCycleKey(driedByWeekly, primaryModel: primary, now: launch) == weeklyCycle)
    // And the drought outlives that refill: five minutes on, the session window is full again and
    // the account is still bound by the same weekly, so it is still the same cycle.
    var afterSessionRefill = driedByWeekly
    afterSessionRefill.sessionRemaining = 100
    afterSessionRefill.sessionResetsAt = launch.addingTimeInterval(5 * 3600)
    check("and the cycle is unchanged once that window actually refills",
          rebalanceCycleKey(afterSessionRefill, primaryModel: primary,
                            now: launch.addingTimeInterval(6 * 60)) == weeklyCycle)
    // Which is the whole point, stated as the claim sees it: one unbroken drought is one cycle, so
    // the claim taken at the start of it still holds at the end and the session is moved once.
    check("one drought is one cycle from end to end",
          rebalanceCycleKey(driedByWeekly, primaryModel: primary, now: launch)
          == rebalanceCycleKey(afterSessionRefill, primaryModel: primary,
                               now: launch.addingTimeInterval(6 * 60)))

    // With no cycle to name there is nothing to claim, and an unclaimed rebalance is the stampede
    // the claim exists to prevent, so both of these mean "do not move".
    var noReset = acct("A", model: 3)
    noReset.modelResetsAt = nil
    check("a binding window with no known reset has no cycle",
          rebalanceCycleKey(noReset, primaryModel: primary, now: launch) == nil)
    var noWindows = acct("A", model: 3)
    (noWindows.sessionRemaining, noWindows.weeklyRemaining, noWindows.modelRemaining) = (nil, nil, nil)
    check("an account reporting no windows has no cycle",
          rebalanceCycleKey(noWindows, primaryModel: primary, now: launch) == nil)

    // MARK: - 26d. The shared claim

    let recordDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-\(UUID().uuidString)")
    let cycleOne = "1800000000", cycleTwo = "1800360000"
    check("the first supervisor to ask for an untouched cycle gets it",
          claimRebalanceCycle("acct-1", cycle: cycleOne, dir: recordDir))
    check("and every one after it is refused",
          !claimRebalanceCycle("acct-1", cycle: cycleOne, dir: recordDir))
    check("another account is unaffected",
          claimRebalanceCycle("acct-2", cycle: cycleOne, dir: recordDir))
    check("and the window resetting re-arms it: a new cycle is a fresh opportunity",
          claimRebalanceCycle("acct-1", cycle: cycleTwo, dir: recordDir))
    check("which is then held in its turn",
          !claimRebalanceCycle("acct-1", cycle: cycleTwo, dir: recordDir))
    // An id with a slash must not write one file and read another (the quarantine's rule next door).
    check("an id with a slash claims once", claimRebalanceCycle("team/acct", cycle: cycleOne,
                                                                dir: recordDir))
    check("and not twice", !claimRebalanceCycle("team/acct", cycle: cycleOne, dir: recordDir))
    // Ids on this machine carry dots ("claude:.claude3"), and the cycle is whole seconds, so the
    // account half of a claim's name is everything before the LAST dot and nothing is ambiguous.
    check("a dotted id claims once", claimRebalanceCycle("claude:.claude3", cycle: cycleOne,
                                                         dir: recordDir))
    check("and not twice", !claimRebalanceCycle("claude:.claude3", cycle: cycleOne, dir: recordDir))
    check("without disturbing the account whose id is its prefix",
          claimRebalanceCycle("claude:", cycle: cycleOne, dir: recordDir))

    // A dying drought does not re-arm when some other window refills under it: the cycle key is the
    // same, so the claim taken during it still holds (26c's weekly drought, five minutes on).
    check("the drought's claim is taken once",
          claimRebalanceCycle("acct-drought", cycle: weeklyCycle, dir: recordDir))
    check("and a session window refilling under it does not hand out a second move",
          !claimRebalanceCycle("acct-drought",
                               cycle: rebalanceCycleKey(afterSessionRefill, primaryModel: primary,
                                                        now: launch.addingTimeInterval(6 * 60))!,
                               dir: recordDir))

    // Claims from cycles that are over are dropped as they are noticed, so the directory does not
    // grow one file per window cycle forever. The cycle being claimed is never swept: a reset time
    // the snapshot has not caught up with is in the past and still the cycle we are in.
    func claimExists(_ accountID: String, cycle: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir
            .appendingPathComponent(rebalanceClaimName(accountID, cycle: cycle)).path)
    }
    let past = "1000000000"   // a reset in 2001: over by any clock this ever runs on
    _ = claimRebalanceCycle("acct-sweep", cycle: past, dir: recordDir)
    check("a claim lands on disk", claimExists("acct-sweep", cycle: past, in: recordDir))
    _ = claimRebalanceCycle("acct-sweep", cycle: cycleTwo, dir: recordDir)
    check("a claim whose reset has come and gone is swept on the way past",
          !claimExists("acct-sweep", cycle: past, in: recordDir))
    check("but the one just taken is not",
          claimExists("acct-sweep", cycle: cycleTwo, in: recordDir))
    check("and so it still holds", !claimRebalanceCycle("acct-sweep", cycle: cycleTwo,
                                                        dir: recordDir))
    check("a sweep for one account leaves another account's claims alone",
          claimExists("acct-1", cycle: cycleTwo, in: recordDir))

    // Records written before the claim existed (a bare per-account file whose body is the cycle) sit
    // in ~/.tally/rebalance on every machine that has run this feature. One is honoured for the
    // cycle it names, so upgrading mid-drought does not hand out a second move, and dropped once it
    // names a cycle that is over.
    func writeLegacy(_ accountID: String, cycle: String) {
        try? cycle.write(to: recordDir.appendingPathComponent(rebalanceRecordName(accountID)),
                         atomically: true, encoding: .utf8)
    }
    writeLegacy("acct-legacy", cycle: cycleOne)
    check("a record from the old shape still blocks its own cycle",
          !claimRebalanceCycle("acct-legacy", cycle: cycleOne, dir: recordDir))
    check("but not another one", claimRebalanceCycle("acct-legacy", cycle: cycleTwo,
                                                     dir: recordDir))
    check("and it is dropped on the way past, not left to block forever",
          !FileManager.default.fileExists(atPath: recordDir
              .appendingPathComponent(rebalanceRecordName("acct-legacy")).path))

    // MARK: - 26d-jitter. A reported reset that moves is still one drought

    // Reset times are parsed out of `/usage`'s human text, whose finest unit is the minute, so one
    // unbroken window is reported a minute later or earlier as the underlying instant rounds one way
    // or the other. Matching cycles by equality read that wobble as a new cycle and handed the
    // account a second move: Claude 2's session window at 1% moved two sessions ten minutes apart on
    // 2026-08-02, leaving claims for that ONE window at 06:39:00Z and 06:40:00Z, and Claude's spent
    // weekly did the same twenty-four minutes apart (16:59:00Z and 17:00:00Z) the same morning.
    // Dated well ahead so no claim here is ever swept for being over on the wall clock: what these
    // assert is the OFFSETS, and the incident's own two claims were 60s apart in exactly this way.
    // The expired case has its own account below, where being in the past is the point.
    let reported = 1_900_000_000.0
    func jitterClaim(_ accountID: String, _ offset: Double) -> Bool {
        claimRebalanceCycle(accountID, cycle: String(Int(reported + offset)), dir: recordDir)
    }
    check("the drought's claim is taken", jitterClaim("acct-jitter", 0))
    check("the same window reported a minute later is not a second move",
          !jitterClaim("acct-jitter", 60))
    check("nor is a minute earlier", !jitterClaim("acct-jitter", -60))
    check("nor anything else inside the tolerance",
          !jitterClaim("acct-jitter", rebalanceCycleTolerance))
    // Nothing lands on disk for the moves that were refused, so the near miss cannot come back as a
    // record of its own.
    check("a refused near miss leaves no claim behind",
          !claimExists("acct-jitter", cycle: String(Int(reported + 60)), in: recordDir))
    // The re-arm the tolerance must not swallow: windows are hours long, so a genuine new cycle is
    // never a few minutes away. The 5h session window is the shortest one there is.
    check("the window actually resetting five hours on is a new drought",
          jitterClaim("acct-jitter", 5 * 3600))
    check("which is then held in its turn", !jitterClaim("acct-jitter", 5 * 3600))
    check("and the drought before it still holds too", !jitterClaim("acct-jitter", 0))

    // A claim whose reset has passed is normally swept, but not while it is still THIS drought's:
    // a reset time the snapshot has not caught up with is in the past and still the cycle we are in,
    // which is exactly the case the tolerance exists for.
    check("a claim from a past drought is taken", claimRebalanceCycle("acct-jitter-past",
                                                                      cycle: past, dir: recordDir))
    check("and a reading a minute off it is still the same drought, expired or not",
          !claimRebalanceCycle("acct-jitter-past", cycle: String(Int(past)! + 60), dir: recordDir))
    check("so the claim survives the sweep it walked past",
          claimExists("acct-jitter-past", cycle: past, in: recordDir))

    // The pre-claim shape carries a cycle in its BODY and one is live on this machine
    // (~/.tally/rebalance/claude:.claude3), so it must not hand out the second move either.
    writeLegacy("acct-legacy-jitter", cycle: String(Int(reported)))
    check("a record from the old shape blocks a reading a minute off its own",
          !claimRebalanceCycle("acct-legacy-jitter", cycle: String(Int(reported + 60)),
                               dir: recordDir))
    check("and is still dropped once the window really has reset",
          claimRebalanceCycle("acct-legacy-jitter", cycle: String(Int(reported + 5 * 3600)),
                              dir: recordDir))

    // The whole point of the claim: N supervisors whose 2s ticks land in the same window ask at
    // once, and exactly one of them moves. A read followed by a write leaves the gap this closes.
    let racers = 32
    /// How many of `racers` threads win one cycle, all of them released from a barrier together.
    func racedWins(cycle: String) -> Int {
        let race = ClaimRace()
        for _ in 0 ..< racers {
            Thread {
                race.gate.lock()
                race.ready += 1
                race.gate.broadcast()
                while !race.released { race.gate.wait() }
                race.gate.unlock()
                let won = claimRebalanceCycle("acct-race", cycle: cycle, dir: recordDir)
                race.gate.lock()
                if won { race.wins += 1 }
                race.done += 1
                race.gate.broadcast()
                race.gate.unlock()
            }.start()
        }
        race.gate.lock()
        while race.ready < racers { race.gate.wait() }   // every thread is parked on the barrier
        race.released = true
        race.gate.broadcast()
        while race.done < racers { race.gate.wait() }
        race.gate.unlock()
        return race.wins
    }
    // Repeated, because one round is a weak instrument: waking 32 threads through one lock lets them
    // out in a staggered line, so a read-then-write claim can still happen to hand out exactly one
    // move (measured 5, 2 and 1 winners on three runs of a deliberately broken build). An atomic
    // claim answers 1 in every round by construction, so requiring that of all of them turns a
    // coin-flip into a check that a torn claim cannot pass.
    // An hour apart, because rounds are meant to be DISTINCT droughts and a claim now holds for
    // every key within a few minutes of it (26d-jitter below).
    let rounds = (0 ..< 8).map { racedWins(cycle: String(1_800_000_000 + $0 * 3600)) }
    check("exactly one of 32 simultaneous supervisors claims the cycle, every round (won: \(rounds))",
          rounds.allSatisfy { $0 == 1 })
    try? FileManager.default.removeItem(at: recordDir)

    // MARK: - 26e. One tick's decision against the live picture

    // An answer here TAKES the cycle's claim, so each check that expects a move gets its own
    // directory rather than inheriting the claim the previous one made. The claim's own behaviour
    // on this path is asserted below, against one shared directory on purpose.
    var scratchDirs: [URL] = []
    func snapshot(_ accounts: [Snapshot.Account]) -> Snapshot {
        Snapshot(version: 2, generatedAt: launch, accounts: accounts)
    }
    func move(_ accounts: [Snapshot.Account], problem: String? = nil, mode: String = "auto",
              isQuiet: Bool = true, fuseAllows: Bool = true,
              quarantine: [String: (model: String?, until: Date)] = [:],
              on: Snapshot.Account = dying, dir: URL? = nil) -> Snapshot.Account? {
        var target = dir
        if target == nil {
            let fresh = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
            scratchDirs.append(fresh)
            target = fresh
        }
        return rebalanceMove(provider: "claude", account: on, primaryModel: primary, mode: mode,
                             isQuiet: isQuiet, fuseAllows: fuseAllows, quarantine: quarantine,
                             loaded: (snapshot(accounts), problem), now: launch, dir: target!)
    }
    check("a tick with a dying account and a healthy sibling answers with the sibling",
          move([dying, healthy])?.id == "B")
    // Answering IS claiming, so a sibling supervisor asking the same question a moment later is
    // refused. There is no window between deciding to move and recording it for a second supervisor
    // to decide the same move in, and no caller left holding a record it could forget to write.
    let moveDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
    check("the first supervisor to ask moves", move([dying, healthy], dir: moveDir)?.id == "B")
    check("and the second is refused, on the live path too",
          move([dying, healthy], dir: moveDir) == nil)
    check("the claim it took is the one the cycle key names",
          claimExists(dying.id, cycle: rebalanceCycleKey(dying, primaryModel: primary,
                                                         now: launch)!, in: moveDir))
    // The account the loop carries was fixed at LAUNCH, and after a self-update exec it has no
    // quota fields at all, so the numbers have to come from the snapshot. This is that case: the
    // struct passed in claims nothing, and the snapshot's copy of it is what is dying.
    let carried = Snapshot.Account(id: "A", provider: "claude", label: "A", launchHome: "/tmp/A",
                                   sessionRemaining: nil, weeklyRemaining: nil, modelRemaining: nil,
                                   sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                                   modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                                   error: nil)
    check("the live snapshot decides, not the account struct the session was launched with",
          move([dying, healthy], on: carried)?.id == "B")
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
    // None of those refusals spent the cycle: an account that was pinned, busy or out of fuse when
    // the tick ran is still free to move the moment those clear.
    let sparedDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
    _ = move([dying, healthy], mode: "manual", dir: sparedDir)
    _ = move([dying, healthy], isQuiet: false, dir: sparedDir)
    _ = move([dying, healthy], fuseAllows: false, dir: sparedDir)
    _ = move([dying, alsoDry], dir: sparedDir)
    check("a tick that refused to move leaves the cycle's claim untaken",
          move([dying, healthy], dir: sparedDir)?.id == "B")

    // The incident end to end, on the path that produced it. An account whose SESSION window is the
    // spent one keys off that window's reset, and that reset is reported to the minute: the same 1%
    // window read 06:39 on one poll and 06:40 on the next, and Claude 2 handed out a second move ten
    // minutes after the first (2026-08-02). One drought is one move, however the clock is reported.
    let driftDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
    var driedSession = acct("A", model: 90)
    driedSession.sessionRemaining = 1
    check("the first tick on a spent session window moves",
          move([driedSession, healthy], on: driedSession, dir: driftDir)?.id == "B")
    var slipped = driedSession
    slipped.sessionResetsAt = driedSession.sessionResetsAt!.addingTimeInterval(60)
    check("and the same window reported a minute later does not move a second session",
          move([slipped, healthy], on: slipped, dir: driftDir) == nil)
    // What must still get through: the window really did reset, five hours on, and was drained
    // again. That is a new drought and it gets its own move.
    var nextWindow = driedSession
    nextWindow.sessionResetsAt = driedSession.sessionResetsAt!.addingTimeInterval(5 * 3600)
    check("but a window that actually reset and drained again is moved once more",
          move([nextWindow, healthy], on: nextWindow, dir: driftDir)?.id == "B")
    try? FileManager.default.removeItem(at: driftDir)
    for dir in scratchDirs + [moveDir, sparedDir] {
        try? FileManager.default.removeItem(at: dir)
    }

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
          loop.contains("if plan == nil, let moveTo = rebalanceMove("))
    check("it waits for the full left-alone bar, transcript and keyboard alike",
          loop.contains("watcher.isQuiet(followIdleSeconds) && keyboard.idle(followIdleSeconds)"))
    check("the move counts against the recovery fuse",
          loop.contains("RelaunchPlan(target: moveTo, reason: \"rebalance\", countsFuse: true)"))
    // The cycle is claimed inside the decision, so the loop has nothing to record and no way to
    // forget: a target it never got is a cycle it never took.
    check("the loop keeps no rebalance record of its own", !loop.contains("recordRebalance("))
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
