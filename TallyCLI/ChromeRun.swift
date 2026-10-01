import Darwin
import Foundation

// `tally chrome run`: ONE Claude in Chrome step, run on the account the extension is signed in to,
// for a session on another account (B-558). The asking session keeps its account; this starts a
// short-lived `claude -p --chrome` on the set account's config home, waits for it, and writes what
// it answered to a result file whose path is the only thing printed.
//
// HOW THE RUN IS SHAPED, measured on 2026-10-01 against 2.1.286 (a live run that listed two
// browsers, opened a page and saved a screenshot in 12 turns):
//   - `--chrome`: `-p` leaves Claude in Chrome off without it, whatever the config says.
//   - the config home's own claude.ai login: Chrome needs that login's scopes, so a token or API key
//     in the environment is removed, and the DEFAULT home runs with CLAUDE_CONFIG_DIR unset
//     (`launchEnv`; set to ~/.claude it answers "Not logged in").
//   - `--strict-mcp-config` with an empty `--mcp-config`: the spawn rule for every child claude;
//     Claude in Chrome is wired in after that filter, so it stays.
//   - `--settings {"disableAllHooks":true}`: the user's and plugins' hooks stay out of the run (a
//     Stop hook would otherwise take the `-p` turn over). Managed hooks would still run.
//   - CLAUDE_CHROME_PERMISSION_MODE=skip_all_permission_checks and `--allowedTools` for the Chrome
//     tools: nobody is there to answer a prompt.
//   - stdin is /dev/null: `-p` would otherwise wait on a pipe nobody writes.

/// The model a run uses. A Chrome step is navigation and reading; the default model cost $1.61 for
/// one twelve-turn probe.
let chromeRunModel = "sonnet"
/// Room for "load the Chrome tools, call them, answer" plus a few page steps (the probe used 12).
let chromeRunMaxTurns = 12
/// How long a run may take before it is stopped and reported as timed out.
let chromeRunTimeout: TimeInterval = 600
/// Set on every run, so a run that tries `tally chrome run` itself is refused.
let chromeRunNestedKey = "TALLY_CHROME_RUN"

let chromeRunRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/chrome-run", isDirectory: true)

/// Never inherited from the session that started the run: a token or key would replace the config
/// home's own login, CLAUDE_CODE_SIMPLE turns Claude in Chrome off, and the supervisor marker would
/// make Tally's hook read the run as the session that asked.
let chromeRunDroppedEnvironment = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY",
                                   "CLAUDE_CODE_SIMPLE", "TALLY_SUPERVISOR_PID"]

let chromeRunUsage = "usage: tally chrome run <task> | --file <task file>"

/// The prompt: the task, wrapped so the answer comes back in a form the asking session can use.
func chromeRunPrompt(task: String) -> String {
    "You are doing one Claude in Chrome step for another Claude Code session, which reads your final"
        + " reply. Use only the Claude in Chrome tools. Save every screenshot you take to disk and list"
        + " each saved path in your final reply. End with the result the task asks for.\n\nTask:\n\n"
        + task
}

/// Everything after the program. Pure.
func chromeRunArguments(task: String) -> [String] {
    ["-p", chromeRunPrompt(task: task),
     "--chrome",
     "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
     "--allowedTools", "mcp__claude-in-chrome__*",
     "--output-format", "json",
     "--max-turns", String(chromeRunMaxTurns),
     "--no-session-persistence",
     "--settings", "{\"disableAllHooks\":true}",
     "--model", chromeRunModel]
}

/// The run's environment, from the caller's. The config-home variable follows `launchEnv`
/// (Snapshot.swift), the one rule every Tally launch uses: unset for the default home.
func chromeRunEnvironment(_ base: [String: String], home: String) -> [String: String] {
    var environment = base
    for key in chromeRunDroppedEnvironment { environment[key] = nil }
    let provider = providers[0]
    environment[provider.envKey] = nil
    if let entry = launchEnv(provider, home: home) { environment[entry.key] = entry.value }
    environment["CLAUDE_CHROME_PERMISSION_MODE"] = "skip_all_permission_checks"
    environment[chromeRunNestedKey] = "1"
    return environment
}

enum ChromeRunTask: Equatable { case task(String), usage(String) }

/// The task from the command line: `--file <path>` read whole, else the words joined. Pure over
/// `read`.
func chromeRunTask(args: [String], read: (String) -> String?) -> ChromeRunTask {
    var text: String
    if args.first == "--file" {
        guard args.count == 2 else { return .usage(chromeRunUsage) }
        guard let body = read(args[1]) else { return .usage("tally chrome run: cannot read \(args[1])") }
        text = body
    } else {
        text = args.joined(separator: " ")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? .usage(chromeRunUsage) : .task(text)
}

enum ChromeRunSetup: Equatable { case ready(account: String, home: String), refused(String) }

/// Which config home the run goes to: the account set for Claude in Chrome. Pure over its readers.
func chromeRunSetup(setting: String?, environment: [String: String],
                    isDirectory: (String) -> Bool) -> ChromeRunSetup {
    if environment[chromeRunNestedKey] != nil {
        return .refused("tally chrome run: already inside a Chrome run; not starting another.")
    }
    guard let setting else {
        return .refused("tally chrome run: no Claude in Chrome account is set in Tally"
                        + " (Settings, \"Claude in Chrome account\").")
    }
    guard let home = accountConfigHome(setting, provider: providers[0]), isDirectory(home) else {
        return .refused("tally chrome run: the account set for Claude in Chrome (\(setting)) has no"
                        + " config home on this machine.")
    }
    return .ready(account: setting, home: home)
}

struct ChromeRunOutcome: Equatable {
    var ok: Bool
    var status: String
    var text: String
}

/// What the run answered, from its stdout (`--output-format json`: one object with `result`,
/// `is_error`, `subtype`). Pure.
func chromeRunOutcome(stdout: Data, exitCode: Int32, timedOut: Bool) -> ChromeRunOutcome {
    let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]
    let text = object?["result"] as? String ?? ""
    if timedOut {
        return ChromeRunOutcome(ok: false, status: "timed out after \(Int(chromeRunTimeout))s", text: text)
    }
    guard let object else {
        return ChromeRunOutcome(ok: false, status: "exit \(exitCode), no JSON result", text: "")
    }
    let isError = object["is_error"] as? Bool ?? true
    if exitCode == 0, !isError, !text.isEmpty { return ChromeRunOutcome(ok: true, status: "ok", text: text) }
    let subtype = object["subtype"] as? String ?? "unknown"
    return ChromeRunOutcome(ok: false, status: "error (\(subtype), exit \(exitCode))", text: text)
}

/// The result file: status first, then the run's whole answer, then its raw output.
func chromeRunResultDocument(account: String, outcome: ChromeRunOutcome, raw: String,
                             rawPath: String, errorPath: String) -> String {
    let answer = outcome.text.isEmpty ? "(no answer; see the raw output and \(errorPath))" : outcome.text
    return "# Claude in Chrome run\n\naccount: \(account)\nstatus: \(outcome.status)\n"
        + "raw output: \(rawPath)\nstderr: \(errorPath)\n\n## Answer\n\n\(answer)\n\n"
        + "## Raw output\n\n```json\n\(raw)\n```\n"
}

/// `<UTC stamp>-<pid>`: sortable, and unique per process.
func chromeRunID(now: Date, pid: Int32) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return "\(format.string(from: now))-\(pid)"
}

/// `tally chrome <verb>`. Only `run` exists.
func runChrome(args: [String]) -> Int32 {
    guard args.first == "run" else { warn(chromeRunUsage); return 2 }
    return runChromeRun(args: Array(args.dropFirst()))
}

/// The live run. stdout carries the result file's path and nothing else; every complaint goes to
/// stderr. 0 when the run answered without error, 1 when it ran and failed, 2 when it never started.
func runChromeRun(args: [String],
                  environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
    let task: String
    switch chromeRunTask(args: args, read: { try? String(contentsOfFile: $0, encoding: .utf8) }) {
    case .task(let text): task = text
    case .usage(let line): warn(line); return 2
    }
    let setup = chromeRunSetup(setting: chromeAccountSetting(), environment: environment,
                               isDirectory: accountHomeIsDirectory)
    let account: String, home: String
    switch setup {
    case .ready(let a, let h): (account, home) = (a, h)
    case .refused(let line): warn(line); return 2
    }
    let program = claudeStableExecutable(resolveProviderExecutable(providers[0].cli))
    guard program.hasPrefix("/") else { warn("tally chrome run: cannot find claude on PATH."); return 2 }
    let dir = chromeRunRoot.appendingPathComponent(chromeRunID(now: Date(), pid: getpid()), isDirectory: true)
    let manager = FileManager.default
    guard (try? manager.createDirectory(at: dir, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])) != nil,
          let cwd = workingDirectoryURL(dir.path) else {
        warn("tally chrome run: cannot create \(dir.path)."); return 2
    }
    let rawURL = dir.appendingPathComponent("stdout.json")
    let errorURL = dir.appendingPathComponent("stderr.log")
    let resultURL = dir.appendingPathComponent("result.md")
    try? task.write(to: dir.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
    manager.createFile(atPath: rawURL.path, contents: nil)
    manager.createFile(atPath: errorURL.path, contents: nil)
    guard let rawHandle = try? FileHandle(forWritingTo: rawURL),
          let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
        warn("tally chrome run: cannot write in \(dir.path)."); return 2
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: program)
    process.arguments = chromeRunArguments(task: task)
    process.environment = chromeRunEnvironment(environment, home: home)
    process.currentDirectoryURL = cwd
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = rawHandle
    process.standardError = errorHandle
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    var timedOut = false
    var outcome: ChromeRunOutcome?
    do {
        try process.run()
        if done.wait(timeout: .now() + chromeRunTimeout) == .timedOut {
            timedOut = true
            process.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                done.wait()
            }
        }
    } catch {
        // Never started: `terminationStatus` would raise, so the outcome is said here.
        try? errorHandle.write(contentsOf: Data("cannot start \(program): \(error.localizedDescription)\n".utf8))
        outcome = ChromeRunOutcome(ok: false, status: "could not start", text: "")
    }
    try? rawHandle.close()
    try? errorHandle.close()
    let rawData = (try? Data(contentsOf: rawURL)) ?? Data()
    let result = outcome ?? chromeRunOutcome(stdout: rawData, exitCode: process.terminationStatus,
                                             timedOut: timedOut)
    let document = chromeRunResultDocument(account: account, outcome: result,
                                           raw: String(decoding: rawData, as: UTF8.self),
                                           rawPath: rawURL.path, errorPath: errorURL.path)
    try? document.write(to: resultURL, atomically: true, encoding: .utf8)
    print(resultURL.path)
    return result.ok ? 0 : 1
}
