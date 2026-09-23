import Foundation

// Bounded catch-up (issue #3). A supervisor bound to a long conversation used to read everything
// from `offset` to the end in one call and run the full line scan over the replayed history, which
// on a 295 MB transcript held the poll loop for minutes. `sawCapHit` now reads a bounded number of
// bytes per call and hands lines older than the launch to a byte-level path that only feeds the
// two readers without a time guard. What has to hold: every field the watcher publishes ends up
// exactly where the full scan leaves it (the slow watcher below IS the full scan, per line), each
// call reads a bounded amount, and the history path takes nearly every old line.
//
// Corpora are synthetic and written to a temp dir. Key order follows Claude Code's own records
// (`timestamp` after `message`), so a stamp sits near the END of a megabyte line.

// MARK: - Corpus

/// One corpus line and whether `sawCapHit` must hand it to the full scan (no stamp, a stamp at or
/// after `since`, or a needle from `transcriptFullPathNeedles`).
struct CatchUpLine {
    let text: String
    let fullPath: Bool
}

struct CatchUpHistory {
    var lines: [CatchUpLine] = []
    /// The context size the newest main-chain, non-zero usage names.
    var lastTokens = 0
    /// The uuid of the newest main-chain user prompt.
    var lastPrompt = ""
    var longestLine = 0
}

func catchUpUser(_ ts: String, uuid: String, text: String, sidechain: Bool = false) -> String {
    #"{"parentUuid":"p-\#(uuid)","isSidechain":\#(sidechain),"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"\#(uuid)","timestamp":"\#(ts)"}"#
}

func catchUpAssistant(_ ts: String, uuid: String, parent: String, model: String = "claude-opus-5-5",
                      cacheCreation: Int, cacheRead: Int = 100_000, output: Int = 7,
                      input: Int = 3, sidechain: Bool = false) -> String {
    #"{"parentUuid":"\#(parent)","isSidechain":\#(sidechain),"type":"assistant","message":{"model":"\#(model)","role":"assistant","content":[{"type":"text","text":"answer"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheCreation),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"iterations":[{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":1}]}},"uuid":"\#(uuid)","timestamp":"\#(ts)"}"#
}

func catchUpToolResult(_ ts: String, uuid: String, payload: String) -> String {
    #"{"parentUuid":"p-\#(uuid)","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_\#(uuid)","type":"tool_result","content":"\#(payload)"}]},"uuid":"\#(uuid)","timestamp":"\#(ts)","toolUseResult":{"stdout":"ok"}}"#
}

func catchUpCap(_ ts: String, uuid: String) -> String {
    #"{"parentUuid":"p-\#(uuid)","isSidechain":false,"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"You've hit your session limit · resets 5pm (Asia/Taipei)"}]},"uuid":"\#(uuid)","timestamp":"\#(ts)"}"#
}

func catchUpAuthFailure(_ ts: String, uuid: String) -> String {
    #"{"parentUuid":"p-\#(uuid)","isSidechain":false,"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Please run /login"}]},"uuid":"\#(uuid)","timestamp":"\#(ts)"}"#
}

func catchUpFlag(_ ts: String, uuid: String, refused: String) -> String {
    #"{"parentUuid":"p-\#(uuid)","isSidechain":false,"type":"system","subtype":"model_refusal_fallback","originalModel":"claude-fable-5","fallbackModel":"claude-opus-4-8","apiRefusalCategory":"cyber","refusedUserMessageUuid":"\#(refused)","uuid":"\#(uuid)","timestamp":"\#(ts)"}"#
}

/// Claude Code's own `/model`: the invocation and the line it printed (nativemodelchecks.swift).
func catchUpModelCommand(_ ts: String, id: String) -> [String] {
    [#"{"parentUuid":"p-c\#(id)","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>"},"uuid":"c\#(id)","timestamp":"\#(ts)"}"#,
     #"{"parentUuid":"c\#(id)","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to \u001b[1mOpus 5 (1M context)\u001b[22m and saved as your default for new sessions with \u001b[1mhigh\u001b[22m effort</local-command-stdout>"},"uuid":"s\#(id)","timestamp":"\#(ts)"}"#]
}

func catchUpLimitReset(_ ts: String) -> String {
    #"{"isSidechain":false,"type":"system","subtype":"local_command","content":"<local-command-stdout>Your session limit is already being reset · one moment</local-command-stdout>","timestamp":"\#(ts)"}"#
}

let catchUpCostState = #"{"type":"cost-state","costUSD":1.25}"#

/// A replayed history, every stamp before the launch: `small` prompt/answer lines with `big` tool
/// results of `bigBytes` spread among them, and one of every special shape near the start.
func catchUpHistory(_ stamp: (TimeInterval) -> String, small: Int, big: Int,
                    bigBytes: Int) -> CatchUpHistory {
    var history = CatchUpHistory()
    var tick: TimeInterval = -100_000
    func next() -> String { tick += 1; return stamp(tick) }
    func add(_ text: String, full: Bool = false) {
        history.lines.append(CatchUpLine(text: text, fullPath: full))
        history.longestLine = max(history.longestLine, text.utf8.count + 1)
    }
    let pairs = small / 2
    let bigEvery = max(1, pairs / (big + 1))
    var bigLeft = big
    for i in 0..<pairs {
        if i == 10 {
            add(catchUpCap(next(), uuid: "h-cap"), full: true)
            add(catchUpAuthFailure(next(), uuid: "h-auth"), full: true)
            add(catchUpFlag(next(), uuid: "h-flag", refused: "u5"), full: true)
            let command = catchUpModelCommand(next(), id: "h-model")
            add(command[0])
            add(command[1], full: true)
            add(catchUpToolResult(next(), uuid: "h-quote",
                                  payload: "grep model_refusal_fallback and authentication_failed"),
                full: true)
            add(catchUpCostState, full: true)
            add(catchUpUser(next(), uuid: "h-side", text: "side prompt", sidechain: true))
            add(catchUpLimitReset(next()))
        }
        if i > 0, i % bigEvery == 0, bigLeft > 0 {
            bigLeft -= 1
            add(catchUpToolResult(next(), uuid: "h-big\(bigLeft)",
                                  payload: String(repeating: "x", count: bigBytes)))
        }
        add(catchUpUser(next(), uuid: "u\(i)", text: "prompt \(i) 中文"))
        add(catchUpAssistant(next(), uuid: "a\(i)", parent: "u\(i)", cacheCreation: i))
        history.lastTokens = 3 + i + 100_000 + 7
        history.lastPrompt = "u\(i)"
    }
    // After the newest main-chain answer: a subagent's (its own context, never this one's) and a
    // synthetic all-zero turn (never a real reading). Neither may move the size.
    add(catchUpAssistant(next(), uuid: "h-sideanswer", parent: "h-side", cacheCreation: 999_999,
                         sidechain: true))
    add(catchUpAssistant(next(), uuid: "h-zero", parent: "u0", model: "<synthetic>",
                         cacheCreation: 0, cacheRead: 0, output: 0, input: 0))
    add(catchUpUser(next(), uuid: "u-final", text: "the last prompt before the relaunch"))
    history.lastPrompt = "u-final"
    return history
}

/// What happens after the launch in a resumed session that is being used: a turn, a `/model`, a
/// fallback flag, a reset notice, a login failure and its recovery, a cap, then a replayed line
/// stamped before the launch (stamps are not monotonic) and a final record with no newline.
func catchUpLive(_ stamp: (TimeInterval) -> String) -> (lines: [CatchUpLine], tail: String) {
    var lines: [String] = [
        catchUpUser(stamp(10), uuid: "u-live1", text: "live prompt"),
        catchUpAssistant(stamp(11), uuid: "a-live1", parent: "u-live1", cacheCreation: 5),
    ]
    lines += catchUpModelCommand(stamp(20), id: "live")
    lines += [
        catchUpUser(stamp(30), uuid: "u-live2", text: "after the model change"),
        catchUpAssistant(stamp(31), uuid: "a-live2", parent: "u-live2", model: "claude-fable-5",
                         cacheCreation: 6),
        catchUpFlag(stamp(32), uuid: "f-live", refused: "u-live2"),
        catchUpLimitReset(stamp(40)),
        catchUpAuthFailure(stamp(50), uuid: "a-auth"),
        catchUpAssistant(stamp(60), uuid: "a-back", parent: "u-live2", cacheCreation: 8),
        catchUpCap(stamp(70), uuid: "a-cap"),
    ]
    var tagged = lines.map { CatchUpLine(text: $0, fullPath: true) }
    tagged.append(CatchUpLine(text: catchUpUser(stamp(-5), uuid: "u-late", text: "replayed late"),
                              fullPath: false))
    return (tagged, catchUpUser(stamp(80), uuid: "u-live3", text: "no newline yet"))
}

func writeCatchUp(_ lines: [CatchUpLine], tail: String? = nil, to url: URL) {
    var text = lines.map(\.text).joined(separator: "\n") + "\n"
    if let tail { text += tail }
    try! Data(text.utf8).write(to: url)
}

/// Every field a reader of the watcher publishes, one per line, dictionaries in a fixed order.
func catchUpSummary(_ w: TranscriptWatcher, hits: [Bool]) -> String {
    func show(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "nil" }
    return [
        "hit=\(hits.contains(true))", "capHitAt=\(show(w.capHitAt))",
        "capHitScope=\(show(w.capHitScope))", "lastModel=\(show(w.lastModel))",
        "lastMainChainEventAt=\(show(w.lastMainChainEventAt))",
        "lastUserTurnAt=\(show(w.lastUserTurnAt))",
        "lastConversationEventAt=\(show(w.lastConversationEventAt))",
        "lastPersonInputAt=\(show(w.lastPersonInputAt))",
        "lastContextTokens=\(show(w.lastContextTokens))",
        "lastModelCommandAt=\(show(w.lastModelCommandAt))",
        "lastModelCommandEffort=\(show(w.lastModelCommandEffort))",
        "lastLimitReset=\(show(w.lastLimitReset))", "lastFlag=\(show(w.lastFlag))",
        "loginRequiredAt=\(show(w.loginRequiredAt))",
        "excerpts=\(w.excerptOrder.map { "\($0)=\(w.recentUserExcerpts[$0] ?? "?")" })",
        "scanSeq=\(w.scanSeq)", "commandSeq=\(show(w.commandSeq))",
        "modelConfirmation=\(show(w.modelConfirmation))",
        "pending=\(show(w.pendingConfirmation?.model))", "offset=\(w.offset)",
        "file=\(show(w.file?.lastPathComponent))", "resumeID=\(show(w.resumeID))",
    ].joined(separator: "\n")
}

// MARK: - Checks

/// Call `sawCapHit` until the offset stops moving; nil when that takes more than 10,000 calls.
func drainCatchUp(_ w: inout TranscriptWatcher,
                  onCall: (UInt64, UInt64) -> Void = { _, _ in }) -> [Bool]? {
    var hits: [Bool] = []
    for _ in 0..<10_000 {
        let before = w.offset
        hits.append(w.sawCapHit())
        onCall(before, w.offset)
        if w.offset == before { return hits }
    }
    return nil
}

/// The full scan on every line, one read to the end: the semantics before issue #3.
func slowCatchUp(_ w: TranscriptWatcher) -> TranscriptWatcher {
    var slow = w
    slow.skipsHistoryCheaply = false
    slow.scanBudgetBytes = .max
    return slow
}

func runTranscriptCatchUpChecks() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-catchup-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // T1. The byte twins answer what the Substring readers answer, shape by shape.
    let shapes: [String] = [
        catchUpUser(stamp(-1), uuid: "u1", text: "hello 中文 ✓"),
        catchUpToolResult(stamp(-1), uuid: "t1", payload: "out"),
        catchUpAssistant(stamp(-1), uuid: "a1", parent: "u1", cacheCreation: 4),
        catchUpAssistant(stamp(-1), uuid: "a0", parent: "u1", cacheCreation: 0, cacheRead: 0,
                         output: 0, input: 0),
        catchUpModelCommand(stamp(-1), id: "x")[1], catchUpCap(stamp(-1), uuid: "c"),
        catchUpCostState, catchUpLimitReset(stamp(-1)),
        #"{"type":"assistant","message":{"usage":{"input_tokens":null,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}},"timestamp":"2026-09-20T01:02:03Z"}"#,
        #"{"type":"assistant","message":{"usage":{"input_tokens":99999999999999999999,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}},"timestamp":"2026-09-20T01:02:03.5Z"}"#,
        #"{"type":"assistant","message":{"usage":{"iterations":[],"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}}}"#,
        #"{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}},"timestamp":"not a date"}"#,
        #"{"type":"user","uuid":"n1","message":{"role":"user"},"timestamp":"2026-09-20T01:02:03.456+08:00"}"#,
        #"{"type":"user","uuid":"n2","message":{"role":"user","content":[{"type":"image"}]}}"#,
        #"{"type":"user","uuid":"n3","message":{"role":"user","content": "spaced"}}"#,
        #"{"type":"user","uuid":"n4","message":{"role":"user","content":"say \"hi\" now"}}"#,
        #"{"type":"user","uuid":"n5","message":{"role":"user","content":[{"type":"text","text":"array ✓"}]}}"#,
        #"{"type":"user","uuid":"n6","message":{"content":"unterminated"#,
        #"{"timestamp":""}"#, #"{"uuid":"#, "",
    ]
    let twinProbe = TranscriptWatcher(projectDir: dir, since: launch)
    var twinMismatches: [String] = []
    for shape in shapes {
        let line = shape[...]
        Data(shape.utf8).withUnsafeBytes { raw in
            if transcriptLineTimestamp(bytes: raw) != lineTimestamp(line) { twinMismatches.append("ts \(shape)") }
            if transcriptLineUUID(bytes: raw) != twinProbe.lineUUID(line) { twinMismatches.append("uuid \(shape)") }
            if transcriptUserExcerpt(bytes: raw) != twinProbe.userExcerpt(line) { twinMismatches.append("excerpt \(shape)") }
            if transcriptContextTokens(bytes: raw) != contextTokens(inLine: line) { twinMismatches.append("tokens \(shape)") }
        }
    }
    check("byte twins agree with the Substring readers on every shape (\(twinMismatches))",
          twinMismatches.isEmpty)
    // …and the text comparison that spares the parse answers what the parsed stamp answers, around
    // a launch that is not on a whole second.
    let offSecond = launch.addingTimeInterval(0.5)
    let key = transcriptSecondKey(offSecond)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamps = [stamp(-1), stamp(0), stamp(1), stamp(-86_400 * 400),
                  fractional.string(from: launch.addingTimeInterval(0.25)),
                  fractional.string(from: launch.addingTimeInterval(0.75)),
                  fractional.string(from: launch.addingTimeInterval(-0.25)),
                  "2027-01-15T16:00:00+08:00", "2027-01-15T15:59:59.999+08:00", "2020-13-45T00:00:00Z",
                  "2020-01-01T00:00:00", "2020-01-01 00:00:00Z", "not a date"]
    var stampMismatches: [String] = []
    for value in stamps {
        let line = #"{"type":"user","timestamp":"\#(value)"}"#
        let parsed = lineTimestamp(line[...])
        let fast = Data(line.utf8).withUnsafeBytes {
            transcriptLineStampedBefore(bytes: $0, since: offSecond, sinceKey: key)
        }
        // A stamp the parse refuses may read as before (the history path treats both alike); any
        // stamp the parse accepts must agree with it exactly.
        if let parsed, fast != (parsed < offSecond) { stampMismatches.append(value) }
        if parsed == nil, fast, !value.hasPrefix("2020-13") { stampMismatches.append(value) }
    }
    check("the stamp comparison agrees with the parsed stamp (\(stampMismatches))",
          stampMismatches.isEmpty)

    // Corpus A: a resumed session with nothing new yet, ~7 MB.
    let history = catchUpHistory(stamp, small: 4_000, big: 3, bigBytes: 2 << 20)
    let fileA = dir.appendingPathComponent("a.jsonl")
    let tailA = CatchUpLine(text: catchUpCostState, fullPath: true)
    writeCatchUp(history.lines + [tailA], to: fileA)
    let sizeA = (try! FileManager.default.attributesOfItem(atPath: fileA.path)[.size] as! NSNumber)
        .uint64Value
    let budget = 1 << 20

    var fastA = TranscriptWatcher(projectDir: dir, file: fileA, since: launch)
    fastA.scanBudgetBytes = budget
    var slowA = slowCatchUp(TranscriptWatcher(projectDir: dir, file: fileA, since: launch))
    var perCall: [UInt64] = []
    let clock = ContinuousClock()
    let fastStart = clock.now
    let fastHits = drainCatchUp(&fastA) { perCall.append($1 &- $0) }
    let fastTime = clock.now - fastStart
    let slowStart = clock.now
    let slowHits = drainCatchUp(&slowA)
    let slowTime = clock.now - slowStart

    // T2. Same answers as the full scan.
    check("catch-up drains within the call limit", fastHits != nil && slowHits != nil)
    check("a resumed session's history leaves every field where the full scan does",
          catchUpSummary(fastA, hits: fastHits ?? []) == catchUpSummary(slowA, hits: slowHits ?? []))
    // T3. And those answers are the right ones, so the two cannot agree on a wrong value.
    check("the size is the newest main-chain, non-zero usage",
          fastA.lastContextTokens == history.lastTokens)
    check("a replayed history reports no cap, no login failure and no serving model",
          fastHits?.contains(true) == false && fastA.capHitAt == nil
          && fastA.loginRequiredAt == nil && fastA.lastModel == nil)
    check("the excerpt FIFO holds the newest 64 prompts",
          fastA.excerptOrder.count == 64 && fastA.excerptOrder.last == history.lastPrompt)
    // T5. Each call reads a bounded amount, and the first does not reach the end.
    let bound = UInt64(budget + history.longestLine + budget)
    check("each call advances at most budget + longest line + one block (max \(perCall.max() ?? 0))",
          perCall.allSatisfy { $0 <= bound })
    check("the first call leaves the rest of the file for later ticks",
          (perCall.first ?? sizeA) < sizeA && fastA.offset == sizeA)
    // T6. The cost bound, counted rather than timed: only lines that must go through the full scan
    //     do, and they are a small fraction of the file.
    let expectedFull = (history.lines + [tailA]).filter(\.fullPath).count
    let totalLines = history.lines.count + 1
    check("only the \(expectedFull) lines that need it reach the full scan (got \(fastA.fullPathLines))",
          fastA.fullPathLines == expectedFull && fastA.fullPathLines < totalLines / 50)
    // T7. The same bound in time, as a ratio within one process.
    let ratio = slowTime / fastTime
    print("  catch-up \(sizeA) bytes: full scan \(slowTime), history path \(fastTime), ratio \(ratio)")
    check("the history path is at least 3x faster than the full scan (\(ratio))", ratio >= 3)

    // T4. A resumed session in use: everything after the launch lands exactly as before.
    let live = catchUpLive(stamp)
    let fileB = dir.appendingPathComponent("b.jsonl")
    writeCatchUp(history.lines + live.lines, tail: live.tail, to: fileB)
    var fastB = TranscriptWatcher(projectDir: dir, file: fileB, since: launch)
    fastB.scanBudgetBytes = budget
    var slowB = slowCatchUp(TranscriptWatcher(projectDir: dir, file: fileB, since: launch))
    let fastBHits = drainCatchUp(&fastB) ?? []
    let slowBHits = drainCatchUp(&slowB) ?? []
    check("a session with post-launch events ends where the full scan does",
          catchUpSummary(fastB, hits: fastBHits) == catchUpSummary(slowB, hits: slowBHits))
    check("its post-launch cap is reported", fastBHits.contains(true)
          && fastB.capHitAt == parseISO(stamp(70)) && fastB.lastModel == "claude-opus-5-5")

    // T9. A self-update relaunch: a new watcher pinned by `--resume`, launched after everything.
    let relaunchAt = launch.addingTimeInterval(3600)
    var pinned = TranscriptWatcher(projectDir: dir, since: relaunchAt, resumeID: "b")
    pinned.scanBudgetBytes = budget
    var pinnedSlow = slowCatchUp(TranscriptWatcher(projectDir: dir, since: relaunchAt,
                                                   resumeID: "b"))
    let pinnedHits = drainCatchUp(&pinned) ?? []
    let pinnedSlowHits = drainCatchUp(&pinnedSlow) ?? []
    check("a self-update relaunch keeps the size and excerpts of the whole conversation",
          catchUpSummary(pinned, hits: pinnedHits) == catchUpSummary(pinnedSlow, hits: pinnedSlowHits)
          && pinned.lastContextTokens != nil && pinned.excerptOrder.count == 64
          && pinned.boundByEvidence && !pinnedHits.contains(true))

    // T10. One line larger than the budget still moves, a tick at a time.
    let fileL = dir.appendingPathComponent("long.jsonl")
    writeCatchUp([CatchUpLine(text: catchUpUser(stamp(-9), uuid: "l1", text: "before"), fullPath: false),
                  CatchUpLine(text: catchUpToolResult(stamp(-8), uuid: "l2",
                                                      payload: String(repeating: "y", count: 2 << 20)),
                              fullPath: false),
                  CatchUpLine(text: catchUpCap(stamp(90), uuid: "l3"), fullPath: true)],
                 to: fileL)
    var longFast = TranscriptWatcher(projectDir: dir, file: fileL, since: launch)
    longFast.scanBudgetBytes = 256 << 10
    var longSlow = slowCatchUp(TranscriptWatcher(projectDir: dir, file: fileL, since: launch))
    var stalls = 0
    let longHits = drainCatchUp(&longFast) { before, after in if after == before { stalls += 1 } }
    let longSlowHits = drainCatchUp(&longSlow) ?? []
    check("a line larger than the budget is read whole and the scan moves past it",
          longHits != nil && stalls == 1
          && catchUpSummary(longFast, hits: longHits ?? []) == catchUpSummary(longSlow, hits: longSlowHits))

    runTranscriptCatchUpForkCheck()
}

/// T8. A fork resets the offset to 0 and the new file (a copied history, then this child's events)
/// is caught up the same bounded way.
func runTranscriptCatchUpForkCheck() {
    let fixture = ForkFixture("catchup")
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    fixture.write("parent.jsonl", [fixture.plainTurn(own: "parent", at: -60)],
                  born: -3600, wrote: -30)
    var fast = fixture.watcher(pinnedTo: "parent")
    fast.scanBudgetBytes = 1 << 20
    var slow = slowCatchUp(fixture.watcher(pinnedTo: "parent"))
    _ = fast.sawCapHit()
    _ = slow.sawCapHit()
    // The marker first, so the fork scan (1 MiB a pass) proves the file on the first pass; the
    // copied history behind it, then this child's cap.
    let history = catchUpHistory(fixture.stamp, small: 2_000, big: 1, bigBytes: 2 << 20)
    fixture.write("fork.jsonl", [fixture.marker(own: "fork", launched: "parent")]
                  + history.lines.map(\.text) + [fixture.capLine(90)], born: 30, wrote: 120)
    fast.followFork(force: true)
    slow.followFork(force: true)
    let fastReset = fast.offset
    let fastHits = drainCatchUp(&fast)
    let slowHits = drainCatchUp(&slow)
    check("a fork restarts the catch-up at the top of the new file",
          fastReset == 0 && fast.file?.lastPathComponent == "fork.jsonl" && fast.resumeID == "fork")
    check("the fork's post-launch cap is found and its copied history is not",
          fastHits?.contains(true) == true
          && fast.capHitAt == parseISO(fixture.stamp(90)) && fast.capHitAt == slow.capHitAt)
    check("after a fork the catch-up ends where the full scan does",
          catchUpSummary(fast, hits: fastHits ?? []) == catchUpSummary(slow, hits: slowHits ?? []))
}
