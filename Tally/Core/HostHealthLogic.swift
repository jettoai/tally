import Foundation

// WHETHER THE MACHINE ITSELF IS STILL STANDING UP, which is the one question every other watchdog
// on this machine is unable to ask.
//
// WHY IT LIVES HERE AT ALL. On 2026-09-05 a harness starved this laptop: 127 of 128 GB held, an
// exec storm at load 273, no idle CPU left. Every watchdog that was supposed to notice lived INSIDE
// the processes being starved, so each of them was as slow as the thing it was watching and none of
// them said anything. Tally is already resident, already sampling, and is not part of the workload
// it would be reporting on, so it is the one process on this machine that can still say "the
// machine is short" while the machine is short.
//
// EVERYTHING IN THIS FILE IS PURE, the split this repository makes everywhere it takes a reading
// (`ProcessTreeReaders.swift` beside `ProcessTreeStats.swift`): the syscalls are in
// HostHealthReaders.swift, the notification and the files are in HostHealthMonitor.swift, and what
// is here can be stated in an assertion harness with no machine under it. Foundation only, so the
// CLI target compiles it too: the app WRITES the report and `tally status` and the supervisor READ
// it, which is two processes speaking through one file and therefore one record compiled twice
// (project.yml states the rule this repository applies to every such pair).
//
// IT DECIDES NOTHING ABOUT WHAT TO DO. This first version samples, states, logs and tells; nothing
// here kills a process or stops a supervisor, and nothing here is meant to be read as a step
// towards doing so without somebody deciding that separately.

/// What one sample read off the machine.
struct HostHealthReading: Equatable, Sendable {
    /// The one-minute load average (`getloadavg`).
    var load1: Double
    /// How many cores that load is spread over, which is what makes it comparable between machines.
    var cores: Int
    /// What could be handed out right now without paging: free plus inactive plus purgeable.
    /// Deliberately NOT counting the compressor, which is memory already spent.
    var freeBytes: UInt64
}

/// One process named in an alarm.
///
/// A NAME AND A NUMBER, NEVER AN ARGUMENT LIST. The rule is the card's own
/// (`ProcessFootprint.memoryLeader`): the name is the EXECUTABLE's, because argv is a string that
/// can carry a token and this record is written to a file and read into a conversation.
struct HostHealthProcess: Codable, Equatable, Sendable {
    var name: String
    /// What it holds in physical memory, in bytes (`ri_phys_footprint`).
    var rss: UInt64
}

/// What the machine looked like at the instant an alarm was raised, kept so that the report can
/// still say what happened after the load has come back down.
struct HostHealthAlarm: Codable, Equatable, Sendable {
    var at: Date
    var load1: Double
    var freeBytes: UInt64
    /// The three biggest memory holders, most first, read once at this instant and never again
    /// (`HostHealthReaders.heaviest` states what that costs and why it is affordable only here).
    var top: [HostHealthProcess]
}

/// Which side of the line the machine is on.
enum HostHealthPhase: String, Codable, Equatable, Sendable {
    case normal
    case alarmed
}

/// The document the app publishes at `~/.tally/host-health.json`, rewritten on every sample.
///
/// ADDITIVE FOR EVER, the compatibility rule every file this repository writes for another of its
/// own processes is under: an older `tally` and a newer app coexist on a machine for as long as a
/// session runs, so a field may be appended and may never change meaning.
struct HostHealthReport: Codable, Equatable, Sendable {
    var sampledAt: Date
    var load1: Double
    var cores: Int
    var freeBytes: UInt64
    var state: HostHealthPhase
    /// Since when the machine has been in that state.
    var since: Date
    /// The last alarm this app raised, kept across the recovery so a person arriving afterwards can
    /// still read what it was. Absent until one has been raised.
    var lastAlarm: HostHealthAlarm?
}

/// What one folded sample asks the caller to do about it.
enum HostHealthEvent: String, Equatable, Sendable {
    /// The machine has just crossed into trouble: notify, and write a line.
    case alarm
    /// And back out of it: write a line, tell nobody.
    case clear
}

/// The watch's memory between samples. Held in the app's own memory and never persisted: a restart
/// starts the count again, which is the honest reading of "this process has not been watching".
struct HostHealthTracker: Equatable, Sendable {
    var state: HostHealthPhase = .normal
    /// When the current state began, and nil before the first sample.
    var since: Date?
    /// How many samples in a row have been over the line, and under it. Both are kept because the
    /// two directions are counted separately: what raises an alarm is a run of readings over, and
    /// what clears it is a run under, and neither may be answered by the other's count.
    var over = 0
    var under = 0
    var lastAlarm: HostHealthAlarm?
}

/// The rules over those readings, and the numbers they are decided against.
enum HostHealthLogic {

    /// How much load per core counts as too much. Three times the core count is the line the
    /// incident was read against: this machine has 16 cores, so 48, and it was sitting at 273.
    /// A busy build sits near 1 per core and a saturated one near 2, so 3 is well clear of work
    /// somebody asked for.
    static let loadPerCore = 3.0

    /// And how little free memory counts as too little: 2 GB. Below this the machine is compressing
    /// and swapping to hand out anything at all, which is where the incident's forty-minute API
    /// round trips came from.
    static let minimumFreeBytes: UInt64 = 2 * 1024 * 1024 * 1024

    /// How many samples in a row it takes to move in either direction.
    ///
    /// A RUN RATHER THAN A READING, in both directions and for two different reasons. Upwards it is
    /// what keeps a single spike quiet: a `pnpm install`, a full test run or an Xcode build all put
    /// this machine over the line for less than a minute, and none of them is the thing this exists
    /// to report. Downwards it is hysteresis: a machine hovering at the line would otherwise
    /// announce, recover and announce again every minute, which is the one failure that would get
    /// this feature turned off.
    static let consecutiveSamples = 3

    /// How long between samples. ONE MINUTE, which the incident's own shape is what sets: a machine
    /// takes minutes to starve and the run above means three of these before anything is said, so
    /// the news is four minutes old at worst and a sample costs two syscalls.
    static let sampleInterval: TimeInterval = 60

    /// The load at which this machine is over the line, which is what a report can be read against
    /// without knowing the rule (`hostHealthStatusLine` prints it as the denominator).
    static func loadLimit(cores: Int) -> Double { loadPerCore * Double(cores) }

    /// Whether one reading is over the line: either witness on its own is enough, because the two
    /// failures the incident produced were exactly these two and either alone makes the machine
    /// unusable.
    ///
    /// A CORE COUNT OF ZERO SILENCES THE LOAD WITNESS RATHER THAN TRIPPING IT, the fail-open
    /// direction `MachineMemoryPressure.reading(of:)` takes for a machine that will not say: an
    /// unreadable core count must not put every machine into alarm. The memory witness is
    /// unaffected and still answers.
    static func exceeds(_ reading: HostHealthReading) -> Bool {
        if reading.cores > 0, reading.load1 >= loadLimit(cores: reading.cores) { return true }
        return reading.freeBytes < minimumFreeBytes
    }

    /// Fold one sample into the watch, returning the next state and what it asks the caller to do.
    ///
    /// THE TRANSITION IS THE EVENT, which is the whole of the notification discipline: an event is
    /// produced by a CROSSING and never by a reading, so a machine that stays over the line for an
    /// hour is announced once. Nothing here re-announces, and nothing here expires.
    ///
    /// The counters are reset at a crossing so the run that clears an alarm is counted from the
    /// alarm, not from whatever happened before it.
    static func advance(_ tracker: HostHealthTracker, reading: HostHealthReading,
                        at now: Date) -> (HostHealthTracker, HostHealthEvent?) {
        var next = tracker
        if next.since == nil { next.since = now }
        let over = exceeds(reading)
        next.over = over ? next.over + 1 : 0
        next.under = over ? 0 : next.under + 1
        switch tracker.state {
        case .normal where next.over >= consecutiveSamples:
            next.state = .alarmed
            next.since = now
            next.over = 0
            next.under = 0
            return (next, .alarm)
        case .alarmed where next.under >= consecutiveSamples:
            next.state = .normal
            next.since = now
            next.over = 0
            next.under = 0
            return (next, .clear)
        default:
            return (next, nil)
        }
    }

    /// The document one sample publishes, out of the watch it has just been folded into.
    static func report(_ tracker: HostHealthTracker, reading: HostHealthReading,
                       at now: Date) -> HostHealthReport {
        HostHealthReport(sampledAt: now, load1: reading.load1, cores: reading.cores,
                         freeBytes: reading.freeBytes, state: tracker.state,
                         since: tracker.since ?? now, lastAlarm: tracker.lastAlarm)
    }
}

// MARK: - What the readings are spelled as

/// One figure, at the precision a person reads it at: a decimal below ten and none above it.
///
/// SPELLED HERE RATHER THAN WITH A FORMATTER, because every reader of these strings is a machine or
/// a log: a locale that writes a comma for the decimal point would put a field separator inside a
/// field. `String(format:)` on a plain double is locale-independent by construction.
func hostHealthFigure(_ value: Double) -> String {
    value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
}

/// Bytes as whole gigabytes, on the same terms.
func hostHealthGigabytes(_ bytes: UInt64) -> String {
    hostHealthFigure(Double(bytes) / 1_073_741_824)
}

/// The three heaviest processes as one phrase, with the unit each caller wants after each figure.
/// Empty when the scan found nothing, which reads the same way everywhere: the phrase is left out.
func hostHealthTopText(_ top: [HostHealthProcess], unit: String) -> String {
    top.map { "\($0.name) \(hostHealthGigabytes($0.rss))\(unit)" }.joined(separator: ", ")
}

/// One line for `~/.tally/logs/host-health.log`.
///
/// THE SAME SHAPE AS `~/.tally/logs/input.log`: an ISO instant, then fixed-offset `key=value`
/// fields for an eye and a `grep`, and the one field that can contain a space last. The names in it
/// are executable names, never arguments (`HostHealthProcess`).
func hostHealthLogLine(_ event: HostHealthEvent, report: HostHealthReport,
                       now: Date = Date()) -> String {
    let top = report.state == .alarmed ? (report.lastAlarm?.top ?? []) : []
    let names = top.map { "\($0.name):\(hostHealthGigabytes($0.rss))G" }.joined(separator: ",")
    return "\(ISO8601DateFormatter().string(from: now)) host-health=\(event.rawValue) "
        + "load=\(hostHealthFigure(report.load1)) cores=\(report.cores) "
        + "free=\(hostHealthGigabytes(report.freeBytes))G"
        + (names.isEmpty ? "\n" : " top=\(names)\n")
}

/// The one sentence a supervised session is told, when the machine goes into alarm underneath it.
///
/// ONE LINE, AND A REFERENCE RATHER THAN A PAYLOAD. It says what is wrong and what is holding the
/// memory, and nothing else: whoever reads it has `~/.tally/logs/host-health.log` and
/// `~/.tally/host-health.json` for the rest, and a session in the middle of a work package should
/// not have a report pasted into it.
func hostHealthKnockSentence(_ alarm: HostHealthAlarm) -> String {
    let names = alarm.top.map(\.name).joined(separator: ",")
    return "[host-health] load=\(hostHealthFigure(alarm.load1)) "
        + "free=\(hostHealthGigabytes(alarm.freeBytes))GB"
        + (names.isEmpty ? "" : " top=\(names)")
}

/// The `Host` line `tally status` prints, or nil when there is nothing honest to print.
///
/// FAIL-OPEN, the rule `loadAdvisorReadings` is under: a machine whose Tally is not running has no
/// report, and a report this build cannot read is the same answer. Both leave the section out
/// rather than printing a state nobody measured.
///
/// A REPORT NOBODY HAS REWRITTEN IN A WHILE STILL PRINTS, with its age beside it. The age is the
/// honest field: a stopped app is exactly the case where a stale "ok" would be a lie, and saying
/// how old the reading is says so without this file having to guess a staleness rule.
func hostHealthStatusLine(_ report: HostHealthReport?, now: Date = Date()) -> String? {
    guard let report else { return nil }
    let limit = hostHealthFigure(HostHealthLogic.loadLimit(cores: report.cores))
    let load = "load \(hostHealthFigure(report.load1))/\(limit)"
    let free = "free \(hostHealthGigabytes(report.freeBytes)) GB"
    let age = Int(max(0, now.timeIntervalSince(report.sampledAt)).rounded())
    switch report.state {
    case .normal:
        return "host: \(load) · \(free) · ok (sampled \(hostHealthAge(age)) ago)"
    case .alarmed:
        var text = "host: ALARM since \(hostHealthClock(report.since)) · \(load) · \(free)"
        let top = hostHealthTopText(report.lastAlarm?.top ?? [], unit: "G")
        if !top.isEmpty { text += " · top: \(top)" }
        return text + " (sampled \(hostHealthAge(age)) ago)"
    }
}

/// How long ago, in the shortest unit that is still true.
func hostHealthAge(_ seconds: Int) -> String {
    if seconds < 90 { return "\(seconds)s" }
    if seconds < 5_400 { return "\(Int((Double(seconds) / 60).rounded()))m" }
    return "\(Int((Double(seconds) / 3_600).rounded()))h"
}

/// Wall-clock hours and minutes, for the instant an alarm began.
///
/// BUILT BY HAND rather than with a `DateFormatter`, for the reason the figures above are: this
/// line is read out of a terminal and out of scripts, and a formatter would spell it differently
/// per locale for no reader who wanted that.
func hostHealthClock(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}

/// Where the app publishes the report, and where both readers look for it.
let hostHealthReportFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/host-health.json")

/// And the log beside it.
let hostHealthLogFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/logs/host-health.log")

/// The one decoder both targets use, so a document this build cannot read means the same thing to
/// each of them.
func decodeHostHealthReport(_ data: Data?) -> HostHealthReport? {
    guard let data else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(HostHealthReport.self, from: data)
}

/// And the one encoder, for the same reason.
func encodeHostHealthReport(_ report: HostHealthReport) -> Data? {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try? encoder.encode(report)
}
