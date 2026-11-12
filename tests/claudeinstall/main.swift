import Foundation

// Assertion harness for the in-app Claude Code install: the pure reading rules
// (Tally/Core/ClaudeInstall.swift) and the runner that drives a real /bin/bash on a pty
// (Tally/Core/ClaudeInstallRunner.swift). The "install script" is always a one-liner written here.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// MARK: pure rules

expect(ClaudeInstall.supports("claude") && !ClaudeInstall.supports("codex"),
       "the in-app install is Claude only; Codex keeps Install in Terminal")
expect(ClaudeInstall.failure(lastLine: "", exitCode: 0, cliFound: true) == nil,
       "exit 0 and a findable CLI is an install")
expect(ClaudeInstall.failure(lastLine: "Done", exitCode: 0, cliFound: false) == .notFound,
       "exit 0 without a findable CLI is not an install")
expect(ClaudeInstall.failure(lastLine: "Failed to get a valid version from x", exitCode: 1, cliFound: false) == .unreachable
       && ClaudeInstall.failure(lastLine: "curl: Could not resolve host: example", exitCode: 6, cliFound: false) == .unreachable,
       "a network failure line reads as unreachable")
expect(ClaudeInstall.failure(lastLine: "Checksum verification failed", exitCode: 1, cliFound: false) == .checksum,
       "a checksum line reads as checksum")
expect(ClaudeInstall.failure(lastLine: "boom", exitCode: 1, cliFound: true) == .other,
       "any other non-zero exit is other, even with a CLI around")
expect(ClaudeInstall.downloadBytes([("claude-1.0", 10), ("claude-2.0", 52), ("other", 999)]) == 52
       && ClaudeInstall.downloadBytes([("other", 5)]) == nil && ClaudeInstall.downloadBytes([]) == nil,
       "the download size is the largest claude- entry, and nil without one")
expect(ClaudeInstall.stage(plainOutput: "x", downloadBytes: nil, downloadSeen: false) == .fetching
       && ClaudeInstall.stage(plainOutput: "x", downloadBytes: 7, downloadSeen: true) == .downloading(bytes: 7)
       && ClaudeInstall.stage(plainOutput: "a\nSetting up Claude Code...\n", downloadBytes: 7, downloadSeen: true) == .settingUp,
       "the stage follows the output and the download file")
expect(ClaudeInstall.lastLine("one\ntwo  \n\n  \n") == "two" && ClaudeInstall.lastLine("") == ""
       && ClaudeInstall.lastLine(String(repeating: "x", count: 500)).count == 300,
       "the last line ignores trailing blanks and is capped")
expect(ClaudeInstall.tail("a\n\nb\nc\n", lines: 2) == ["b", "c"], "the tail keeps the last non-empty lines")

// MARK: the runner, against a real bash

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _pid: pid_t = 0
    private var _updates: [ClaudeInstallRunner.Update] = []
    var pid: pid_t { lock.lock(); defer { lock.unlock() }; return _pid }
    var updates: [ClaudeInstallRunner.Update] { lock.lock(); defer { lock.unlock() }; return _updates }
    func setPid(_ p: pid_t) { lock.lock(); _pid = p; lock.unlock() }
    func add(_ u: ClaudeInstallRunner.Update) { lock.lock(); _updates.append(u); lock.unlock() }
}

final class Result: @unchecked Sendable { var outcome = ClaudeInstallRunner.Outcome.cancelled }

struct Run {
    var outcome: ClaudeInstallRunner.Outcome
    var log: String
    var box: Box
    var seconds: TimeInterval
    var home: URL
}

/// Runs `command` through the runner in a fresh temp home. `cancelAfter` raises Cancel from a timer.
func runInstall(_ command: String, cliFound: Bool = true, stall: TimeInterval = 90, overall: TimeInterval = 600,
                cancelAfter: TimeInterval? = nil) -> Run {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudeinstall-\(UUID().uuidString)")
    let home = dir.appendingPathComponent("home")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("install.log")
    let cancel = ClaudeInstallRunner.Cancel()
    let box = Box()
    let result = Result()
    if let after = cancelAfter {
        DispatchQueue.global().asyncAfter(deadline: .now() + after) { cancel.raise() }
    }
    let semaphore = DispatchSemaphore(value: 0)
    let started = Date()
    Task {
        result.outcome = await ClaudeInstallRunner.run(
            command: command, home: home.path, log: log, stallSeconds: stall, overallSeconds: overall,
            cancel: cancel, onStart: { box.setPid($0) }, onUpdate: { box.add($0) }, cliFound: { cliFound })
        semaphore.signal()
    }
    semaphore.wait()
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    return Run(outcome: result.outcome, log: text, box: box, seconds: Date().timeIntervalSince(started), home: home)
}

extension ClaudeInstallRunner.Outcome {
    var isTooLong: Bool { if case .failed(let r) = self { return r.failure == .tooLong } else { return false } }
}

// 1. a plain success, output in the log
let r1 = runInstall("echo hi")
expect(r1.outcome == .installed && r1.log.contains("hi"),
       "a script that exits 0 with the CLI found is installed, and its output is logged")

// 2. exit 0 but no CLI
expect(runInstall("true", cliFound: false).outcome == .failed(.init(failure: .notFound, lastLine: "")),
       "exit 0 without a findable CLI fails as notFound")

// 3. the unreachable line is quoted back
let line3 = "Failed to get a valid version from downloads.claude.ai"
expect(runInstall("echo '\(line3)'; exit 1", cliFound: false).outcome == .failed(.init(failure: .unreachable, lastLine: line3)),
       "a network failure ends as unreachable with the script's own last line")

// 4. checksum
expect(runInstall("echo 'Checksum verification failed'; exit 1", cliFound: false).outcome
       == .failed(.init(failure: .checksum, lastLine: "Checksum verification failed")),
       "a checksum failure ends as checksum")

// 5. pipefail: a failed download piped to a shell must not read as success
expect(runInstall("false | cat").outcome == .failed(.init(failure: .other, lastLine: "")),
       "the command runs under pipefail, so a failed download is a failed install")

// 6. cancel ends the whole process group
let r6 = runInstall("sleep 30 | cat", cancelAfter: 1)
var groupGone = false
for _ in 0 ..< 40 {
    if kill(-r6.box.pid, 0) == -1 && errno == ESRCH { groupGone = true; break }
    usleep(50_000)
}
expect(r6.outcome == .cancelled && r6.seconds < 5 && r6.box.pid > 0 && groupGone,
       "Cancel ends the whole process group: bash, sleep and cat are all gone")

// 7. a silent script is a stall
let r7 = runInstall("sleep 10", stall: 2)
expect(r7.outcome == .failed(.init(failure: .stalled, lastLine: "")) && r7.seconds < 6,
       "no output and no download growth for the stall window is a stall")

// 8. a growing download file is progress
let r8 = runInstall("mkdir -p \"$HOME/.claude/downloads\"; for i in 1 2 3 4; do printf x >> \"$HOME/.claude/downloads/claude-x\"; sleep 1; done",
                    stall: 2)
expect(r8.outcome == .installed, "a growing download file keeps a silent script from reading as a stall")
expect(r8.box.updates.contains { if case .downloading = $0.stage { return true } else { return false } },
       "the stage reports the download once its file exists")

// 9. the settling-up stage
let r9 = runInstall("echo 'Setting up Claude Code...'; sleep 1")
expect(r9.box.updates.contains { $0.stage == .settingUp }, "the stage reaches settingUp when the script says so")

// 10. stdin is /dev/null, so a prompt does not wait for a person
let r10 = runInstall("read x; echo \"rc=$?\"")
expect(r10.seconds < 3 && r10.log.contains("rc=1"), "a script that reads input gets EOF instead of waiting")

// 11. control codes stay out of the log
let r11 = runInstall("printf '\\033[31mred\\033[0m\\n'")
expect(r11.log.contains("red") && !r11.log.contains("\u{1B}"), "the log holds the output without terminal control codes")

// 12. the overall clock
let r12 = runInstall("while :; do echo tick; sleep 0.5; done", overall: 2)
expect(r12.outcome.isTooLong && r12.seconds < 7, "a script that keeps going past the overall limit is stopped as tooLong")

// 13. HOME is the one handed in, and the env is the narrow one
let r13 = runInstall("echo \"$HOME\"; echo \"$PATH\"")
expect(r13.log.contains(r13.home.path) && r13.log.contains("/usr/bin:/bin:/usr/sbin:/sbin"),
       "the script runs with the given home and a system-only PATH")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASS")
