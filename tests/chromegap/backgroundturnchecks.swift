import Darwin
import Foundation

// MARK: - B-558 fix round 1: work this turn started in the background, and witnesses that exist but
// cannot be read, both answer "busy" (TallyCLI/ChromePreflight.swift).

func runBackgroundTurnChecks() {
    func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               as: UTF8.self)
    }
    func person(_ text: String) -> String {
        json(["type": "user", "isSidechain": false, "promptSource": "typed",
              "message": ["role": "user", "content": text]])
    }
    func call(_ name: String, _ input: [String: Any], sidechain: Bool = false) -> String {
        json(["type": "assistant", "isSidechain": sidechain,
              "message": ["role": "assistant",
                          "content": [["type": "tool_use", "id": "t-\(name)", "name": name, "input": input]]]])
    }
    func result(_ id: String) -> String {
        json(["type": "user", "isSidechain": false,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }
    let chrome = call("mcp__claude-in-chrome__navigate", ["url": "http://127.0.0.1:3000/"])
    let devServer = call("Bash", ["command": "pnpm dev", "run_in_background": true])
    let plain = call("Bash", ["command": "ls"])
    func turn(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    let sample = turn([person("check the page"), devServer, result("t-Bash"), chrome])
    check("BG-1 a dev server started in the background this turn, then Chrome: started",
          chromeBackgroundStartedThisTurn(tail: sample) == true)
    check("BG-2 a background start in the previous turn is left to the roster",
          chromeBackgroundStartedThisTurn(tail: turn([person("a"), devServer, person("b"), plain, chrome])) == false)
    check("BG-3 a Monitor this turn: started",
          chromeBackgroundStartedThisTurn(tail: turn([person("a"), call("Monitor", ["command": "tail -f x"]), chrome])) == true)
    check("BG-4 an Agent in the background this turn: started",
          chromeBackgroundStartedThisTurn(tail: turn([person("a"),
                                                       call("Agent", ["prompt": "x", "run_in_background": true])])) == true)
    check("BG-5 a turn with only foreground calls: not started",
          chromeBackgroundStartedThisTurn(tail: turn([person("a"), plain, result("t-Bash"), chrome])) == false)
    check("BG-6 a tool result does not open a new turn",
          chromeBackgroundStartedThisTurn(tail: turn([person("a"), devServer, result("t-Bash"), plain])) == true)
    check("BG-7 a subagent's background call is not this turn's",
          chromeBackgroundStartedThisTurn(tail: turn([person("a"),
              call("Bash", ["command": "x", "run_in_background": true], sidechain: true)])) == false)
    check("BG-8 no person input in the tail: cannot say",
          chromeBackgroundStartedThisTurn(tail: turn([devServer, chrome])) == nil)
    check("BG-9 an assistant line after the input that will not parse: cannot say",
          chromeBackgroundStartedThisTurn(tail: turn([person("a"), "{\"type\":\"assistant\",\"message\":"])) == nil)

    // The live reader, over a scratch supervisor whose child is this process.
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tally-bgturn-\(UUID().uuidString)")
    let dir = base.appendingPathComponent("state"), home = base.appendingPathComponent("home")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let supervisor = String(getppid())
    try? "\(getpid())\n".write(to: supervisorChildFile(pid: supervisor, dir: dir), atomically: true, encoding: .utf8)
    let hooks: [String: Any] = Dictionary(uniqueKeysWithValues: ["SubagentStart", "SubagentStop"].map {
        ($0, [["hooks": [["type": "command", "command": "/usr/local/bin/tally hook-agents \($0)"]]]])
    })
    try? JSONSerialization.data(withJSONObject: ["hooks": hooks])
        .write(to: home.appendingPathComponent("settings.json"))
    let transcript = base.appendingPathComponent("s.jsonl")
    let environment = ["CLAUDE_CONFIG_DIR": home.path,
                       "CLAUDE_CODE_EXECPATH": "/x/.local/share/claude/versions/2.1.300"]
    func live() -> Bool {
        chromeAgentsIdleLive(supervisor: supervisor, context: ChromeCallContext(transcriptPath: transcript.path),
                             environment: environment, dir: dir, now: Date())
    }
    try? turn([person("check the page"), plain, chrome]).write(to: transcript, atomically: true, encoding: .utf8)
    check("BG-L0 every witness readable and quiet: idle (the move still happens)", live())
    try? sample.write(to: transcript, atomically: true, encoding: .utf8)
    check("BG-L1 the dev-server sample read live: busy", !live())
    try? turn([person("check the page"), plain, chrome]).write(to: transcript, atomically: true, encoding: .utf8)
    let roster = sessionAgentsFile(pid: supervisor, dir: dir)
    try? "not json".write(to: roster, atomically: true, encoding: .utf8)
    check("BG-L2 a roster file that will not decode: busy", !live())
    try? FileManager.default.removeItem(at: roster)
    let subagents = base.appendingPathComponent("s/subagents")
    try? FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    chmod(subagents.path, 0)
    check("BG-L3 a subagents directory that cannot be listed: busy", !live())
    chmod(subagents.path, 0o755)
    check("BG-L4 the same directory readable again: idle", live())
    try? FileManager.default.removeItem(at: base)
}
