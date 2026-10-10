import Foundation

// MOVING EARLY WHEN THE WALL IS NEAR (B-1360, WallForecast.swift).
//
// The readings below are the real 5h-window history of the account that walled nine sessions on
// 2026-10-07: 10% left at 06:00:25 and zero at 06:14:25, while the turn-boundary move waited for
// the 5% line and one claim per cycle.

func runWallForecastChecks() {
    let iso = ISO8601DateFormatter()
    func at(_ ts: String) -> Date { iso.date(from: ts)! }
    // (ts, used) from ~/.tally/history.jsonl, account claude:.claude3, window session.
    let drought: [BurnSample] = [
        ("2026-10-07T05:34:24Z", 59), ("2026-10-07T05:36:28Z", 61), ("2026-10-07T05:37:26Z", 63),
        ("2026-10-07T05:39:23Z", 64), ("2026-10-07T05:40:21Z", 65), ("2026-10-07T05:42:25Z", 67), ("2026-10-07T05:43:31Z", 68),
        ("2026-10-07T05:45:22Z", 70), ("2026-10-07T05:46:19Z", 71), ("2026-10-07T05:47:24Z", 74),
        ("2026-10-07T05:49:24Z", 76), ("2026-10-07T06:00:25Z", 90),
    ].map { BurnSample(at: at($0.0), remaining: 100 - $0.1) }
    let tick = at("2026-10-07T06:00:25Z")

    // MARK: - C1-C3. The slope

    let slope = burnSlope(drought, now: tick)
    check("C1. the 06:00:25 reading burns about 1.35 points a minute",
          slope.map { abs($0 - 1.35) < 0.01 } ?? false)
    check("C1. …which is about 7.4 minutes to the wall from 10%",
          slope.map { abs(10 / $0 - 7.4) < 0.05 } ?? false)
    check("C1. …while at 05:49:24 the same history read 21.2 minutes, still over the line",
          burnSlope(drought, now: at("2026-10-07T05:49:24Z")).map { abs(24 / $0 - 21.2) < 0.1 }
              ?? false)
    check("C2. one sample inside the lookback is no forecast",
          burnSlope(drought, now: at("2026-10-07T06:10:00Z")) == nil)
    let reset = [BurnSample(at: tick.addingTimeInterval(-300), remaining: 5),
                 BurnSample(at: tick, remaining: 100)]
    check("C3. a window that came back up (a reset) is no forecast", burnSlope(reset, now: tick) == nil)
    let sinceReset = [BurnSample(at: tick.addingTimeInterval(-600), remaining: 5),
                      BurnSample(at: tick.addingTimeInterval(-540), remaining: 100),
                      BurnSample(at: tick.addingTimeInterval(-240), remaining: 96),
                      BurnSample(at: tick, remaining: 90)]
    check("C3b. five minutes after a reset the new cycle's burn is forecast (1.11 points a minute)",
          burnSlope(sinceReset, now: tick).map { abs($0 - 10.0 / 9) < 0.01 } ?? false)
    // Whole-percent readings a minute apart turn one point of rounding into a point a minute.
    let close = [BurnSample(at: tick.addingTimeInterval(-60), remaining: 11),
                 BurnSample(at: tick, remaining: 10)]
    check("C2b. two samples a minute apart are no forecast", burnSlope(close, now: tick) == nil)
    let fiveApart = [BurnSample(at: tick.addingTimeInterval(-300), remaining: 11),
                     BurnSample(at: tick, remaining: 10)]
    check("C2b. …while five minutes apart are", burnSlope(fiveApart, now: tick) != nil)

    // The whole forecast, through the rated windows and the history key mapping.
    let albert = Snapshot.Account(
        id: "claude:.claude3", provider: "claude", label: "albert", launchHome: "/tmp/a",
        sessionRemaining: 10, weeklyRemaining: 80, modelRemaining: 80,
        sessionResetsAt: at("2026-10-07T09:00:00Z"), weeklyResetsAt: tick.addingTimeInterval(4e5),
        modelResetsAt: tick.addingTimeInterval(4e5), modelWindowName: "fable",
        resetCreditsAvailable: nil, isStale: false, error: nil)
    let history = ["claude:.claude3\tsession": drought]
    let minutes = minutesToWall(albert, primaryModel: "fable", now: tick) {
        history[burnSampleKey(account: "claude:.claude3", ratedWindow: $0)] ?? []
    }
    check("C1. minutesToWall reads the session window's history and lands on 7.4",
          minutes.map { abs($0 - 7.4) < 0.05 } ?? false)
    check("the three rated window names map onto the history's three",
          burnSampleKey(account: "x", ratedWindow: AccountRoles.sessionWindowName) == "x\tsession"
              && burnSampleKey(account: "x", ratedWindow: AccountRoles.weeklyWindowName)
                  == "x\tweeklyAll"
              && burnSampleKey(account: "x", ratedWindow: "fable") == "x\tweeklyModel")

    // MARK: - C4-C9. The gate

    func acct(_ id: String, model: Double) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil,
                         isStale: false, error: nil)
    }
    let tenLeft = acct("A", model: 10)
    let healthy = acct("B", model: 77)
    func target(current: Snapshot.Account = tenLeft, candidates: [Snapshot.Account] = [healthy],
                agentsIdle: Bool = true,
                forecast: [String: Double] = ["A": 7.4], sessions: Int = 9,
                claim: () -> Bool = { false }) -> Snapshot.Account? {
        turnBoundaryTarget(steering: true, mode: "auto", blocked: false, keyboardIdle: true,
                           draftSuspected: false, carryable: true, fuseAllows: true,
                           agentsIdle: agentsIdle, turnEnded: true, toolCallOpen: false,
                           current: current, candidates: candidates, primaryModel: "fable",
                           now: launch, forecast: { forecast[$0.id] }, sessionsOnCurrent: sessions,
                           claim: claim)
    }
    check("C4. 10% left, 7.4 minutes to the wall, nine sessions: moves without the claim",
          target()?.id == "B")
    check("C5. 22.8 minutes to the wall is not near enough", target(forecast: ["A": 22.8]) == nil)
    check("C6. a lone session still has to win the claim", target(sessions: 1) == nil)
    check("C6. …and moves when it does", target(sessions: 1, claim: { true })?.id == "B")
    check("C7. a subagent still working holds it however near the wall",
          target(agentsIdle: false) == nil)
    // C8. The target's own forecast is asked of an EARLY move only. An ordinary move (under the 5%
    // line) is due now and takes the cap handoff's target; refusing it walls the session mid-turn
    // and the cap handoff then lands on that same target.
    check("C8. an ordinary move (4% left) is not refused by the target's own forecast",
          target(current: acct("A", model: 4), forecast: ["B": 30], claim: { true })?.id == "B")
    check("C8. …nor is a move off a spent account",
          target(current: acct("A", model: 0), forecast: ["B": 30])?.id == "B")
    let lesser = acct("C", model: 50)
    check("C8. an early move skips a target 30 minutes from its wall and takes the next candidate",
          target(candidates: [healthy, lesser], forecast: ["A": 7.4, "B": 30])?.id == "C")
    check("C8. an early move with no refuge among the candidates stays",
          target(forecast: ["A": 7.4, "B": 30]) == nil)
    check("C8. …while 41 minutes is a refuge", target(forecast: ["A": 7.4, "B": 41])?.id == "B")
    check("C9. no forecast at all leaves a comfortable account where it is",
          target(forecast: [:], claim: { true }) == nil)

    // MARK: - The station writes the early move into the handoff log

    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-wallforecast-\(UUID().uuidString)")
    let log = logDir.appendingPathComponent("handoff.log")
    var plan: RelaunchPlan?
    var state = TurnBoundaryState()
    applyTurnBoundaryMove(plan: &plan, state: &state, event: SessionTurnEnd(at: launch, sessionID: "s"),
                          steering: true, provider: "claude", account: tenLeft,
                          primaryModel: "fable", mode: "auto", blocked: false, keyboardIdle: true,
                          draftSuspected: false, carryable: true, fuseAllows: true,
                          agents: { _, _ in .idle }, turnEnded: true, toolCallOpen: false,
                          forecast: { $0.id == "A" ? 7.4 : nil }, sessionsOnCurrent: { 9 },
                          log: log, quarantine: [:],
                          loaded: (Snapshot(version: 2, generatedAt: launch,
                                            accounts: [tenLeft, healthy]), nil),
                          now: launch, dir: logDir.appendingPathComponent("claims"))
    let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check("the station plans the early move", plan?.target.id == "B")
    check("…and logs it as an early move in handoff.log",
          logged.contains("early-move account=A minutes=7.4 sessions=9"))
    try? FileManager.default.removeItem(at: logDir)

    // MARK: - C10. Live sessions on an account

    let stateDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-livecount-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let dead = Process()
    dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? dead.run()
    dead.waitUntilExit()
    for (pid, account) in [(getpid(), "claude:.claude3"), (getppid(), "claude:.claude3"),
                           (dead.processIdentifier, "claude:.claude3")] {
        writeSupervisorAccount(account, pid: String(pid), dir: stateDir)
    }
    check("C10. three account files, one of a dead pid, count two live sessions",
          liveSessionCount(onAccount: "claude:.claude3", dir: stateDir) == 2)
    check("C10. …and none on another account",
          liveSessionCount(onAccount: "claude:.claude4", dir: stateDir) == 0)
    // Every reading that fails is unknown (nil), which every caller reads as full.
    let ownFile = supervisorAccountFile(pid: String(getpid()), dir: stateDir)
    chmod(ownFile.path, 0)
    check("C10. a live supervisor's account file that cannot be read is unknown",
          liveSessionCount(onAccount: "claude:.claude3", dir: stateDir) == nil)
    check("C10. …and the panel's count reads the same file as unknown (B-1374)",
          ProbeCadence.liveAccountCounts(dir: stateDir, isAlive: { supervisorAlive($0) }) == nil)
    chmod(ownFile.path, 0o644)
    chmod(stateDir.path, 0)
    check("C10. a state directory that cannot be listed is unknown",
          liveSessionCount(onAccount: "claude:.claude3", dir: stateDir) == nil)
    check("C10. …and the panel's count reads it as unknown too",
          ProbeCadence.liveAccountCounts(dir: stateDir, isAlive: { supervisorAlive($0) }) == nil)
    chmod(stateDir.path, 0o755)
    check("C10. a state directory nobody has written yet is a real zero",
          liveSessionCount(onAccount: "claude:.claude3",
                           dir: stateDir.appendingPathComponent("absent")) == 0)
    try? FileManager.default.removeItem(at: stateDir)

    // MARK: - C11. Reading the history tail

    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-history-\(UUID().uuidString).jsonl")
    let rows = [
        #"{"ts":"2026-10-07T05:00:00Z","account":"claude:.claude3","window":"session","used":1}"#,
        #"{"ts":"2026-10-07T06:00:25.500Z","account":"claude:.claude3","window":"session","used":90}"#,
        #"{"ts":"2026-10-07T06:02:19Z","account":"claude:.claude3","window":"session","used":92}"#,
    ]
    try? (rows.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    let tail = rows[1].utf8.count + rows[2].utf8.count + 2 + 10  // cuts into the first row
    let loaded = loadBurnSamples(file: file, tailBytes: tail)["claude:.claude3\tsession"] ?? []
    check("C11. the half row the cut left is dropped and both whole rows are read",
          loaded.count == 2)
    check("C11. …a fractional-second stamp keeps its fraction",
          loaded.first.map { abs($0.at.timeIntervalSince(at("2026-10-07T06:00:25Z")) - 0.5) < 0.001 }
              ?? false)
    check("C11. …and remaining is 100 minus used", loaded.map(\.remaining) == [10, 8])
    check("a missing history is no samples, never an error",
          loadBurnSamples(file: file.appendingPathExtension("missing")).isEmpty)
    try? FileManager.default.removeItem(at: file)
}
