import Foundation

/// WHAT THE HISTORY ANSWERS: the shape of the last N minutes, and how often a gate would have let
/// a new session open during working hours. Pure functions over `[HostLoadSample]`; the clock, the
/// calendar and the time zone are parameters so a harness can pin them (HostLoadHistory.swift has
/// the line format).
///
/// A gate PASSES a sample when `load1 < gate`, the direction both real gates use (the head-open
/// hook refuses at `>= max`, `load-slot` takes the lock at `< max`). The HEAD gate adds the memory
/// witness `mem_pct >= memMin`. The hook's third rule (three minutes since the last start) is the
/// dispatcher's pacing, not a property of the machine, and is not modelled.
///
/// WHAT IS NEVER DONE: no extrapolation, no back-fill. A minute with no line (app closed, laptop
/// asleep) is a gap and stays out of both sides of the rate; `expected` is printed beside
/// `samples` so the gap is visible instead of hidden.
enum HostLoadStats {
    /// Local hours the rates are taken over: `[start, end)`, so 09:00 counts and 24:00 (the next
    /// midnight) does not. The repo has no working-hours definition; this is B-3775's working
    /// assumption and the one place to change it.
    static let workHours = (start: 9, end: 24)
    /// Less history than this and the rates are a first look, not a measurement.
    static let sufficientHours = 24.0
    static let maxSparkCells = 120

    // MARK: Pure arithmetic

    /// Nearest-rank percentile: sort ascending, take the `ceil(pct/100 * n)`-th value (1-based).
    /// Integer arithmetic, so 95 of 100 never lands on 96 through a floating-point 95.00000000000001.
    static func percentile(_ values: [Double], pct: Int) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, (pct * sorted.count + 99) / 100)
        return sorted[min(rank, sorted.count) - 1]
    }

    static func inWorkHours(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= workHours.start && hour < workHours.end
    }

    /// One decimal, nil when there is nothing to divide: no samples is "no data", not 0% and not 100%.
    static func ratePct(passed: Int, samples: Int) -> Double? {
        guard samples > 0 else { return nil }
        return (Double(passed) * 1000 / Double(samples)).rounded() / 10
    }

    static func historyHours(_ samples: [HostLoadSample]) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.at.timeIntervalSince(first.at) / 3600
    }

    static func insufficient(_ samples: [HostLoadSample]) -> Bool {
        historyHours(samples) < sufficientHours
    }

    // MARK: Gates

    struct Gate: Equatable {
        var below: Double
        /// Set for the head gate: the memory witness too.
        var memMin: Int?
        var label: String {
            memMin.map { "head gate (<\(Self.number(below)), mem>=\($0)%)" } ?? "< \(Self.number(below))"
        }
        static func number(_ value: Double) -> String { String(format: "%g", value) }
    }

    /// nil: this sample cannot be judged by this gate (the head gate without a memory reading).
    static func passes(_ sample: HostLoadSample, _ gate: Gate) -> Bool? {
        guard let memMin = gate.memMin else { return sample.load1 < gate.below }
        guard let memPct = sample.memPct else { return nil }
        return sample.load1 < gate.below && memPct >= memMin
    }

    struct Count: Equatable {
        var samples = 0
        var expected = 0
        var passed = 0
        var rate: Double? { HostLoadStats.ratePct(passed: passed, samples: samples) }
    }

    struct DayRow: Equatable { var date: String; var tally: Count }

    struct GateResult: Equatable {
        var gate: Gate
        var days: [DayRow]
        var total: Count
        /// Working-hours samples the head gate had to leave out for lack of a memory reading.
        var excludedNoMem: Int
    }

    struct Window: Equatable {
        var minutes: Int
        var samples: [HostLoadSample]
        var expected: Int
        var p50: Double?, p95: Double?, max: Double?
        var maxAt: Date?
        var spark: String
    }

    struct Report: Equatable {
        var now: Date
        var cores: Int
        var window: Window
        var gates: [GateResult]
        var historyHours: Double
        var insufficient: Bool
        var corruptLines: Int
        var duplicateLines: Int
    }

    // MARK: The report

    /// Nil when there is no sample at all. `days` counts local calendar days back from today
    /// (today included); `gates` are the load limits, and `memMin` adds the head gate on the first.
    static func report(_ read: HostLoadRead, now: Date, minutes: Int, days: Int,
                       gates limits: [Double], memMin: Int?, calendar: Calendar) -> Report? {
        let all = read.samples
        guard let first = all.first, let last = all.last, let primary = limits.first else { return nil }

        var gates = limits.map { Gate(below: $0, memMin: nil) }
        if let memMin { gates.append(Gate(below: primary, memMin: memMin)) }

        let from = now.addingTimeInterval(-Double(minutes) * 60)
        let inWindow = all.filter { $0.at > from && $0.at <= now }
        let loads = inWindow.map(\.load1)
        let peak = inWindow.max { $0.load1 < $1.load1 }
        let span = Int(now.timeIntervalSince(max(from, first.at)) / 60) + 1
        let window = Window(
            minutes: minutes, samples: inWindow, expected: max(min(minutes, span), inWindow.count),
            p50: percentile(loads, pct: 50), p95: percentile(loads, pct: 95),
            max: peak?.load1, maxAt: peak?.at,
            spark: sparkline(inWindow, from: from, minutes: minutes,
                             scale: Swift.max(primary, peak?.load1 ?? 0)))

        let today = calendar.startOfDay(for: now)
        let dayStarts = (0..<days).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var byDay: [String: [HostLoadSample]] = [:]
        for sample in all where inWorkHours(sample.at, calendar: calendar) {
            byDay[hostLoadDayKey(sample.at, calendar: calendar), default: []].append(sample)
        }
        let results = gates.map { gate -> GateResult in
            var rows: [DayRow] = []
            var total = Count(), excluded = 0
            for start in dayStarts {
                let key = hostLoadDayKey(start, calendar: calendar)
                let expected = expectedMinutes(day: start, from: first.at, to: now, calendar: calendar)
                let samples = byDay[key] ?? []
                var row = Count(expected: expected)
                for sample in samples {
                    guard let ok = passes(sample, gate) else { excluded += 1; continue }
                    row.samples += 1
                    if ok { row.passed += 1 }
                }
                row.expected = Swift.max(expected, row.samples)
                // Same days for every gate, so the table lines up: skip only a day with nothing at all.
                if expected == 0, samples.isEmpty { continue } // before the first sample, or not begun
                rows.append(DayRow(date: key, tally: row))
                total.samples += row.samples
                total.expected += row.expected
                total.passed += row.passed
            }
            return GateResult(gate: gate, days: rows, total: total, excludedNoMem: excluded)
        }
        return Report(now: now, cores: last.cores, window: window, gates: results,
                      historyHours: historyHours(all), insufficient: insufficient(all),
                      corruptLines: read.corruptLines, duplicateLines: read.duplicateLines)
    }

    /// Whole minutes of that local day's working hours that fall between the first sample ever
    /// taken and now, counted on the real clock (a 25-hour DST day still has 15 working hours).
    static func expectedMinutes(day: Date, from first: Date, to now: Date, calendar: Calendar) -> Int {
        guard let begin = calendar.date(bySettingHour: workHours.start, minute: 0, second: 0, of: day),
              let end = workHours.end >= 24
                ? calendar.date(byAdding: .day, value: 1, to: day)
                : calendar.date(bySettingHour: workHours.end, minute: 0, second: 0, of: day)
        else { return 0 }
        let low = Swift.max(begin, first), high = Swift.min(end, now)
        return high > low ? Int(high.timeIntervalSince(low) / 60) : 0
    }

    // MARK: Rendering

    /// One cell per minute (a blank for a minute with no sample), scaled so `scale` is a full block;
    /// past 120 minutes a cell takes the MAX of its stretch, because the peaks are the point.
    static func sparkline(_ samples: [HostLoadSample], from: Date, minutes: Int, scale: Double) -> String {
        let blocks = Array("▁▂▃▄▅▆▇█")
        let cells = Swift.min(minutes, maxSparkCells)
        let perCell = Double(minutes) / Double(cells)
        var peaks = [Double?](repeating: nil, count: cells)
        for sample in samples {
            let index = Swift.min(cells - 1, Swift.max(0, Int(sample.at.timeIntervalSince(from) / 60 / perCell)))
            peaks[index] = Swift.max(peaks[index] ?? 0, sample.load1)
        }
        return String(peaks.map { peak -> Character in
            guard let peak else { return " " }
            return blocks[Swift.min(blocks.count - 1, Int(peak / Swift.max(scale, 0.01) * Double(blocks.count)))]
        })
    }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func text(_ report: Report, calendar: Calendar) -> String {
        let window = report.window
        var out = ["host load, last \(window.minutes) min (\(window.samples.count) of "
                   + "\(window.expected) samples, \(Swift.max(0, window.expected - window.samples.count)) missing)"]
        if let p50 = window.p50, let p95 = window.p95, let peak = window.max, let at = window.maxAt {
            out.append("  " + window.spark)
            out.append(String(format: "  p50 %.1f · p95 %.1f · max %.1f (%@)", p50, p95, peak,
                              clock(at, calendar: calendar)))
        } else {
            out.append("  no samples in this window")
        }
        let hours = String(format: "%02d:00-%02d:00", workHours.start, workHours.end)
        out.append("work hours \(hours), load1 below the gate")
        let heads = report.gates.map(\.gate.label)
        out.append(pad("  date", 14) + pad("samples", 11) + heads.map { pad($0, 10) }.joined())
        let dates = report.gates.first?.days.map(\.date) ?? []
        for (index, date) in dates.enumerated() {
            let tally = report.gates[0].days[index].tally
            var row = pad("  " + date, 14) + pad("\(tally.samples)/\(tally.expected)", 11)
            for gate in report.gates {
                row += pad(rate(gate.days[index].tally.rate), 10)
            }
            if Double(tally.samples) < Double(tally.expected) / 2 { row += "(partial)" }
            out.append(row)
        }
        if let first = report.gates.first {
            out.append(pad("  total", 14) + pad("\(first.total.samples)/\(first.total.expected)", 11)
                       + report.gates.map { pad(rate($0.total.rate), 10) }.joined())
        }
        if let head = report.gates.first(where: { $0.gate.memMin != nil }) {
            out.append("head gate also needs memory free; the 3-minute spacing rule is not modelled"
                       + (head.excludedNoMem > 0 ? " (\(head.excludedNoMem) samples without a memory reading left out)" : ""))
        }
        if report.insufficient {
            out.append(String(format: "history covers %.0fh (%d samples): under 24 hours, read the rates as a first look",
                              report.historyHours, report.gates.first?.total.samples ?? 0))
        }
        if report.corruptLines + report.duplicateLines > 0 {
            out.append("skipped \(report.corruptLines) damaged and \(report.duplicateLines) duplicate-minute lines")
        }
        return out.joined(separator: "\n")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func rate(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "-"
    }

    /// The machine-readable report (`schema` 1). `ratePct` is a JSON null when there were no samples.
    static func json(_ report: Report, calendar: Calendar) -> String {
        let stamp = hostLoadDateFormatter(timeZone: calendar.timeZone)
        func orNull<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
        // A Double prints with 17 digits through JSONSerialization (91.8 as 91.799999999999997); a
        // decimal made from the rounded text prints as written.
        func num(_ value: Double, _ places: Int = 1) -> NSDecimalNumber {
            NSDecimalNumber(string: String(format: "%.\(places)f", value))
        }
        func tally(_ t: Count) -> [String: Any] {
            ["samples": t.samples, "expected": t.expected, "passed": t.passed,
             "ratePct": orNull(t.rate.map { num($0) })]
        }
        let window = report.window
        let load: [String: Any] = ["p50": orNull(window.p50.map { num($0, 2) }), "p95": orNull(window.p95.map { num($0, 2) }),
                                   "max": orNull(window.max.map { num($0, 2) }), "maxAt": orNull(window.maxAt.map { stamp.string(from: $0) })]
        let series = window.samples.map { s -> [String: Any] in
            ["at": stamp.string(from: s.at), "load1": num(s.load1, 2), "freeGB": num(s.freeGB),
             "memPct": orNull(s.memPct)]
        }
        let gates = report.gates.map { g -> [String: Any] in
            var entry: [String: Any] = [
                "kind": g.gate.memMin == nil ? "load" : "head", "below": num(g.gate.below, 2),
                "days": g.days.map { var d = tally($0.tally); d["date"] = $0.date; return d },
                "total": tally(g.total)]
            if let memMin = g.gate.memMin { entry["memMinPct"] = memMin; entry["excludedNoMem"] = g.excludedNoMem }
            return entry
        }
        let document: [String: Any] = [
            "schema": 1, "available": true, "now": stamp.string(from: report.now),
            "timeZone": calendar.timeZone.identifier, "cores": report.cores,
            "window": ["minutes": window.minutes, "samples": window.samples.count,
                       "expected": window.expected, "load1": load, "series": series],
            "workHours": ["start": workHours.start, "end": workHours.end], "gates": gates,
            "historyHours": num(report.historyHours),
            "insufficient": report.insufficient, "corruptLines": report.corruptLines,
            "duplicateLines": report.duplicateLines]
        return render(document)
    }

    /// What `--json` prints when there is no history, so a script's parser never branches on rc.
    static let jsonUnavailable = render(["schema": 1, "available": false, "historyHours": 0,
                                         "insufficient": true] as [String: Any])

    private static func render(_ document: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
