import Foundation

/// THE MINUTE-BY-MINUTE LOAD HISTORY: one line a minute in `~/.tally/host-load/<local date>.log`,
/// written by the app (HostLoadHistoryWriter.swift) and read back by `tally status --history`
/// (TallyCLI/HostHistoryCommand.swift). Both targets compile this one copy, so the line the app
/// writes and the line the CLI parses cannot drift apart. Only Foundation, so a harness runs it.
///
/// `host-health.log` holds ALARM EVENTS and `host-health.json` holds only the present value; neither
/// can answer "how often was the machine below the line last week", which is what this exists for.
///
/// A line is space-separated `key=value`, newline-terminated; unknown keys are ignored on read, so
/// a later build may add a field without breaking this reader (the "add, never change" rule the
/// host-health report keeps):
///
///     2026-11-04T02:31:05+08:00 load1=12.34 free_gb=53.1 mem_pct=73 cores=16
struct HostLoadSample: Equatable, Sendable {
    var at: Date
    var load1: Double
    var freeGB: Double
    /// kern.memorystatus_level, the "System-wide memory free percentage"; nil when unreadable (the
    /// field is then left out of the line rather than written empty).
    var memPct: Int?
    var cores: Int
}

extension HostLoadSample {
    init(at: Date, load1: Double, freeBytes: UInt64, memPct: Int?, cores: Int) {
        self.init(at: at, load1: load1, freeGB: Double(freeBytes) / 1_073_741_824,
                  memPct: memPct, cores: cores)
    }
}

/// Where the day's files live. An unshipped build (Dev, a DerivedData Release) writes its own
/// folder so it never pollutes the history the installed app builds; the CLI reads the shipped one.
func hostLoadDirectory(unshipped: Bool) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(unshipped ? ".tally/host-load-dev" : ".tally/host-load")
}

/// An explicit Gregorian calendar in `timeZone`: `Calendar.current` follows the user's regional
/// calendar (Buddhist, Japanese), which would name a file `2569-11-04.log`.
func hostLoadCalendar(timeZone: TimeZone = .current) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

/// `YYYY-MM-DD` of `date` in `calendar`, which is also the file stem and the per-day bucket key.
func hostLoadDayKey(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

func hostLoadFileName(for date: Date, timeZone: TimeZone = .current) -> String {
    hostLoadDayKey(date, calendar: hostLoadCalendar(timeZone: timeZone)) + ".log"
}

/// Whether `name` is one of ours (`YYYY-MM-DD.log`), which is the only kind of file pruning or
/// reading ever touches: anything else in the folder is somebody else's.
func isHostLoadFileName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard bytes.count == 14, name.hasSuffix(".log") else { return false }
    for (index, byte) in bytes.prefix(10).enumerated() {
        if index == 4 || index == 7 { if byte != UInt8(ascii: "-") { return false } }
        else if !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { return false }
    }
    return true
}

func hostLoadDateFormatter(timeZone: TimeZone = .current) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}

/// One sample as a line, newline included. `String(format:)` without a locale, so a comma-decimal
/// system language cannot split a number into two fields. The timestamp is to the second and
/// carries the local offset; compare times as `Date`s, never as these strings.
func hostLoadLine(_ sample: HostLoadSample, timeZone: TimeZone = .current) -> String {
    var line = hostLoadDateFormatter(timeZone: timeZone).string(from: sample.at)
    line += String(format: " load1=%.2f free_gb=%.1f", sample.load1, sample.freeGB)
    if let memPct = sample.memPct { line += " mem_pct=\(memPct)" }
    return line + " cores=\(sample.cores)\n"
}

/// One line back into a sample, or nil when it is damaged: a missing or malformed required field
/// (`load1`, `free_gb`, `cores`), a negative or non-finite number, an unparseable timestamp.
/// Nothing is repaired or guessed, because a half-read line would be counted as a real minute.
func parseHostLoadLine(_ line: String, formatter: ISO8601DateFormatter) -> HostLoadSample? {
    let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
    guard let stamp = tokens.first, let at = formatter.date(from: String(stamp)) else { return nil }
    var load1: Double?, freeGB: Double?, memPct: Int?, cores: Int?
    for token in tokens.dropFirst() {
        let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        let value = String(pair[1])
        switch pair[0] {
        case "load1": load1 = Double(value)
        case "free_gb": freeGB = Double(value)
        case "mem_pct":
            guard let n = Int(value), (0...100).contains(n) else { return nil }
            memPct = n
        case "cores":
            guard let n = Int(value), n > 0 else { return nil }
            cores = n
        default: continue
        }
    }
    guard let load1, load1.isFinite, load1 >= 0, let freeGB, freeGB.isFinite, freeGB >= 0,
          let cores else { return nil }
    return HostLoadSample(at: at, load1: load1, freeGB: freeGB, memPct: memPct, cores: cores)
}

struct HostLoadRead: Equatable {
    /// Sorted by time, one per clock minute.
    var samples: [HostLoadSample] = []
    /// Lines that were not a sample: empty, damaged, or an unterminated last line.
    var corruptLines = 0
    /// Extra lines for a minute that already had one (two app builds writing the same folder).
    var duplicateLines = 0
}

/// Every day file in `directory`, parsed, ordered and thinned to the FIRST line of each clock
/// minute. A file that cannot be read (a directory with that name, no permission) is skipped.
///
/// THE LAST LINE MUST END IN A NEWLINE to count: the writer always ends a line with one, so an
/// unterminated tail is a write cut short, and its last field could be truncated without looking
/// wrong (`cores=1` for `cores=16`).
func readHostLoadSamples(in directory: URL) -> HostLoadRead {
    var result = HostLoadRead()
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
        return result
    }
    let formatter = hostLoadDateFormatter()
    var all: [HostLoadSample] = []
    for name in names where isHostLoadFileName(name) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
        var pieces = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        // `split` leaves "" after the final newline, or the unterminated tail
        if pieces.popLast()?.isEmpty == false { result.corruptLines += 1 }
        for piece in pieces {
            let text = String(decoding: piece, as: UTF8.self)
            if let sample = parseHostLoadLine(text, formatter: formatter) { all.append(sample) }
            else { result.corruptLines += 1 }
        }
    }
    all.sort { $0.at < $1.at }
    var seen = Set<Int>()
    for sample in all {
        if seen.insert(Int((sample.at.timeIntervalSince1970 / 60).rounded(.down))).inserted {
            result.samples.append(sample)
        } else {
            result.duplicateLines += 1
        }
    }
    return result
}
