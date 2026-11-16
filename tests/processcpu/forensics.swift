import Foundation

// The evidence file the CPU watch leaves behind (Tally/Core/ProcessForensicsLogic.swift and
// ProcessForensicsReaders.swift), driven with fake probes and, at the end, the real ones. Called from main.swift,
// whose `expect`, fixture clock and helpers it uses.

typealias F = ProcessForensicsLogic
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return names.filter { $0 == name }.count }
}
func fakeProbes(_ calls: Calls, readable: Bool, fail: String? = nil, rootHelper: Bool = false) -> ProcessForensicsProbes {
    @Sendable func answer(_ name: String, _ text: String) -> Result<String, ProcessForensicsFailure> {
        calls.add(name)
        return fail.map { .failure(ProcessForensicsFailure(reason: $0)) } ?? .success(text)
    }
    return ProcessForensicsProbes(
        canRead: { _ in readable },
        sample: { _ in answer("sample", "SAMPLE-BODY") },
        fsEvents: { answer("fsEvents", "events=3\n2  /Users/x/y/z") },
        writers: { answer("writers", "100 bytes  pid 7  Python") },
        threads: { _ in answer("threads", "THREADS-BODY") },
        registrations: { answer("registrations", "4  pid 66583") },
        rootHelper: { calls.add("rootHelper"); return rootHelper },
        privileged: { _ in answer("privileged", "ROOT-SAMPLE-AND-FS_USAGE") })
}
func plan(_ pid: Int32 = 665, name: String = "fseventsd", file: String? = nil) -> ProcessForensicsPlan {
    ProcessForensicsPlan(pid: pid, name: name, path: "/System/Library/CoreServices/\(name)", percent: 102,
                         since: t0, identity: F.identity(pid: pid, startedAt: t0),
                         fileName: file ?? F.fileName(pid: pid, name: name, at: t0), capturedAt: t0)
}

func forensicsTests() {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("processcpu-forensics-\(getpid())")
    try? FileManager.default.removeItem(at: scratch)
    defer { try? FileManager.default.removeItem(at: scratch) }
    do {  // T17 the file name
        let plain = F.fileName(pid: 665, name: "fseventsd", at: t0)
        expect(plain == "20270115T080000Z-pid665-fseventsd.txt", "T17 UTC stamp without colons: \(plain)")
        let dirty = F.fileName(pid: 7, name: "we ird/na:me\n\u{1B}[31m" + String(repeating: "a", count: 80), at: t0)
        let part = dirty.dropFirst("20270115T080000Z-pid7-".count).dropLast(".txt".count)
        expect(part.count == 40 && part.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } && !dirty.contains("/")
               && !dirty.contains(":") && !dirty.contains("\n") && !dirty.contains(" "),
               "T17 a name with space, slash, colon, newline, escape and 80 letters keeps allowed characters, 40 of them: \(dirty)")
        expect(F.safeName("\n /:") == "unknown" && F.safeName("") == "unknown", "T17 nothing left is unknown")
        expect(F.identity(pid: 5, startedAt: t0) == "5@1800000000", "T17 identity is pid and start second")
    }
    expect(F.directory(unshipped: false).path.hasSuffix("/.tally/logs/process-forensics")
           && F.directory(unshipped: true).path.hasSuffix("/.tally/logs-dev/process-forensics"),
           "T18 a Dev or unshipped build writes its own folder")
    do {  // T19 keeping
        let day = 86_400.0
        func entry(_ name: String, days: Double, size: Int = 1000) -> ProcessForensicsEntry {
            ProcessForensicsEntry(name: name, size: size, modified: t0.addingTimeInterval(-days * day))
        }
        expect(F.prune([entry("old", days: 15), entry("new", days: 13), entry("edge", days: 14)], now: t0) == ["old"],
               "T19 15 days old goes, 13 and exactly 14 stay")
        let mb = 1024 * 1024
        let big = (0..<101).map { entry("f\($0)", days: Double($0) / 10 + 1, size: mb) }
        expect(F.prune(big, now: t0) == ["f100"], "T19 101 MB drops only the oldest, to exactly 100 MB")
        expect(F.prune(Array(big.prefix(100)), now: t0).isEmpty, "T19 exactly 100 MB stays")
        expect(F.prune(Array(big.prefix(100)), now: t0, reserve: 5 * mb).count == 5, "T19 room is made for the file about to be written")
    }
    do {  // T20 how many
        func recent(_ n: Int, hours: Double = 1) -> [ProcessForensicsEntry] {
            (0..<n).map { ProcessForensicsEntry(name: "r\($0)", size: 1, modified: t0.addingTimeInterval(-hours * 3600)) }
        }
        expect(F.decide(identity: "a", seen: ["a"], entries: [], accepted: 0, now: t0) == .repeated, "T20 the same process twice is one capture")
        expect(F.decide(identity: "b", seen: ["a"], entries: recent(11), accepted: 0, now: t0) == .capture, "T20 the 12th in 24 hours is captured")
        expect(F.decide(identity: "b", seen: [], entries: recent(12), accepted: 0, now: t0) == .rateLimited, "T20 the 13th is not")
        expect(F.decide(identity: "b", seen: [], entries: recent(11), accepted: 1, now: t0) == .rateLimited, "T20 files accepted in this reading count before they exist")
        expect(F.decide(identity: "b", seen: [], entries: recent(12, hours: 25), accepted: 0, now: t0) == .capture, "T20 files older than 24 hours do not count")
    }
    do {  // T21 the two shapes
        let root = Calls()
        let rootText = F.compose(plan(), probes: fakeProbes(root, readable: false))
        expect(rootText.contains("privilege=none missing=root") && root.count("sample") == 0 && root.count("threads") == 1
               && root.count("fsEvents") == 1 && root.count("writers") == 1 && root.count("registrations") == 1
               && !rootText.contains("SAMPLE-BODY"), "T21 a process this user cannot read: no sample, header says why, the four readable parts")
        let other = Calls()
        _ = F.compose(plan(name: "node"), probes: fakeProbes(other, readable: false))
        expect(other.count("registrations") == 0, "T21 the listener registrations are read for fseventsd only")
        let mine = Calls()
        let mineText = F.compose(plan(name: "node"), probes: fakeProbes(mine, readable: true))
        expect(mineText.contains("privilege=own") && !mineText.contains("missing=root") && mine.count("sample") == 1
               && mineText.contains("SAMPLE-BODY") && mine.count("threads") == 0 && mine.count("fsEvents") == 1 && mine.count("writers") == 1,
               "T21 a process of this user gets sample plus the machine-wide parts")
    }
    do {  // T27 the root helper (B-4616, second half): used when the rule works, never otherwise
        let withHelper = Calls()
        let text = F.compose(plan(), probes: fakeProbes(withHelper, readable: false, rootHelper: true))
        expect(text.contains("privilege=root") && !text.contains("missing=root") && withHelper.count("privileged") == 1
               && text.contains("ROOT-SAMPLE-AND-FS_USAGE") && withHelper.count("sample") == 0 && withHelper.count("threads") == 1
               && withHelper.count("fsEvents") == 1, "T27 a refused-by-ownership process with the helper working: one root capture beside the usual parts")
        let refused = Calls()
        let fallback = F.compose(plan(), probes: fakeProbes(refused, readable: false, rootHelper: false))
        expect(fallback.contains("privilege=none missing=root") && refused.count("privileged") == 0 && !fallback.contains("ROOT-SAMPLE-AND-FS_USAGE")
               && refused.count("rootHelper") == 1, "T27 sudo -n -l refused: back to the no-root file, the helper never called")
        let own = Calls()
        _ = F.compose(plan(name: "node"), probes: fakeProbes(own, readable: true, rootHelper: true))
        expect(own.count("privileged") == 0 && own.count("rootHelper") == 0, "T27 a process of this user never asks for root")
    }
    do {  // T27b a helper that floods the file: the clip cuts the helper's tail, not the parts after it
        var probes = fakeProbes(Calls(), readable: false, rootHelper: true)
        probes.privileged = { _ in .success("ROOT-SAMPLE\n" + String(repeating: "x", count: 6 * 1024 * 1024)) }
        let text = F.compose(plan(), probes: probes)
        expect(text.contains("== threads (ps -M) ==") && text.contains("== writes by this account ==")
               && text.contains("== fsevents paths (machine-wide) ==") && text.contains("ROOT-SAMPLE")
               && text.hasSuffix("truncated=yes\n") && text.utf8.count <= F.maxFileBytes,
               "T27b a 6 MB helper output keeps threads, writes and fsevents, ends truncated=yes")
    }
    do {  // T28 who made the file system work: the fs_usage ranking at the top of the root file
        func ln(_ call: String, _ name: String, tid: Int = 1, rest: String = "/p/x", ts: String = "14:06:38.460972",
                elapsed: String = "0.000003", w: String = "") -> String {
            "\(ts)  \(call.padding(toLength: 18, withPad: " ", startingAt: 0))\(rest)   \(elapsed)\(w)   \(name).\(tid)"
        }
        func seg(_ lines: [String], tail: String = "\n") -> String {
            "=== sample 1 ===\nSAMPLE\n=== fs_usage (machine-wide, 10 s) ===\n" + lines.joined(separator: "\n") + tail
        }
        func rank(_ lines: [String]) -> [FsUsageWriter] { F.fsUsageWriters(seg(lines))?.writers ?? [] }
        func byName(_ lines: [String]) -> [String: Int] { Dictionary(uniqueKeysWithValues: rank(lines).map { ($0.name, $0.changes) }) }
        expect(rank([ln("rename", "claude", tid: 109783326), ln("rename", "claude", tid: 109783327)]) == [FsUsageWriter(name: "claude", changes: 2, events: 2)],
               "T28 one name under two tids is one row, the lines added")
        expect(rank([ln("stat64", "Google Chrome Helper (Aperitif)", tid: 17591)]).map(\.name) == ["Google Chrome Helper (Aperitif)"], "T28 a name with spaces stays whole")
        let withW = F.fsUsageWriters(seg([ln("RdData", "Tally", tid: 109763522, w: " W")]))
        expect(withW?.unparsed == 0 && withW?.writers.map(\.name) == ["Tally"], "T28 an elapsed column followed by ` W` parses")
        expect(rank([ln("unlink", "XProtectBridgeSe"), ln("unlink", "XProtectBridgeSe"), ln("unlink", "XProtectBridgeService"),
                     ln("stat64", "XProtectBridgeService"), ln("stat64", "XProtectBridgeService")])
               == [FsUsageWriter(name: "XProtectBridgeService", changes: 3, events: 5)], "T28 a name cut at 16 letters joins its whole name")
        expect(rank([ln("stat64", "Google Chrome Helper (Aperitif "), ln("stat64", "Google Chrome Helper (Aperitif)")]).map(\.name)
               == ["Google Chrome Helper (Aperitif)"], "T28 a cut name that kept a trailing space still joins")
        expect(Set(rank([ln("stat64", "ABCDEFGHIJKLMNO"), ln("stat64", "ABCDEFGHIJKLMNOP")]).map(\.name)) == ["ABCDEFGHIJKLMNO", "ABCDEFGHIJKLMNOP"],
               "T28 a 15-letter prefix is not a cut name")
        expect(Set(rank([ln("stat64", "ABCDEFGHIJKLMNOP"), ln("stat64", "ABCDEFGHIJKLMNOPQ"), ln("stat64", "ABCDEFGHIJKLMNOPR")]).map(\.name))
               == ["ABCDEFGHIJKLMNOP", "ABCDEFGHIJKLMNOPQ", "ABCDEFGHIJKLMNOPR"], "T28 a prefix of two longer names joins neither")
        expect(rank([ln("stat64", "python3.12", tid: 4455)]).map(\.name) == ["python3.12"], "T28 a dot in the name stays, the last .digits is the tid")
        let empty = F.fsUsageWriters(seg([ln("close", "", tid: 109789660), ln("close", "real")]))
        expect(empty?.unparsed == 1 && empty?.lines == 2 && empty?.writers.map(\.name) == ["real"], "T28 a line of an exited process (empty name) is unparsed")
        expect(Set(rank([ln("stat64", "fs_usage"), ln("stat64", "sample"), ln("stat64", "sampled"), ln("stat64", "fs_usage2")]).map(\.name)) == ["sampled", "fs_usage2"],
               "T28 fs_usage and sample are left out, names that only start like them are not")
        let calls = byName([ln("open", "o1", rest: "F=3        (_WC_T______X___)  /p"), ln("open", "o2", rest: "[  2] (R__________X___)  /p"),
                            ln("open", "o3", rest: "[  2]  /p"), ln("rename", "r1"), ln("unlink", "u1"), ln("mkdir", "m1"),
                            ln("fstatat64", "s1"), ln("write", "w1", rest: "F=14 B=0x4"), ln("WrData[A]", "w2"), ln("openat", "o4", rest: "F=3 (_W_________X___)  /p")])
        expect(calls == ["o1": 1, "o2": 0, "o3": 0, "r1": 1, "u1": 1, "m1": 1, "s1": 0, "w1": 0, "w2": 0, "o4": 1],
               "T28 which calls count as changes: \(calls.sorted { $0.key < $1.key })")
        let twelve = (1...12).map { i in ln("stat64", String(format: "n%02d", i)) } + [ln("stat64", "n12")]
        expect(rank(twelve).count == 10 && rank(twelve).first?.name == "n12", "T28 twelve names come back as ten, most lines first")
        expect(rank([ln("stat64", "b"), ln("stat64", "a"), ln("rename", "z"), ln("stat64", "c"), ln("stat64", "c")]).map(\.name) == ["z", "c", "a", "b"],
               "T28 changes first, then lines, then the name")
        expect(rank([ln("stat64", "real", tid: 77, rest: "/tmp/x 0.000001   evil.1")]).map(\.name) == ["real"], "T28 a path that looks like an elapsed column does not move the name")
        let escaped = F.fsUsageWriters(seg([ln("stat64", "ev\u{1B}[31mil")])).map { F.writersSection($0) } ?? ""
        expect(!escaped.contains("\u{1B}") && escaped.contains("ev[31mil"), "T28 control characters in a name do not reach the file")
        let midnight = F.fsUsageWriters(seg([ln("stat64", "a", ts: "23:59:59.900000"), ln("stat64", "a", ts: "00:00:00.100000")]))
        expect(abs((midnight?.span ?? 0) - 0.2) < 1e-6, "T28 the window crosses midnight: \(midnight?.span ?? -1)")
        let none = F.fsUsageWriters("=== fs_usage (machine-wide, 10 s) ===\n(no fs_usage output)\n")
        expect(none == FsUsageSummary(writers: [], lines: 0, unparsed: 0, span: nil, cut: false)
               && F.fsUsageWriters("=== fs_usage (machine-wide, 10 s) ===\n")?.lines == 0 && F.fsUsageWriters("=== sample 1 ===\nx\n") == nil,
               "T28 no output and an empty segment give zero lines, no segment gives nil")
        let halved = F.fsUsageWriters(seg([ln("rename", "a")], tail: "\n14:06:38.601320  fstatat64            "))
        expect(halved?.cut == true && halved?.lines == 1 && halved?.unparsed == 0, "T28 a last line cut by the cap sets cut=yes and is not counted")
        let lonely = Calls()
        var rooted = fakeProbes(lonely, readable: false, rootHelper: true)
        rooted.privileged = { _ in .success(seg([ln("rename", "claude"), ln("stat64", "node")])) }
        let composed = F.compose(plan(), probes: rooted)
        let at = { (s: String) in composed.range(of: s)?.lowerBound }
        expect(at("== top writers (fs_usage) ==") != nil && at("privilege=root")! < at("== top writers (fs_usage) ==")!
               && at("== top writers (fs_usage) ==")! < at("== fsevents paths (machine-wide) ==")! && composed.contains("   1       1  claude"),
               "T28 the root file opens with the ranking, after the header and before the other parts")
        var flood = fakeProbes(Calls(), readable: false, rootHelper: true)
        let bulk = (0..<6000).map { _ in ln("stat64", "bulk", rest: String(repeating: "p", count: 1000)) }
        flood.privileged = { _ in .success(seg([ln("rename", "top"), ln("rename", "top")] + bulk)) }
        let flooded = F.compose(plan(), probes: flood)
        expect(flooded.contains("   2       2  top\n") && flooded.range(of: "top writers")!.lowerBound < flooded.range(of: "== fsevents paths")!.lowerBound
               && flooded.utf8.count <= F.maxFileBytes && flooded.hasSuffix("truncated=yes\n"), "T28 a 6 MB helper output: the ranking is whole, the file ends truncated=yes")
        expect(!F.compose(plan(), probes: fakeProbes(Calls(), readable: false, rootHelper: false)).contains("top writers"), "T28 no root, no ranking")
        let failed = F.compose(plan(), probes: fakeProbes(Calls(), readable: false, fail: "boom", rootHelper: true))
        expect(failed.contains("== top writers (fs_usage) ==\nunavailable: boom\n"), "T28 a failed helper is written as its reason")
        var missing = fakeProbes(Calls(), readable: false, rootHelper: true)
        missing.privileged = { _ in .success("no segment here") }
        expect(F.compose(plan(), probes: missing).contains("== top writers (fs_usage) ==\nunavailable: no fs_usage section in the helper output\n"),
               "T28 helper output without a segment is written as unavailable")
        expect(ProcessForensicsPrivilege.wrapperScript().contains("head -c \(F.fsUsageCap) \"$d/fs_usage.txt\""),
               "T28 the cap in the ranking is the cap in the root script")
    }
    do {  // T22 failures still leave a file
        let calls = Calls()
        let probes = fakeProbes(calls, readable: true, fail: "timeout after 50 s")
        let text = F.compose(plan(name: "node"), probes: probes)
        expect(text.contains("unavailable: timeout after 50 s") && text.contains("== sample ==") && text.contains("privilege=own"),
               "T22 a failed probe is written as its reason")
        let wrote = ProcessForensicsReaders.write(plan(name: "node"), probes: probes, directory: scratch)
        let path = scratch.appendingPathComponent(plan(name: "node").fileName).path
        let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let size = attributes[.size] as? Int ?? 0
        let mode = attributes[.posixPermissions] as? Int ?? 0
        expect(wrote && size > 0 && mode == 0o600, "T22 every probe failing still writes the named file, 0600 (size \(size), mode \(String(mode, radix: 8)))")
    }
    do {  // T23 the banner
        let file = ProcessForensicsOutcome.file("20270115T080000Z-pid665-fseventsd.txt", partial: false)
        let part = ProcessForensicsOutcome.file("20270115T080000Z-pid665-fseventsd.txt", partial: true)
        expect(F.noticeLine(file, localized: identity) == "Evidence: process-forensics/20270115T080000Z-pid665-fseventsd.txt", "T23 the notice names the file")
        expect(F.noticeLine(part, localized: identity)?.hasPrefix("Partial evidence (no root permission for sample and fs_usage): process-forensics/") == true, "T23 a root process's notice says what is missing")
        expect(F.noticeLine(.skipped("rate"), localized: identity) == nil, "T23 a skipped capture has no notice line")
        func alarm(_ evidence: ProcessForensicsOutcome?) -> ProcessCPUEvent {
            ProcessCPUEvent(kind: .alarm, pid: 665, path: node, percent: 100, since: t0, until: t0.addingTimeInterval(900),
                            announced: true, evidence: evidence)
        }
        let at = t0.addingTimeInterval(900)
        let plainBody = W.alarmBody([alarm(nil)], now: at, localized: identity, displayName: baseName)
        let withBody = W.alarmBody([alarm(part)], now: at, localized: identity, displayName: baseName)
        expect(withBody == plainBody + "\nPartial evidence (no root permission for sample and fs_usage): process-forensics/20270115T080000Z-pid665-fseventsd.txt",
               "T23 the body ends with the notice line: \(withBody.replacingOccurrences(of: "\n", with: " | "))")
        expect(W.alarmBody([alarm(.skipped("rate"))], now: at, localized: identity, displayName: baseName) == plainBody, "T23 a skipped alarm's body is unchanged")
    }
    do {  // T24 the log line
        let event = ProcessCPUEvent(kind: .alarm, pid: 665, path: "/x/My App", percent: 100, since: t0, until: t0,
                                    announced: true, evidence: .file("20270115T080000Z-pid665-My_App.txt", partial: false))
        let line = W.logLine(event, now: t0, displayName: { _ in "My App" })
        let evidenceAt = line.range(of: " evidence=20270115T080000Z-pid665-My_App.txt ")
        let nameAt = line.range(of: " name=")
        expect(evidenceAt != nil && nameAt != nil && evidenceAt!.upperBound <= nameAt!.upperBound && line.hasSuffix(" name=My App\n")
               && line.filter { $0 == "\n" }.count == 1, "T24 evidence= comes before name=, and a name with a space is still the rest of the line: \(line.dropLast())")
        var skipped = event
        skipped.evidence = .skipped("rate")
        expect(W.logLine(skipped, now: t0, displayName: baseName).contains(" evidence=skipped_rate "), "T24 a skipped capture is logged as skipped_rate")
        var none = event
        none.evidence = nil
        expect(!W.logLine(none, now: t0, displayName: baseName).contains("evidence="), "T24 an event with no capture decision has no evidence field")
    }
    do {  // T25 the size cap
        let six = String(repeating: "a", count: 6 * 1024 * 1024)
        let cut = F.clipped(six)
        expect(cut.utf8.count <= F.maxFileBytes && cut.hasSuffix("truncated=yes\n"), "T25 6 MB is cut to 5 MB with truncated=yes")
        expect(F.clipped("short") == "short", "T25 a small file is untouched")
    }
    do {  // T26 the real thing, one second each
        let me = getpid()
        let mine = plan(me, name: "processcpu-test", file: "own.txt")
        let started = Date()
        var probes = ProcessForensicsReaders.live(seconds: 1)
        probes.rootHelper = { false }   // a machine that has installed the helper must not run it from a test
        expect(ProcessForensicsReaders.write(mine, probes: probes, directory: scratch), "T26 the real capture of this process wrote its file")
        let text = (try? String(contentsOf: scratch.appendingPathComponent("own.txt"), encoding: .utf8)) ?? ""
        expect(!text.isEmpty && text.contains("privilege=own") && text.contains("== sample ==")
               && !text.contains("unavailable"), "T26 own process: real sample plus FSEvents plus writes, nothing unavailable (\(text.utf8.count) bytes, \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        expect(text.contains("events=") && text.contains("readable="), "T26 the FSEvents stream started and the write counts were read")
        let rooted = plan(1, name: "launchd", file: "root.txt")
        expect(ProcessForensicsReaders.write(rooted, probes: probes, directory: scratch), "T26 the real capture of a root process wrote its file")
        let rootText = (try? String(contentsOf: scratch.appendingPathComponent("root.txt"), encoding: .utf8)) ?? ""
        expect(rootText.contains("privilege=none missing=root") && !rootText.contains("== sample ==") && rootText.contains("== threads (ps -M) ==")
               && !rootText.contains("unavailable"), "T26 root process (launchd): header, threads, FSEvents and writes, no sample")
        expect(ProcessForensicsReaders.entries(in: scratch).count >= 2, "T26 the folder lists what was written")
    }
}
