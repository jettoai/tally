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

/// Where every audit line this suite provokes is sent. The supervisor's own default is
/// `~/.tally/handoff.log`, the USER's history, and a run that reached a logging path wrote invented
/// records straight into it (62 `model-pin=adopted` lines and 7 fork reports before this existed,
/// 2026-08-07). Same discipline as every other home-directory file the suites touch: injected,
/// under a per-run temporary path, and asserted at the end (`runAuditSinkChecks`).
let testAuditLog = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-audit-test-\(UUID().uuidString).log")

/// The transcript name this suite's logging fixtures run under, unique per RUN.
///
/// It used to be `session`, and the marker asserted against was a model pair - both of which a real
/// conversation can legitimately produce, so the check could go red on an honest log and, worse,
/// could not see a leak that happened to carry neither string (review, 2026-08-07).
///
/// THE ENTROPY HAS TO LAND IN THE CHARACTERS THAT ARE RECORDED. A log line carries
/// `String(sessionID.prefix(8))` and nothing more, so a sentinel built as `tf<pid>x<clock>` spent
/// all eight on the constant and the pid - two runs minutes apart, or a reused pid meeting a
/// leftover line, produced the same marker and the check could go red on a leak that was not this
/// run's (review, 2026-08-07). So the random part comes FIRST and is sized to fill what survives:
/// two letters of provenance, then six base-36 digits drawn from a range that cannot be shorter.
///
/// `tf` also keeps it out of the space of real ids: a Claude Code transcript is named for a UUID,
/// whose characters are hex, and `t` is not one of them.
func makeFixtureSessionID() -> String {
    // 36^5 ..< 36^6: every draw is exactly six base-36 digits, so none of them is padded away.
    "tf" + String(UInt64.random(in: 60_466_176 ..< 2_176_782_336), radix: 36)
}

let testFixtureSessionID = makeFixtureSessionID()

/// The 8 characters of it that reach a log line, which is what the assertions grep for.
let testAuditFixtureMarker = "session=\(testFixtureSessionID.prefix(8))"

/// What every fixture in every suite writes into a `session=` field, this run's and any other's.
/// Broader than the sentinel on purpose: the sentinel says "THIS run leaked", these say "a test
/// leaked", and the added-line check below wants both answers.
let testFixtureSessionShapes = ["session=tf", "session=session ", "session=parent "]

/// The user's own audit log, asked about rather than written to.
let realAuditLog = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/handoff.log")

/// How long it was BEFORE anything in this suite ran, so the end can read exactly what was appended
/// while the suite was running.
///
/// WHY NOT "THE FILE IS UNCHANGED", which is what this used to assert. That file is SHARED: on this
/// machine a real supervisor is always resident, and a handoff, a drift episode or a reload during
/// the twenty seconds the suite takes appends a legitimate line to it. The assertion was therefore
/// not a fact about the suite at all - it was a fact about whether the user happened to switch
/// accounts while it ran (review, 2026-08-07). No amount of care makes it obtainable: the property
/// "nobody else wrote here" cannot be established by the process that is not the only writer.
///
/// So the judgement is narrowed to what IS about this suite - were any of the lines added while it
/// ran written BY it - and the general "no path leaks anywhere" guarantee moves to where it can
/// actually be enforced: `appendHandoffLine` has no default sink, so the compiler requires every
/// call site to name one, and the source scans in the fork and safeguard checks pin the paths that
/// must not reach a terminal or a shared file at all.
let realAuditOffset: UInt64 = {
    (try? FileHandle(forReadingFrom: realAuditLog).seekToEnd()) ?? 0
}()

/// The lines appended to a log since `offset`, or nil when the file cannot be read from there (it
/// was rotated or truncated under us, which is not a leak and must not read as one).
func auditLinesAdded(to log: URL, since offset: UInt64) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: log) else { return offset == 0 ? "" : nil }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd(), end >= offset else { return nil }
    try? handle.seek(toOffset: offset)
    return String(data: handle.readDataToEndOfFile(), encoding: .utf8)
}

/// Whether the lines a run added to a shared log are all somebody else's. Pure, so the two cases
/// that matter - a real supervisor writing while the suite runs, and the suite writing at all - can
/// both be asserted without either one having to actually happen.
func auditAdditionsAreClean(_ added: String, sentinel: String) -> Bool {
    !added.contains(sentinel) && !testFixtureSessionShapes.contains { added.contains($0) }
}

/// `sink` is set BEFORE the scan, which is the only order that works for a fixture whose scan
/// itself writes an audit line (the anchor canary): assigning it afterwards leaves that line in the
/// user's own log, which is what `runAuditSinkChecks` then catches.
func watcherAfterScanning(_ lines: [String], sink: URL? = nil) -> TranscriptWatcher {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-watcher-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("\(testFixtureSessionID).jsonl")
    try! lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    var watcher = TranscriptWatcher(projectDir: dir, file: file, since: launch)
    if let sink { watcher.auditLog = sink }
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
// What actually feeds `hasTarget` is checked in capgatechecks.swift (the handoff's stricter gate).
runCapGateChecks()

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
// The note reports the self-update that is already under way rather than asking for a manual
// restart, which is what it meant before the supervisor could replace itself (selfupdatefoldchecks
// holds the full wording assertions).
check("outdated renders a note about the update in flight",
      SupervisionStatus.outdated.note == "supervisor updating at next idle")
check("ok renders no note", SupervisionStatus.ok.note == nil)

// 11b. The version lookup walks up from the RESOLVED executable path. The installed command is a
//      symlink into the bundle, and reading it as invoked walked up from /usr/local/bin, found no
//      Info.plist, and left every supervised session reporting "status unknown" forever.
do {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-bundle-\(getpid())")
    let helpers = root.appendingPathComponent("Contents/Helpers")
    try? FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    let plist = ["CFBundleShortVersionString": "9.9.9"] as [String: Any]
    let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try? data?.write(to: root.appendingPathComponent("Contents/Info.plist"))
    let real = helpers.appendingPathComponent("tally")
    FileManager.default.createFile(atPath: real.path, contents: Data())
    check("a bundled executable reads its version", supervisorBuildVersion(executable: real) == "9.9.9")

    let link = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-link-\(getpid())")
    try? FileManager.default.removeItem(at: link)
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    check("a symlinked command resolves to the same version",
          supervisorBuildVersion(executable: link) == "9.9.9")
    check("an executable outside any bundle has no version",
          supervisorBuildVersion(executable: URL(fileURLWithPath: "/usr/bin/true")) == nil)
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: link)
}

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

// 14. DriftMonitor: a flag opens an episode; a newer flag supersedes it; the actual model returning
//     to the primary clears the episode with a duration.
let dT0 = Date(timeIntervalSince1970: 1_800_000_000)
func mkFlag(_ offset: TimeInterval, uuid: String = "f") -> SafeguardFlag {
    SafeguardFlag(at: dT0.addingTimeInterval(offset), from: "claude-fable-5",
                  to: "claude-opus-4-8", category: "cyber", refusedUUID: uuid, uuid: "e-\(uuid)")
}
var mon = DriftMonitor()
check("a flag starts an episode",
      mon.tick(flag: mkFlag(0), actualModel: "claude-opus-4-8", primary: "fable", now: dT0)
      == .started(mkFlag(0)))
check("the episode is active", mon.isActive)
check("activeFrom is the drifted-from model", mon.activeFrom == "claude-fable-5")
// The episode is what the status line paints for as long as it lasts, so nothing here counts down
// to a reminder any more: the badge IS the reminder, and it is on screen the whole time (the
// five-minute nudge it replaced printed over whatever the child was drawing).
_ = mon.tick(flag: mkFlag(400, uuid: "f2"), actualModel: "claude-opus-4-8", primary: "fable",
             now: dT0.addingTimeInterval(400))
check("a newer flag does not close the episode", mon.isActive)
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
check("clearing ends the drift episode", readDriftState(pid: "12345", dir: sDir) == nil)
// The file itself outlives the episode: its existence is what marks the supervisor live, so a
// session that recovered from a drift is still counted by `tally reload`.
check("clearing keeps the supervisor's presence entry",
      FileManager.default.fileExists(atPath: sDir.appendingPathComponent("12345").path))
markSupervisorLive(pid: "23456", dir: sDir)
check("a live supervisor with no drift has no badge", readDriftState(pid: "23456", dir: sDir) == nil)
removeSupervisorState(pid: "12345", dir: sDir)
check("exiting unlinks the state file",
      !FileManager.default.fileExists(atPath: sDir.appendingPathComponent("12345").path))
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

// MARK: - 19. Idle detection sees subagents

// A session blocked on a subagent appends nothing to its OWN transcript while it waits, so the
// session file alone reported a live work package as idle and the non-urgent relaunches took it
// (measured in this repo 2026-07-25: packages run 5 to 15 minutes against the 120s follow bar, and
// the subagent died with the child, losing its work silently). Quiet must mean the session AND its
// newest subagent have both been silent for the window.
//
// Ages are seconds BEFORE now, so they read against a real `Date()` comparison; the bar is 60s.
// The fixture itself is `watcherWatchingSubagents`, kept with the other layout fixtures in
// dispatchlayoutchecks.swift; its subagent keys are paths relative to `<session>/subagents/`, so a
// nested workflow agent is just a key with a slash in it.
//
// The subagent arm answers on `subagentIdleSeconds`, NOT on the caller's bar: a healthy subagent
// goes silent for the whole of any single long tool call (measured 2026-07-25 across three healthy
// packages here: 61s, 52s, 109s of silence, all inside an xcodebuild or a run of the eleven
// suites). The ages below are therefore chosen against that constant, not against `idleBar`.
let idleBar: TimeInterval = 60
let liveGap: TimeInterval = 300     // silent, but well inside the subagent window: still working
let doneGap: TimeInterval = 700     // silent past the window: genuinely finished
// The common case: no subagent was ever dispatched, so there is no directory and the session's own
// silence is the whole answer.
var noSubagents = watcherWatchingSubagents(sessionAge: 600, subagents: nil)
check("a quiet session with no subagents directory is quiet", noSubagents.isQuiet(idleBar))
var emptySubagents = watcherWatchingSubagents(sessionAge: 600, subagents: [:])
check("a quiet session with an empty subagents directory is quiet", emptySubagents.isQuiet(idleBar))
var finishedSubagents = watcherWatchingSubagents(
    sessionAge: 600, subagents: ["agent-a1.jsonl": 900, "agent-a2.jsonl": doneGap])
check("a quiet session whose subagents all finished long ago is quiet",
      finishedSubagents.isQuiet(idleBar))
// The defect: the session file is 10 minutes stale because the turn is BLOCKED on this subagent.
var liveSubagent = watcherWatchingSubagents(sessionAge: 600, subagents: ["agent-a1.jsonl": 5])
check("a quiet session with a freshly written subagent transcript is NOT quiet",
      !liveSubagent.isQuiet(idleBar))
// The measured failure: 150s of silence clears the 120s follow bar, so reusing the caller's window
// relaunched the child on a subagent that was merely inside a slow build.
var slowToolCall = watcherWatchingSubagents(
    sessionAge: 600, subagents: ["agent-a1.jsonl": 150])
check("a subagent silent past the follow bar but inside its own window is NOT quiet",
      !slowToolCall.isQuiet(followIdleSeconds))
// The window is not open-ended: past it, the subagent is treated as finished and the session is
// free again. Without this bound one dispatched subagent would pin the session busy forever.
var expiredSubagent = watcherWatchingSubagents(sessionAge: 600, subagents: ["agent-a1.jsonl": doneGap])
check("a subagent silent past its own window lets the session be quiet again",
      expiredSubagent.isQuiet(followIdleSeconds))
check("the subagent window is the wider of the two bars", subagentIdleSeconds > followIdleSeconds)
// Several subagents, and the live one is neither first nor last by name: the NEWEST decides, so
// binding to any single file (or trusting name order) would miss it. Its gap also clears `idleBar`,
// so only the subagent window can explain the answer.
var mixedSubagents = watcherWatchingSubagents(
    sessionAge: 600,
    subagents: ["agent-a1.jsonl": 900, "agent-a2.jsonl": liveGap, "agent-a3.jsonl": 1200])
check("the newest of several subagent files decides", !mixedSubagents.isQuiet(idleBar))
// A workflow fan-out nests its agents one level deeper, and those are the longest packages of all.
var workflowSubagent = watcherWatchingSubagents(
    sessionAge: 600, subagents: ["agent-a1.jsonl": 900, "workflows/wf_1/agent-a2.jsonl": liveGap])
check("a live workflow agent one level deeper is seen too", !workflowSubagent.isQuiet(idleBar))
// The session's OWN window is untouched: the caller's `seconds` still decides that arm. A session
// that wrote 6 seconds ago is quiet at the 5s urgent bar and busy at the 120s follow bar, exactly
// as before. Had the subagent window leaked into this arm, both would read busy.
var restingSession = watcherWatchingSubagents(sessionAge: 6, subagents: nil)
check("the session's own window still answers to the caller's bar", restingSession.isQuiet(5))
check("the same session is still busy at the follow bar", !restingSession.isQuiet(followIdleSeconds))
var streamingSession = watcherWatchingSubagents(sessionAge: 4, subagents: nil)
check("a session mid-stream is busy at the urgent bar", !streamingSession.isQuiet(5))
check("a session mid-turn is still busy with no subagents", !streamingSession.isQuiet(idleBar))
var streamingWithStale = watcherWatchingSubagents(sessionAge: 5, subagents: ["agent-a1.jsonl": 900])
check("a session mid-turn stays busy even with only finished subagents",
      !streamingWithStale.isQuiet(idleBar))

runCapResetChecks()
runCapSelfUpdateChecks()
runForkChecks()
runRequestTranscriptChecks()
runRequestForwardChecks()
runTranscriptIdentityChecks()
runStandDownChecks()
runDispatchLayoutChecks()
runReloadChecks()
runSelfUpdateFoldChecks()
runRebalanceChecks()
runWindowRepickChecks()
runSafeguardChecks()
runOpenTurnChecks()
runKeyboardChecks()
runTerminalDrainChecks()
runPendingNoticeChecks()
runSessionContextChecks()
runSessionInventoryChecks()
runResumePromptChecks()
runShimChecks()
runFollowChecks()
runSwitchChecks()
runSwitchRequestChecks()
runSwitchSessionChecks()
runSwitchHookChecks()
runSessionPinChecks()
runCapSessionPinChecks()
runModelRequestChecks()
runModelTickChecks()
runModelSurfaceChecks()
/// The CJK characters that MAY appear in a shipped source file, per file and verbatim.
///
/// Exact rather than by directory, because the point is that each one was looked at: a directory
/// exemption would have swallowed the next accident silently, and this check exists because exactly
/// that happened - a batch of review notes in Chinese reached production comments and a whole
/// package of self-checks did not see them (2026-08-07).
///
/// Two kinds, and both are deliberate. `SettingsView` names languages in their own script, which is
/// what a language picker is for. The rest quote something: an incident's terminal noise, a
/// requirement, a line of NORTH_STAR. They are grandfathered, not endorsed - prose in a shipped
/// comment should be English, and the four quoting ones are worth a pass of their own.
let cjkAllowances: [String: [String]] = [
    "TallyCLI/LaunchFlags.swift": ["tj3裡"],
    "Tally/Core/AppLocale.swift": ["預設當地 locale"],
    "Tally/Providers/Claude/ClaudeProvider.swift": ["不在範圍"],
    "Tally/Providers/ProviderModels.swift": ["預設顯示最高級模型"],
    // The language picker's own option names, which stay in their own language by definition.
    // They moved here with the Display pane when SettingsView.swift reached the 500-line cap.
    "Tally/Views/SettingsDisplayPane.swift": ["繁體中文", "简体中文", "日本語", "한국어"],
    "Tally/Views/TokenActivityHeatmapView.swift": ["週一"],
]

/// Whether a string carries a Han, kana or Hangul character.
func carriesCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x3040 ... 0x30FF).contains(scalar.value)       // kana
            || (0x3400 ... 0x4DBF).contains(scalar.value)   // Han, extension A
            || (0x4E00 ... 0x9FFF).contains(scalar.value)   // Han
            || (0xAC00 ... 0xD7AF).contains(scalar.value)   // Hangul
    }
}

/// EVERY SHIPPED SOURCE FILE IS ENGLISH, asserted rather than remembered.
///
/// The rule is the repo's (AGENTS.md: everything that enters git is English), and it was broken by
/// the one thing a personal checklist cannot catch - the language of the conversation the work was
/// briefed in leaking into the comments written during it. A commit message claimed a scan had been
/// added to the closing checks; what had actually been added was an intention. This is the scan.
///
/// Sources only: `.xcstrings` catalogues are translations by definition, and the tests keep fixtures
/// of real terminal noise that must stay byte-for-byte what the incident produced.
func runLanguageChecks() {
    var scanned = 0
    var offenders: [String] = []
    for root in ["TallyCLI", "Tally"] {
        guard let walk = FileManager.default.enumerator(atPath: root) else { continue }
        for case let name as String in walk where name.hasSuffix(".swift") {
            let path = "\(root)/\(name)"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            scanned += 1
            let allowed = cjkAllowances[path] ?? []
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                var rest = String(line)
                for allowance in allowed { rest = rest.replacingOccurrences(of: allowance, with: "") }
                if carriesCJK(rest) { offenders.append("\(path):\(number + 1)") }
            }
        }
    }
    // The corpus itself is asserted: a scan that walked nothing would otherwise pass loudest of all.
    check("the language scan reads the whole shipped source tree", scanned > 60)
    check("and every shipped source file is written in English",
          offenders.isEmpty || {
              print("   CJK outside the allowances: \(offenders.joined(separator: ", "))")
              return false
          }())
    // The allowances are exact, so one that stops being needed has to be noticed rather than left
    // to rot: every file named here still has to carry the text it is excused for.
    let stale = cjkAllowances.filter { path, allowances in
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return true }
        return !allowances.allSatisfy { text.contains($0) }
    }
    check("and no allowance outlives the line it was written for",
          stale.isEmpty || {
              print("   stale allowances: \(stale.keys.joined(separator: ", "))")
              return false
          }())
}

/// THE SUITE'S OWN FOOTPRINT, asserted last because it is about everything above it: a test that
/// reaches a code path which logs must write into its injected sink and nowhere else. Read from
/// disk rather than trusted, because the failure this closes was invisible for exactly as long as
/// nobody looked at the file.
func runAuditSinkChecks() {
    let written = (try? String(contentsOf: testAuditLog, encoding: .utf8)) ?? ""
    check("the suite's audit lines land in its own sink",
          written.contains(testAuditFixtureMarker) && written.contains("model-pin=adopted"))
    check("…and the fork report with them", written.contains("fork=ambiguous"))
    // THE PRIMARY JUDGEMENT: of the lines the user's own log gained while this suite ran, none was
    // written by it. Narrower than "it gained nothing" for a reason that cannot be engineered away
    // (see `realAuditOffset`): a resident supervisor shares that file and appends to it legitimately
    // while the suite runs.
    let added = auditLinesAdded(to: realAuditLog, since: realAuditOffset)
    check("the user's own audit log gained nothing this suite wrote",
          added.map { auditAdditionsAreClean($0, sentinel: testAuditFixtureMarker) } ?? true)
    // …and the two halves of that judgement, on synthetic input, so both are asserted whether or not
    // either happened during this run. A real handoff landing mid-run must pass;
    let concurrent = "2026-08-07T05:00:00Z session=9f2a1c04 pid=4242 Claude->Claude 2 "
        + "reason=manual-switch cwd=/Users/x/work\n"
    check("a real supervisor writing while the suite runs is not a leak",
          auditAdditionsAreClean(concurrent, sentinel: testAuditFixtureMarker))
    // …and anything this run wrote must not, whichever fixture wrote it.
    check("a line from this run's fixtures is",
          !auditAdditionsAreClean(concurrent + "… \(testAuditFixtureMarker) model-pin=adopted\n",
                                  sentinel: testAuditFixtureMarker))
    check("…as is one from a fixture that predates this run's naming",
          !auditAdditionsAreClean("2026-08-04T06:07:12Z session=session safeguard-restore=queued\n",
                                  sentinel: testAuditFixtureMarker))

    // THE SENTINEL ITSELF has to be new every run, and new in the eight characters a log line keeps:
    // everything past `prefix(8)` is thrown away by the writer, so entropy spent there is not spent
    // at all (review, 2026-08-07). Thirty-two draws rather than two: a composition whose variable
    // part is one character over would pass a pair often enough to look fine.
    let drawn = Set((0 ..< 32).map { _ in String(makeFixtureSessionID().prefix(8)) })
    check("every sentinel differs in the characters a log line actually records", drawn.count == 32)
    check("…and is eight characters long, so none of it is thrown away",
          testFixtureSessionID.count >= 8)
    try? FileManager.default.removeItem(at: testAuditLog)
}

runNativeModelChecks()
runMCPPickerChecks()
runAccountWindowChecks()
runPickerChecks()
runPickGraceChecks()
runPickClaimChecks()
runPickHeightChecks()
runPickPaletteChecks()
runPickRowChecks()
runPickCircleChecks()
runPickSurfaceChecks()
runPickModifierChecks()
runTallyPromptChecks()
runBackstopChecks()
runLanguageChecks()
runAuditSinkChecks()
runSessionStateChecks()
runTerminalJumpChecks()
runSessionBoardOrderChecks()
runProcessTreeChecks()
runProcessTreeLineChecks()
runProcessTreeCensusChecks()
runFootprintAlertChecks()
runFootprintTrendChecks()
runSessionCardEdgeChecks()
runAgentRosterChecks()
runTurnEndChecks()
runSessionInputChecks()
runSessionSendChecks()
runSessionClearChecks()
runQuotaKnockChecks()
// LAST, because it registers the capture flag in this process's defaults and everything after it
// would then be running in demo mode (`demoboardchecks.swift` says so at its own head).
runDemoSessionBoardChecks()

exit(failures == 0 ? 0 : 1)
