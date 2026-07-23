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

// 6. R8: a resumed handoff pins <id>.jsonl directly, so two sessions in one directory never
//    cross-bind. Without an id the mtime heuristic still finds the newest file; an id that is
//    not yet in this account's tree falls back to that heuristic too.
func watcherLocating(resumeID: String?, files: [String: TimeInterval]) -> TranscriptWatcher {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-locate-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, offset) in files {
        let url = dir.appendingPathComponent(name)
        try! "{}".write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.modificationDate: launch.addingTimeInterval(offset)], ofItemAtPath: url.path)
    }
    var watcher = TranscriptWatcher(projectDir: dir, since: launch, resumeID: resumeID)
    watcher.locateFile()
    return watcher
}
let pinnedTranscript = watcherLocating(resumeID: "aaaa", files: ["aaaa.jsonl": 10, "bbbb.jsonl": 100])
check("resume id pins its own transcript over a newer sibling",
      pinnedTranscript.file?.lastPathComponent == "aaaa.jsonl")
let heuristicTranscript = watcherLocating(resumeID: nil, files: ["aaaa.jsonl": 10, "bbbb.jsonl": 100])
check("no resume id falls back to the newest file",
      heuristicTranscript.file?.lastPathComponent == "bbbb.jsonl")
let missingTranscript = watcherLocating(resumeID: "cccc", files: ["aaaa.jsonl": 10, "bbbb.jsonl": 100])
check("resume id absent from tree falls back to the heuristic",
      missingTranscript.file?.lastPathComponent == "bbbb.jsonl")

// 7. R4: the cap-recovery priority order (pure decision, no child needed). Pinned outranks
//    everything (staying put is what a pin means), then the fuse, then a stale snapshot, then
//    no eligible sibling; only a clear board hands off.
check("manual pin stays put", capRecoveryAction(mode: "manual", fuseAllows: true,
      snapshotStale: false, hasTarget: true) == .waitPinned)
check("spent fuse waits", capRecoveryAction(mode: "auto", fuseAllows: false,
      snapshotStale: false, hasTarget: true) == .waitFuse)
check("stale snapshot waits", capRecoveryAction(mode: "auto", fuseAllows: true,
      snapshotStale: true, hasTarget: true) == .waitStale)
check("no eligible sibling waits", capRecoveryAction(mode: "auto", fuseAllows: true,
      snapshotStale: false, hasTarget: false) == .waitNoTarget)
check("clear board hands off", capRecoveryAction(mode: "auto", fuseAllows: true,
      snapshotStale: false, hasTarget: true) == .handoff)
// Unpinning a capped session hands off with no second cap event: same pending state, mode flips
// auto, the board is otherwise clear.
check("unpin flips a pinned wait straight to handoff",
      capRecoveryAction(mode: "auto", fuseAllows: true, snapshotStale: false, hasTarget: true)
      == .handoff)

// 8. A main-chain assistant event newer than the cap clears the pending recovery (came back on
//    its own); an event OLDER than the cap (replayed history) does not.
let cappedAt = launch.addingTimeInterval(100)
let recoveredWatcher = watcherAfterScanning([
    #"{"timestamp":"\#(stamp(200))","message":{"model":"claude-fable-5"}}"#,
])
check("a post-cap assistant event signals self-recovery",
      (recoveredWatcher.lastMainChainEventAt.map { $0 > cappedAt }) == true)
let staleWatcher = watcherAfterScanning([
    #"{"timestamp":"\#(stamp(50))","message":{"model":"claude-fable-5"}}"#,
])
check("a pre-cap assistant event does not signal recovery",
      (staleWatcher.lastMainChainEventAt.map { $0 > cappedAt }) != true)

exit(failures == 0 ? 0 : 1)
