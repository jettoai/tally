import Foundation

// Assertion harness for the host-health watch: the pure state machine and its report
// (Tally/Core/HostHealthLogic.swift) and the supervisor station's pure half
// (TallyCLI/HostHealthKnockLogic.swift).
//
// WHAT A PURE HARNESS CANNOT REACH IS ASSERTED AS SOURCE, at the end: the throttle, the tick this
// rides, the branch the expensive scan is confined to and the station's place in the poll loop are
// all structural promises this feature was accepted under ("do not become the load you report on"),
// and none of them can be driven without a machine, a timer and a live session under it.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS: \(name)") } else { failures += 1; print("FAIL: \(name)") }
}

let gigabyte: UInt64 = 1_073_741_824
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ minutes: Int) -> Date { t0.addingTimeInterval(Double(minutes) * 60) }

/// A comfortable machine: well under the load line and with plenty free.
func calm(cores: Int = 16) -> HostHealthReading {
    HostHealthReading(load1: 3.2, cores: cores, freeBytes: 41 * gigabyte)
}

/// One the incident would recognise.
func starved(cores: Int = 16) -> HostHealthReading {
    HostHealthReading(load1: 273, cores: cores, freeBytes: gigabyte * 9 / 10)
}

/// Fold a run of readings in, collecting what each one asked for.
func run(_ tracker: HostHealthTracker, _ readings: [HostHealthReading],
         from minute: Int = 0) -> (HostHealthTracker, [HostHealthEvent?]) {
    var state = tracker
    var events: [HostHealthEvent?] = []
    for (index, reading) in readings.enumerated() {
        let (next, event) = HostHealthLogic.advance(state, reading: reading, at: at(minute + index))
        state = next
        events.append(event)
    }
    return (state, events)
}

// MARK: - 1. The run, in both directions

// A spike is not an alarm: one sample over the line and back down says nothing at all. This is the
// whole reason the rule is a run rather than a reading (a test run, an install, a build).
do {
    let (state, events) = run(HostHealthTracker(), [calm(), starved(), calm(), calm()])
    expect(events.allSatisfy { $0 == nil }, "a single spike raises nothing")
    expect(state.state == .normal, "…and leaves the machine reading normal")
    expect(state.over == 0, "…with the run counted back to zero by the reading after it")
}

// Two in a row is still not an alarm, and the third is.
do {
    let (state, events) = run(HostHealthTracker(), [starved(), starved()])
    expect(events == [nil, nil], "two in a row raise nothing")
    expect(state.state == .normal, "…and the machine still reads normal")
    let (after, third) = run(state, [starved()], from: 2)
    expect(third == [.alarm], "the third consecutive reading raises the alarm")
    expect(after.state == .alarmed, "…and the machine reads alarmed from then on")
    expect(after.since == at(2), "…since the instant it crossed")
    expect(after.over == 0 && after.under == 0,
           "…and both runs are counted from the crossing rather than from before it")
}

// And nothing re-announces while it stands, however long it stands: the event is the CROSSING.
do {
    let (alarmed, _) = run(HostHealthTracker(), [starved(), starved(), starved()])
    let (state, events) = run(alarmed, Array(repeating: starved(), count: 10), from: 3)
    expect(events.allSatisfy { $0 == nil }, "an alarm that stands is not announced again")
    expect(state.state == .alarmed, "…and the machine is still in alarm")
}

// Coming back takes a run of its own, which is the hysteresis: two quiet samples and one loud one
// leave the alarm standing, and only three quiet ones in a row clear it.
do {
    let (alarmed, _) = run(HostHealthTracker(), [starved(), starved(), starved()])
    let (wobbling, events) = run(alarmed, [calm(), calm(), starved()], from: 3)
    expect(events.allSatisfy { $0 == nil }, "a machine hovering at the line clears nothing")
    expect(wobbling.state == .alarmed, "…and stays in alarm")
    let (recovered, back) = run(wobbling, [calm(), calm(), calm()], from: 6)
    expect(back == [nil, nil, .clear], "three quiet samples in a row clear it")
    expect(recovered.state == .normal, "…and the machine reads normal again")
    expect(recovered.since == at(8), "…since the instant it came back")
}

// A recovery is a `clear` and never an `alarm`: what the caller does with the two differs (one is
// written down, the other is written down AND announced).
do {
    let (alarmed, _) = run(HostHealthTracker(), [starved(), starved(), starved()])
    let (_, back) = run(alarmed, [calm(), calm(), calm()], from: 3)
    expect(back.last == .clear, "the recovery event is a clear")
    expect(!back.contains(.alarm), "…and nothing in a recovery is an alarm")
}

// MARK: - 2. The two witnesses, each on its own

// Load alone, with memory in no trouble at all.
do {
    let loaded = HostHealthReading(load1: 60, cores: 16, freeBytes: 64 * gigabyte)
    expect(HostHealthLogic.exceeds(loaded), "load alone is over the line")
    let (_, events) = run(HostHealthTracker(), [loaded, loaded, loaded])
    expect(events == [nil, nil, .alarm], "…and alarms on its own")
}

// Memory alone, on an idle machine.
do {
    let short = HostHealthReading(load1: 0.1, cores: 16, freeBytes: gigabyte / 2)
    expect(HostHealthLogic.exceeds(short), "free memory alone is over the line")
    let (_, events) = run(HostHealthTracker(), [short, short, short])
    expect(events == [nil, nil, .alarm], "…and alarms on its own")
}

// The two lines themselves, at the boundary.
do {
    let cores = 16
    let limit = HostHealthLogic.loadLimit(cores: cores)
    expect(limit == 48, "the load line on a sixteen-core machine is 48")
    expect(HostHealthLogic.exceeds(HostHealthReading(load1: 48, cores: cores,
                                                     freeBytes: 64 * gigabyte)),
           "a load exactly at the line is over it")
    expect(!HostHealthLogic.exceeds(HostHealthReading(load1: 47.9, cores: cores,
                                                      freeBytes: 64 * gigabyte)),
           "…and one just under it is not")
    expect(!HostHealthLogic.exceeds(HostHealthReading(load1: 1, cores: cores,
                                                      freeBytes: 2 * gigabyte)),
           "exactly two gigabytes free is not short")
    expect(HostHealthLogic.exceeds(HostHealthReading(load1: 1, cores: cores,
                                                     freeBytes: 2 * gigabyte - 1)),
           "…and one byte less is")
}

// A machine that will not say how many cores it has silences the LOAD witness rather than tripping
// it, the fail-open direction every other reading in this app takes. The memory witness answers on.
do {
    expect(!HostHealthLogic.exceeds(HostHealthReading(load1: 900, cores: 0,
                                                      freeBytes: 64 * gigabyte)),
           "an unreadable core count silences the load witness")
    expect(HostHealthLogic.exceeds(HostHealthReading(load1: 900, cores: 0, freeBytes: gigabyte)),
           "…and leaves the memory witness answering")
}

// MARK: - 3. The document

let sampleTop = [HostHealthProcess(name: "node", rss: 14 * gigabyte + gigabyte * 6 / 10),
                 HostHealthProcess(name: "qemu", rss: 6 * gigabyte + gigabyte / 5),
                 HostHealthProcess(name: "Google Chrome", rss: 4 * gigabyte + gigabyte / 10)]

do {
    var (alarmed, _) = run(HostHealthTracker(), [starved(), starved(), starved()])
    alarmed.lastAlarm = HostHealthAlarm(at: at(2), load1: 273, freeBytes: gigabyte * 9 / 10,
                                        top: sampleTop)
    let report = HostHealthLogic.report(alarmed, reading: starved(), at: at(2))
    expect(report.state == .alarmed && report.since == at(2), "the report carries state and since")
    expect(report.lastAlarm?.top.count == 3, "…and the three processes the alarm named")
    guard let data = encodeHostHealthReport(report) else {
        expect(false, "the report encodes")
        exit(1)
    }
    expect(decodeHostHealthReport(data) == report, "…and survives a round trip unchanged")
    let text = String(decoding: data, as: UTF8.self)
    for field in ["sampledAt", "load1", "cores", "freeBytes", "state", "since", "lastAlarm",
                  "rss", "name", "top"] {
        expect(text.contains("\"\(field)\""), "the document names \(field)")
    }
    expect(text.contains("\"alarmed\""), "…and spells the state as a word readers can match on")
    expect(!text.contains("/Applications"), "no path is written into the document")
}

// Fail-open on every reading failure: nothing there, and something there that is not this format,
// both answer nothing rather than a state nobody measured.
do {
    expect(decodeHostHealthReport(nil) == nil, "a missing document decodes to nothing")
    expect(decodeHostHealthReport(Data("not json at all".utf8)) == nil,
           "…and so does one that is not this format")
    expect(decodeHostHealthReport(Data("{\"load1\": 3}".utf8)) == nil,
           "…and so does a half-written one")
}

// MARK: - 4. What `tally status` prints

do {
    expect(hostHealthStatusLine(nil) == nil, "no report prints no section")
    expect(hostHealthStatusLine(decodeHostHealthReport(Data("{".utf8))) == nil,
           "…and an unreadable one prints no section either")
}

do {
    let report = HostHealthReport(sampledAt: at(0), load1: 3.2, cores: 16,
                                  freeBytes: 41 * gigabyte, state: .normal, since: at(-30),
                                  lastAlarm: nil)
    let line = hostHealthStatusLine(report, now: at(0).addingTimeInterval(12))
    expect(line == "host: load 3.2/48 · free 41 GB · ok (sampled 12s ago)",
           "a calm machine prints load, free and the age of the reading")
}

do {
    let alarm = HostHealthAlarm(at: at(0), load1: 273, freeBytes: gigabyte * 9 / 10, top: sampleTop)
    let report = HostHealthReport(sampledAt: at(3), load1: 273, cores: 16,
                                  freeBytes: gigabyte * 9 / 10, state: .alarmed, since: at(0),
                                  lastAlarm: alarm)
    let line = hostHealthStatusLine(report, now: at(3).addingTimeInterval(5)) ?? ""
    expect(line.hasPrefix("host: ALARM since "), "an alarmed machine leads with the alarm")
    expect(line.contains("· load 273/48 · free 0.9 GB"),
           "…and prints the reading against the line")
    expect(line.contains("· top: node 15G, qemu 6.2G, Google Chrome 4.1G"),
           "…and names what is holding the memory")
    expect(line.hasSuffix("(sampled 5s ago)"), "…and says how old the reading is")
}

// The wall clock the alarm's start is printed at, against an independent oracle rather than against
// itself: a formatter set to the same fixed pattern in the same zone.
do {
    let oracle = DateFormatter()
    oracle.locale = Locale(identifier: "en_US_POSIX")
    oracle.dateFormat = "HH:mm"
    for offset in [0, 3_600, 86_399, 45_000] {
        let moment = t0.addingTimeInterval(Double(offset))
        expect(hostHealthClock(moment) == oracle.string(from: moment),
               "the alarm clock reads \(oracle.string(from: moment)) at +\(offset)s")
    }
}

// How old a reading is, in the shortest unit that is still true.
do {
    expect(hostHealthAge(0) == "0s" && hostHealthAge(89) == "89s", "seconds up to ninety")
    expect(hostHealthAge(90) == "2m" && hostHealthAge(3_600) == "60m", "minutes past that")
    expect(hostHealthAge(5_400) == "2h" && hostHealthAge(86_400) == "24h",
           "hours past ninety of them")
}

// The figures themselves: a decimal below ten and none above it, on both axes.
do {
    expect(hostHealthFigure(0.9) == "0.9" && hostHealthFigure(273) == "273", "load figures")
    expect(hostHealthGigabytes(gigabyte * 9 / 10) == "0.9", "a fraction of a gigabyte")
    expect(hostHealthGigabytes(41 * gigabyte) == "41", "and whole ones")
    expect(hostHealthTopText([], unit: "GB").isEmpty, "an empty scan produces no phrase")
}

// MARK: - 5. The sentence a session is told

do {
    let alarm = HostHealthAlarm(at: at(0), load1: 273, freeBytes: gigabyte * 9 / 10, top: sampleTop)
    expect(hostHealthKnockSentence(alarm)
            == "[host-health] load=273 free=0.9GB top=node,qemu,Google Chrome",
           "the sentence is one line naming the reading and what is holding the memory")
    expect(!hostHealthKnockSentence(alarm).contains("\n"), "…and is exactly one line")
    let unnamed = HostHealthAlarm(at: at(0), load1: 273, freeBytes: gigabyte, top: [])
    expect(hostHealthKnockSentence(unnamed) == "[host-health] load=273 free=1.0GB",
           "…and leaves the phrase out entirely when the scan named nothing")
}

// MARK: - 6. One sentence per alarm

/// A report as the app would have published it at that instant.
func alarmedReport(at moment: Date) -> HostHealthReport {
    HostHealthReport(sampledAt: moment, load1: 273, cores: 16, freeBytes: gigabyte * 9 / 10,
                     state: .alarmed, since: moment,
                     lastAlarm: HostHealthAlarm(at: moment, load1: 273,
                                                freeBytes: gigabyte * 9 / 10, top: sampleTop))
}

do {
    var state = HostHealthKnockState()
    var reads = 0
    let report = alarmedReport(at: at(0))
    func look(_ stamp: Date?) -> HostHealthAlarm? {
        HostHealthKnockLogic.observe(&state, stamp: stamp, read: { reads += 1; return report })
    }
    expect(look(at(0))?.at == at(0), "an alarmed report owes this session a sentence")
    expect(reads == 1, "…decoded once")
    // The station records the announcement only once the bytes are on their way, which is why the
    // reading before that still owes: a tick whose gate held has said nothing.
    expect(look(at(0))?.at == at(0), "…still owed while nothing has been said")
    expect(reads == 1, "…and the unchanged document is not decoded again")
    state.announced = at(0)
    expect(look(at(0)) == nil, "once said, the same alarm is never said again")
    // The app rewrites this document every minute for as long as the alarm stands. A station keyed
    // on the document rather than on the alarm would say the same thing sixty times an hour.
    for minute in 1...60 {
        _ = look(at(minute))
    }
    expect(look(at(61)) == nil, "…not even after the report has been rewritten sixty times")
    expect(reads == 62, "…though every rewrite was read")
}

// A SECOND alarm is different news, and is said.
do {
    var state = HostHealthKnockState(seenAt: at(0), report: alarmedReport(at: at(0)),
                                     announced: at(0))
    let second = alarmedReport(at: at(30))
    let owed = HostHealthKnockLogic.observe(&state, stamp: at(30), read: { second })
    expect(owed?.at == at(30), "a machine that recovered and crossed again is announced again")
}

// A calm report owes nothing, and neither does an alarmed one this build cannot read an alarm out
// of: an alarm with no instant on it could never be said exactly once.
do {
    var state = HostHealthKnockState()
    let calmReport = HostHealthReport(sampledAt: at(0), load1: 3.2, cores: 16,
                                      freeBytes: 41 * gigabyte, state: .normal, since: at(0),
                                      lastAlarm: nil)
    expect(HostHealthKnockLogic.observe(&state, stamp: at(0), read: { calmReport }) == nil,
           "a calm report owes nothing")
    var second = HostHealthKnockState()
    let headless = HostHealthReport(sampledAt: at(0), load1: 273, cores: 16, freeBytes: gigabyte,
                                    state: .alarmed, since: at(0), lastAlarm: nil)
    expect(HostHealthKnockLogic.observe(&second, stamp: at(0), read: { headless }) == nil,
           "…and neither does an alarm with no instant on it")
    expect(HostHealthKnockLogic.observe(&second, stamp: at(0), read: { headless }) == nil,
           "…however many ticks look at it")
}

// A report that has GONE is not a machine that recovered: the cache goes with it, so a Tally that
// was closed mid-alarm and reopened tells this session again.
do {
    var state = HostHealthKnockState()
    let report = alarmedReport(at: at(0))
    _ = HostHealthKnockLogic.observe(&state, stamp: at(0), read: { report })
    state.announced = at(0)
    expect(HostHealthKnockLogic.observe(&state, stamp: nil, read: { report }) == nil,
           "no report on disk owes nothing")
    expect(state.report == nil && state.seenAt == nil, "…and the cache is dropped with it")
    state.announced = nil
    expect(HostHealthKnockLogic.observe(&state, stamp: at(5), read: { report })?.at == at(0),
           "…and a report that comes back is read afresh")
}

// MARK: - 7. The promises a pure harness cannot drive

func source(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

let timing = source("Tally/Stores/ProcessFootprintTiming.swift")
let monitor = source("Tally/Core/HostHealthMonitor.swift")
let readers = source("Tally/Core/HostHealthReaders.swift")
let station = source("TallyCLI/HostHealthKnock.swift")
let loop = source("TallyCLI/Supervisor.swift")
let statusCommand = source("TallyCLI/main.swift")
let project = source("project.yml")

expect(!timing.isEmpty && !monitor.isEmpty && !station.isEmpty && !loop.isEmpty,
       "the sources this suite reads are readable from it")

// IT OPENS NO TIMER OF ITS OWN. The one timer in this feature is the footprint sampler's, which
// already runs for the life of the process, and the watch rides it.
expect(timing.contains("HostHealthMonitor.shared.tick()"),
       "the watch rides the footprint sampler's existing tick")
expect(!monitor.contains("Timer(") && !monitor.contains("DispatchSourceTimer")
        && !monitor.contains("asyncAfter"),
       "…and starts no timer, queue or delay of its own")

// AND SPAWNS NOTHING. The whole point of this landing in this app is that a machine which cannot
// fork is exactly the machine this is reporting on.
for file in [monitor, readers] {
    expect(!file.contains("Process()") && !file.contains("posix_spawn")
            && !file.contains("system("),
           "the watch runs no subprocess")
}
for command in ["/usr/bin/top", "/usr/bin/vm_stat", "/bin/ps", "/bin/sh", "/usr/bin/env"] {
    expect(!monitor.contains(command) && !readers.contains(command),
           "…and names no shell command (\(command))")
}

// THE THROTTLE IS BY THE CLOCK, so both of the sampler's rates deliver the same one sample a
// minute.
expect(monitor.contains("now.timeIntervalSince(last) < HostHealthLogic.sampleInterval"),
       "the watch throttles itself against the clock")
expect(source("Tally/Core/HostHealthLogic.swift")
        .contains("static let sampleInterval: TimeInterval = 60"),
       "…at one sample a minute")

// AN ORDINARY SAMPLE IS TWO SYSCALLS. The process table is walked in `heaviest` and nowhere else,
// and `heaviest` is called from exactly one place: the branch that has just raised an alarm.
expect(readers.contains("proc_listallpids") == false,
       "the sample path does not walk the process table itself")
expect(readers.contains("ProcessTree.liveProcesses()"),
       "…the one walk it makes is the shared one")
do {
    let calls = monitor.components(separatedBy: "HostHealthReaders.heaviest()").count - 1
    expect(calls == 1, "the expensive scan has exactly one caller")
    guard let branch = monitor.range(of: "if event == .alarm {"),
          let call = monitor.range(of: "HostHealthReaders.heaviest()") else {
        expect(false, "the expensive scan sits inside the alarm branch")
        exit(1)
    }
    expect(branch.upperBound < call.lowerBound, "…and it sits inside the alarm branch")
}
expect(monitor.contains("if event == .alarm { post(report) }"),
       "a recovery is written down and not announced")

// THE STATION SPEAKS LAST AND THROUGH THE EXISTING DOOR. Placed after the quota knock, told what
// that knock typed, and holding entirely when a filed sentence is still sitting unread.
do {
    guard let knock = loop.range(of: "applyQuotaKnock("),
          let host = loop.range(of: "applyHostHealthKnock(") else {
        expect(false, "the tick runs the host-health station")
        exit(1)
    }
    expect(knock.upperBound < host.lowerBound,
           "the host-health station speaks after the quota knock")
    let call = String(loop[host.lowerBound...].prefix(900))
    expect(call.contains("typedAlready: action.typed != nil || resumed != nil || knocked != nil"),
           "…and stays silent on a tick that has already written to this composer")
    expect(call.contains("filing: { quotaKnockFiling }"),
           "…and is filed or typed on the same reading the quota knock uses")
}
expect(station.contains("guard !undelivered(pid, dir) else { return nil }"),
       "a filed sentence nobody has read yet is not written over")
expect(station.contains("sessionInputHold(state: session, quiet: quiet, turnEnded: turnEnded(),"),
       "the typed channel asks the same gate every other writer asks")
expect(station.contains("state.announced = alarm.at"),
       "the announcement is recorded before the bytes go out")

// AND NOTHING IN THIS FEATURE ENDS ANYTHING. The incident report asked for reporting first.
for file in [monitor, readers, station, source("Tally/Core/HostHealthLogic.swift")] {
    expect(!file.contains("kill(") && !file.contains("SIGTERM") && !file.contains("SIGKILL"),
           "the watch signals nothing")
}

// The status section, and the one file both processes read the record out of.
expect(statusCommand.contains("if let host = hostHealthStatusLine(loadHostHealthReport()) {"),
       "`tally status` prints the host section")
expect(project.contains("- path: Tally/Core/HostHealthLogic.swift"),
       "…out of the record the CLI target compiles with the app")

// The names in the report are executable names, never arguments: this document is read into a
// conversation, and argv is a string that can carry a token.
expect(readers.contains("ProcessTree.executablePath(of: entry.key)"),
       "the alarm names processes by their executable")
expect(!readers.contains("KERN_PROCARGS") && !readers.contains("commandLine("),
       "…and never reads argv")

print(failures == 0 ? "all host-health checks passed" : "\(failures) host-health checks failed")
exit(failures == 0 ? 0 : 1)
