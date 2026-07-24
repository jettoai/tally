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

// 9. R3: the fuse is per-supervisor and in memory - five sessions hitting a fleet-wide drain at
//    once never burn each other's budget. One fuse allows its first `max` recoveries, blocks the
//    next, and recovers after the window; a separate fuse is fully independent.
let fuseT0 = Date(timeIntervalSince1970: 1_800_000_000)
var fuseA = RecoveryFuse(max: 3, window: 600)
check("first recovery allowed", fuseA.allows(now: fuseT0)); fuseA.record(now: fuseT0)
check("second recovery allowed", fuseA.allows(now: fuseT0)); fuseA.record(now: fuseT0)
check("third recovery allowed", fuseA.allows(now: fuseT0)); fuseA.record(now: fuseT0)
check("fourth recovery blocked (3 in the window)", !fuseA.allows(now: fuseT0))
check("allowed again once the window rolls past",
      fuseA.allows(now: fuseT0.addingTimeInterval(601)))
var fuseB = RecoveryFuse(max: 3, window: 600)
check("a separate supervisor's fuse is independent", fuseB.allows(now: fuseT0))

// 10. R5: a just-capped account is quarantined across launches via the shared per-account record,
//     the record expires on its TTL, an id with a slash round-trips, and session-local entries
//     union with the shared ones. `nil` model = a whole-account quarantine (blocks any pick).
let qDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-quarantine-test-\(UUID().uuidString)")
let qNow = Date(timeIntervalSince1970: 1_800_000_000)
quarantineAccount("acct-2", model: nil, until: qNow.addingTimeInterval(600), dir: qDir)
quarantineAccount("with/slash", model: nil, until: qNow.addingTimeInterval(600), dir: qDir)
check("a freshly capped account is quarantined",
      quarantinedAccounts(forPrimary: "fable", now: qNow, dir: qDir).contains("acct-2"))
check("an id with a slash round-trips",
      quarantinedAccounts(forPrimary: "fable", now: qNow, dir: qDir).contains("with/slash"))
check("the record expires after its TTL",
      !quarantinedAccounts(forPrimary: "fable", now: qNow.addingTimeInterval(601), dir: qDir)
          .contains("acct-2"))
check("session-local quarantine unions with the shared records",
      quarantinedAccounts(forPrimary: "fable",
                          sessionLocal: ["local-1": (model: nil, until: qNow.addingTimeInterval(60))],
                          now: qNow, dir: qDir).contains("local-1"))

// 10b. F2: a quarantine is scoped to the model window that capped. A fable-window cap does not
//      exclude the account from a sonnet pick (that pick does not spend the fable window), but does
//      from a fable pick; a nil (whole-account / legacy) quarantine blocks everything.
let mDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-quarantine-model-\(UUID().uuidString)")
quarantineAccount("acct-fable", model: "fable", until: qNow.addingTimeInterval(600), dir: mDir)
check("a fable quarantine does not block a sonnet pick",
      !quarantinedAccounts(forPrimary: "sonnet", now: qNow, dir: mDir).contains("acct-fable"))
check("a fable quarantine blocks a fable pick",
      quarantinedAccounts(forPrimary: "fable", now: qNow, dir: mDir).contains("acct-fable"))
check("a fable quarantine blocks a nil (flagship-first) pick",
      quarantinedAccounts(forPrimary: nil, now: qNow, dir: mDir).contains("acct-fable"))
check("quarantineBlocks: fable does not block sonnet",
      !quarantineBlocks(quarantineModel: "fable", pickModel: "sonnet"))
check("quarantineBlocks: fable blocks fable",
      quarantineBlocks(quarantineModel: "fable", pickModel: "fable"))
check("quarantineBlocks: a nil quarantine blocks all",
      quarantineBlocks(quarantineModel: nil, pickModel: "sonnet"))
check("quarantineBlocks: a nil pick is blocked by any",
      quarantineBlocks(quarantineModel: "fable", pickModel: nil))
// A legacy space-separated record (no model field) is read as a whole-account quarantine.
let lDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-quarantine-legacy-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: lDir, withIntermediateDirectories: true)
try! "\(qNow.addingTimeInterval(600).timeIntervalSince1970) legacy-acct"
    .write(to: lDir.appendingPathComponent("legacy-acct"), atomically: true, encoding: .utf8)
check("a legacy record blocks any pick (read as whole-account)",
      quarantinedAccounts(forPrimary: "sonnet", now: qNow, dir: lDir).contains("legacy-acct"))

// 11. R2/R6: the status line's supervision note. A matching version is silent; a mismatch is
//     "outdated"; a missing supervisor version is "unknown" (never "outdated" - a --no-handoff
//     bare launch has none either); a session not steered by Tally says nothing.
check("matching version is silent",
      supervisionStatus(steered: true, supervised: true, supervisorVersion: "0.18.0", installedVersion: "0.18.0") == .ok)
check("a version mismatch is outdated",
      supervisionStatus(steered: true, supervised: true, supervisorVersion: "0.17.0", installedVersion: "0.18.0") == .outdated)
check("a missing supervisor version is unknown, not outdated",
      supervisionStatus(steered: true, supervised: true, supervisorVersion: nil, installedVersion: "0.18.0") == .unknown)
check("a session not steered by Tally has no note",
      supervisionStatus(steered: false, supervised: true, supervisorVersion: nil, installedVersion: "0.18.0") == .notSteered)
check("an unknown installed version can't assert outdated",
      supervisionStatus(steered: true, supervised: true, supervisorVersion: "0.17.0", installedVersion: nil) == .ok)
check("outdated renders a restart nudge", SupervisionStatus.outdated.note?.contains("restart") == true)
check("ok renders no note", SupervisionStatus.ok.note == nil)

// F3: a deliberate unsupervised launch (the opt-out marker is stamped) stays quiet, even without a
// version - it is a choice, not an outdated supervisor. Only a supervised launch with no version is
// "unknown" (an old pre-marker supervisor still gets nagged).
check("a deliberately unsupervised launch has no note",
      supervisionStatus(steered: true, supervised: false, supervisorVersion: nil, installedVersion: "0.18.0") == .notSupervised)
check("notSupervised renders no note", SupervisionStatus.notSupervised.note == nil)
check("supervised but versionless is still unknown (old supervisor)",
      supervisionStatus(steered: true, supervised: true, supervisorVersion: nil, installedVersion: "0.18.0") == .unknown)

// 12. Safeguard flag: the real model_refusal_fallback shape parses into a SafeguardFlag with every
//     field; a sidechain copy and one older than launch are both ignored (a resumed session replays
//     its history, so a stale flag must never re-raise).
func flagLine(_ offset: TimeInterval, uuid: String = "u-trigger", sidechain: Bool = false,
              from: String = "claude-fable-5", to: String = "claude-opus-4-8",
              category: String = "cyber") -> String {
    #"{"type":"system","subtype":"model_refusal_fallback","level":"warning","trigger":"refusal","direction":"retry","originalModel":"\#(from)","fallbackModel":"\#(to)","apiRefusalCategory":"\#(category)","refusedUserMessageUuid":"\#(uuid)","timestamp":"\#(stamp(offset))","isSidechain":\#(sidechain)}"#
}
let flagged = watcherAfterScanning([flagLine(60)])
check("a fallback event captures originalModel", flagged.lastFlag?.from == "claude-fable-5")
check("a fallback event captures fallbackModel", flagged.lastFlag?.to == "claude-opus-4-8")
check("a fallback event captures the refusal category", flagged.lastFlag?.category == "cyber")
check("a fallback event captures the refused uuid", flagged.lastFlag?.refusedUUID == "u-trigger")
check("a sidechain fallback is ignored", watcherAfterScanning([flagLine(60, sidechain: true)]).lastFlag == nil)
check("a fallback older than launch is ignored", watcherAfterScanning([flagLine(-60)]).lastFlag == nil)

// 13. User excerpt map: the refused message resolves to its prompt; an unknown uuid and a sidechain
//     prompt both resolve to nil; the FIFO evicts the oldest past its capacity. The `parentUuid`
//     (camelCase, no leading quote before "uuid") must not shadow the event's own uuid.
func userLine(_ offset: TimeInterval, uuid: String, text: String, sidechain: Bool = false) -> String {
    #"{"parentUuid":"p-\#(uuid)","type":"user","uuid":"\#(uuid)","isSidechain":\#(sidechain),"timestamp":"\#(stamp(offset))","message":{"role":"user","content":"\#(text)"}}"#
}
let withExcerpt = watcherAfterScanning([
    userLine(10, uuid: "u-trigger", text: "please scan this binary for vulns"),
    flagLine(60, uuid: "u-trigger"),
])
check("driftTriggerExcerpt resolves the refused prompt",
      withExcerpt.driftTriggerExcerpt == "please scan this binary for vulns")
let unknownExcerpt = watcherAfterScanning([
    userLine(10, uuid: "u-other", text: "hello"),
    flagLine(60, uuid: "u-missing"),
])
check("an unknown refused uuid resolves to nil", unknownExcerpt.driftTriggerExcerpt == nil)
let sidechainUser = watcherAfterScanning([
    userLine(10, uuid: "u-side", text: "subagent prompt", sidechain: true),
    flagLine(60, uuid: "u-side"),
])
check("a sidechain user line is not remembered", sidechainUser.driftTriggerExcerpt == nil)
var manyUsers: [String] = []
for i in 0..<65 { manyUsers.append(userLine(Double(i), uuid: "u-\(i)", text: "prompt \(i)")) }
check("the oldest user excerpt is evicted past capacity",
      watcherAfterScanning(manyUsers + [flagLine(100, uuid: "u-0")]).driftTriggerExcerpt == nil)
check("a recent user excerpt survives eviction",
      watcherAfterScanning(manyUsers + [flagLine(100, uuid: "u-64")]).driftTriggerExcerpt == "prompt 64")

// 14. DriftMonitor: a flag opens an episode; the nudge waits out the cooldown then fires once; a
//     newer flag re-arms it; the actual model returning to the primary clears with a duration.
let dT0 = Date(timeIntervalSince1970: 1_800_000_000)
func mkFlag(_ offset: TimeInterval, uuid: String = "f") -> SafeguardFlag {
    SafeguardFlag(at: dT0.addingTimeInterval(offset), from: "claude-fable-5",
                  to: "claude-opus-4-8", category: "cyber", refusedUUID: uuid)
}
var mon = DriftMonitor()
check("a flag starts an episode",
      mon.tick(flag: mkFlag(0), actualModel: "claude-opus-4-8", primary: "fable", now: dT0)
      == .started(mkFlag(0)))
check("the episode is active", mon.isActive)
check("activeFrom is the drifted-from model", mon.activeFrom == "claude-fable-5")
check("no nudge before the cooldown", !mon.shouldNudge(now: dT0.addingTimeInterval(60)))
check("a nudge after the cooldown", mon.shouldNudge(now: dT0.addingTimeInterval(301)))
mon.markNudged()
check("the nudge fires only once", !mon.shouldNudge(now: dT0.addingTimeInterval(400)))
_ = mon.tick(flag: mkFlag(400, uuid: "f2"), actualModel: "claude-opus-4-8", primary: "fable",
             now: dT0.addingTimeInterval(400))
check("a newer flag re-arms the nudge cooldown", !mon.shouldNudge(now: dT0.addingTimeInterval(460)))
check("and it re-fires after another cooldown", mon.shouldNudge(now: dT0.addingTimeInterval(701)))
let cleared = mon.tick(flag: mkFlag(400, uuid: "f2"), actualModel: "claude-fable-5",
                       primary: "fable", now: dT0.addingTimeInterval(800))
check("returning to the primary clears the episode with its duration", cleared == .cleared(800))
check("the episode is inactive after clearing", !mon.isActive)
check("a re-read of the same flag does not re-open a cleared episode",
      mon.tick(flag: mkFlag(400, uuid: "f2"), actualModel: "claude-fable-5", primary: "fable",
               now: dT0.addingTimeInterval(900)) == nil)

// 14b. No declared primary (Settings model cleared, no --model): the episode still opens, and the
//      actual model returning to the drifted-from model clears it - the state machine must never
//      hold a dead-end episode that outlives the user's /model switch-back.
var nilPrimary = DriftMonitor()
_ = nilPrimary.tick(flag: mkFlag(0), actualModel: "claude-opus-4-8", primary: nil, now: dT0)
check("a flag opens an episode even with no declared primary", nilPrimary.isActive)
check("with no primary, returning to the drifted-from model clears the episode",
      nilPrimary.tick(flag: mkFlag(0), actualModel: "claude-fable-5", primary: nil,
                      now: dT0.addingTimeInterval(120)) == .cleared(120))
check("the nil-primary episode is inactive after clearing", !nilPrimary.isActive)

// 15. The gate: isActive is exactly the value the fallback/rescue blocks read (they run on
//     !isActive). Active through the episode (paths suppressed), inactive once cleared (re-enabled).
var gateMon = DriftMonitor()
_ = gateMon.tick(flag: mkFlag(0), actualModel: "claude-opus-4-8", primary: "fable", now: dT0)
check("quota-degradation paths are gated while drift is active", gateMon.isActive)
_ = gateMon.tick(flag: mkFlag(0), actualModel: "claude-fable-5", primary: "fable",
                 now: dT0.addingTimeInterval(30))
check("quota-degradation paths re-enable once drift clears", !gateMon.isActive)

// 16. The drift state file: write -> read roundtrip, cleared -> gone, missing -> nil (injected dir).
let sDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-drift-state-\(UUID().uuidString)")
writeDriftState(mkFlag(0), pid: "12345", dir: sDir)
check("drift state round-trips through the file",
      readDriftState(pid: "12345", dir: sDir)
      == DriftState(from: "claude-fable-5", to: "claude-opus-4-8", category: "cyber"))
clearDriftState(pid: "12345", dir: sDir)
check("clearing removes the state file", readDriftState(pid: "12345", dir: sDir) == nil)
check("a missing state file reads as nil", readDriftState(pid: "99999", dir: sDir) == nil)
check("shortModelName trims a claude id to its family", shortModelName("claude-fable-5") == "fable")
check("shortModelName trims opus too", shortModelName("claude-opus-4-8") == "opus")

// 17. Classification is mutually exclusive: a cap event never raises a drift flag, and a drift
//     event never trips the cap detector (their transcript shapes do not overlap).
func scanForCap(_ lines: [String]) -> (hit: Bool, watcher: TranscriptWatcher) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-excl-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("session.jsonl")
    try! lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    var w = TranscriptWatcher(projectDir: dir, file: file, since: launch)
    return (w.sawCapHit(), w)
}
let capLine = #"{"timestamp":"\#(stamp(60))","isApiErrorMessage":true,"message":{"content":"You've hit your session limit"}}"#
let flagScan = scanForCap([flagLine(60, uuid: "u-x")])
check("a drift event does not trip the cap detector", !flagScan.hit)
check("a drift event raises a flag", flagScan.watcher.lastFlag != nil)
let capScan = scanForCap([capLine])
check("a cap event trips the cap detector", capScan.hit)
check("a cap event raises no drift flag", capScan.watcher.lastFlag == nil)

// MARK: - 18. Dead-supervisor state sweep

let sweepDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tally-sweep-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: sweepDir, withIntermediateDirectories: true)
for name in ["99999", String(getpid()), "notes.txt"] {
    try? "a\tb\tc\t1".write(to: sweepDir.appendingPathComponent(name),
                            atomically: true, encoding: .utf8)
}
sweepDeadSupervisorState(dir: sweepDir)
check("sweep reaps a dead supervisor's state file",
      !FileManager.default.fileExists(atPath: sweepDir.appendingPathComponent("99999").path))
check("sweep keeps a live supervisor's state file",
      FileManager.default.fileExists(atPath: sweepDir.appendingPathComponent(String(getpid())).path))
check("sweep leaves non-pid files alone",
      FileManager.default.fileExists(atPath: sweepDir.appendingPathComponent("notes.txt").path))

exit(failures == 0 ? 0 : 1)
