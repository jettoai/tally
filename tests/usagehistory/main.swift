import Foundation

// Assertion harness for UsageHistory.samples(since:): every read through the incremental cache must
// equal a whole-file decode of the same file (the pre-cache implementation, kept below as the oracle).

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-usagehistory-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

func line(_ minutesAgo: Double, _ account: String = "a", used: Double = 1) -> Data {
    let s = UsageHistory.Sample(ts: now.addingTimeInterval(-minutesAgo * 60), account: account,
                                provider: "claude", window: "weeklyAll", model: nil, used: used,
                                resetAt: now.addingTimeInterval(86_400))
    return try! encoder.encode(s) + Data("\n".utf8)
}
func lines(_ range: ClosedRange<Int>, _ account: String = "a") -> Data {
    range.reduce(Data()) { $0 + line(Double(10_000 - $1), account, used: Double($1)) }
}

/// The pre-cache implementation: whole file, line-by-line tolerant decode, `ts >= since`.
func reference(_ url: URL, since: Date) -> [UsageHistory.Sample] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return data.split(separator: UInt8(ascii: "\n")).compactMap {
        guard let s = try? decoder.decode(UsageHistory.Sample.self, from: Data($0)), s.ts >= since
        else { return nil }
        return s
    }
}
func read(_ h: UsageHistory, since: Date) -> [UsageHistory.Sample] {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: [UsageHistory.Sample] = []
    h.samples(since: since) { out = $0; sem.signal() }
    sem.wait()
    return out
}
func key(_ s: [UsageHistory.Sample]) -> [String] {
    s.map { "\($0.ts.timeIntervalSince1970)|\($0.account)|\($0.used)|\($0.resetAt?.timeIntervalSince1970 ?? -1)" }
}
func same(_ a: [UsageHistory.Sample], _ b: [UsageHistory.Sample]) -> Bool { key(a) == key(b) }
func appendRaw(_ url: URL, _ data: Data) {
    let h = try! FileHandle(forWritingTo: url); _ = try! h.seekToEnd(); try! h.write(contentsOf: data); try! h.close()
}
let all = Date.distantPast
let fleet72h = now.addingTimeInterval(-72 * 3_600)
let advisor28d = now.addingTimeInterval(-28 * 86_400)

// 1. Cold start: first call equals the whole-file reference.
do {
    let url = dir.appendingPathComponent("h1.jsonl")
    try! lines(1...200).write(to: url)
    let h = UsageHistory(fileURL: url)
    let got = read(h, since: all)
    expect(got.count == 200 && same(got, reference(url, since: all)), "1 cold start equals reference")
}

// 2. N lines appended between calls: exactly those N more, nothing duplicated.
do {
    let url = dir.appendingPathComponent("h2.jsonl")
    try! lines(1...100).write(to: url)
    let h = UsageHistory(fileURL: url)
    let first = read(h, since: all)
    appendRaw(url, lines(101...137))
    let second = read(h, since: all)
    expect(second.count == first.count + 37 && same(second, reference(url, since: all)),
           "2 appended lines arrive once, no duplicates")
}

// 3. Half-written trailing line: not returned; once completed, returned exactly once.
do {
    let url = dir.appendingPathComponent("h3.jsonl")
    try! lines(1...10).write(to: url)
    let h = UsageHistory(fileURL: url)
    _ = read(h, since: all)
    let full = line(1, "half", used: 99)
    let cut = full.count / 2
    appendRaw(url, full.prefix(cut))
    let partial = read(h, since: all)
    expect(partial.count == 10 && !partial.contains { $0.account == "half" }, "3 half line not returned")
    appendRaw(url, full.suffix(from: cut))
    let done = read(h, since: all)
    let again = read(h, since: all)
    expect(done.filter { $0.account == "half" }.count == 1 && same(done, reference(url, since: all))
           && same(again, done), "3 completed line returned exactly once")
}

// 4a. External atomic rewrite (new inode), shorter: equals reference.
do {
    let url = dir.appendingPathComponent("h4.jsonl")
    try! lines(1...300).write(to: url)
    let h = UsageHistory(fileURL: url)
    _ = read(h, since: all)
    try! lines(200...300, "b").write(to: url, options: .atomic)
    expect(same(read(h, since: all), reference(url, since: all)), "4a atomic rewrite equals reference")
    // Same size, new inode, different content: identity alone must catch it.
    let size = (try! Data(contentsOf: url)).count
    var alt = lines(200...300, "c")
    expect(alt.count == size, "4a same-size fixture")
    try! alt.write(to: url, options: .atomic)
    let got = read(h, since: all)
    expect(got.allSatisfy { $0.account == "c" } && same(got, reference(url, since: all)),
           "4a same-size atomic rewrite reloads")
    alt = Data()
}

// 4b. In-process prune (first record of the run) drops expired lines: equals reference.
do {
    let url = dir.appendingPathComponent("h4b.jsonl")
    let old = line(Double(40 * 1_440), "old") + line(Double(30 * 1_440), "old")
    try! (old + lines(1...50)).write(to: url)
    let h = UsageHistory(fileURL: url)
    _ = read(h, since: advisor28d)
    let metric = UsageMetric(id: "weeklyAll:Weekly", kind: .weeklyAll, label: "Weekly", modelName: nil,
                             usedPercent: 42, severity: .normal, resetsAt: nil, isActive: false)
    h.record([AccountUsage(id: "new", providerID: "claude", accountLabel: "new", planName: nil,
                           metrics: [metric], refreshedAt: now)], at: now)
    let got = read(h, since: advisor28d)   // queued after record's prune + append
    let ref = reference(url, since: advisor28d)
    let pruned = !((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("\"old\"")
    expect(pruned && got.contains { $0.account == "new" } && same(got, ref),
           "4b in-process prune + append equals reference")
}

// 5. File deleted: empty; recreated and appended: read again.
do {
    let url = dir.appendingPathComponent("h5.jsonl")
    try! lines(1...20).write(to: url)
    let h = UsageHistory(fileURL: url)
    _ = read(h, since: all)
    try! FileManager.default.removeItem(at: url)
    expect(read(h, since: all).isEmpty, "5 deleted file reads empty")
    try! lines(1...3, "z").write(to: url)
    appendRaw(url, lines(4...5, "z"))
    let got = read(h, since: all)
    expect(got.count == 5 && same(got, reference(url, since: all)), "5 recreated file read again")
}

// 6. Truncated in place (same inode) to smaller: reloads correctly.
do {
    let url = dir.appendingPathComponent("h6.jsonl")
    try! lines(1...100).write(to: url)
    let h = UsageHistory(fileURL: url)
    _ = read(h, since: all)
    let keep = lines(1...40).count
    let fh = try! FileHandle(forWritingTo: url); try! fh.truncate(atOffset: UInt64(keep)); try! fh.close()
    let got = read(h, since: all)
    expect(got.count == 40 && same(got, reference(url, since: all)), "6 truncated file reloads")
    // Truncated mid-line and regrown past the old offset on the same inode: the byte before the
    // offset is no longer a newline, so the cache must reload rather than decode from mid-line.
    let fh2 = try! FileHandle(forWritingTo: url); try! fh2.truncate(atOffset: 7); try! fh2.close()
    appendRaw(url, Data("\n".utf8) + lines(1...90, "r"))
    let regrown = read(h, since: all)
    expect(regrown.count == 90 && same(regrown, reference(url, since: all)),
           "6 in-place rewrite past offset reloads")
}

// 7. Two callers, different since, back to back (and again after an append).
do {
    let url = dir.appendingPathComponent("h7.jsonl")
    var data = Data()
    for m in stride(from: 40 * 1_440, through: 0, by: -600) { data += line(Double(m), "s") }
    try! data.write(to: url)
    let h = UsageHistory(fileURL: url)
    let f1 = read(h, since: fleet72h), a1 = read(h, since: advisor28d)
    expect(!f1.isEmpty && a1.count > f1.count
           && same(f1, reference(url, since: fleet72h)) && same(a1, reference(url, since: advisor28d)),
           "7 fleet 72h and advisor 28d equal reference")
    appendRaw(url, line(0, "t") + line(0, "u"))
    let f2 = read(h, since: fleet72h), a2 = read(h, since: advisor28d)
    expect(f2.count == f1.count + 2 && same(f2, reference(url, since: fleet72h))
           && same(a2, reference(url, since: advisor28d)), "7 both callers after append")
}

// 8. Corrupt lines are skipped exactly as before.
do {
    let url = dir.appendingPathComponent("h8.jsonl")
    let bad = Data("not json\n{\"ts\":\"yesterday\",\"account\":\"x\"}\n\n".utf8)
    try! (lines(1...5) + bad + lines(6...9)).write(to: url)
    let h = UsageHistory(fileURL: url)
    let first = read(h, since: all)
    expect(first.count == 9 && same(first, reference(url, since: all)), "8 corrupt lines skipped")
    appendRaw(url, Data("{broken\n".utf8) + lines(10...11))
    let second = read(h, since: all)
    expect(second.count == 11 && same(second, reference(url, since: all)), "8 corrupt appended line skipped")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
