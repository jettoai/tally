import Foundation

// The token statistics as the app calls them: Swift shells (Tally/Core/TokenStats) over the Rust
// core through the UniFFI bindings. Three things only this suite can see, because each needs Swift
// and Rust in one process: the app's own day arithmetic agrees with the core's across zones, a
// whole scan through the bindings produces hand-computed numbers and leaves a cache the previous
// (Swift) engine could still read, and the core's Swift `String` rules answer what Swift answers.

var failures = 0

func check(_ ok: Bool, _ name: String) {
    if ok { print("PASS: \(name)") } else { failures += 1; print("FAIL: \(name)") }
}

func L(_ key: String) -> String { key }

// MARK: (C) Today's day number: Swift shell against the core

for name in ["Asia/Taipei", "America/New_York", "Australia/Lord_Howe", "Asia/Kathmandu", "Pacific/Chatham"] {
    let zone = TimeZone(identifier: name)!
    var mismatch: Int?
    var instant = Date(timeIntervalSince1970: 1_577_836_800)            // 2020-01-01
    while instant.timeIntervalSince1970 < 1_893_456_000 {                // 2030-01-01
        let s = Int64(instant.timeIntervalSince1970)
        let rust = tokenLocalDay(epochSeconds: s, offsetSeconds: Int32(zone.secondsFromGMT(for: instant)))
        if Int(rust) != LocalDayStamper.today(zone: zone, now: instant) { mismatch = Int(s); break }
        instant += 37 * 60
    }
    check(mismatch == nil, "today agrees with the core every 37 minutes 2020-2030 in \(name)\(mismatch.map { " (first miss \($0))" } ?? "")")
}
check(Int(heatmapWeekColumns()) == TokenActivityHeatmap.weekColumns && TokenActivityHeatmap.weekColumns == 53,
      "the heatmap grid is 53 week columns on both sides")

// MARK: (D) A whole scan through the bindings

setenv("TZ", "Asia/Taipei", 1)
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("tally-tokenstats-\(getpid())").path
let home = root + "/home"
let projects = home + "/.claude/projects/-w-alpha"
let rollouts = home + "/.codex/sessions/2026/01/02"
try! fm.createDirectory(atPath: home + "/workspace/alpha/.git", withIntermediateDirectories: true)
try! fm.createDirectory(atPath: projects, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: rollouts, withIntermediateDirectories: true)
let alpha = home + "/workspace/alpha"

func claude(_ ts: String, id: String?, _ usage: String) -> String {
    let idPart = id.map { "\"id\":\"\($0)\"," } ?? ""
    return "{\"cwd\":\"\(alpha)/src\",\"timestamp\":\"\(ts)\",\"message\":{\(idPart)\"usage\":{\(usage)}}}\n"
}
// One turn restated three times (counted at its peaks), a line without an id (counted whole) and
// one past local midnight (16:30Z is 00:30 at +08:00), then a half-written last line.
let s1 = claude("2026-01-01T15:00:00Z", id: "m1", "\"input_tokens\":10,\"output_tokens\":1")
    + claude("2026-01-01T15:00:01Z", id: "m1", "\"input_tokens\":10,\"output_tokens\":5")
    + claude("2026-01-01T15:00:02Z", id: "m1", "\"input_tokens\":10,\"cache_read_input_tokens\":3,\"output_tokens\":4")
    + claude("2026-01-01T15:10:00Z", id: nil, "\"cache_creation_input_tokens\":7")
    + claude("2026-01-01T16:30:00Z", id: nil, "\"output_tokens\":2")
    + "{\"cwd\":\"\(alpha)\",\"timestamp\":\"2026-01-01T16:40:00Z\",\"mess"
try! s1.write(toFile: projects + "/s1.jsonl", atomically: true, encoding: .utf8)
func codex(_ ts: String, _ i: Int, _ c: Int, _ o: Int) -> String {
    "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(i),\"cached_input_tokens\":\(c),\"output_tokens\":\(o)}}}}\n"
}
let rollout = "{\"timestamp\":\"2026-01-02T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/tmp/elsewhere\"}}\n"
    + codex("2026-01-02T01:00:00Z", 100, 40, 10) + codex("2026-01-02T02:00:00Z", 150, 60, 15)
    + codex("2026-01-02T03:00:00Z", 20, 5, 3)
try! rollout.write(toFile: rollouts + "/rollout-1.jsonl", atomically: true, encoding: .utf8)
try! fm.createSymbolicLink(atPath: projects + "/link.jsonl", withDestinationPath: projects + "/s1.jsonl")
try! s1.write(toFile: projects + "/.hidden.jsonl", atomically: true, encoding: .utf8)

let cachePath = root + "/token-stats.json"
let host = AppTokenStatsHost(observedAt: WorktreeOrigins.timestamp(),
                             originsFile: URL(fileURLWithPath: root + "/worktree-origins.json"))
let input = FfiScanInput(home: home, claudeHomes: [home + "/.claude"], codexHomes: [home + "/.codex"],
                         zone: "Asia/Taipei", cachePath: cachePath)
let core = TokenStatsCore()
let jan1 = 20_454

func rows(_ o: FfiScanOutcome) -> [String] {
    o.samples.map(TokenSample.init).map { s in
        "\(s.day - jan1) \(s.project == alpha ? "alpha" : s.project) \(s.providerID) "
            + "\(s.totals.input)/\(s.totals.cacheWrite)/\(s.totals.cacheRead)/\(s.totals.output)"
    }
}

let first = try! core.scan(input: input, host: host)
check(first.filesSeen == 2 && first.filesReparsed == 2,
      "two transcripts found, the symlink and the hidden file skipped (seen \(first.filesSeen))")
check(rows(first) == ["0 alpha claude 10/7/3/5", "1  codex 105/0/65/18", "1 alpha claude 0/0/0/2"],
      "the scan's samples are the hand-computed ones: \(rows(first))")
check(try! core.scan(input: input, host: host).filesReparsed == 0, "an unchanged rescan reads nothing")
check(try! TokenStatsCore().scan(input: input, host: host).filesReparsed == 0,
      "a fresh core starts warm from the cache file")

// The cache must stay readable by the engine it replaced, so a downgrade starts warm too. This is
// that engine's own Codable shape, restated as the oracle.
struct OldBucket: Codable { var day: Int; var project: String; var totals: TokenTotals }
struct OldEntry: Codable { var provider: String; var size: Int64; var modified: Double; var buckets: [OldBucket] }
struct OldCache: Codable { var version: Int; var zone: String; var files: [String: OldEntry] }
let old = try? JSONDecoder().decode(OldCache.self, from: Data(contentsOf: URL(fileURLWithPath: cachePath)))
check(old?.version == 7 && old?.zone == "Asia/Taipei" && old?.files.count == 2
      && old?.files[projects + "/s1.jsonl"]?.buckets.count == 2,
      "the cache the core wrote decodes as the Swift engine's cache")

try! (s1 + "\n" + claude("2026-01-01T15:20:00Z", id: "m9", "\"output_tokens\":40")).write(
    toFile: projects + "/s1.jsonl", atomically: true, encoding: .utf8)
let changed = try! core.scan(input: input, host: host)
check(changed.filesReparsed == 1 && rows(changed).first == "0 alpha claude 10/7/3/45", "a changed file is read again")
try! fm.removeItem(atPath: rollouts + "/rollout-1.jsonl")
let removed = try! core.scan(input: input, host: host)
check(removed.filesSeen == 1 && !rows(removed).contains { $0.contains("codex") }, "a deleted file's tokens disappear")
let otherZone = FfiScanInput(home: home, claudeHomes: input.claudeHomes, codexHomes: input.codexHomes,
                             zone: "UTC", cachePath: cachePath)
check(try! core.scan(input: otherZone, host: host).filesReparsed == 1, "another zone rescans everything")
try? fm.removeItem(atPath: root)

// MARK: (E) The core's Swift String rules against Swift itself

let e = "e\u{301}", eAcute = "\u{e9}"
let samples: [(String, String)] = [
    ("/Users/a/caf" + e, "/Users/a/caf" + eAcute), ("/Users/a/caf" + eAcute + "/x", "/Users/a/caf" + e),
    ("/a/cafe" + "\u{301}", "/a/cafe"), ("/w/p", "/w/p/"), ("a\r\nb\nc", "\n"), ("a/\u{301}b/c", "/"),
    ("\u{3000} gitdir: x \t", ""), ("\u{a0}x\u{2009}", ""), ("x\r\n", ""), ("/w/\u{1F44D}\u{1F3FD}/a", "/"),
    ("/w/\u{65E5}\u{672C}", "/w/\u{65E5}"), ("/Users/u/.claude2/projects/-Users-u-w-caf" + e, "-"),
    ("/W/\u{212B}", "/W/\u{C5}"), ("//a///b", "/"), ("", ""), ("a-b_c.d", "-"), ("a\r\nb", "a\r"),
]
for (a, b) in samples {
    let swiftSplit = a.split(separator: Character(b.isEmpty ? "/" : String(b.first!))).map(String.init)
    let probes: [(String, String, String)] = [
        ("eq", b, String(a == b)),
        ("has_prefix", b, String(a.hasPrefix(b))),
        ("count", "", String(a.count)),
        ("split", b.isEmpty ? "/" : String(b.first!), swiftSplit.joined(separator: "\u{1}")),
        ("trim", "", a.trimmingCharacters(in: .whitespaces)),
        ("munged", "", String(a.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" ? $0 : "-" })),
    ]
    for (op, arg, want) in probes {
        let got = tokenStatsSwiftStrProbe(op: op, a: a, b: arg)
        check(got == want, "\(op)(\(a.debugDescription), \(arg.debugDescription)) is \(want.debugDescription), core says \(got.debugDescription)")
    }
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
