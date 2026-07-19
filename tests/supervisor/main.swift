import Foundation

// Assertion harness for the supervisor's transcript-model tracking, compiled against the real
// source. Regression for the 2026-07-19 live misfire: a continued session replays its whole
// history, and unguarded "model" scanning poisoned lastModel with old lines and "<synthetic>"
// error turns - the degradation rescue then ping-ponged the session between accounts unprompted.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

let launch = Date(timeIntervalSince1970: 1_800_000_000)
let iso = ISO8601DateFormatter()
func stamp(_ offset: TimeInterval) -> String { iso.string(from: launch.addingTimeInterval(offset)) }

func watcherAfterScanning(_ lines: [String]) -> TranscriptWatcher {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-watcher-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("session.jsonl")
    try! lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    var watcher = TranscriptWatcher(projectDir: dir, file: file, since: launch)
    _ = watcher.sawCapHit()
    return watcher
}

// 1. The misfire: history older than launch (real model ids AND synthetic turns) must not count.
let poisoned = watcherAfterScanning([
    #"{"timestamp":"\#(stamp(-3600))","message":{"model":"claude-opus-4-8"}}"#,
    #"{"timestamp":"\#(stamp(-1800))","message":{"model":"<synthetic>"}}"#,
])
check("replayed history never sets lastModel", poisoned.lastModel == nil)

// 2. A fresh real event does count - this is the genuine degradation signal.
let degraded = watcherAfterScanning([
    #"{"timestamp":"\#(stamp(-3600))","message":{"model":"claude-fable-5"}}"#,
    #"{"timestamp":"\#(stamp(60))","message":{"model":"claude-opus-4-8"}}"#,
])
check("fresh event sets lastModel", degraded.lastModel == "claude-opus-4-8")

// 3. Fresh but synthetic (error turns) and sidechain (subagents run their own models) events
//    must both be ignored.
let noisy = watcherAfterScanning([
    #"{"timestamp":"\#(stamp(30))","message":{"model":"claude-fable-5"}}"#,
    #"{"timestamp":"\#(stamp(60))","message":{"model":"<synthetic>"}}"#,
    #"{"timestamp":"\#(stamp(90))","isSidechain":true,"message":{"model":"claude-haiku-4-5"}}"#,
])
check("synthetic and sidechain events do not overwrite", noisy.lastModel == "claude-fable-5")

// 4. A line without a timestamp cannot prove it is new - rejected.
let stampless = watcherAfterScanning([#"{"message":{"model":"claude-opus-4-8"}}"#])
check("stampless lines are rejected", stampless.lastModel == nil)

// 5. The session's expectation comes from its actual launch args (typed --model outranks the
//    configured default).
check("flagValue reads the launched model", flagValue(["--continue", "--model", "haiku"], "--model") == "haiku")
check("flagValue absent flag is nil", flagValue(["--continue"], "--model") == nil)
check("flagValue dangling flag is nil", flagValue(["--model"], "--model") == nil)

exit(failures == 0 ? 0 : 1)
