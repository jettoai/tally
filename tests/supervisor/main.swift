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

func flagLine(_ offset: TimeInterval, uuid: String = "u-trigger", sidechain: Bool = false,
              from: String = "claude-fable-5", to: String = "claude-opus-4-8",
              category: String = "cyber") -> String {
    #"{"type":"system","subtype":"model_refusal_fallback","level":"warning","trigger":"refusal","direction":"retry","originalModel":"\#(from)","fallbackModel":"\#(to)","apiRefusalCategory":"\#(category)","refusedUserMessageUuid":"\#(uuid)","timestamp":"\#(stamp(offset))","isSidechain":\#(sidechain)}"#
}

func userLine(_ offset: TimeInterval, uuid: String, text: String, sidechain: Bool = false) -> String {
    #"{"parentUuid":"p-\#(uuid)","type":"user","uuid":"\#(uuid)","isSidechain":\#(sidechain),"timestamp":"\#(stamp(offset))","message":{"role":"user","content":"\#(text)"}}"#
}


func scanForCap(_ lines: [String]) -> (hit: Bool, watcher: TranscriptWatcher) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-excl-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("session.jsonl")
    try! lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    var w = TranscriptWatcher(projectDir: dir, file: file, since: launch)
    return (w.sawCapHit(), w)
}

runSupervisorMainChecks()

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
runLoginSignalChecks()
runSupervisorFreshnessChecks()
runTerminalJumpChecks()
runSessionBoardOrderChecks()
runProcessTreeChecks()
runProcessTreeLineChecks()
runProcessTreeCensusChecks()
runSessionGroupChecks()
runMachineLoadChecks()
// The same rollup as the board now draws it: cards rather than a section above them
// (ghostboardchecks.swift).
runGhostBoardChecks()
// The one suite here that drives a @MainActor store rather than a pure rule: the project rollup's
// state BETWEEN two ticks is the half no pure function can hold (projectloadchecks.swift).
MainActor.assumeIsolated { runProjectLoadChecks() }
// The same, one question further on: what the rollup finds, and whether it should still be running
// (orphanchecks.swift). Drives a store too, for the same reason - a kill is a thing that happens
// BETWEEN two rounds - and nothing in it touches a real process.
MainActor.assumeIsolated { runOrphanChecks() }
runFootprintChecks()
MainActor.assumeIsolated { runFootprintPaintChecks() }
runFootprintAlertChecks()
runFootprintTrendChecks()
runSessionCardEdgeChecks()
runAgentRosterChecks()
runTurnEndChecks()
runSteeringOffChecks()
runTurnBoundaryChecks()
runDroughtChecks()
runCapResumeChecks()
runCapLimitResetChecks()
runSessionInputChecks()
runSessionSendChecks()
runSessionClearChecks()
runDraftStashChecks()
runQuotaKnockChecks()
runReserveMoverChecks()
runKnockChannelChecks()
runKnockHookChecks()
// LAST, because it registers the capture flag in this process's defaults and everything after it
// would then be running in demo mode (`demoboardchecks.swift` says so at its own head).
runDemoSessionBoardChecks()

exit(failures == 0 ? 0 : 1)
