import Foundation

// THE RULES OF THE ONE-PROCESS CPU WATCH (B-4496). Foundation only, so tests/processcpu compiles it
// with a fixture clock and a fake process table.
//
// WHY ONE PROCESS AND NOT THE MACHINE. On 2026-11-13 fseventsd (root) held about 100% of one core
// for over an hour on a 16-core Mac. That is 6% of the machine, so the whole-machine CPU watch
// (CPUAlertLogic, 90%) and the host-load watch (HostHealthLogic) were right to stay quiet, and a
// person found it. This watch asks the other question: is any single process stuck at a core's
// worth of CPU, for long enough that it is not a build.
//
// THE UNIT IS A SINGLE CORE'S SHARE (Activity Monitor's %CPU): a 4-thread virtual machine reads 400.
// The reading is the difference of two cumulative CPU times over the wall-clock gap between them.
//
// WHY THE CLEAR IS ANNOUNCED. CPUAlertMonitor and HostHealthMonitor log their clears and never
// post them, on purpose: nobody acts on "the machine calmed down". A single-process alarm sends
// somebody to deal with that process, and the clear is what tells them they can stop.

/// One row of the process table, as `/bin/ps -A -o pid=,etime=,cputime=,comm=` prints it.
struct ProcessCPURow: Equatable, Sendable {
    var pid: Int32
    /// now minus elapsed time, second precision: it jitters by about a second between two reads.
    var startedAt: Date
    /// Cumulative user plus system CPU of all threads.
    var cpuSeconds: Double
    /// The executable path. May contain spaces. Never argv.
    var path: String
}

/// The lines the watch is decided against. A number outside its range falls back to the default
/// rather than being clamped, the rule `HostHealthLimits.from` states: a typo must not silently
/// become the edge. The keys exist so a test run can shorten the thresholds.
struct ProcessCPULimits: Equatable, Sendable {
    /// Share of ONE core that counts as stuck.
    var percent: Double
    var sustain: TimeInterval
    var clearAfter: TimeInterval
    var sampleInterval: TimeInterval
    /// A gap longer than this is a sleep or a missed turn; the window across it is dropped.
    var maxGap: TimeInterval { max(150, sampleInterval * 2.5) }

    static let standard = ProcessCPULimits(percent: 80, sustain: 900, clearAfter: 120, sampleInterval: 60)

    static let percentKey = "processCPUPercent"
    static let sustainKey = "processCPUSustainSeconds"
    static let clearKey = "processCPUClearSeconds"
    static let sampleKey = "processCPUSampleSeconds"

    static func from(_ defaults: UserDefaults) -> ProcessCPULimits {
        // A launch argument (`-processCPUSustainSeconds 120`) arrives as a string, so one is read too.
        func number(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            let object = defaults.object(forKey: key)
            let value = (object as? NSNumber)?.doubleValue ?? (object as? String).flatMap(Double.init)
            guard let value, range.contains(value) else { return fallback }
            return value
        }
        return ProcessCPULimits(
            percent: number(percentKey, 10...1600, standard.percent),
            sustain: number(sustainKey, 60...7200, standard.sustain),
            clearAfter: number(clearKey, 20...3600, standard.clearAfter),
            sampleInterval: number(sampleKey, 10...300, standard.sampleInterval))
    }
}

struct ProcessCPUTrack: Equatable, Sendable {
    var pid: Int32
    var startedAt: Date
    var path: String
    var lastCPU: Double
    var lastAt: Date
    var lastPercent: Double?
    /// Start of the first window of the current run at or over the line.
    var overSince: Date?
    /// Start of the first window of the current run under the line; kept only while alarmed.
    var underSince: Date?
    /// Non-nil while in alarm: the start of the run that crossed.
    var alarmedSince: Date?
    /// Whether the alarm went out as a banner. Only such an alarm gets a clear banner.
    var announced = false
}

struct ProcessCPUWatch: Equatable, Sendable {
    var tracks: [Int32: ProcessCPUTrack] = [:]
}

enum ProcessCPUEventKind: String, Sendable { case alarm, clear, exited }

struct ProcessCPUEvent: Equatable, Sendable {
    var kind: ProcessCPUEventKind
    var pid: Int32
    var path: String
    /// The window that decided it; nil for a process that is gone.
    var percent: Double?
    /// When the run over the line began.
    var since: Date
    /// When it stopped being over (a clear, an exit); equals the event's own time for an alarm.
    var until: Date
    var announced: Bool
    /// The app macOS holds responsible for a system executable, filled in by the monitor.
    var app: String? = nil
}

enum ProcessCPUOwner: Equatable, Sendable { case tally, system, none }

enum ProcessCPUWatchLogic {
    /// The Settings switch (`SettingsStore.processCPUAlertEnabled` writes it); on unless turned off.
    static let enabledKey = "processCPUAlertEnabled"
    static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Two reads of the same pid are the same process when its start time agrees within this.
    static let startTolerance: TimeInterval = 2
    static let maxNamed = 3

    /// Dev and other unshipped builds write their own folder, as `hostLoadDirectory` does, so they
    /// never mix lines into the log the installed app writes.
    static func logFile(unshipped: Bool) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(unshipped ? ".tally/logs-dev/process-cpu.log" : ".tally/logs/process-cpu.log")
    }

    // MARK: - the process table

    /// "ss", "mm:ss", "hh:mm:ss" or "dd-hh:mm:ss".
    static func etimeSeconds(_ text: Substring) -> Int? {
        var days = 0
        var rest = text
        if let dash = text.firstIndex(of: "-") {
            guard let d = Int(text[..<dash]), d >= 0 else { return nil }
            days = d
            rest = text[text.index(after: dash)...]
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let values = parts.map { $0! }
        return days * 86_400 + values.reduce(0) { $0 * 60 + $1 }
    }

    /// "m:ss.ss" with the minutes unbounded ("3736:15.48"); "h:mm:ss" and bare seconds are accepted
    /// defensively. The fraction rides on the last field.
    static func cputimeSeconds(_ text: Substring) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// The table `ps` printed. A line that does not parse is skipped, never the whole table.
    static func parse(_ table: String, now: Date) -> [ProcessCPURow] {
        table.split(whereSeparator: \.isNewline).compactMap { line -> ProcessCPURow? in
            var rest = line.drop(while: { $0 == " " || $0 == "\t" })
            var fields: [Substring] = []
            for _ in 0..<3 {
                guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
                fields.append(rest[..<end])
                rest = rest[end...].drop(while: { $0 == " " || $0 == "\t" })
            }
            let path = rest.trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(fields[0]), pid > 0, let elapsed = etimeSeconds(fields[1]),
                  let cpu = cputimeSeconds(fields[2]), !path.isEmpty else { return nil }
            return ProcessCPURow(pid: pid, startedAt: now.addingTimeInterval(-Double(elapsed)),
                                 cpuSeconds: cpu, path: path)
        }
    }

    /// Whether a table can be folded: a `ps` that was cut short would otherwise read as hundreds of
    /// processes exiting at once.
    static func usable(_ rows: [ProcessCPURow], previous: ProcessCPUWatch) -> Bool {
        !rows.isEmpty && rows.count * 2 >= previous.tracks.count
    }

    // MARK: - the state machine

    private static func fresh(_ row: ProcessCPURow, at now: Date) -> ProcessCPUTrack {
        ProcessCPUTrack(pid: row.pid, startedAt: row.startedAt, path: row.path,
                        lastCPU: row.cpuSeconds, lastAt: now)
    }

    private static func exited(_ track: ProcessCPUTrack, at now: Date) -> ProcessCPUEvent? {
        guard let since = track.alarmedSince else { return nil }
        return ProcessCPUEvent(kind: .exited, pid: track.pid, path: track.path, percent: nil,
                               since: since, until: now, announced: track.announced)
    }

    /// Fold one reading of the whole table in. Events are returned only for crossings: a process
    /// that stays over the line says nothing after its alarm.
    static func advance(_ watch: ProcessCPUWatch, rows: [ProcessCPURow], at now: Date,
                        limits: ProcessCPULimits,
                        announcing: Bool) -> (ProcessCPUWatch, [ProcessCPUEvent]) {
        var next = ProcessCPUWatch()
        var events: [ProcessCPUEvent] = []
        for row in rows where next.tracks[row.pid] == nil {
            guard var track = watch.tracks[row.pid] else {
                next.tracks[row.pid] = fresh(row, at: now)
                continue
            }
            // A reused pid: another start time, another executable, or a counter that went backwards.
            if abs(track.startedAt.timeIntervalSince(row.startedAt)) > startTolerance
                || track.path != row.path || row.cpuSeconds < track.lastCPU {
                if let event = exited(track, at: now) { events.append(event) }
                next.tracks[row.pid] = fresh(row, at: now)
                continue
            }
            let windowStart = track.lastAt
            let gap = now.timeIntervalSince(windowStart)
            let delta = row.cpuSeconds - track.lastCPU
            track.lastCPU = row.cpuSeconds
            track.lastAt = now
            guard gap > 0, gap <= limits.maxGap else {
                // An unread stretch breaks any run but leaves an alarm standing: a sleep adds no
                // CPU time, and that is not the process calming down.
                track.overSince = nil
                track.underSince = nil
                next.tracks[row.pid] = track
                continue
            }
            let percent = delta / gap * 100
            track.lastPercent = percent
            if track.alarmedSince == nil {
                if percent >= limits.percent {
                    let since = track.overSince ?? windowStart
                    track.overSince = since
                    if now.timeIntervalSince(since) >= limits.sustain {
                        track.alarmedSince = since
                        track.announced = announcing
                        track.overSince = nil
                        events.append(ProcessCPUEvent(kind: .alarm, pid: row.pid, path: row.path,
                                                      percent: percent, since: since, until: now,
                                                      announced: announcing))
                    }
                } else {
                    track.overSince = nil
                }
            } else if let alarmedSince = track.alarmedSince {
                if percent < limits.percent {
                    let under = track.underSince ?? windowStart
                    track.underSince = under
                    if now.timeIntervalSince(under) >= limits.clearAfter {
                        events.append(ProcessCPUEvent(kind: .clear, pid: row.pid, path: row.path,
                                                      percent: percent, since: alarmedSince, until: under,
                                                      announced: track.announced))
                        track.alarmedSince = nil
                        track.underSince = nil
                        track.announced = false
                    }
                } else {
                    track.underSince = nil
                }
            }
            next.tracks[row.pid] = track
        }
        for pid in watch.tracks.keys.sorted() where next.tracks[pid] == nil {
            if let track = watch.tracks[pid], let event = exited(track, at: now) { events.append(event) }
        }
        return (next, events)
    }

    // MARK: - who it is

    static func owner(path: String) -> ProcessCPUOwner {
        if path.range(of: "/Tally[^/]*\\.app/", options: .regularExpression) != nil { return .tally }
        return hostHealthIsSystemPath(path) ? .system : .none
    }

    // MARK: - words

    private static func minutes(_ seconds: TimeInterval) -> String {
        String(max(0, Int((seconds / 60).rounded())))
    }

    private static func figure(_ percent: Double?) -> String {
        percent.map { String(Int($0.rounded())) } ?? "?"
    }

    private static func name(_ path: String, displayName: (String) -> String?) -> String {
        let raw = displayName(path) ?? (path as NSString).lastPathComponent
        let clean = keystrokeStripped(raw)
        return clean.isEmpty ? "unknown" : clean
    }

    /// The process's name with its owner tag: `tally (Tally)`, `fseventsd (system)`, `com.docker (Docker)`.
    static func label(_ event: ProcessCPUEvent, localized: (String) -> String,
                      displayName: (String) -> String?) -> String {
        let base = name(event.path, displayName: displayName)
        switch owner(path: event.path) {
        case .tally: return base + " (Tally)"
        case .system:
            let who = event.app.map(keystrokeStripped).flatMap { $0.isEmpty ? nil : $0 } ?? localized("system")
            return base + String(format: localized(" (%@)"), who)
        case .none: return base
        }
    }

    /// Hottest first, ties by pid, so the title names the one worth looking at.
    private static func ranked(_ events: [ProcessCPUEvent]) -> [ProcessCPUEvent] {
        events.sorted { ($0.percent ?? 0) == ($1.percent ?? 0) ? $0.pid < $1.pid : ($0.percent ?? 0) > ($1.percent ?? 0) }
    }

    private static func title(_ events: [ProcessCPUEvent], one: String, many: String,
                              localized: (String) -> String, displayName: (String) -> String?) -> String {
        let events = ranked(events)
        guard let first = events.first else { return "" }
        let who = label(first, localized: localized, displayName: displayName)
        if events.count == 1 { return String(format: localized(one), who) }
        return String(format: localized(many), who, String(events.count - 1))
    }

    private static func lines(_ events: [ProcessCPUEvent], localized: (String) -> String,
                              displayName: (String) -> String?,
                              line: (ProcessCPUEvent, String) -> String) -> String {
        ranked(events).prefix(maxNamed).map {
            line($0, label($0, localized: localized, displayName: displayName))
        }.joined(separator: "\n")
    }

    static func alarmTitle(_ events: [ProcessCPUEvent], localized: (String) -> String,
                           displayName: (String) -> String?) -> String {
        title(events, one: "Process running hot: %@", many: "Processes running hot: %1$@ and %2$@ more",
              localized: localized, displayName: displayName)
    }

    static func alarmBody(_ events: [ProcessCPUEvent], now: Date, localized: (String) -> String,
                          displayName: (String) -> String?) -> String {
        lines(events, localized: localized, displayName: displayName) { event, who in
            String(format: localized("%1$@ at %2$@%% of one core for %3$@ min"),
                   who, figure(event.percent), minutes(now.timeIntervalSince(event.since)))
        }
    }

    static func clearTitle(_ events: [ProcessCPUEvent], localized: (String) -> String,
                           displayName: (String) -> String?) -> String {
        title(events, one: "Process calmed down: %@", many: "Processes calmed down: %1$@ and %2$@ more",
              localized: localized, displayName: displayName)
    }

    static func clearBody(_ events: [ProcessCPUEvent], localized: (String) -> String,
                          displayName: (String) -> String?) -> String {
        lines(events, localized: localized, displayName: displayName) { event, who in
            let held = minutes(event.until.timeIntervalSince(event.since))
            return event.kind == .exited
                ? String(format: localized("%1$@ exited after %2$@ min over the line"), who, held)
                : String(format: localized("%1$@ is down to %2$@%% after %3$@ min over the line"),
                         who, figure(event.percent), held)
        }
    }

    // MARK: - the log

    private static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// One line per event, the name last because it can hold spaces.
    static func logLine(_ event: ProcessCPUEvent, now: Date, displayName: (String) -> String?) -> String {
        var line = "\(stamp(now)) process-cpu=\(event.kind.rawValue) pid=\(event.pid)"
        if let percent = event.percent { line += " pct=\(figure(percent))" }
        if event.kind == .alarm {
            line += " since=\(stamp(event.since))"
        } else {
            line += " held_min=\(minutes(event.until.timeIntervalSince(event.since)))"
        }
        let owner = owner(path: event.path)
        let ownerText = owner == .tally ? "tally" : owner == .system ? "system" : "none"
        line += " announced=\(event.announced ? "yes" : "no") owner=\(ownerText)"
        let app = event.app.map(keystrokeStripped).flatMap { $0.isEmpty ? nil : $0 }
        if let app { line += " app=\(app.replacingOccurrences(of: " ", with: "_"))" }
        return line + " name=\(name(event.path, displayName: displayName))\n"
    }

    static func unreadLine(reason: String, now: Date) -> String {
        "\(stamp(now)) process-cpu=unread reason=\(reason)\n"
    }
}
