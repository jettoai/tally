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
        "--output-format", "json",
        "--max-turns", "12",
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
              && pair("--max-turns", "12") && args.contains("--chrome"))

    let prompt = chromeRunPrompt(task: task)
    check("R2 the prompt opens with the wrapper and ends with the task word for word",
          prompt.hasPrefix("You are doing one Claude in Chrome step for another Claude Code session")
              && prompt.hasSuffix("Task:\n\n" + task))

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
}
