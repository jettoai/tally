import Foundation
import TallyRustCore

// The Rust line reader (TallyCLI/TranscriptLineRust.swift, rust/) against the substring readers it
// replaces on the live scan. Every member of the two views is compared on one fixture line per
// input shape, then whole fixture files are scanned through each view and the watcher state is
// compared. `run bench <corpus list>` is the speed gate (G1), not part of the suite.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    if ok { print("PASS: \(name)") } else { failures += 1; print("FAIL: \(name)") }
}

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("ctxrust-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let emptyDir = scratch.appendingPathComponent("empty", isDirectory: true)
try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

func watcher(_ file: URL, since: Date, forceString: Bool, budget: Int? = nil,
             history: Bool = false) -> TranscriptWatcher {
    var w = TranscriptWatcher(projectDir: emptyDir, file: file, since: since)
    w.skipsHistoryCheaply = history
    w.forceStringLineView = forceString
    w.auditLog = scratch.appendingPathComponent("audit.log")
    if let budget { w.scanBudgetBytes = budget }
    return w
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "bench" {
    runBench(corpusList: CommandLine.arguments[2])
    exit(0)
}

// MARK: ABI layout, the same numbers rust/crates/ffi/src/lib.rs asserts.
check(MemoryLayout<TallySpan>.size == 16, "abi: TallySpan is 16 bytes")
check(MemoryLayout<TallyLineFields>.size == 120, "abi: TallyLineFields is 120 bytes")
let offsets: [(PartialKeyPath<TallyLineFields>, Int)] = [
    (\.context_tokens, 8), (\.ts_seconds, 16), (\.ts_millis, 24), (\.ts_kind, 28),
    (\.utf8_valid, 32), (\.ts_raw, 40), (\.uuid, 56), (\.parent_uuid, 72), (\.model, 88),
    (\.excerpt, 104),
]
check(offsets.allSatisfy { MemoryLayout<TallyLineFields>.offset(of: $0.0) == $0.1 },
      "abi: every field offset matches the Rust layout")
check(MemoryLayout<TallyScanLine>.size == 144 && MemoryLayout<TallyScanLine>.offset(of: \.off) == 120
      && MemoryLayout<TallyScanLine>.offset(of: \.kind) == 136, "abi: TallyScanLine matches")
let blockOffsets: [(PartialKeyPath<TallyScanBlock>, Int)] = [
    (\.at_end, 24), (\.bytes, 32), (\.lines, 48), (\.tail, 64), (\.has_tail, 208),
]
check(MemoryLayout<TallyScanBlock>.size == 216
      && blockOffsets.allSatisfy { MemoryLayout<TallyScanBlock>.offset(of: $0.0) == $0.1 },
      "abi: TallyScanBlock matches")

// MARK: The needle table.
check(LineNeedle.table.count == LineNeedle.allCases.count + limitResetPrefilter.count,
      "needles: the table is the cases plus limitResetPrefilter")
do {
    let x: [UInt8] = [0x78]
    let refused = x.withUnsafeBufferPointer { b -> Bool in
        let ptrs = [UnsafePointer<UInt8>?](repeating: b.baseAddress, count: 65)
        let lens = [Int](repeating: 1, count: 65)
        return tally_needles_new(ptrs, lens, 65) == nil
    }
    check(refused, "needles: a table over 64 is refused (every line then reads as before)")
}

// MARK: One line per input shape, every member compared.
let ts = "\"timestamp\":\"2026-10-03T08:15:30.120Z\""
let fixtures: [String] = [
    #"{"parentUuid":"p0","type":"user","origin":{"kind":"human"},"promptSource":"typed","message":{"role":"user","content":"hello"},"uuid":"u1",\#(ts)}"#,
    #"{"parentUuid":"u1","type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":3,"cache_creation_input_tokens":40,"cache_read_input_tokens":500,"output_tokens":6000}},"uuid":"a1","timestamp":"2026-10-03T08:15:31Z"}"#,
    #"{"parentUuid":"a1","type":"assistant","message":{"model":"claude-x","usage":{"input_tokens":3,"cache_creation_input_tokens":40,"cache_read_input_tokens":500,"iterations":[{"output_tokens":9}]}},"uuid":"a2","timestamp":"2026-10-03T08:15:31.5Z"}"#,
    #"{"type":"assistant","message":{"model":"claude-x","usage":{"input_tokens":3,"iterations":[{"cache_creation_input_tokens":1,"cache_read_input_tokens":2}]}},"uuid":"a3","timestamp":"2026-10-03T08:15:31.05Z"}"#,
    #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"uuid":"a4",\#(ts)}"#,
    #"{"type":"assistant","message":{"model":"claude-x","usage":{"input_tokens":99999999999999999999,"cache_creation_input_tokens":0,"cache_read_input_tokens":1}},"uuid":"a5",\#(ts)}"#,
    #"{"isSidechain":true,"type":"assistant","message":{"model":"claude-side","usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}},"uuid":"s1",\#(ts)}"#,
    #"{"parentUuid":"","type":"user","message":{"content":[{"type":"tool_result","content":"<command-name>/model</command-name>"}]},"uuid":"t1",\#(ts)}"#,
    #"{"type":"user","isMeta":true,"message":{"content":"skill body"},"uuid":"m1",\#(ts)}"#,
    #"{"type":"user","isCompactSummary":true,"message":{"content":"summary"},"uuid":"c1",\#(ts)}"#,
    #"{"type":"user","promptSource":"system","origin":{"kind":"task-notification"},"message":{"content":"<task-notification><task-id>abc</task-id><status>stopped</status></task-notification>"},"uuid":"n1",\#(ts)}"#,
    #"{"type":"user","message":{"content":"<task-notification><task-id>x1</task-id><task-id>__orphan_summary__1</task-id><status>killed</status></task-notification>"},"uuid":"n2","timestamp":"2026-10-03T08:15:32.999Z"}"#,
    #"{"type":"user","origin":{"kind":"peer"},"promptSource":"queued","message":{"content":"from a peer"},"uuid":"o1",\#(ts)}"#,
    #"{"type":"user","promptSource":"sdk","message":{"content":"sdk \"quoted\" text"},"uuid":"q1",\#(ts)}"#,
    #"{"type":"user","promptSource":"other","message":{"content":"x"},"uuid":"q2",\#(ts)}"#,
    #"{"type":"user","message":{"content":"<command-name>/model</command-name><command-args>opus</command-args>"},"uuid":"cmd1","timestamp":"2026-10-03T08:16:00Z"}"#,
    #"{"type":"user","message":{"content":"<local-command-stdout>Set model to \u001b[1mOpus\u001b[22m with high effort</local-command-stdout>"},"uuid":"cmd2","timestamp":"2026-10-03T08:16:01Z"}"#,
    #"{"type":"system","subtype":"model_refusal_fallback","originalModel":"claude-fable","fallbackModel":"claude-opus","apiRefusalCategory":"cyber","refusedUserMessageUuid":"u1","uuid":"f1","timestamp":"2026-10-03T08:16:02Z"}"#,
    #"{"type":"system","subtype":"local_command","content":"<local-command-stdout>Weekly reset used. Session limit reset</local-command-stdout>","uuid":"lr1","timestamp":"2026-10-03T08:16:03Z"}"#,
    #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 5pm"}]},"uuid":"cap1","timestamp":"2026-10-03T08:16:04Z"}"#,
    #"{"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed","message":{"model":"<synthetic>","content":"Please run /login"},"uuid":"auth1","timestamp":"2026-10-03T08:16:05Z"}"#,
    #"{"type":"user","message":{"content":"after login"},"uuid":"u2","timestamp":"2026-10-03T08:16:06Z"}"#,
    #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":"ok"},"uuid":"a6","timestamp":"2026-10-03T08:16:07Z"}"#,
    #"{"type":"user","message":{"content":"four digits"},"uuid":"t4","timestamp":"2026-10-03T08:16:08.1234Z"}"#,
    #"{"type":"user","message":{"content":"six digits"},"uuid":"t6","timestamp":"2026-10-03T08:16:08.123456Z"}"#,
    #"{"type":"user","message":{"content":"offset"},"uuid":"to","timestamp":"2026-10-03T16:16:08+08:00"}"#,
    #"{"type":"user","message":{"content":"month 13"},"uuid":"tm","timestamp":"2026-13-03T08:16:08Z"}"#,
    #"{"type":"user","message":{"content":"no stamp"},"uuid":"tn"}"#,
    #"{"type":"user","message":{"content":"unclosed"},"uuid":"tu","timestamp":"2026-10-03T08:16:08Z"#,
    "{\"type\":\"user\",\"message\":{\"content\":\"crlf\"},\"uuid\":\"cr\",\(ts)}\r",
    "\u{FEFF}{\"type\":\"user\",\"message\":{\"content\":\"bom\\u0000nul\u{0}\"},\"uuid\":\"bom\",\(ts)}",
    #"{"type":"user","message":{"content":"中文 ✓ émoji 🎉"},"uuid":"utf","timestamp":"2026-10-03T08:16:09.9Z"}"#,
]
// Shapes where a character match and a byte match disagree (plan blind spots B1, B2): printed,
// not asserted.
let blindSpotFixtures: [String] = [
    "{\"type\":\"user\",\"message\":{\"content\":\"\u{301}x\"},\"uuid\":\"b1\",\(ts)}",
    "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-x\",\"usage\":{\"input_tokens\":12\u{663},\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":1}},\"uuid\":\"b2\",\(ts)}",
]

func describe(_ v: some TranscriptLineView) -> [String] {
    var out = LineNeedle.allCases.map { "\($0)=\(v.has($0))" }
    out += ["limitReset=\(v.hasLimitResetToken())", "uuid=\(v.uuid ?? "nil")",
            "parent=\(v.parentUUID ?? "nil")", "ts=\(ctxHex(v.timestamp))",
            "model=\(v.modelValue.map(String.init) ?? "nil")",
            "ctx=\(v.contextTokens.map(String.init) ?? "nil")", "excerpt=\(v.excerpt ?? "nil")",
            "text=\(ctxFNV(String(v.text)))",
            "person=\(lineIsPersonInput(view: v))", "startsTurn=\(lineStartsTurn(view: v))"]
    return out
}

func compareLine(_ line: [UInt8], name: String, strict: Bool) {
    line.withUnsafeBytes { raw in
        guard let fields = RustLineFields.read(raw) else { check(false, "\(name): core answered"); return }
        let text = String(bytes: raw, encoding: .utf8)
        guard fields.utf8_valid == 1 else {
            check(text == nil, "\(name): invalid UTF-8 skipped by both readers")
            return
        }
        guard let text else { check(false, "\(name): String refused a line Rust accepted"); return }
        let s = StringLineView(line: text[...])
        let r = RustLineView(bytes: raw, f: fields)
        let a = describe(s), b = describe(r)
        let diff = zip(a, b).filter { $0.0 != $0.1 }.map { "\($0.0) vs \($0.1)" }
        let legacy = lineIsPersonInput(text[...]) == lineIsPersonInput(view: s)
            && lineStartsTurn(text[...]) == lineStartsTurn(view: s)
        if strict {
            check(diff.isEmpty && legacy, "\(name): every member agrees \(diff)")
        } else {
            print("NOTE: \(name) (blind spot) differences: \(diff)")
        }
    }
}

for (i, line) in fixtures.enumerated() { compareLine(Array(line.utf8), name: "line \(i)", strict: true) }
for (i, line) in blindSpotFixtures.enumerated() {
    compareLine(Array(line.utf8), name: "blind \(i)", strict: false)
}
for (i, bad) in ([[0x7B, 0xFF, 0x7D], [0x7B, 0x80, 0x7D], [0x7B, 0xC0, 0x80, 0x7D],
                 [0x7B, 0xED, 0xA0, 0x80, 0x7D]] as [[UInt8]]).enumerated() {
    compareLine(bad, name: "invalid utf8 \(i)", strict: true)
}
do {
    // 50 MB single line: the excerpt runs to the end of the padding.
    var big = Array(#"{"type":"user","message":{"content":"x"#.utf8)
    big += [UInt8](repeating: 0x61, count: 50 << 20)
    big += Array("\",\"usage\":{}},\"uuid\":\"big\",\(ts)}".utf8)
    compareLine(big, name: "50 MB line", strict: true)
}

// MARK: Panic inside the core: that one line reads as it always did.
do {
    let probe = Array("__tally_panic_probe__".utf8)
    let answered = probe.withUnsafeBytes { RustLineFields.read($0) } != nil
    check(!answered, "panic: the core reports a panic instead of unwinding into Swift")
}

// MARK: Whole files through each view, watcher state compared.
func fixtureFile(_ name: String, _ lines: [String], trailingNewline: Bool = true) -> URL {
    let url = scratch.appendingPathComponent(name)
    var body = lines.joined(separator: "\n")
    if trailingNewline { body += "\n" }
    try? Data(body.utf8).write(to: url)
    return url
}

let early = Date(timeIntervalSince1970: 0)
let mid = parseISO("2026-10-03T08:16:00Z")!
var files: [URL] = [
    fixtureFile("all.jsonl", fixtures + ["__tally_panic_probe__"]),
    fixtureFile("tail.jsonl", fixtures, trailingNewline: false),
    fixtureFile("partial.jsonl", fixtures + [#"{"type":"user","message":{"content":"half"#],
                trailingNewline: false),
]
let invalid = Data(fixtures.joined(separator: "\n").utf8) + Data([0x0A, 0x7B, 0xFF, 0x7D, 0x0A])
    + Data(fixtures.reversed().joined(separator: "\n").utf8) + Data([0x0A])
let invalidURL = scratch.appendingPathComponent("invalid.jsonl")
try? invalid.write(to: invalidURL)
files.append(invalidURL)
// The string side is the read loop in Swift; the Rust side is the core's scan
// (rust/crates/core/src/scan.rs).
// History on: every line before `since` goes through the history path; `late` makes them all
// history, so a login failure opened mid-tick sends the lines after it down the full path.
let late = parseISO("2026-10-04T00:00:00Z")!
let modes: [(Date, Int?, Bool, String)] = [
    (early, nil, false, "A"), (mid, nil, false, "B"), (early, 64, false, "C"),
    (mid, nil, true, "H"), (mid, 64, true, "HC"), (late, 7, true, "HL"), (late, nil, true, "HL2"),
]
for file in files {
    for (since, budget, history, mode) in modes {
        var s = watcher(file, since: since, forceString: true, budget: budget, history: history)
        var r = watcher(file, since: since, forceString: false, budget: budget, history: history)
        let sh = ctxScan(&s), rh = ctxScan(&r)
        let a = ctxDump(s, hits: sh), b = ctxDump(r, hits: rh)
        let diff = zip(a.split(separator: "\t"), b.split(separator: "\t")).filter { $0.0 != $0.1 }
        check(a == b, "watcher \(file.lastPathComponent) mode \(mode): same state \(diff)")
    }
}
do {
    // The scan panics on the probe line and the tick falls back to the Swift loop (compared above).
    var block = TallyScanBlock()
    let key = transcriptSecondKey(early)
    let rc = RustScan.read(path: files[0].path, offset: 0, budget: 1 << 20, block: 1 << 20,
                           since: early, sinceKey: key, into: &block)
    check(rc == TALLY_ERR_PANIC, "scan: a panic in the core is reported, not unwound")
    var ok = TallyScanBlock()
    let good = RustScan.read(path: files[1].path, offset: 0, budget: 1 << 20, block: 1 << 20,
                             since: early, sinceKey: key, into: &ok)
    check(good == 0 && ok.line_count == fixtures.count - 1 && ok.has_tail == 1,
          "scan: the file without a final newline reads as lines plus a tail")
    tally_scan_block_free(&ok)
    let missing = RustScan.read(path: scratch.appendingPathComponent("none").path, offset: 0,
                                budget: 1, block: 1, since: early, sinceKey: key, into: &block)
    check(missing == TALLY_ERR_NOFILE, "scan: a missing file is TALLY_ERR_NOFILE")
}
do {
    // The fixtures do reach the states compared above (an all-nil comparison proves nothing).
    var w = watcher(files[0], since: early, forceString: false)
    let hits = ctxScan(&w)
    check(hits >= 1 && w.lastContextTokens != nil && w.lastModel != nil && w.lastStoppedTasks != nil
          && w.lastModelCommandAt != nil && w.lastFlag != nil && w.lastUserTurnAt != nil,
          "watcher: the fixture drives cap, context, model, task, command and fallback state")
}

try? FileManager.default.removeItem(at: scratch)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
