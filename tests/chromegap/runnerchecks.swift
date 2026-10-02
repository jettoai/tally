import Foundation

// MARK: - B-558: `tally chrome run` (TallyCLI/ChromeRun.swift). Only the pure parts: the argv, the
// environment, the task and setup readers and the result. The live run is never started here.

func runRunnerChecks() {
    let task = "Open https://example.com/ and report the page title."
    let args = chromeRunArguments(task: task)

    check("R1 the argv is exactly the measured shape", args == [
        "-p", chromeRunPrompt(task: task),
        "--chrome",
        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        "--allowedTools", "mcp__claude-in-chrome__*",
        "--output-format", "stream-json", "--verbose",
        "--max-turns", "14",
        "--no-session-persistence",
        "--settings", "{\"disableAllHooks\":true}",
        "--model", "sonnet"])
    func pair(_ flag: String, _ value: String) -> Bool {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return false }
        return args[index + 1] == value
    }
    check("R1 it isolates MCP, turns hooks off, and names model, turns and Chrome",
          args.contains("--strict-mcp-config") && pair("--mcp-config", "{\"mcpServers\":{}}")
              && pair("--settings", "{\"disableAllHooks\":true}") && pair("--model", "sonnet")
              && pair("--max-turns", "14") && args.contains("--chrome"))

    let prompt = chromeRunPrompt(task: task)
    check("R2 the prompt opens with the wrapper and ends with the task word for word",
          prompt.hasPrefix("You are doing one Claude in Chrome step for another Claude Code session")
              && prompt.hasSuffix("Task:\n\n" + task))
    check("R2b the prompt asks the run to close the tabs it opened", prompt.contains("tabs_close_mcp"))

    let provider = providers[0]
    let base = ["CLAUDE_CONFIG_DIR": "/x", "PATH": "/usr/bin:/bin", "HOME": "/Users/x",
                "CLAUDE_CODE_OAUTH_TOKEN": "t", "ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_SIMPLE": "1",
                "TALLY_SUPERVISOR_PID": "77123"]
    let atDefault = chromeRunEnvironment(base, home: defaultHome(provider))
    check("R3 the default home runs with CLAUDE_CONFIG_DIR unset", atDefault["CLAUDE_CONFIG_DIR"] == nil)
    let two = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude2").path
    let atTwo = chromeRunEnvironment(base, home: two)
    check("R4 another home runs with CLAUDE_CONFIG_DIR set to it", atTwo["CLAUDE_CONFIG_DIR"] == two)
    check("R5 the dropped keys are gone", chromeRunDroppedEnvironment.allSatisfy { atTwo[$0] == nil }
              && chromeRunDroppedEnvironment.count == 4)
    check("R5 permissions are skipped and the run is marked",
          atTwo["CLAUDE_CHROME_PERMISSION_MODE"] == "skip_all_permission_checks" && atTwo["TALLY_CHROME_RUN"] == "1")
    check("R5 PATH and HOME are kept", atTwo["PATH"] == "/usr/bin:/bin" && atTwo["HOME"] == "/Users/x")

    let files = ["/t/task.md": "\n  open the page  \n"]
    let read: (String) -> String? = { files[$0] }
    check("R6 --file reads the file and trims it",
          chromeRunTask(args: ["--file", "/t/task.md"], read: read) == .task("open the page"))
    check("R6 words are joined", chromeRunTask(args: ["open", "x"], read: read) == .task("open x"))
    func usage(_ task: ChromeRunTask) -> Bool { if case .usage = task { return true }; return false }
    for (name, input) in [("nothing", [String]()), ("blank", ["  "]), ("--file alone", ["--file"]),
                          ("an unreadable file", ["--file", "/t/missing.md"])] {
        check("R6 \(name) is a usage error", usage(chromeRunTask(args: input, read: read)))
    }

    func refused(_ setup: ChromeRunSetup) -> Bool { if case .refused = setup { return true }; return false }
    check("R7 no setting is refused", refused(chromeRunSetup(setting: nil, environment: [:], isDirectory: { _ in true })))
    check("R7 a setting whose home is missing is refused",
          refused(chromeRunSetup(setting: "claude:.claude9", environment: [:], isDirectory: { _ in false })))
    let ready = chromeRunSetup(setting: "claude:.claude2", environment: [:], isDirectory: { _ in true })
    if case .ready(let account, let home) = ready {
        check("R7 a setting with a home is ready on that home", account == "claude:.claude2" && home.hasSuffix("/.claude2"))
    } else {
        check("R7 a setting with a home is ready on that home", false)
    }
    check("R7 a run inside a run is refused",
          refused(chromeRunSetup(setting: "claude:.claude2", environment: ["TALLY_CHROME_RUN": "1"],
                                 isDirectory: { _ in true })))
    check("R7 a Codex id is refused",
          refused(chromeRunSetup(setting: "codex:.codex", environment: [:], isDirectory: { _ in true })))

    let ok = chromeRunOutcome(stdout: Data("{\"result\":\"done\",\"is_error\":false}".utf8), exitCode: 0, timedOut: false)
    check("R8 an answer without error is ok", ok == ChromeRunOutcome(ok: true, status: "ok", text: "done"))
    let maxed = chromeRunOutcome(stdout: Data("{\"result\":\"partial\",\"is_error\":true,\"subtype\":\"error_max_turns\"}".utf8),
                                 exitCode: 1, timedOut: false)
    check("R8 an error names its subtype and keeps the answer",
          !maxed.ok && maxed.status.contains("error_max_turns") && maxed.text == "partial")
    let garbage = chromeRunOutcome(stdout: Data("not json".utf8), exitCode: 1, timedOut: false)
    check("R8 output that is not JSON is not ok", !garbage.ok && garbage.status.contains("no JSON"))
    let late = chromeRunOutcome(stdout: Data("{\"result\":\"half\"}".utf8), exitCode: 15, timedOut: true)
    check("R8 a timeout says so and keeps what was answered",
          !late.ok && late.status == "timed out after 600s" && late.text == "half")

    let document = chromeRunResultDocument(account: "claude:.claude2", outcome: ok, raw: "{\"result\":\"done\"}",
                                           rawPath: "/r/stdout.json", errorPath: "/r/stderr.log")
    check("R9 the result file carries the status, the answer and the raw output",
          document.contains("status: ok") && document.contains("## Answer\n\ndone\n")
              && document.contains("## Raw output") && document.contains("{\"result\":\"done\"}"))
    let empty = chromeRunResultDocument(account: "claude:.claude2", outcome: garbage, raw: "",
                                        rawPath: "/r/stdout.json", errorPath: "/r/stderr.log")
    check("R9 an empty answer points at the raw output", empty.contains("(no answer;"))

    check("R10 the run id is a UTC stamp and the pid",
          chromeRunID(now: Date(timeIntervalSince1970: 1_790_000_000), pid: 4242) == "20260921T141320Z-4242")
    runStreamChecks()
}

// MARK: - B-468: the stream the run prints, and closing the tabs it left open.

private func userLine(_ content: Any) -> String {
    let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
        ["type": "tool_result", "tool_use_id": "t", "content": content]]]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func textParts(_ text: String) -> [[String: Any]] { [["type": "text", "text": text]] }

private func scanAll(_ text: String) -> ChromeRunStream {
    var buffer = Data(text.utf8)
    var stream = ChromeRunStream()
    for line in chromeRunTakeLines(&buffer) { chromeRunScan(line: line, into: &stream) }
    if !buffer.isEmpty { chromeRunScan(line: buffer, into: &stream) }
    return stream
}

func runStreamChecks() {
    // The forms measured in real tool results on 2026-10-02 (B-468 plan, section 2c).
    let lines = [
        #"{"type":"system","subtype":"init","session_id":"s"}"#,
        userLine(textParts("\nTab context (from front-loaded tabs_context_mcp):\n{\"availableTabs\":[{\"tabId\":1772725101,\"title\":\"New Tab\"}],\"tabGroupId\":599418428}")),
        userLine(textParts("Created new tab. Tab ID: 1772725102")),
        userLine(textParts("Navigated.\n\nTab Context:\n- Executed on tabId: 1772725103\n- Available tabs:\n  \u{2022} tabId 1772725103: \"x\" (\"https://x\")")),
        userLine(textParts("Closed tab 1772725101. Group is now empty (auto-removed).")),
    ]
    let stream = scanAll(lines.joined(separator: "\n") + "\n")
    check("R11a tool results give the seen and closed tab ids",
          stream.seen == [1772725101, 1772725102, 1772725103] && stream.closed == [1772725101]
              && stream.leftOpen == [1772725102, 1772725103] && stream.result == nil)
    check("R11b a tool result whose content is a string counts too",
          scanAll(userLine("Created new tab. Tab ID: 1772725200") + "\n").seen == [1772725200])

    let assistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":"tabId 1772725999 \"tabId\":1772725999"},{"type":"tool_use","name":"x","input":{"tabId":1772725999}}]}}"#
    let maxed = #"{"type":"result","subtype":"error_max_turns","is_error":true,"terminal_reason":"max_turns","num_turns":15,"permission_denials":[{"tool_input":{"tabId":1772725998}}]}"#
    let noise = scanAll(assistant + "\n" + maxed + "\n")
    check("R11c ids outside tool results never count", noise.seen.isEmpty)
    let maxedOutcome = chromeRunOutcome(stdout: noise.result ?? Data(), exitCode: 1, timedOut: false)
    check("R11d the result line is kept and reads as before (max_turns)",
          noise.result == Data(maxed.utf8) && !maxedOutcome.ok && maxedOutcome.status.contains("error_max_turns"))
    let success = #"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#
    let okOutcome = chromeRunOutcome(stdout: scanAll(success + "\n").result ?? Data(), exitCode: 0, timedOut: false)
    check("R11d the result line is kept and reads as before (success)",
          okOutcome == ChromeRunOutcome(ok: true, status: "ok", text: "done"))

    let whole = lines.joined(separator: "\n") + "\n" + success
    let bytes = Data(whole.utf8)
    var buffer = Data()
    var chunked = ChromeRunStream()
    for cut in [(0, 37), (37, bytes.count / 2 + 3), (bytes.count / 2 + 3, bytes.count)] {
        buffer.append(bytes[cut.0..<cut.1])
        for line in chromeRunTakeLines(&buffer) { chromeRunScan(line: line, into: &chunked) }
    }
    check("R11e a last line without a newline waits in the buffer", chunked.result == nil && !buffer.isEmpty)
    chromeRunScan(line: buffer, into: &chunked)
    check("R11e lines cut across chunks read the same as one feed", chunked == scanAll(whole))

    let killed = scanAll(lines[2] + "\n" + lines[3] + "\n")
    check("R11f a run stopped before its result still names the tabs it left open",
          killed.result == nil && killed.leftOpen == [1772725102, 1772725103]
              && chromeRunOutcome(stdout: Data(), exitCode: 15, timedOut: true).status == "timed out after 600s")

    let mixed = ChromeRunStream(seen: [1, 2, 3], closed: [2], result: nil)
    check("R12 only tabs left open and not open before the run are closed",
          chromeRunTabsToClose(mixed, before: [3]) == [1])
    check("R12 no list from before the run closes nothing", chromeRunTabsToClose(mixed, before: nil).isEmpty)
    check("R12 Chrome closed before the run (empty list) still closes what the run left open",
          chromeRunTabsToClose(mixed, before: []) == [1, 3])

    let script = chromeCloseTabsScript(ids: [1772725767])
    check("R13 the close script never starts Chrome and names only the given id",
          script.hasPrefix("if application \"Google Chrome\" is not running")
              && script.contains("whose id is 1772725767")
              && script.components(separatedBy: "whose id is ").dropFirst().allSatisfy { $0.hasPrefix("1772725767)") })
    check("R13 no ids, no close", !chromeCloseTabsScript(ids: []).contains("whose"))

    check("R14 the tabs line", chromeRunTabsLine(leftOpen: 0, closed: 0) == "none left open"
              && chromeRunTabsLine(leftOpen: 2, closed: 2) == "closed 2 the run left open"
              && chromeRunTabsLine(leftOpen: 3, closed: 1) == "closed 1 of 3 the run left open"
              && chromeRunTabsLine(leftOpen: 2, closed: nil) == "2 left open (could not close them)"
              && chromeRunTabsLine(leftOpen: 2, closed: 0, listedBefore: false)
                  == "2 left open (could not list tabs before the run)")

    let ok = ChromeRunOutcome(ok: true, status: "ok", text: "done")
    let plain = chromeRunResultDocument(account: "a", outcome: ok, raw: "{}", rawPath: "/r/o", errorPath: "/r/e")
    let withTabs = chromeRunResultDocument(account: "a", outcome: ok, raw: "{}", rawPath: "/r/o", errorPath: "/r/e",
                                           tabs: "closed 2 the run left open")
    check("R15 the tabs line follows the status, and nothing else changes",
          withTabs.contains("status: ok\ntabs: closed 2 the run left open\nraw output:")
              && withTabs.replacingOccurrences(of: "tabs: closed 2 the run left open\n", with: "") == plain)
}
