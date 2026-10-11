import Foundation
import Darwin

// The pre-spawn check (TallyCLI/PreSpawnHook.swift) run for real through /bin/sh, plus source
// locks on where Supervisor.swift calls it. Config files live in a temp directory; ~/.tally is
// never touched.

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL"): \(name)")
    if !ok { failures += 1 }
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("prespawn-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let ctx = PreSpawnContext(provider: "claude", homePath: "/x", homeVariable: ("CLAUDE_CONFIG_DIR", "/x"),
                          label: "L", accountID: "acct", reason: "cap")

func config(_ text: String?) -> URL {
    let url = work.appendingPathComponent("\(UUID().uuidString).json")
    if let text { try! text.write(to: url, atomically: true, encoding: .utf8) }
    return url
}
func entry(_ command: String, timeout: Int = 5) -> URL {
    config("{\"claude\":{\"command\":\(String(data: try! JSONEncoder().encode(command), encoding: .utf8)!),\"timeoutSeconds\":\(timeout)}}")
}
func run(_ command: String, timeout: Int = 5) -> (PreSpawnVerdict, TimeInterval) {
    let start = Date()
    let verdict = preSpawnVerdict(ctx, url: entry(command, timeout: timeout)).verdict
    return (verdict, Date().timeIntervalSince(start))
}

// 1-3. What counts as "nothing set".
let missing = preSpawnVerdict(ctx, url: config(nil))
check("1 no file is unset and not unreadable", missing.verdict == .unset && !missing.unreadable)
check("2 a blank command is unset",
      preSpawnVerdict(ctx, url: entry("   ")).verdict == .unset)
let broken = preSpawnVerdict(ctx, url: config("not json"))
check("3 an unparsable file is unset, flagged unreadable", broken.verdict == .unset && broken.unreadable)
check("3b another provider's entry is unset for this one",
      preSpawnVerdict(PreSpawnContext(provider: "codex", homePath: "/x",
                                      homeVariable: ("CODEX_HOME", "/x"), label: "L",
                                      accountID: "a", reason: "launch"), url: entry("exit 1")).verdict == .unset)

// 4-5. Pass and reject.
check("4 exit 0 passes", run("exit 0").0 == .passed)
let rejected = run("echo 'wrong account' >&2; echo second >&2; exit 1").0
check("5 nonzero rejects with the first stderr line",
      rejected == .rejected(status: "exit 1", firstLine: "wrong account"))
let terminal = preSpawnTerminalLine(rejected, label: "Work Max") ?? ""
check("5b the terminal line names the label and the reason",
      terminal.contains("wrong account") && terminal.contains("Work Max"))
check("5c nothing to say when it passed or is unset",
      preSpawnTerminalLine(.passed, label: "L") == nil && preSpawnTerminalLine(.unset, label: "L") == nil)

// 6-7. Timeout passes, and leaves nothing behind.
let (slow, slowTime) = run("sleep 30", timeout: 1)
check("6 a hung command times out as a pass", slow == .timedOut(seconds: 1) && slowTime < 3)
let pidFile = work.appendingPathComponent("bg.pid")
_ = run("sleep 30 & echo $! > '\(pidFile.path)'; wait", timeout: 1)
let orphan = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
var orphanGone = false
for _ in 0..<10 {
    if orphan > 0 && kill(orphan, 0) == -1 && errno == ESRCH { orphanGone = true; break }
    usleep(20_000)
}
check("7 a timed-out command's background child is killed too", orphan > 0 && orphanGone)
if !orphanGone && orphan > 0 { kill(orphan, SIGKILL) }

// 8. A command that does not exist.
if case .rejected(let status, let line) = run("definitely-not-a-command-xyz").0 {
    check("8 a missing program rejects with exit 127 and says so",
          status == "exit 127" && line.contains("not found"))
} else { check("8 a missing program rejects with exit 127 and says so", false) }

// 9-12. Environment, stdin, stdout, a flood on stderr.
check("9 the target home reaches the command",
      run("[ \"$TALLY_HOME_PATH\" = /x ] && [ \"$TALLY_HOME_LABEL\" = L ] && [ \"$TALLY_ACCOUNT_ID\" = acct ] && [ \"$TALLY_SPAWN_REASON\" = cap ] && [ \"$TALLY_PROVIDER\" = claude ] && [ \"$CLAUDE_CONFIG_DIR\" = /x ]").0 == .passed)
// 9b. The home variable follows the launch, not the path: the default home launches with it UNSET
// (`launchEnv`), so the check must too, an inherited value included, or a CLI it runs reads
// another login (codex review of 858d2ef).
let inherited = ["CLAUDE_CONFIG_DIR": "/wrong", "PATH": "/usr/bin:/bin"]
let defaultCtx = PreSpawnContext(provider: "claude", homePath: "/d", homeVariable: ("CLAUDE_CONFIG_DIR", nil),
                                 label: "L", accountID: "acct", reason: "launch")
check("9b a home launched with the variable unset is checked with it unset, inherited value too",
      preSpawnEnvironment(defaultCtx, base: inherited)["CLAUDE_CONFIG_DIR"] == nil
          && preSpawnEnvironment(defaultCtx, base: inherited)["TALLY_HOME_PATH"] == "/d")
check("9c a home launched with the variable set is checked with that value over an inherited one",
      preSpawnEnvironment(ctx, base: inherited)["CLAUDE_CONFIG_DIR"] == "/x")
check("10 stdin is not a terminal (and not readable input)",
      run("[ -t 0 ] && exit 3; read x && exit 4; exit 0").0 == .passed)
let capture = work.appendingPathComponent("stdout.txt")
fflush(stdout)
let savedOut = dup(STDOUT_FILENO)
let captureFD = open(capture.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
dup2(captureFD, STDOUT_FILENO)
let leakVerdict = run("echo LEAK; exit 0").0
fflush(stdout)
dup2(savedOut, STDOUT_FILENO)
close(captureFD); close(savedOut)
let leaked = (try? String(contentsOf: capture, encoding: .utf8)) ?? "unreadable"
check("11 the command's stdout never reaches ours", leakVerdict == .passed && !leaked.contains("LEAK"))
let (flood, floodTime) = run("head -c 200000 /dev/zero | tr '\\0' x >&2; exit 2")
if case .rejected(let status, let line) = flood {
    check("12 a large stderr neither blocks nor overflows the reason",
          status == "exit 2" && line.count == 200 && floodTime < 2)
} else { check("12 a large stderr neither blocks nor overflows the reason", false) }

// 13. The handoff log line.
let logLine = preSpawnLogLine(.rejected(status: "exit 1", firstLine: "a\tb\nc"), pid: "42",
                              from: "A", to: "B", reason: "cap") ?? ""
check("13 the log line is one line with fixed fields",
      logLine.hasSuffix("\n") && logLine.dropLast().split(separator: "\n").count == 1
          && logLine.dropLast().components(separatedBy: "\t").count == 8
          && logLine.contains("\tprespawn-rejected\tpid=42\tfrom=A\tto=B\treason=cap\texit 1\ta b c"))
check("13b a timeout is logged as such; a pass is not logged",
      (preSpawnLogLine(.timedOut(seconds: 5), pid: "1", from: "A", to: "B", reason: "cap") ?? "")
          .contains("\tprespawn-timeout\t")
          && preSpawnLogLine(.passed, pid: "1", from: "A", to: "B", reason: "cap") == nil)

// 14. The file the CLI writes.
let saved = work.appendingPathComponent("sub/prespawn.json")
try! savePreSpawn(["claude": PreSpawnEntry(command: "exit 0", timeoutSeconds: 7)], to: saved)
let mode = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int) ?? 0
check("14 the saved file is owner-only and reads back",
      mode == 0o600 && readPreSpawn(provider: "claude", url: saved)
          == .entry(PreSpawnEntry(command: "exit 0", timeoutSeconds: 7)))
try! savePreSpawn([:], to: saved)
check("14b clearing the last entry removes the file",
      !FileManager.default.fileExists(atPath: saved.path))

// 14c. The relaunch hold: a rejection is not asked again until it lapses, anything else is.
var hold = PreSpawnHold()
var runs = 0
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let reject: (PreSpawnContext) -> PreSpawnVerdict = { _ in runs += 1; return .rejected(status: "exit 1", firstLine: "no") }
let first = hold.ask(ctx, now: t0, check: reject)
let again = hold.ask(ctx, now: t0.addingTimeInterval(preSpawnHoldSeconds - 1), check: reject)
check("14c a rejected target is held without running the check again",
      first == .rejected(status: "exit 1", firstLine: "no") && again == nil && runs == 1)
let lapsed = hold.ask(ctx, now: t0.addingTimeInterval(preSpawnHoldSeconds + 1), check: { _ in runs += 1; return .passed })
check("14d once the hold lapses it asks again, and a pass clears the hold",
      lapsed == .passed && runs == 2 && hold.until[ctx.accountID] == nil)

// 15. Where the supervisor calls it.
let source = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
check("15 the supervisor source is readable", !source.isEmpty)
let gateA = source.range(of: "preSpawnVerdict(")
let signals = source.range(of: "signal(SIGINT, SIG_IGN)")
check("15a the first-launch gate runs before the signal dispositions",
      gateA != nil && signals != nil && gateA!.lowerBound < signals!.lowerBound)
// The relaunch gate is part of the tick's one "is this child being replaced" answer: asked after the
// fork hold and BEFORE the input gate reads it, and a rejection turns that answer to false. Asked
// after the input gate, a rejected tick held every `tally session send` until it expired (codex
// review of 858d2ef).
let forkHold = source.range(of: "var replacingChild = relaunchIsHappening(")
let gateB = forkHold.flatMap { source.range(of: "!preSpawnAdmits(", range: $0.upperBound ..< source.endIndex) }
let inputGate = source.range(of: "let action = applySessionInput(")
let commit = source.range(of: "safeguardRecord?.commit()")
let handoff = source.range(of: "performHandoff(to: plan.target")
check("15b the relaunch gate runs after the fork hold, before the input gate and before any teardown",
      forkHold != nil && gateB != nil && inputGate != nil && commit != nil && handoff != nil
          && gateB!.lowerBound < inputGate!.lowerBound && gateB!.lowerBound < commit!.lowerBound
          && gateB!.lowerBound < handoff!.lowerBound)
let standDown = gateB.flatMap { source[$0.upperBound ..< inputGate!.lowerBound].range(of: "replacingChild = false") }
check("15b2 a rejection stands the tick down as one with nothing planned",
      standDown != nil && source[gateB!.upperBound ..< inputGate!.lowerBound].contains("plan = nil"))
check("15b3 nothing asks the check a second time at the execution point",
      source.components(separatedBy: "preSpawnVerdict(").count == 2)
// A `tally session clear` landing answers its caller as it lands, so the move is asked about there.
let boundary = source.range(of: "clearBoundary: {")
let boundaryEnd = boundary.flatMap { source.range(of: "windowRepick.apply(action.repick", range: $0.upperBound ..< source.endIndex) }
check("15d a clear's move is asked of the check before the caller is told it moved",
      boundary != nil && boundaryEnd != nil
          && source[boundary!.upperBound ..< boundaryEnd!.lowerBound].contains("preSpawnAdmits(move,")
          && source[boundary!.upperBound ..< boundaryEnd!.lowerBound].contains("? target : nil"))
check("15c there is still exactly one place a child is spawned",
      source.components(separatedBy: "spawnChild([provider.cli]").count == 2)

print(failures == 0 ? "all prespawn checks passed" : "\(failures) prespawn check(s) failed")
exit(failures == 0 ? 0 : 1)
