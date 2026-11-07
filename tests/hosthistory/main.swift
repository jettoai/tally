import Foundation

// Assertion harness for the load history: the line format and its reader (Tally/Core/HostLoadHistory.swift),
// the writer (HostLoadHistoryWriter.swift), the rate arithmetic (HostLoadStats.swift) and the
// `tally status --history` command (TallyCLI/HostHistoryCommand.swift). Every folder is a fresh
// temporary one; nothing here touches ~/.tally.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS: \(name)") } else { failures += 1; print("FAIL: \(name)") }
}

/// The writer's default folder asks the real BuildVariant; the harness never uses the default.
enum BuildVariant { static let isUnshipped = true }

func calendar(_ zone: String) -> Calendar { hostLoadCalendar(timeZone: TimeZone(identifier: zone)!) }
let taipei = calendar("Asia/Taipei")

func moment(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0, _ cal: Calendar = taipei) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

func sample(_ at: Date, load: Double = 10, mem: Int? = 70, cpu: Int? = nil) -> HostLoadSample {
    HostLoadSample(at: at, load1: load, freeGB: 40, memPct: mem, cpuPct: cpu, cores: 16)
}

func scratch() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hosthistory-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func lines(_ samples: [HostLoadSample]) -> String { samples.map { hostLoadLine($0, timeZone: taipei.timeZone) }.joined() }

func write(_ text: String, _ name: String, in dir: URL) {
    try! Data(text.utf8).write(to: dir.appendingPathComponent(name))
}

func report(_ samples: [HostLoadSample], now: Date, gates: [Double] = [48], memMin: Int? = nil,
            minutes: Int = 60, days: Int = 7, cal: Calendar = taipei) -> HostLoadStats.Report {
    HostLoadStats.report(HostLoadRead(samples: samples), now: now, minutes: minutes, days: days,
                         gates: gates, memMin: memMin, calendar: cal)!
}

// MARK: - 1. The line

do {
    let s = HostLoadSample(at: moment(2026, 11, 4, 2, 31, 5), load1: 12.345, freeBytes: 57_037_979_648,
                           memPct: 73, cores: 16)
    expect(hostLoadLine(s, timeZone: taipei.timeZone)
           == "2026-11-04T02:31:05+08:00 load1=12.35 free_gb=53.1 mem_pct=73 cores=16\n",
           "a sample is one exact line, local offset and all")
    var noMem = s; noMem.memPct = nil
    expect(!hostLoadLine(noMem, timeZone: taipei.timeZone).contains("mem_pct"), "an unreadable memory figure leaves the field out")
    // String(format:) without a locale never consults the system language; a comma here would split a field.
    expect(!hostLoadLine(s, timeZone: taipei.timeZone).contains(","), "no decimal comma in a line")
    let back = parseHostLoadLine(hostLoadLine(s, timeZone: taipei.timeZone).trimmingCharacters(in: .newlines),
                                 formatter: hostLoadDateFormatter())
    expect(back?.load1 == 12.35 && back?.memPct == 73 && back?.cores == 16 && back?.at == s.at, "a line parses back to what it said")
}

do {
    let f = hostLoadDateFormatter()
    let a = parseHostLoadLine("2026-11-04T02:31:05+08:00 load1=1 free_gb=1 cores=4", formatter: f)
    let b = parseHostLoadLine("2026-11-03T18:31:05Z load1=1 free_gb=1 cores=4", formatter: f)
    let c = parseHostLoadLine("2026-11-03T13:31:05-05:00 load1=1 free_gb=1 cores=4", formatter: f)
    expect(a != nil && a?.at == b?.at && b?.at == c?.at, "+08:00, Z and -05:00 are the same instant")
    let extra = parseHostLoadLine("2026-11-04T02:31:05+08:00 foo=1 load1=2 free_gb=1 cores=4 bar=x", formatter: f)
    expect(extra?.load1 == 2, "unknown fields are ignored and the rest still read")
}

// MARK: - 2. Damage

do {
    let dir = scratch()
    var data = Data(lines([sample(moment(2026, 11, 4, 10, 0))]).utf8)
    data.append(Data("2026-11-04T10:01:05+08:00 load1=abc free_gb=1 cores=16\n".utf8))
    data.append(Data("\n".utf8))
    data.append(Data([0xFF, 0xFE, 0xFD, 0x0A]))
    data.append(Data("2026-11-04T10:02:05+08:00 load1=-3 free_gb=1 cores=16\n".utf8))
    data.append(Data("2026-11-04T10:03:05+08:00 load1=NaN free_gb=1 cores=16\n".utf8))
    data.append(Data(lines([sample(moment(2026, 11, 4, 10, 4))]).utf8))
    // A tail that parses as a whole line but has no newline is still a cut-short write (cores=1 of cores=16).
    data.append(Data("2026-11-04T10:05:05+08:00 load1=1 free_gb=1 cores=1".utf8))
    try! data.write(to: dir.appendingPathComponent("2026-11-04.log"))
    let read = readHostLoadSamples(in: dir)
    expect(read.samples.count == 2, "damage is skipped and the good lines around it still count")
    expect(read.corruptLines == 6, "abc, empty, garbage bytes, negative, NaN and the unterminated tail are all damaged lines (got \(read.corruptLines))")
}

do {
    let dir = scratch()
    write(lines([sample(moment(2026, 11, 4, 10, 0))]), "2026-11-04.log", in: dir)
    try! FileManager.default.createDirectory(at: dir.appendingPathComponent("2026-11-05.log"), withIntermediateDirectories: false)
    write(lines([sample(moment(2026, 11, 4, 11, 0))]), "2026-11-03.log", in: dir)
    chmod(dir.appendingPathComponent("2026-11-03.log").path, 0o000)
    let read = readHostLoadSamples(in: dir)
    expect(read.samples.count == 1, "a directory with a day-file name and an unreadable file are skipped without a crash")
    chmod(dir.appendingPathComponent("2026-11-03.log").path, 0o644)
    expect(readHostLoadSamples(in: dir.appendingPathComponent("absent")).samples.isEmpty, "a folder that does not exist reads as empty")
}

// MARK: - 3. One line per minute

do {
    let dir = scratch()
    write(lines([sample(moment(2026, 11, 4, 2, 31, 5), load: 11), sample(moment(2026, 11, 4, 2, 31, 39), load: 99),
                 sample(moment(2026, 11, 4, 2, 32, 5))]), "2026-11-04.log", in: dir)
    let read = readHostLoadSamples(in: dir)
    expect(read.samples.count == 2 && read.duplicateLines == 1 && read.samples[0].load1 == 11,
           "two lines in one minute count once, the first, and the extra is reported")
}

// MARK: - 4. The writer

do {
    let dir = scratch().appendingPathComponent("host-load")
    let a = sample(moment(2026, 11, 4, 10, 0)), b = sample(moment(2026, 11, 4, 10, 1), load: 20)
    HostLoadHistoryWriter.append(a, in: dir, timeZone: taipei.timeZone)
    HostLoadHistoryWriter.append(b, in: dir, timeZone: taipei.timeZone)
    let read = readHostLoadSamples(in: dir)
    expect(read.samples.count == 2 && read.samples[1].load1 == 20, "append makes the folder and two appends read back as two samples")
}

do {
    let dir = scratch()
    for day in 26...31 { write("x\n", "2026-10-\(day).log", in: dir) }
    for day in 1...3 { write("x\n", String(format: "2026-11-%02d.log", day), in: dir) }
    write("keep me", "notes.txt", in: dir)
    HostLoadHistoryWriter.append(sample(moment(2026, 11, 4, 0, 5)), in: dir, timeZone: taipei.timeZone)
    let names = Set(try! FileManager.default.contentsOfDirectory(atPath: dir.path))
    expect(names == ["2026-10-28.log", "2026-10-29.log", "2026-10-30.log", "2026-10-31.log", "2026-11-01.log",
                     "2026-11-02.log", "2026-11-03.log", "2026-11-04.log", "notes.txt"],
           "today's first line prunes to today plus 7 days and leaves other files alone (\(names.sorted()))")
}

do {
    let dir = scratch()
    let file = dir.appendingPathComponent("2026-11-04.log")
    try! Data(count: Int(HostLoadHistoryWriter.fileByteLimit)).write(to: file)
    HostLoadHistoryWriter.append(sample(moment(2026, 11, 4, 10, 0)), in: dir, timeZone: taipei.timeZone)
    let full = (try! FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).intValue
    expect(full == Int(HostLoadHistoryWriter.fileByteLimit), "a day file at the size cap takes no more")
    try! Data(count: Int(HostLoadHistoryWriter.fileByteLimit) - 1).write(to: file)
    HostLoadHistoryWriter.append(sample(moment(2026, 11, 4, 10, 1)), in: dir, timeZone: taipei.timeZone)
    let under = (try! FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).intValue
    expect(under > Int(HostLoadHistoryWriter.fileByteLimit), "one byte under the cap still takes a line")
}

do {
    let dir = scratch()
    HostLoadHistoryWriter.append(sample(moment(2026, 11, 4, 23, 59, 30)), in: dir, timeZone: taipei.timeZone)
    HostLoadHistoryWriter.append(sample(moment(2026, 11, 5, 0, 0, 30)), in: dir, timeZone: taipei.timeZone)
    let names = try! FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    expect(names == ["2026-11-04.log", "2026-11-05.log"], "a line after midnight goes to the next day's file")
    expect(hostLoadFileName(for: moment(2026, 11, 4, 23, 59, 30), timeZone: taipei.timeZone) == "2026-11-04.log"
           && !isHostLoadFileName("notes.txt") && !isHostLoadFileName("2026-11-04.logx") && isHostLoadFileName("2026-11-04.log"),
           "file names: the day in the writer's zone, and only that pattern counts as ours")
}

// MARK: - 5. Rates

do {
    // 08:59, 09:00, 23:59 on the 4th and 00:00 on the 5th: only 09:00 and 23:59 are working hours.
    let samples = [sample(moment(2026, 11, 4, 8, 59)), sample(moment(2026, 11, 4, 9, 0)),
                   sample(moment(2026, 11, 4, 23, 59)), sample(moment(2026, 11, 5, 0, 0))]
    let r = report(samples, now: moment(2026, 11, 5, 12, 0))
    let day = r.gates[0].days.first { $0.date == "2026-11-04" }
    expect(day?.tally.samples == 2, "working hours are [09:00, 24:00): 09:00 and 23:59 in, 08:59 and 00:00 out (got \(day?.tally.samples ?? -1))")
    expect(r.gates[0].days.first { $0.date == "2026-11-05" }?.tally.samples == 0, "00:00 belongs to no working day it could be counted in")
}

do {
    let base = moment(2026, 11, 4, 10, 0)
    let loads: [Double] = [48.0, 47.99, 20.0, 19.99]
    let samples = loads.enumerated().map { sample(base.addingTimeInterval(Double($0.offset) * 60), load: $0.element) }
    let r = report(samples, now: moment(2026, 11, 4, 12, 0), gates: [48, 20])
    expect(r.gates[0].total.passed == 3, "gate 48: 48.0 is not under it, 47.99 / 20.0 / 19.99 are (got \(r.gates[0].total.passed))")
    expect(r.gates[1].total.passed == 1, "gate 20: 20.0 is not under it, 19.99 is (got \(r.gates[1].total.passed))")
}

do {
    let r = report([sample(moment(2026, 11, 4, 7, 0))], now: moment(2026, 11, 4, 12, 0))
    let day = r.gates[0].days.first { $0.date == "2026-11-04" }
    expect(day != nil && day?.tally.samples == 0 && day?.tally.rate == nil, "a day with no working-hours sample has no rate, not 0 and not 100")
    expect(HostLoadStats.text(r, calendar: taipei).contains("0/") && HostLoadStats.text(r, calendar: taipei).contains(" -"),
           "...and prints a dash")
}

do {
    let base = moment(2026, 11, 4, 10, 0)
    let samples = [sample(base, mem: 30), sample(base.addingTimeInterval(60), mem: 29),
                   sample(base.addingTimeInterval(120), mem: nil),
                   sample(base.addingTimeInterval(180), load: 48.0, mem: 70)]
    let r = report(samples, now: moment(2026, 11, 4, 12, 0), memMin: 30)
    let head = r.gates[1]
    expect(head.gate.memMin == 30 && head.total.samples == 3 && head.total.passed == 1 && head.excludedNoMem == 1,
           "head gate: mem 30 passes, 29 does not, load 48.0 does not, no reading is left out and counted")
}

do {
    let start = moment(2026, 11, 3, 10, 0)
    expect(HostLoadStats.insufficient([sample(start), sample(start.addingTimeInterval(23.9 * 3600))]), "23.9 hours is not enough history")
    expect(!HostLoadStats.insufficient([sample(start), sample(start.addingTimeInterval(24 * 3600))]), "24.0 hours is")
}

do {
    // The day clocks go back in New York (2026-11-01): the working hours are still 15 real hours.
    let ny = calendar("America/New_York")
    let samples = [sample(moment(2026, 11, 1, 0, 30, 0, ny)), sample(moment(2026, 11, 1, 10, 0, 0, ny))]
    let r = report(samples, now: moment(2026, 11, 2, 12, 0, 0, ny), cal: ny)
    let day = r.gates[0].days.first { $0.date == "2026-11-01" }
    expect(day?.tally.expected == 900 && day?.tally.samples == 1, "DST-end day: 900 expected working minutes (got \(day?.tally.expected ?? -1))")
}

do {
    // Written at 02:00 +08:00 on the 4th, which is 18:00 UTC on the 3rd: a UTC reader files it there.
    let f = hostLoadDateFormatter()
    let s = parseHostLoadLine("2026-11-04T02:00:00+08:00 load1=5 free_gb=1 cores=16", formatter: f)!
    let utc = calendar("UTC")
    let r = report([s], now: moment(2026, 11, 4, 12, 0, 0, utc), cal: utc)
    expect(r.gates[0].days.first { $0.date == "2026-11-03" }?.tally.samples == 1,
           "days are cut in the reader's zone, whatever offset the file was written in")
}

// MARK: - 6. Percentiles and the curve

do {
    expect(HostLoadStats.percentile([5], pct: 50) == 5 && HostLoadStats.percentile([5], pct: 95) == 5, "nearest-rank, n=1")
    expect(HostLoadStats.percentile([2, 1], pct: 50) == 1 && HostLoadStats.percentile([2, 1], pct: 95) == 2, "nearest-rank, n=2")
    let hundred = (1...100).map(Double.init)
    expect(HostLoadStats.percentile(hundred, pct: 50) == 50 && HostLoadStats.percentile(hundred, pct: 95) == 95, "nearest-rank, n=100")
    expect(HostLoadStats.percentile([], pct: 50) == nil, "nearest-rank, n=0")
}

do {
    let now = moment(2026, 11, 4, 12, 0)
    let from = now.addingTimeInterval(-600)
    let s = [sample(from.addingTimeInterval(30), load: 0), sample(from.addingTimeInterval(90), load: 48)]
    let line = HostLoadStats.sparkline(s, from: from, minutes: 10, scale: 48)
    expect(line.count == 10 && Array(line)[0] == "▁" && Array(line)[1] == "█" && Array(line)[2] == " ", "a gap is a blank cell, a full-scale minute a full block")
    expect(HostLoadStats.sparkline(s, from: from, minutes: 600, scale: 48).count == 120, "past 120 minutes the curve is 120 cells")
}

// MARK: - 7. The command

do {
    let none = hostHistoryCommand(args: ["--history"], read: HostLoadRead(), now: Date(), calendar: taipei)
    expect(none.code == 1 && none.err?.contains("no load history") == true, "no history: a message and exit 1")
    let json = hostHistoryCommand(args: ["--history", "--json"], read: HostLoadRead(), now: Date(), calendar: taipei)
    expect(json.code == 0 && json.out.contains("\"available\":false") && json.out.contains("\"insufficient\":true"),
           "no history with --json: available false and exit 0")
    for bad in [["--minutes", "0"], ["--minutes", "10081"], ["--days", "9"], ["--gate", "abc"], ["--gate", "0"], ["--mem-min", "101"], ["--bogus"]] {
        expect(hostHistoryCommand(args: ["--history"] + bad, read: HostLoadRead(samples: [sample(Date())]), now: Date(), calendar: taipei).code == 2,
               "bad arguments exit 2: \(bad.joined(separator: " "))")
    }
}

do {
    let base = moment(2026, 11, 4, 10, 0)
    let samples = (0..<3).map { sample(base.addingTimeInterval(Double($0) * 60), load: 10 + Double($0)) }
    let now = moment(2026, 11, 4, 10, 30)
    let human = hostHistoryCommand(args: ["--history", "--gate", "48", "--gate", "20", "--mem-min", "30"],
                                   read: HostLoadRead(samples: samples), now: now, calendar: taipei)
    expect(human.code == 0 && human.out.contains("host load, last 60 min (3 of") && human.out.contains("2026-11-04")
           && human.out.contains("< 48") && human.out.contains("head gate (<48, mem>=30%)")
           && human.out.contains("under 24 hours") && human.out.contains("(partial)"),
           "human output: window line, the day row, all three columns, the first-look and partial notes")
    let json = hostHistoryCommand(args: ["--history", "--gate", "48", "--mem-min", "30", "--json"],
                                  read: HostLoadRead(samples: samples), now: now, calendar: taipei)
    let doc = try? JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any]
    let gates = doc?["gates"] as? [[String: Any]]
    expect(doc?["schema"] as? Int == 1 && doc?["insufficient"] as? Bool == true && gates?.count == 2
           && gates?[1]["kind"] as? String == "head" && gates?[1]["memMinPct"] as? Int == 30,
           "json: schema 1, insufficient, a load gate and a head gate")
    let nullRate = HostLoadStats.json(report([sample(moment(2026, 11, 4, 7, 0))], now: moment(2026, 11, 4, 12, 0)), calendar: taipei)
    let days = ((try? JSONSerialization.jsonObject(with: Data(nullRate.utf8)) as? [String: Any])?["gates"] as? [[String: Any]])?[0]["days"] as? [[String: Any]]
    expect(days?.first?["ratePct"] is NSNull, "json: ratePct is null, not 0, when there were no samples")
    // 2 of 3 working-hours samples pass: the rate must print as 66.7, not 66.7000000000000028.
    let two = [sample(moment(2026, 11, 4, 10, 0), load: 5), sample(moment(2026, 11, 4, 10, 1), load: 6),
               sample(moment(2026, 11, 4, 10, 2), load: 60)]
    let rated = HostLoadStats.json(report(two, now: moment(2026, 11, 4, 10, 3)), calendar: taipei)
    expect(rated.contains("\"ratePct\":66.7,") && rated.contains("\"load1\":60,"), "json numbers print as written, not as 17-digit doubles")
    // The default gate is 3 x cores.
    let dflt = hostHistoryCommand(args: ["--history"], read: HostLoadRead(samples: samples), now: now, calendar: taipei)
    expect(dflt.out.contains("< 48"), "the default gate is 3 x cores (16 cores: 48)")
}

// MARK: - 8. The CPU share (B-4094)

do {
    let at = moment(2026, 11, 4, 2, 31, 5)
    let s = HostLoadSample(at: at, load1: 12.345, freeBytes: 57_037_979_648, memPct: 73, cpuPct: 41, cores: 16)
    expect(hostLoadLine(s, timeZone: taipei.timeZone)
           == "2026-11-04T02:31:05+08:00 load1=12.35 free_gb=53.1 mem_pct=73 cpu_pct=41 cores=16\n",
           "a sample with a CPU share writes cpu_pct between mem_pct and cores")
    var noMem = s; noMem.memPct = nil
    expect(hostLoadLine(noMem, timeZone: taipei.timeZone) == "2026-11-04T02:31:05+08:00 load1=12.35 free_gb=53.1 cpu_pct=41 cores=16\n",
           "no memory reading: cpu_pct still sits before cores")
    var noCPU = s; noCPU.cpuPct = nil
    expect(!hostLoadLine(noCPU, timeZone: taipei.timeZone).contains("cpu_pct"), "an unreadable CPU share leaves the field out")
    let back = parseHostLoadLine(hostLoadLine(s, timeZone: taipei.timeZone).trimmingCharacters(in: .newlines), formatter: hostLoadDateFormatter())
    expect(back?.cpuPct == 41 && back?.memPct == 73 && back?.cores == 16 && back?.load1 == 12.35 && back?.at == at,
           "a new line parses back with its CPU share")
    let old = parseHostLoadLine("2026-11-04T02:31:05+08:00 load1=1 free_gb=1 mem_pct=70 cores=4", formatter: hostLoadDateFormatter())
    expect(old != nil && old?.cpuPct == nil && old?.memPct == 70, "a line from before cpu_pct is valid and has no CPU share")
}

do {
    let f = hostLoadDateFormatter()
    func cpu(_ field: String) -> HostLoadSample? {
        parseHostLoadLine("2026-11-04T02:31:05+08:00 load1=1 free_gb=1 \(field) cores=4", formatter: f)
    }
    expect(cpu("cpu_pct=101") == nil && cpu("cpu_pct=-1") == nil && cpu("cpu_pct=12.5") == nil && cpu("cpu_pct=") == nil,
           "cpu_pct of 101, -1, 12.5 or nothing damages the line")
    expect(cpu("cpu_pct=0")?.cpuPct == 0 && cpu("cpu_pct=100")?.cpuPct == 100, "cpu_pct 0 and 100 are valid")
}

do {
    expect(hostLoadCPUPct(nil) == nil && hostLoadCPUPct(.nan) == nil && hostLoadCPUPct(.infinity) == nil
           && hostLoadCPUPct(-.infinity) == nil, "no CPU figure, NaN and infinity give no CPU share")
    expect(hostLoadCPUPct(41.4) == 41 && hostLoadCPUPct(41.5) == 42 && hostLoadCPUPct(99.6) == 100 && hostLoadCPUPct(100) == 100,
           "the CPU share rounds half up")
    expect(hostLoadCPUPct(-0.3) == 0 && hostLoadCPUPct(100.4) == 100, "the CPU share is clamped to 0...100")
}

do {
    let dir = scratch().appendingPathComponent("host-load")
    HostLoadHistoryWriter.append(sample(moment(2026, 11, 4, 10, 0), cpu: 41), in: dir, timeZone: taipei.timeZone)
    let text = try! String(contentsOf: dir.appendingPathComponent("2026-11-04.log"), encoding: .utf8)
    expect(text.contains(" cpu_pct=41 cores=16\n"), "the writer puts cpu_pct in the file")
    expect(readHostLoadSamples(in: dir).samples.first?.cpuPct == 41, "...and the reader gets it back")
}

do {
    // Only new lines: CPU 0, 50, 100 in three consecutive minutes.
    let base = moment(2026, 11, 4, 10, 0)
    let samples = [0, 50, 100].enumerated().map { sample(base.addingTimeInterval(Double($0.offset) * 60), cpu: $0.element) }
    let r = report(samples, now: moment(2026, 11, 4, 10, 2, 30))
    expect(r.window.cpuP50 == 50 && r.window.cpuP95 == 100 && r.window.cpuMax == 100
           && r.window.cpuMaxAt == base.addingTimeInterval(120), "CPU window: p50 50, p95 100, max 100 at the third minute")
    let spark = Array(r.window.cpuSpark)
    expect(spark.count == 60 && Array(spark.suffix(3)) == ["▁", "▅", "█"], "the CPU curve is a full block at 100% (got \(r.window.cpuSpark))")
    let text = HostLoadStats.text(r, calendar: taipei)
    expect(text.contains("  cpu p50 50% · p95 100% · max 100% (10:02)") && !text.contains("cpu: no readings"),
           "text: the CPU curve and its figures follow the load curve")
    let load = text.range(of: "p50 10.0 ·")!.lowerBound, cpuLine = text.range(of: "cpu p50")!.lowerBound
    expect(load < cpuLine, "text: the CPU lines come after the load lines")
}

do {
    // Only old lines: no CPU anywhere.
    let base = moment(2026, 11, 4, 10, 0)
    let samples = (0..<3).map { sample(base.addingTimeInterval(Double($0) * 60), load: 10 + Double($0)) }
    let r = report(samples, now: moment(2026, 11, 4, 10, 30))
    let text = HostLoadStats.text(r, calendar: taipei)
    expect(r.window.cpuSpark == "" && r.window.cpuP50 == nil && r.window.cpuMax == nil
           && text.contains("\n  cpu: no readings in this window") && text.contains("host load, last 60 min (3 of"),
           "old lines only: the CPU part says it has no readings and the load part is unchanged")
    let doc = try? JSONSerialization.jsonObject(with: Data(HostLoadStats.json(r, calendar: taipei).utf8)) as? [String: Any]
    let window = doc?["window"] as? [String: Any]
    let cpu = window?["cpuPct"] as? [String: Any]
    let series = window?["series"] as? [[String: Any]]
    expect(doc?["schema"] as? Int == 1 && cpu?["p50"] is NSNull && cpu?["p95"] is NSNull && cpu?["max"] is NSNull
           && cpu?["maxAt"] is NSNull && series?.count == 3 && series?.allSatisfy { $0["cpuPct"] is NSNull } == true,
           "json, old lines only: window.cpuPct is all null and every series cpuPct is null")
}

do {
    // Mixed: two old lines, then two lines with a CPU share, in one day file.
    let dir = scratch()
    let newer = [sample(moment(2026, 11, 4, 10, 2), cpu: 41), sample(moment(2026, 11, 4, 10, 3), cpu: 77)]
    write("2026-11-04T10:00:05+08:00 load1=10 free_gb=40 mem_pct=70 cores=16\n"
          + "2026-11-04T10:01:05+08:00 load1=10 free_gb=40 mem_pct=70 cores=16\n" + lines(newer),
          "2026-11-04.log", in: dir)
    let read = readHostLoadSamples(in: dir)
    expect(read.samples.count == 4 && read.corruptLines == 0, "mixed old and new lines all parse")
    let now = moment(2026, 11, 4, 10, 3, 30)
    let human = hostHistoryCommand(args: ["--history"], read: read, now: now, calendar: taipei)
    expect(human.out.contains("  cpu p50 41% · p95 77% · max 77% (10:03)"), "mixed: the CPU figures count only the lines that carry one")
    let curves = human.out.split(separator: "\n").filter {
        $0.hasPrefix("  ") && !$0.contains("p50") && $0.contains { "▁▂▃▄▅▆▇█".contains($0) }
    }
    let cells = curves.map { Array($0.dropFirst(2).suffix(4)) }
    expect(cells.count == 2 && !cells[0].contains(" ") && cells[1].prefix(2) == [" ", " "] && !cells[1].suffix(2).contains(" "),
           "mixed: the load curve has no gap, the CPU curve is blank for the two old minutes")
    let json = hostHistoryCommand(args: ["--history", "--json"], read: read, now: now, calendar: taipei)
    let doc = try? JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any]
    let window = doc?["window"] as? [String: Any]
    let series = window?["series"] as? [[String: Any]]
    expect(series?[0]["cpuPct"] is NSNull && series?[2]["cpuPct"] as? Int == 41
           && (window?["cpuPct"] as? [String: Any])?["max"] as? Int == 77, "json, mixed: null for old minutes, 41 for the third, window max 77")
}

// MARK: - 9. Swap and pressure (B-4065)

do {
    let at = moment(2026, 11, 4, 2, 31, 5)
    let s = HostLoadSample(at: at, load1: 12.345, freeBytes: 57_037_979_648, memPct: 73, cpuPct: 41, cores: 16,
                           swapBytes: 52_303_191_040, pressure: 2)
    let line = hostLoadLine(s, timeZone: taipei.timeZone)
    expect(line == "2026-11-04T02:31:05+08:00 load1=12.35 free_gb=53.1 mem_pct=73 cpu_pct=41 swap_gb=48.7 pressure=2 cores=16\n",
           "a sample with swap and pressure writes both keys between cpu_pct and cores")
    let back = parseHostLoadLine(line.trimmingCharacters(in: .newlines), formatter: hostLoadDateFormatter())
    expect(back?.pressure == 2 && abs((back?.swapGB ?? -1) - 48.7) < 0.05 && back?.cpuPct == 41 && back?.cores == 16,
           "a new line parses back with its swap and pressure")
    var noSwap = s; noSwap.swapGB = nil
    var noPressure = s; noPressure.pressure = nil
    expect(!hostLoadLine(noSwap, timeZone: taipei.timeZone).contains("swap_gb")
           && hostLoadLine(noSwap, timeZone: taipei.timeZone).contains("pressure=2"),
           "an unreadable swap figure leaves only swap_gb out")
    expect(!hostLoadLine(noPressure, timeZone: taipei.timeZone).contains("pressure")
           && hostLoadLine(noPressure, timeZone: taipei.timeZone).contains("swap_gb=48.7"),
           "an unreadable pressure level leaves only pressure out")
    // Zero swap is a reading (no swap file yet), not a missing one.
    let zero = HostLoadSample(at: at, load1: 1, freeBytes: 1_073_741_824, memPct: nil, cores: 4, swapBytes: 0)
    expect(hostLoadLine(zero, timeZone: taipei.timeZone).contains("swap_gb=0.0"), "zero swap is written, not omitted")
    // An earlier line (no new keys) still reads, and the new keys are simply absent.
    let old = parseHostLoadLine("2026-11-04T02:31:05+08:00 load1=1 free_gb=1 mem_pct=70 cpu_pct=5 cores=4", formatter: hostLoadDateFormatter())
    expect(old != nil && old?.swapGB == nil && old?.pressure == nil, "a line from before swap_gb has neither new field")
    // The previous release's parser (unknown keys ignored) is modelled by stripping the new keys: same sample otherwise.
    let stripped = line.replacingOccurrences(of: " swap_gb=48.7", with: "").replacingOccurrences(of: " pressure=2", with: "")
    expect(parseHostLoadLine(stripped.trimmingCharacters(in: .newlines), formatter: hostLoadDateFormatter())?.cpuPct == 41,
           "a line without the new keys is the earlier format and still parses")
}

do {
    let f = hostLoadDateFormatter()
    func field(_ text: String) -> HostLoadSample? {
        parseHostLoadLine("2026-11-04T02:31:05+08:00 load1=1 free_gb=1 \(text) cores=4", formatter: f)
    }
    expect(field("swap_gb=-1") == nil && field("swap_gb=nan") == nil && field("swap_gb=") == nil && field("swap_gb=abc") == nil,
           "a negative, non-finite or empty swap_gb damages the line")
    expect(field("pressure=0") == nil && field("pressure=3") == nil && field("pressure=5") == nil && field("pressure=") == nil,
           "a pressure level other than 1, 2 or 4 damages the line")
    expect(field("pressure=1")?.pressure == 1 && field("pressure=4")?.pressure == 4 && field("swap_gb=0")?.swapGB == 0,
           "pressure 1 and 4 and swap_gb 0 are valid")
}

do {
    let dir = scratch().appendingPathComponent("host-load")
    let s = HostLoadSample(at: moment(2026, 11, 4, 10, 0), load1: 2, freeBytes: 40 << 30, memPct: 70, cores: 16,
                           swapBytes: 3 << 30, pressure: 1)
    HostLoadHistoryWriter.append(s, in: dir, timeZone: taipei.timeZone)
    let read = readHostLoadSamples(in: dir)
    expect(read.samples.count == 1 && read.samples[0].pressure == 1 && read.samples[0].swapGB == 3.0,
           "the writer's file reads back with swap and pressure")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
