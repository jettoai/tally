import Foundation

// A PIN IS A PRIORITY, NOT A CAGE (B-1540, Albert 2026-10-12). The account a pin names is where a
// session runs while it has quota; when it runs out the session steps aside to the smart pick, and
// when it refills the pin switch carries the session home at a quiet moment. Until this the APP's
// own pin never yielded, so a session under it sat on the wall for up to five hours.
//
// The cells follow one session through the four steps the owner asked for (out of quota, stepped
// aside, refilled, home again), then the surfaces that say so (`pinAwayAccount`) and the new launch
// that steps aside before it starts (`pinStepAsideRow`).

func runPinPriorityChecks() {
    let pNow = Date(timeIntervalSince1970: 1_800_000_000)

    func pinAccount(_ id: String, model: Double?, label: String? = nil,
                    resetsIn: TimeInterval = 100 * 3600, stale: Bool = false,
                    windows: Bool = true) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label ?? id, launchHome: "/tmp/\(id)",
                         sessionRemaining: windows ? 90 : nil, weeklyRemaining: windows ? 90 : nil,
                         modelRemaining: model,
                         sessionResetsAt: pNow.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: pNow.addingTimeInterval(100 * 3600),
                         modelResetsAt: pNow.addingTimeInterval(resetsIn),
                         modelWindowName: "fable", resetCreditsAvailable: nil, isStale: stale,
                         error: nil, refreshedAt: pNow)
    }
    let healthyP = pinAccount("P", model: 60, label: "Claude 4")
    let emptyP = pinAccount("P", model: 0, label: "Claude 4")
    let fullP = pinAccount("P", model: 100, label: "Claude 4")
    let sibling = pinAccount("S", model: 80, label: "Claude 3")
    var appPinned = LaunchPolicy()
    appPinned.mode = "manual"
    appPinned.pinnedAccountID = "P"
    var appAuto = LaunchPolicy()
    appAuto.mode = "auto"
    func snapshot(_ rows: [Snapshot.Account], at moment: Date? = nil) -> (Snapshot?, String?) {
        (Snapshot(version: 2, generatedAt: moment ?? pNow, accounts: rows), nil)
    }

    /// The fleet as the tick reads it: the drought watch over `rows`, then the release.
    func released(_ fleet: LaunchPolicy, on current: Snapshot.Account,
                  rows: [Snapshot.Account]) -> (moving: LaunchPolicy, spent: Bool) {
        var watch = DroughtWatch()
        watch.observe(provider: "claude", account: current, primaryModel: "fable",
                      pinned: fleet.pinnedAccountID, loaded: snapshot(rows), now: pNow)
        let yields = pinYieldsToSpentAccount(pinnedSpent: watch.pinnedSpent,
                                             pinnedUnderReserve: false)
        return (pinReleasedPolicy(fleet, yielding: yields), watch.pinnedSpent)
    }
    /// A cap on `current`, handed off under `fleet`.
    func capTick(_ fleet: LaunchPolicy, on current: Snapshot.Account, rows: [Snapshot.Account],
                 sessionPin: String? = nil) -> (plan: RelaunchPlan?, pending: PendingCapRecovery?) {
        var plan: RelaunchPlan?
        var pending: PendingCapRecovery? = PendingCapRecovery(
            cappedAccountID: current.id, cappedAt: pNow, primaryModel: "fable",
            recoveryResetsAt: nil, nextRetry: .distantPast, reason: "")
        applyCapHandoff(plan: &plan, pendingCap: &pending, account: current, providerID: "claude",
                        fleet: fleet, steering: true, sessionPin: sessionPin, quarantine: [:],
                        fuseAllows: true, now: pNow, loaded: snapshot(rows))
        return (plan, pending)
    }
    let switchDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-pinpriority-\(UUID().uuidString)")
    /// The pin switch on a tick where the session sits on `on`.
    func pinTick(_ policy: LaunchPolicy, on current: Snapshot.Account, rows: [Snapshot.Account],
                 sessionPin: String? = nil,
                 quarantine: [String: (model: String?, until: Date)] = [:],
                 watcher busy: TranscriptWatcher? = nil, typing: Bool = false)
        -> (plan: RelaunchPlan?, waiting: PendingBadge?) {
        var watcher = busy ?? idleWatcher("pinpriority")
        var plan: RelaunchPlan?
        var state = ManualMoveState(sessionKey: "4242", servedEpoch: 100, sessionPin: sessionPin,
                                    dir: switchDir)
        var record: PendingSwitchConsumption?
        var under = policy
        applyManualMoves(plan: &plan, state: &state, record: &record, policy: &under,
                         account: current, providerID: "claude", primaryModel: "fable",
                         quarantine: quarantine, watcher: &watcher,
                         childAge: 9999, keyboardIdle: { _ in !typing }, dir: switchDir,
                         request: { _ in nil }, accounts: { rows },
                         loaded: { switchFleetReading(rows) },
                         quarantineIn: switchQuarantineDir)
        return (plan, state.waiting)
    }
    func rebalances(_ mode: String, from current: Snapshot.Account,
                    to candidates: [Snapshot.Account]) -> Snapshot.Account? {
        rebalanceTarget(steering: true, mode: mode, blocked: false, agentsWorking: false,
                        isQuiet: true, carryable: true, fuseAllows: true, current: current,
                        candidates: candidates, primaryModel: "fable", now: pNow)
    }

    // MARK: - Step 1. Out of quota: the session on the pinned account hits the wall

    // T1. The snapshot still reads P healthy (the usual shape: the app polls every minute or two).
    let lagging = released(appPinned, on: healthyP, rows: [healthyP, sibling])
    check("a lagging snapshot does not release the app's pin on its own", !lagging.spent)
    let wallLagging = capTick(lagging.moving, on: healthyP, rows: [healthyP, sibling])
    check("but a cap on the pinned account hands the session on anyway (the wall is the evidence)",
          wallLagging.plan?.reason == "cap" && wallLagging.plan?.target.id == "S")
    // T2. The snapshot has caught up.
    let caughtUp = released(appPinned, on: emptyP, rows: [emptyP, sibling])
    check("an empty pinned account releases the app's pin",
          caughtUp.spent && caughtUp.moving.mode == "auto")
    check("…and the cap hands the session to the sibling",
          capTick(caughtUp.moving, on: emptyP, rows: [emptyP, sibling]).plan?.target.id == "S")
    // T12. A session pin on the same account, over the app's pin on it.
    check("a session pin and the app's pin both naming the wall let the cap pick for itself", {
        let reading = capReading(fleet: appPinned, sessionPin: "P", candidates: [sibling],
                                 capped: "P")
        return reading.mode == "auto" && reading.preferred == nil
    }())
    check("…and the cap lands on the sibling",
          capTick(appPinned, on: healthyP, rows: [healthyP, sibling],
                  sessionPin: "P").plan?.target.id == "S")

    // MARK: - Step 2. Stepped aside: on the sibling, and staying there while P is empty

    // T3. Snapshot still lagging: the quarantine the cap wrote is what holds the pin switch.
    let held = pinTick(released(appPinned, on: sibling, rows: [healthyP, sibling]).moving,
                       on: sibling, rows: [healthyP, sibling],
                       quarantine: ["P": (model: "fable", until: Date().addingTimeInterval(600))])
    check("a just-capped pinned account holds the pin switch on its quarantine",
          held.plan == nil && held.waiting?.badge == "pin: just capped")
    // T4. Snapshot caught up: released, so the pin switch stands down without a word.
    let aside = released(appPinned, on: sibling, rows: [emptyP, sibling])
    let quietAside = pinTick(aside.moving, on: sibling, rows: [emptyP, sibling])
    check("an empty pinned account releases the pin while the session is away from it",
          aside.moving.mode == "auto" && quietAside.plan == nil && quietAside.waiting == nil)
    check("…and no mover carries the session back onto the empty account",
          rebalances(aside.moving.mode, from: sibling, to: [emptyP]) == nil)
    // T5. The imminent-reset grace: P reads zero with five minutes to its reset. `accountIsSpent`
    // reads that window as full, so the release used to lapse before P could take the session.
    let graceP = pinAccount("P", model: 0, label: "Claude 4", resetsIn: 300)
    let grace = released(appPinned, on: sibling, rows: [graceP, sibling])
    check("a pinned account at zero inside the reset grace still releases the pin", grace.spent)
    check("…so the pin switch neither drags the session back nor strands it",
          pinTick(grace.moving, on: sibling, rows: [graceP, sibling]).plan == nil)
    // T10. A second session still sitting on P when it empties is carried off at a quiet moment.
    let stillOnP = released(appPinned, on: emptyP, rows: [emptyP, sibling])
    check("a quiet session still on the empty pinned account is moved to the sibling",
          rebalances(stillOnP.moving.mode, from: emptyP, to: [sibling])?.id == "S")
    // T11. A `tally switch` the user typed outranks the app's pin, before and after P refills.
    check("a session pin over the app's pin is never dragged home when P refills",
          pinTick(appPinned, on: pinAccount("X", model: 70), rows: [fullP, sibling,
                  pinAccount("X", model: 70)], sessionPin: "X").plan == nil)

    // MARK: - Step 3 and 4. Refilled, and home again

    // T6.
    let refilled = released(appPinned, on: sibling, rows: [fullP, sibling])
    check("a refilled pinned account no longer releases the pin", refilled.moving.mode == "manual")
    let home = pinTick(refilled.moving, on: sibling, rows: [fullP, sibling],
                       quarantine: ["P": (model: "fable", until: Date().addingTimeInterval(-1))])
    check("…and the pin switch carries the session home once the quarantine has lapsed",
          home.plan?.reason == "pin" && home.plan?.target.id == "P")
    // T7. Ten ticks on the sibling while P is empty: no restart loop. Then P refills.
    var loopWatch = DroughtWatch()
    var draggedBack = 0
    var releasedTicks = 0
    for step in 0 ..< 10 {
        let moment = pNow.addingTimeInterval(Double(step) * droughtWatchInterval)
        loopWatch.observe(provider: "claude", account: sibling, primaryModel: "fable",
                          pinned: "P", loaded: snapshot([emptyP, sibling], at: moment),
                          now: moment)
        let yields = pinYieldsToSpentAccount(pinnedSpent: loopWatch.pinnedSpent,
                                             pinnedUnderReserve: false)
        if yields { releasedTicks += 1 }
        if pinTick(pinReleasedPolicy(appPinned, yielding: yields), on: sibling,
                   rows: [emptyP, sibling]).plan != nil { draggedBack += 1 }
    }
    check("ten ticks away from an empty pinned account drag the session back on none",
          draggedBack == 0 && releasedTicks == 10)
    let eleventh = pNow.addingTimeInterval(10 * droughtWatchInterval)
    loopWatch.observe(provider: "claude", account: sibling, primaryModel: "fable", pinned: "P",
                      loaded: snapshot([fullP, sibling], at: eleventh), now: eleventh)
    let backHome = pinYieldsToSpentAccount(pinnedSpent: loopWatch.pinnedSpent,
                                           pinnedUnderReserve: false)
    check("…and the eleventh, with P refilled, takes it home",
          pinTick(pinReleasedPolicy(appPinned, yielding: backHome), on: sibling,
                  rows: [fullP, sibling]).plan?.target.id == "P")

    // Every cell here runs under `appPinned`, the panel's own pin: the ◉fleet scope the owner asked
    // about, not the project pin that already stepped aside before B-1540.
    check("the pin these cells follow is the app's own, drawn as ◉fleet",
          sessionPinScope(appMode: appPinned.mode, appPinnedAccountID: appPinned.pinnedAccountID,
                          projectAccountID: nil, sessionPin: nil) == .fleet)

    // T25. P refills while the session is mid-turn on the sibling: the pin switch waits for the
    // turn to end (and for the keyboard), so the move never cuts a turn and nothing needs resuming.
    check("a refill mid-turn does not move the session",
          pinTick(refilled.moving, on: sibling, rows: [fullP, sibling],
                  watcher: midTurnWatcher("pinpriority-busy")).plan == nil)
    check("…nor while somebody is typing in it",
          pinTick(refilled.moving, on: sibling, rows: [fullP, sibling], typing: true).plan == nil)
    check("…and the first quiet tick after the turn takes it home",
          pinTick(refilled.moving, on: sibling, rows: [fullP, sibling]).plan?.target.id == "P")

    // T26. The account it stepped aside to runs out too, while P is still empty: the cap hands on
    // to whichever account still has quota (never back onto the empty pin), and with none left it
    // stays where it is and waits. The card still reads away from P on the third account.
    let emptyS = pinAccount("S", model: 0, label: "Claude 3")
    let third = pinAccount("X", model: 70, label: "Claude 2")
    let bothEmpty = released(appPinned, on: emptyS, rows: [emptyP, emptyS, third])
    check("an empty stand-in hands the session on to a third account, not back to the empty pin",
          capTick(bothEmpty.moving, on: emptyS, rows: [emptyP, emptyS, third]).plan?.target.id == "X")
    check("…and is still drawn away from the pinned account there",
          pinAwayAccount(appPinned, sessionPin: nil, on: "X") == "P")
    let nowhere = capTick(released(appPinned, on: emptyS, rows: [emptyP, emptyS]).moving, on: emptyS,
                          rows: [emptyP, emptyS])
    check("with every account empty the session stays put and the cap keeps waiting",
          nowhere.plan == nil && nowhere.pending != nil)

    // MARK: - T8. The surfaces: which sessions are away from their pin

    var project = ProjectPolicy()
    project.accountID = "P"
    check("a session off the app's pinned account is away from it",
          pinAwayAccount(appPinned, sessionPin: nil, on: "S") == "P")
    check("…and one on it is not", pinAwayAccount(appPinned, sessionPin: nil, on: "P") == nil)
    check("a session pin is never away (the move that carries it off clears it)",
          pinAwayAccount(appPinned, sessionPin: "S", on: "S") == nil)
    check("nothing pinned, nothing away", pinAwayAccount(appAuto, sessionPin: nil, on: "S") == nil)
    check("a project pin is away on the same terms",
          pinAwayAccount(effectivePolicy(appAuto, project: project), sessionPin: nil,
                         on: "S") == "P")

    // MARK: - T9. A new launch steps aside from an empty pin

    func stepAside(_ rows: [Snapshot.Account], quarantined: Set<String> = [],
                   reserves: AccountReserves = .none, spend: Bool = false) -> String? {
        pinStepAsideRow(Snapshot(version: 2, generatedAt: pNow, accounts: rows), policy: appPinned,
                        primaryModel: "fable", quarantined: quarantined, reserves: reserves,
                        spendReserve: spend, now: pNow)?.id
    }
    check("an empty pin steps aside while a sibling can take the launch",
          stepAside([emptyP, sibling]) == "P")
    check("…but not into nothing", stepAside([emptyP, pinAccount("S", model: 0)]) == nil)
    check("a just-capped pin steps aside too, whatever the snapshot reads",
          stepAside([healthyP, sibling], quarantined: ["P"]) == "P")
    check("a reading Tally cannot trust keeps the pin",
          stepAside([pinAccount("P", model: 0, stale: true), sibling]) == nil)
    check("a row with no counted window is evidence of nothing",
          stepAside([pinAccount("P", model: nil, windows: false), sibling]) == nil)
    let reserved = AccountReserves(settings: ["/tmp/P": AccountRoleSetting(
        role: AccountRoles.personal, reserve: 30)])
    check("a pin under its owner's line keeps the launch, so the refusal still answers",
          stepAside([emptyP, sibling], reserves: reserved) == nil)
    check("…unless the launch spends the reserve",
          stepAside([emptyP, sibling], reserves: reserved, spend: true) == "P")
    check("a healthy pin launches the pin, as it always has", stepAside([healthyP, sibling]) == nil)
    // T27. Where the stepped-aside launch lands: `tally claude` skips the pin branch and falls to
    // the smart pick (`launchPick`, main.swift), which is the sibling, not the empty pin.
    check("a new session under an empty pin starts on the smart pick", stepAside([emptyP, sibling]) == "P"
          && launchPick(providerID: "claude", in: Snapshot(version: 2, generatedAt: pNow,
                                                             accounts: [emptyP, sibling]),
                        primaryModel: "fable", quarantined: [], now: pNow)?.id == "S")

    // MARK: - T24. The wiring this cannot reach without a child, read off the source

    let supervisorCode = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift",
                                      encoding: .utf8)) ?? ""
    let mainCode = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
    check("the supervisor publishes `pinAway` on both of its publishes",
          supervisorCode.components(separatedBy: "pinAway: pinAwayAccount(fleetPolicy").count - 1
              == 2)
    check("…and asks the release without the app's mode",
          !supervisorCode.isEmpty && !supervisorCode.contains("pinYieldsToSpentAccount(appMode"))
    check("`tally claude` no longer launches an empty pin unconditionally",
          !mainCode.isEmpty && !mainCode.contains(#"launching anyway (\(pinnedBy))"#)
              && mainCode.contains("!pinStepsAside("))

    // B-1736: a `--account` Codex window is monitored like any other, so a startup menu it stalls
    // on reaches `tally status`; a `--account` Claude launch stays a plain exec.
    let pinnedBranch: String = {
        guard let open = mainCode.range(of: "    if let pinned {\n") else { return "" }
        let rest = mainCode[open.upperBound...]
        return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
    }()
    let codexCode = (try? String(contentsOfFile: "TallyCLI/CodexSupervisor.swift", encoding: .utf8)) ?? ""
    let helper = codexCode.components(separatedBy: "func launchOnAccount(").dropFirst().first ?? ""
    check("a --account Codex launch goes through the monitored launch",
          pinnedBranch.contains("(pinned)") && pinnedBranch.contains("monitorCodex: wantsCodexMonitoring"))
    check("…which monitors before it would exec",
          helper.range(of: "runCodexSupervised(").map { monitor in
              helper.range(of: "launchProvider(").map { monitor.lowerBound < $0.lowerBound } ?? false
          } ?? false)
    check("…while a --account Claude launch stays a plain exec",
          !pinnedBranch.isEmpty && !pinnedBranch.contains("runSupervised(")
              && mainCode.contains("let wantsCodexMonitoring = provider.id == \"codex\""))
}
