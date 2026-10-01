import Darwin
import Foundation

// MARK: - B-558 fix round 1: work this turn started in the background, and witnesses that exist but
// cannot be read, both answer "busy" (TallyCLI/ChromePreflight.swift).

func runBackgroundTurnChecks() {
    func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               as: UTF8.self)
    }
    // Every line is stamped one second after the one before it, from `epoch`; `counted` is a roll
    // call between the second and third line unless a check says otherwise.
    let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func stamped(_ lines: [[String: Any]]) -> String {
        lines.enumerated().map { index, line in
            var line = line
            line["timestamp"] = iso.string(from: epoch.addingTimeInterval(Double(index) + 0.25))
            return json(line)
        }.joined(separator: "\n") + "\n"
    }
    func person(_ text: String, source: String = "typed") -> [String: Any] {
        ["type": "user", "isSidechain": false, "promptSource": source,
         "message": ["role": "user", "content": text]]
    }
    func call(_ name: String, _ input: [String: Any], sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "isSidechain": sidechain,
         "message": ["role": "assistant",
                     "content": [["type": "tool_use", "id": "t-\(name)", "name": name, "input": input]]]]
    }
    func result(_ id: String) -> [String: Any] {
        ["type": "user", "isSidechain": false,
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]]
    }
    let chrome = call("mcp__claude-in-chrome__navigate", ["url": "http://127.0.0.1:3000/"])
    let devServer = call("Bash", ["command": "pnpm dev", "run_in_background": true])
    let plain = call("Bash", ["command": "ls"])
    let counted = epoch.addingTimeInterval(1.5)
    func started(_ lines: [[String: Any]], since: Date? = counted) -> Bool? {
        chromeBackgroundStartedThisTurn(tail: stamped(lines), countedSince: since)
    }

    // Line 0 and 1 fall before the roll call, line 2 onward after it.
    check("BG-1 a dev server started after the roll call, then Chrome: started",
          started([person("a"), plain, person("check the page"), devServer, result("t-Bash"), chrome]) == true)
    check("BG-2 a background start before the Stop roll call is left to the roster's count",
          started([devServer, result("t-Bash"), person("b"), plain, chrome]) == false)
    check("BG-3 a Monitor after the roll call: started",
          started([person("a"), plain, call("Monitor", ["command": "tail -f x"]), chrome]) == true)
    check("BG-4 an Agent in the background after the roll call: started",
          started([person("a"), plain, call("Agent", ["prompt": "x", "run_in_background": true])]) == true)
    check("BG-5 only foreground calls after the roll call: not started",
          started([person("a"), plain, person("b"), plain, result("t-Bash"), chrome]) == false)
    check("BG-7 a subagent's background call is not the session's",
          started([person("a"), plain, call("Bash", ["command": "x", "run_in_background": true], sidechain: true)])
              == false)
    check("BG-10 sample 2: a background start, then a queued message with no Stop between, then Chrome",
          started([person("a"), plain, person("start it"), devServer, result("t-Bash"),
                   person("now check", source: "queued"), chrome]) == true)
    check("BG-11 a background start, an interrupted turn (no Stop), then typed input: started",
          started([person("a"), plain, person("start it"), devServer, person("again"), chrome]) == true)
    check("BG-8 no roll call: cannot say", started([person("a"), plain, chrome], since: nil) == nil)
    check("BG-12 a tail that does not reach back to the roll call: cannot say",
          started([person("a"), plain, chrome], since: epoch.addingTimeInterval(-10)) == nil)
    check("BG-14 a roll call and a background start in the same second (the roster drops the fraction): started",
          started([person("a"), plain, devServer], since: epoch.addingTimeInterval(2)) == true)
    check("BG-15 the tail opens at the top of the file and never reaches back: quiet reads as quiet",
          chromeBackgroundStartedThisTurn(tail: stamped([person("a"), plain, chrome]),
                                          countedSince: epoch.addingTimeInterval(-10), fromFileStart: true) == false)
    check("BG-16 the same with a background start: started",
          chromeBackgroundStartedThisTurn(tail: stamped([person("a"), devServer, chrome]),
                                          countedSince: epoch.addingTimeInterval(-10), fromFileStart: true) == true)
    check("BG-9 an assistant line after the roll call that will not parse: cannot say",
          chromeBackgroundStartedThisTurn(tail: stamped([person("a"), plain]) + "{\"type\":\"assistant\",\"message\":\n",
                                          countedSince: counted) == nil)
    check("BG-13 an assistant line after the roll call with no stamp: cannot say",
          chromeBackgroundStartedThisTurn(tail: stamped([person("a"), plain]) + json(plain) + "\n",
                                          countedSince: counted) == nil)

    // The live reader, over a scratch supervisor whose child is this process.
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tally-bgturn-\(UUID().uuidString)")
    let dir = base.appendingPathComponent("state"), home = base.appendingPathComponent("home")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let supervisor = String(getppid())
    try? "\(getpid())\n".write(to: supervisorChildFile(pid: supervisor, dir: dir), atomically: true, encoding: .utf8)
    func registerHooks(_ events: [String]) {
        let hooks: [String: Any] = Dictionary(uniqueKeysWithValues: events.map {
            ($0, [["hooks": [["type": "command", "command": "/usr/local/bin/tally hook-agents \($0)"]]]])
        })
        try? JSONSerialization.data(withJSONObject: ["hooks": hooks])
            .write(to: home.appendingPathComponent("settings.json"))
    }
    registerHooks(["SubagentStart", "SubagentStop"])
    check("BG-H1 the two edges without the Stop roll call: not registered",
          !agentRosterHookRegistered(home: home.path))
    registerHooks(AgentRosterEvent.events)
    check("BG-H2 all three events: registered", agentRosterHookRegistered(home: home.path))
    let transcript = base.appendingPathComponent("s.jsonl")
    let environment = ["CLAUDE_CONFIG_DIR": home.path,
                       "CLAUDE_CODE_EXECPATH": "/x/.local/share/claude/versions/2.1.300"]
    func live() -> Bool {
        chromeAgentsIdleLive(supervisor: supervisor, context: ChromeCallContext(transcriptPath: transcript.path),
                             environment: environment, dir: dir, now: Date())
    }
    let roster = sessionAgentsFile(pid: supervisor, dir: dir)
    let childStart = Double(processIdentity(getpid())?.startedAt ?? 0) / 1_000_000
    // A whole second (the roster file keeps no fraction), after this child started.
    let callAt = Date(timeIntervalSince1970: (max(childStart, Date().timeIntervalSince1970) + 5).rounded(.up))
    func liveTail(_ lines: [[String: Any]]) {
        // Lines 0 and 1 before the roll call, line 2 onward after it; all after this child started.
        let shifted = lines.enumerated().map { index, line -> String in
            var line = line
            line["timestamp"] = iso.string(from: callAt.addingTimeInterval(Double(index) - 1.5))
            return json(line)
        }.joined(separator: "\n") + "\n"
        try? shifted.write(to: transcript, atomically: true, encoding: .utf8)
    }
    func roll(_ background: Int?, at: Date? = nil) {
        writeSessionAgents(SessionAgentsRecord(live: [], trusted: true, updatedAt: callAt, background: background,
                                               backgroundCountedAt: at ?? callAt), pid: supervisor, dir: dir)
    }
    let quietLines = [person("a"), plain, person("check the page"), plain, chrome]
    let previousTurnServer = [person("start it"), devServer, result("t-Bash"), person("check the page"), chrome]

    registerHooks(["SubagentStart", "SubagentStop"])
    liveTail(previousTurnServer)
    check("BG-L5 two hooks only, no roster, a dev server started the turn before: busy", !live())
    registerHooks(AgentRosterEvent.events)
    check("BG-L5b the same with all three hooks: still busy (the start is after the child's)", !live())
    liveTail(quietLines)
    check("FIRST-TURN a new child, no roll call yet, no background start: idle", live())
    writeSessionAgents(SessionAgentsRecord(live: ["a1"], trusted: true, updatedAt: callAt), pid: supervisor, dir: dir)
    check("FIRST-TURN-b the same with a live subagent: busy", !live())
    writeSessionAgents(SessionAgentsRecord(live: [], trusted: true, updatedAt: callAt), pid: supervisor, dir: dir)
    check("BG-L6 a current roster with no roll call yet, transcript quiet: idle", live())
    roll(0)
    liveTail(quietLines)
    check("BG-L0 every witness readable and quiet: idle (the move still happens)", live())
    liveTail([person("a"), plain, person("check the page"), devServer, result("t-Bash"), chrome])
    check("BG-L1 the dev-server sample read live: busy", !live())
    liveTail([person("a"), plain, person("start it"), devServer, person("now", source: "queued"), chrome])
    check("BG-L7 sample 2 read live (queued message after a background start): busy", !live())
    liveTail([person("a"), devServer, person("check the page"), plain, chrome])
    check("BG-L9 a start the roll call covered, counted 0: idle", live())
    roll(1)
    check("BG-L10 the same start, counted 1 at the roll call: busy", !live())
    // A roll call at x.6 is stored as x, so a start at x.3 (before it) stays visible: the safe error.
    roll(0, at: callAt.addingTimeInterval(0.6))
    try? json(["type": "assistant", "isSidechain": false,
               "timestamp": iso.string(from: callAt.addingTimeInterval(0.3)),
               "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t-B", "name": "Bash",
                                                              "input": ["command": "x", "run_in_background": true]]]]])
        .appending("\n").write(to: transcript, atomically: true, encoding: .utf8)
    check("BG-L8 a start in the roll call's second, before it by the fraction: busy", !live())
    roll(0)
    liveTail(quietLines)
    try? "not json".write(to: roster, atomically: true, encoding: .utf8)
    check("BG-L2 a roster file that will not decode: busy", !live())
    roll(0)
    let subagents = base.appendingPathComponent("s/subagents")
    try? FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    chmod(subagents.path, 0)
    check("BG-L3 a subagents directory that cannot be listed: busy", !live())
    chmod(subagents.path, 0o755)
    check("BG-L4 the same directory readable again: idle", live())
    try? FileManager.default.removeItem(at: base)
}
