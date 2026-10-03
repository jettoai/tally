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
//   - `--output-format stream-json --verbose`: Tally reads the run line by line, so a run that is
//     stopped (timeout, max_turns) still tells which tabs it opened; the last `result` line is the
//     same object `--output-format json` printed, and stdout.json keeps exactly that (B-468).
//     After the run, the tabs it opened and did not close are closed over AppleScript; a tab that
//     was open before the run started is never closed.

/// The model a run uses. A Chrome step is navigation and reading; the default model cost $1.61 for
/// one twelve-turn probe.
let chromeRunModel = "sonnet"
/// Room for "load the Chrome tools, call them, answer" plus a few page steps (the probe used 12),
/// and two more for closing the tabs the run opened before it answers (B-468: 19 of 88 runs ended
/// on max_turns with their tabs still open).
let chromeRunMaxTurns = 14
/// The most turns `--max-turns` accepts.
let chromeRunMaxTurnsLimit = 60
/// How long a run may take before it is stopped and reported as timed out: 600 seconds, or 30 a
/// turn when more turns were asked for. Pure.
func chromeRunTimeout(maxTurns: Int = chromeRunMaxTurns) -> TimeInterval {
    TimeInterval(max(600, maxTurns * 30))
}
/// Set on every run, so a run that tries `tally chrome run` itself is refused.
let chromeRunNestedKey = "TALLY_CHROME_RUN"

let chromeRunRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/chrome-run", isDirectory: true)

/// Never inherited from the session that started the run: a token or key would replace the config
/// home's own login, CLAUDE_CODE_SIMPLE turns Claude in Chrome off, and the supervisor marker would
/// make Tally's hook read the run as the session that asked.
let chromeRunDroppedEnvironment = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY",
                                   "CLAUDE_CODE_SIMPLE", "TALLY_SUPERVISOR_PID"]

let chromeRunUsage = "usage: tally chrome run [--max-turns <1-60>] <task> | --file <task file>"

/// The prompt: the task, wrapped so the answer comes back in a form the asking session can use.
func chromeRunPrompt(task: String) -> String {
    "You are doing one Claude in Chrome step for another Claude Code session, which reads your final"
        + " reply. Use only the Claude in Chrome tools. Save every screenshot you take to disk and list"
        + " each saved path in your final reply. Each time you open a tab, note its tab id; before"
        + " your final reply, close every tab you opened with tabs_close_mcp. Open each new tab with its"
        + " own tabs_create_mcp call, never inside browser_batch, so Tally can tell the tab is yours."
        + " End with the result the task asks for.\n\nTask:\n\n"
        + task
}

/// Everything after the program. Pure.
func chromeRunArguments(task: String, maxTurns: Int = chromeRunMaxTurns) -> [String] {
    ["-p", chromeRunPrompt(task: task),
     "--chrome",
     "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
     "--allowedTools", "mcp__claude-in-chrome__*",
     "--output-format", "stream-json", "--verbose",
     "--max-turns", String(maxTurns),
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

enum ChromeRunTask: Equatable { case task(String, maxTurns: Int = chromeRunMaxTurns), usage(String) }

/// The task from the command line: an optional leading `--max-turns <1-60>`, then `--file <path>`
/// read whole, else the words joined. Pure over `read`.
func chromeRunTask(args: [String], read: (String) -> String?) -> ChromeRunTask {
    var args = args
    var maxTurns = chromeRunMaxTurns
    if args.first == "--max-turns" {
        guard args.count >= 2, let turns = Int(args[1]), (1...chromeRunMaxTurnsLimit).contains(turns) else {
            return .usage(chromeRunUsage)
        }
        maxTurns = turns
        args.removeFirst(2)
    }
    var text: String
    if args.first == "--file" {
        guard args.count == 2 else { return .usage(chromeRunUsage) }
        guard let body = read(args[1]) else { return .usage("tally chrome run: cannot read \(args[1])") }
        text = body
    } else {
        text = args.joined(separator: " ")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? .usage(chromeRunUsage) : .task(text, maxTurns: maxTurns)
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

/// Which tabs to close: the ones the run's receipts say it opened and did not close, minus every tab
/// already open before the run started. The second check only catches tabs older than the run, not
/// a user's tab that appeared during it; ownership rests on the receipts. With no list from before
/// the run (`nil`) nothing is closed. Pure.
func chromeRunTabsToClose(_ stream: ChromeRunStream, before: Set<Int>?) -> [Int] {
    guard let before else { return [] }
    return stream.leftOpen.subtracting(before).sorted()
}

/// Lists every tab id; returns "" without starting Chrome when it is not running. The ids are
/// joined with commas: inside `tell application "Google Chrome"` the word `tab` is Chrome's tab
/// class, not the tab character.
let chromeListTabsScript = """
if application "Google Chrome" is not running then return ""
set out to ""
tell application "Google Chrome"
    repeat with w in windows
        repeat with t in tabs of w
            set out to out & (id of t as text) & ","
        end repeat
    end repeat
end tell
return out
"""

/// Closes exactly the given tab ids, wherever they are, and returns how many it closed. The ids are
/// written into the script as numbers (they are Ints, so nothing else can reach the source); a tab
/// that is already gone is skipped. Never starts Chrome. Pure.
func chromeCloseTabsScript(ids: [Int]) -> String {
    var lines = ["if application \"Google Chrome\" is not running then return \"0\"",
                 "set closedCount to 0",
                 "tell application \"Google Chrome\""]
    for id in ids {
        lines += ["    repeat with w in windows",
                  "        try",
                  "            set hits to (tabs of w whose id is \(id))",
                  "            if (count of hits) > 0 then",
                  "                close (tabs of w whose id is \(id))",
                  "                set closedCount to closedCount + (count of hits)",
                  "            end if",
                  "        end try",
                  "    end repeat"]
    }
    lines += ["end tell", "return closedCount as text"]
    return lines.joined(separator: "\n")
}

/// Runs one AppleScript with a deadline and stdin on /dev/null; nil when it failed, timed out or
/// could not start. The first run may stop on macOS asking whether this terminal may control
/// Google Chrome, so a timeout is just "could not close".
func chromeRunAppleScript(_ source: String, timeout: TimeInterval = 15) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    process.standardInput = FileHandle.nullDevice
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    guard (try? process.run()) != nil else { return nil }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = done.wait(timeout: .now() + 2)
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    // The output is a short list of numbers, far below a pipe's buffer, so reading after exit is safe.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Every open tab id; [] when Chrome is not running (no tab is open), nil when the script failed or
/// timed out (the tabs are unknown, which is not the same as none).
func chromeListTabIDs() -> Set<Int>? {
    chromeRunAppleScript(chromeListTabsScript).map { Set($0.split(separator: ",").compactMap { Int($0) }) }
}

/// The `tabs:` line of the result file. Pure.
func chromeRunTabsLine(leftOpen: Int, closed: Int?, listedBefore: Bool = true, unproven: Int = 0) -> String {
    let main = chromeRunTabsMain(leftOpen: leftOpen, closed: closed, listedBefore: listedBefore)
    return unproven == 0 ? main : main + "; \(unproven) listed tabs not proven ours, left open"
}

private func chromeRunTabsMain(leftOpen: Int, closed: Int?, listedBefore: Bool) -> String {
    if leftOpen == 0 { return "none left open" }
    guard listedBefore else { return "\(leftOpen) left open (could not list tabs before the run)" }
    guard let closed else { return "\(leftOpen) left open (could not close them)" }
    return closed == leftOpen ? "closed \(closed) the run left open"
        : "closed \(closed) of \(leftOpen) the run left open"
}

/// The stream as the reader thread builds it; the main thread takes a copy under the lock.
private final class ChromeRunStreamBox: @unchecked Sendable {
    let lock = NSLock()
    var value = ChromeRunStream()
    func scan(_ lines: [Data]) {
        lock.lock(); defer { lock.unlock() }
        for line in lines { chromeRunScan(line: line, into: &value) }
    }
    var snapshot: ChromeRunStream { lock.lock(); defer { lock.unlock() }; return value }
}

/// What the run answered, from its stdout (`--output-format json`: one object with `result`,
/// `is_error`, `subtype`). Pure.
func chromeRunOutcome(stdout: Data, exitCode: Int32, timedOut: Bool,
                      timeout: TimeInterval = chromeRunTimeout()) -> ChromeRunOutcome {
    let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]
    let text = object?["result"] as? String ?? ""
    if timedOut {
        return ChromeRunOutcome(ok: false, status: "timed out after \(Int(timeout))s", text: text)
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
                             rawPath: String, errorPath: String, tabs: String? = nil) -> String {
    let answer = outcome.text.isEmpty ? "(no answer; see the raw output and \(errorPath))" : outcome.text
    let tabsLine = tabs.map { "tabs: \($0)\n" } ?? ""
    return "# Claude in Chrome run\n\naccount: \(account)\nstatus: \(outcome.status)\n" + tabsLine
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
    let task: String, maxTurns: Int
    switch chromeRunTask(args: args, read: { try? String(contentsOfFile: $0, encoding: .utf8) }) {
    case .task(let text, let turns): (task, maxTurns) = (text, turns)
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
    let streamURL = dir.appendingPathComponent("stream.jsonl")
    let errorURL = dir.appendingPathComponent("stderr.log")
    let resultURL = dir.appendingPathComponent("result.md")
    try? task.write(to: dir.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
    manager.createFile(atPath: streamURL.path, contents: nil)
    manager.createFile(atPath: errorURL.path, contents: nil)
    guard let streamHandle = try? FileHandle(forWritingTo: streamURL),
          let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
        warn("tally chrome run: cannot write in \(dir.path)."); return 2
    }
    // Tabs open before the run are never closed by it, whatever its output says.
    let tabsBefore = chromeListTabIDs()
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: program)
    process.arguments = chromeRunArguments(task: task, maxTurns: maxTurns)
    process.environment = chromeRunEnvironment(environment, home: home)
    process.currentDirectoryURL = cwd
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errorHandle
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    let stream = ChromeRunStreamBox()
    let readerDone = DispatchSemaphore(value: 0)
    let timeout = chromeRunTimeout(maxTurns: maxTurns)
    var timedOut = false
    var outcome: ChromeRunOutcome?
    do {
        try process.run()
        // Only the child keeps the write end, so the read below ends when the run ends.
        try? output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        Thread.detachNewThread {
            // One reader, plain read(2): no buffered reader mixed with polling on this descriptor.
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                let data = Data(chunk[0..<count])
                try? streamHandle.write(contentsOf: data)
                pending.append(data)
                stream.scan(chromeRunTakeLines(&pending))
            }
            if !pending.isEmpty { stream.scan([pending]) }
            readerDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                done.wait()
            }
        }
        // A helper the run started could still hold its stdout; what was read by then is enough.
        _ = readerDone.wait(timeout: .now() + 5)
    } catch {
        try? output.fileHandleForWriting.close()
        // Never started: `terminationStatus` would raise, so the outcome is said here.
        try? errorHandle.write(contentsOf: Data("cannot start \(program): \(error.localizedDescription)\n".utf8))
        outcome = ChromeRunOutcome(ok: false, status: "could not start", text: "")
    }
    let scanned = stream.snapshot
    try? streamHandle.close()
    try? errorHandle.close()
    let resultData = scanned.result ?? Data()
    try? resultData.write(to: rawURL)  // stdout.json: the one result object, as before
    let result = outcome ?? chromeRunOutcome(stdout: resultData, exitCode: process.terminationStatus,
                                             timedOut: timedOut, timeout: timeout)
    // Closing is best effort: whatever happens here, the run's status and exit code stay as they are.
    let doomed = chromeRunTabsToClose(scanned, before: tabsBefore)
    let closed: Int? = doomed.isEmpty ? 0
        : chromeRunAppleScript(chromeCloseTabsScript(ids: doomed)).flatMap { Int($0) }
    let document = chromeRunResultDocument(account: account, outcome: result,
                                           raw: String(decoding: resultData, as: UTF8.self),
                                           rawPath: rawURL.path, errorPath: errorURL.path,
                                           tabs: chromeRunTabsLine(
                                               leftOpen: tabsBefore == nil ? scanned.leftOpen.count : doomed.count,
                                               closed: closed, listedBefore: tabsBefore != nil,
                                               unproven: scanned.unproven.subtracting(tabsBefore ?? []).count))
    try? document.write(to: resultURL, atomically: true, encoding: .utf8)
    print(resultURL.path)
    return result.ok ? 0 : 1
}
