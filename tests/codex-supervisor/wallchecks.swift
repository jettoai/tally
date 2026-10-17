import Foundation

// B-2096 package 2: a usage wall read from the window's own rollout. The three fixtures are
// content-free extracts of real Codex 0.163 rollouts (token_count and task records only, timestamps
// and quota numbers verbatim, credit balances rewritten); each one names its source file.

func runWallChecks() throws {
    let fixtures = URL(fileURLWithPath: "tests/codex-supervisor/fixtures")
    let wroot = root.appendingPathComponent("wall")
    try FileManager.default.createDirectory(at: wroot, withIntermediateDirectories: true)
    var counter = 0
    typealias Step = (wall: Bool, state: SupervisedState, canAccept: Bool, used: Double?)

    /// Feeds a fixture to an observer one record at a time and reads the wall verdict after each,
    /// "now" being the record's own timestamp. `launchedAt` defaults to just before the first record.
    func replay(_ name: String, launchedAfter: TimeInterval = -1) throws -> [Step] {
        let rows = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let meta = try JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as! [String: Any]
        let id = (meta["payload"] as! [String: Any])["id"] as! String
        let times = try rows.map { row -> Date in
            codexEventDate(((try JSONSerialization.jsonObject(with: Data(row.utf8)) as! [String: Any])["timestamp"]) as! String)!
        }
        counter += 1
        let file = sessions.appendingPathComponent("wall-\(counter).jsonl")
        try Data((rows[0] + "\n").utf8).write(to: file)
        var observer = CodexSessionObserver(binding: CodexSessionBinding(nonce: "wall", sessionID: id,
            transcriptPath: file.path, model: nil), launchedAt: times[0].addingTimeInterval(launchedAfter))
        var steps: [Step] = []
        for index in 1..<rows.count {
            try append(Data((rows[index] + "\n").utf8), to: file)
            observer.poll(home: home.path)
            steps.append((codexRolloutWall(observer.rateReading, now: times[index]), observer.state,
                          observer.canAcceptInput, observer.rateReading?.usedPercent))
        }
        check("\(name): replay never invalidated the observer", !observer.invalidated)
        return steps
    }

    let hit = try replay("wall-100-0.163.jsonl")
    check("W1 real 100% rollout: not a wall at 99%, a wall at 100%",
          hit.filter { $0.used == 99 }.allSatisfy { !$0.wall } && hit.contains { $0.used == 100 && $0.wall })
    check("W1/W9 the turn that crossed 100% ends idle at task_complete, where a hand-off waits",
          hit.last?.wall == true && hit.last?.state == .idle && hit.last?.canAccept == true)
    check("W9 the quota record leaves the turn state machine alone: working until the turn ends",
          hit.dropLast().allSatisfy { $0.state == .working && !$0.canAccept })

    let near = try replay("nowall-98-0.163.jsonl")
    check("W2 real 98% rollout is never a wall, and still reaches idle", near.allSatisfy { !$0.wall }
          && near.last?.state == .idle && near.last?.canAccept == true)

    let redeemed = try replay("wall-then-redeem-0.163.jsonl")
    check("W3 real wall then redeem: a wall at 100%, cleared by the 0% reading after it",
          redeemed.contains { $0.used == 100 && $0.wall } && redeemed.last?.used == 0 && redeemed.last?.wall == false
          && redeemed.firstIndex { $0.wall }! < redeemed.firstIndex { $0.used == 0 }!)

    let resumed = try replay("wall-100-0.163.jsonl", launchedAfter: 3600)
    check("W5 a launch that starts after the 100% reading (a resume onto another account) reads no wall",
          resumed.allSatisfy { !$0.wall && $0.used == nil })

    // Single readings, built the way the observer builds them.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func reading(_ limits: [String: Any]) -> CodexRateReading? { CodexRateReading(limits: limits, at: now) }
    func window(_ used: Double, resets: TimeInterval?) -> [String: Any] {
        var window: [String: Any] = ["used_percent": used, "window_minutes": 10080]
        if let resets { window["resets_at"] = resets }
        return window
    }
    let future = now.timeIntervalSince1970 + 3600
    check("W4 100% whose reset has passed describes a refilled window",
          !codexRolloutWall(reading(["primary": window(100, resets: now.timeIntervalSince1970 - 1)]), now: now))
    check("W4 100% with no reset time is not trusted", !codexRolloutWall(reading(["primary": window(100, resets: nil)]), now: now))
    check("W2 99.9% is not a wall", !codexRolloutWall(reading(["primary": window(99.9, resets: future)]), now: now))
    check("W6 the server naming a reached limit is a wall at 90%",
          codexRolloutWall(reading(["primary": window(90, resets: future), "rate_limit_reached_type": "rate_limit_reached"]), now: now))
    check("W6 a null reached type adds nothing",
          !codexRolloutWall(reading(["primary": window(90, resets: future), "rate_limit_reached_type": NSNull()]), now: now))
    check("W7 a second window at 100% is a wall though the first has room",
          codexRolloutWall(reading(["primary": window(50, resets: future), "secondary": window(100, resets: future)]), now: now))

    // W10: a turn that ends with an error is told apart from one that does not, until the next turn starts.
    let (failFile, _) = try fixture("wall-failed-turn")
    var failing = CodexSessionObserver(binding: CodexSessionBinding(nonce: "f", sessionID: sid,
        transcriptPath: failFile.path, model: nil), launchedAt: start)
    try append(event("task_started"), to: failFile)
    try append(line("event_msg", ["type": "task_complete", "turn_id": turn,
        "error": ["message": "x", "codex_error_info": "usage_limit_exceeded"]]), to: failFile)
    failing.poll(home: home.path)
    check("W10 a task_complete carrying an error is a failed turn, and the observer is idle", failing.lastTurnFailed && failing.state == .idle)
    try append(event("task_started", turnID: nextTurn), to: failFile)
    failing.poll(home: home.path)
    check("W10 the next turn starting clears it", !failing.lastTurnFailed)
    try append(line("event_msg", ["type": "task_complete", "turn_id": nextTurn, "error": NSNull()]), to: failFile)
    failing.poll(home: home.path)
    check("W10 a task_complete with a null error is a clean turn", !failing.lastTurnFailed && failing.state == .idle)

    // W8: malformed quota records update nothing and never invalidate the observer.
    let (file, _) = try fixture("wall-malformed")
    var observer = CodexSessionObserver(binding: CodexSessionBinding(nonce: "m", sessionID: sid,
        transcriptPath: file.path, model: nil), launchedAt: start)
    try append(event("task_started"), to: file)
    let good: [String: Any] = ["primary": window(100, resets: start.timeIntervalSince1970 + 3600)]
    for limits in [good, ["secondary": NSNull()], ["primary": "100"], ["primary": ["resets_at": 5]]] as [[String: Any]] {
        try append(line("event_msg", ["type": "token_count", "rate_limits": limits]), to: file)
        observer.poll(home: home.path)
    }
    try append(line("event_msg", ["type": "token_count", "rate_limits": NSNull()]), to: file)
    observer.poll(home: home.path)
    check("W8 malformed rate_limits records neither invalidate nor erase the last good reading",
          !observer.invalidated && observer.rateReading?.usedPercent == 100 && observer.state == .working)
}
