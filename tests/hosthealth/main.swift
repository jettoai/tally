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

// MARK: - 4. Naming the CPU culprit (2026-10-02: a load-227 banner listed memory holders while a
// stuck System Settings scan at 188% was the cause)

do {
    let culprits = [
        HostHealthCPUProcess(name: "ApplicationsStorageExtension", percent: 188.4, project: nil,
                             system: true),
        HostHealthCPUProcess(name: "node", percent: 104, project: "geo", system: false),
        HostHealthCPUProcess(name: "llama-server", percent: 70, project: nil, system: false)]
    expect(hostHealthCPUText(culprits, system: "system", stoppable: " · can stop")
            == "ApplicationsStorageExtension 188% (system) · can stop, node 104% (geo), llama-server 70%",
           "one-core percent, checkout or system owner, the stoppable mark, nothing for the rest")
    expect(hostHealthCPUText(culprits, system: "系統", stoppable: "・可停", tag: { "（\($0)）" })
            .hasPrefix("ApplicationsStorageExtension 188%（系統）・可停, "),
           "…with the language's own parentheses")

    // System only for the OS's own executables; Homebrew and the person's programs are not.
    for path in ["/System/Library/PrivateFrameworks/X.framework/ApplicationsStorageExtension",
                 "/usr/libexec/mds_stores", "/usr/sbin/cfprefsd", "/Library/Apple/usr/bin/x"] {
        expect(hostHealthIsSystemPath(path), "\(path) is the system's")
    }
    for path in ["/usr/local/bin/llama-server", "/opt/homebrew/bin/node",
                 "/Applications/Tally.app/Contents/MacOS/Tally", "/Users/me/bin/tool"] {
        expect(!hostHealthIsSystemPath(path), "\(path) is not the system's")
    }

    // The banner: the CPU list and "free memory" for a load alarm, alone or beside the memory list.
    let en: (String) -> String = { $0 }
    var tracker = HostHealthTracker(state: .alarmed)
    tracker.lastAlarm = HostHealthAlarm(at: at(0), load1: 227, freeBytes: 25 * gigabyte,
                                        top: sampleTop, cpuTop: culprits)
    let loadOnly = HostHealthLogic.report(tracker, reading: HostHealthReading(
        load1: 227, cores: 16, freeBytes: 25 * gigabyte), at: at(0))
    expect(hostHealthAlarmBody(loadOnly, localized: en)
            == "load 227 (16 cores) · free memory 25 GB · top: ApplicationsStorageExtension 188% "
            + "(system) · can stop, node 104% (geo), llama-server 70%",
           "a load alarm names what burns CPU, and says the free figure is memory")
    expect(hostHealthAlarmTitle(loadOnly, localized: en)
            == "Host under pressure: ApplicationsStorageExtension (system)",
           "…and its title carries the first culprit, which a stacked-banner summary still reads")
    tracker.lastAlarm?.freeBytes = gigabyte
    let both = HostHealthLogic.report(tracker, reading: HostHealthReading(
        load1: 227, cores: 16, freeBytes: gigabyte), at: at(0))
    expect(hostHealthAlarmBody(both, localized: en).hasSuffix(
            "\nmemory: node 15GB, qemu 6.2GB, Google Chrome 4.1GB"),
           "both witnesses: the memory holders get a second line")
    tracker.lastAlarm?.cpuTop = nil
    let memoryOnly = HostHealthLogic.report(tracker, reading: HostHealthReading(
        load1: 2, cores: 16, freeBytes: gigabyte), at: at(0))
    expect(hostHealthAlarmBody(memoryOnly, localized: en)
            == "load 2.0 (16 cores) · free memory 1.0 GB · top: node 15GB, qemu 6.2GB, Google Chrome 4.1GB",
           "a memory alarm names the memory holders as before")
    expect(hostHealthAlarmTitle(memoryOnly, localized: en) == "Host under pressure: node",
           "…and titles the biggest one")
    tracker.lastAlarm?.top = []
    expect(hostHealthAlarmTitle(HostHealthLogic.report(tracker, reading: HostHealthReading(
        load1: 2, cores: 16, freeBytes: gigabyte), at: at(0)), localized: en) == "Host under pressure",
           "no name, the plain title")

    // The log keeps `top=` last and adds `cpu=` before it; an older report without the field still
    // decodes (the document is additive for ever).
    tracker.lastAlarm = HostHealthAlarm(at: at(0), load1: 227, freeBytes: 25 * gigabyte,
                                        top: sampleTop, cpuTop: culprits)
    let line = hostHealthLogLine(.alarm, report: HostHealthLogic.report(tracker, reading:
        HostHealthReading(load1: 227, cores: 16, freeBytes: 25 * gigabyte), at: at(0)), now: at(0))
    expect(line.contains(" free=25G cpu=ApplicationsStorageExtension[system]:188%,node[geo]:104%,"
                         + "llama-server:70% top=node:15G,"), "the log line gains cpu= before top=")
    let old = #"{"cores":16,"freeBytes":1,"lastAlarm":{"at":"2026-10-02T13:23:45Z","freeBytes":1,"load1":227,"top":[]},"load1":227,"sampledAt":"2026-10-02T13:23:45Z","since":"2026-10-02T13:23:45Z","state":"alarmed"}"#
    expect(decodeHostHealthReport(Data(old.utf8))?.lastAlarm?.cpuTop == nil,
           "a report written before cpuTop still decodes")

    // The thread census (2026-10-03) sits after free= and before cpu=, so `top=` stays last.
    tracker.lastAlarm?.threads = HostHealthThreads(
        running: 12, uninterruptible: 340, total: 9000, processes: 812,
        top: [HostHealthThreadHolder(name: "Virtualization", threads: 410),
              HostHealthThreadHolder(name: "no\nde", threads: 388)])
    let threaded = HostHealthLogic.report(tracker, reading: HostHealthReading(
        load1: 227, cores: 16, freeBytes: 25 * gigabyte), at: at(0))
    let census = hostHealthLogLine(.alarm, report: threaded, now: at(0))
    expect(census.contains(" free=25G thr=r12,u340,t9000 procs=812 nthr=Virtualization:410,node:388"
                           + " cpu=ApplicationsStorageExtension[system]:188%,"),
           "the log line carries the thread census between free= and cpu=, names repaired")
    expect(census.hasSuffix(" top=node:15G,qemu:6.2G,Google Chrome:4.1G\n")
            && census.components(separatedBy: "\n").count == 2,
           "…and `top=` is still the last field of one line")
    tracker.state = .normal
    expect(!hostHealthLogLine(.clear, report: HostHealthLogic.report(tracker, reading:
        HostHealthReading(load1: 2, cores: 16, freeBytes: 25 * gigabyte), at: at(0)), now: at(0))
            .contains("thr="), "a clear line carries no census")
    expect(decodeHostHealthReport(Data(old.utf8))?.lastAlarm?.threads == nil,
           "a report written before the census still decodes")
    let roundTrip = encodeHostHealthReport(threaded).flatMap(decodeHostHealthReport)
    expect(roundTrip?.lastAlarm?.threads == tracker.lastAlarm?.threads, "the census round-trips")
}

// MARK: - 5. Naming the session (B-693, 2026-10-02: `node 104% (geo)` could not say which of three
// geo sessions was burning it)

do {
    let inSession = HostHealthCPUProcess(name: "node", percent: 104, project: "geo", system: false,
                                         session: "geo-12")
    expect(inSession.owner(system: "system") == "geo-12", "the session outranks the checkout")
    expect(hostHealthCPUText([inSession], system: "system", stoppable: " · can stop")
            == "node 104% (geo-12)", "the banner names the session")
    let unnamedSystem = HostHealthCPUProcess(name: "mds_stores", percent: 90, project: nil,
                                             system: true, session: nil)
    expect(unnamedSystem.owner(system: "system") == "system", "no session: system stays system")

    let en: (String) -> String = { $0 }
    var tracker = HostHealthTracker(state: .alarmed)
    tracker.lastAlarm = HostHealthAlarm(at: at(0), load1: 227, freeBytes: 25 * gigabyte,
                                        top: sampleTop, cpuTop: [inSession, unnamedSystem])
    let report = HostHealthLogic.report(tracker, reading: HostHealthReading(
        load1: 227, cores: 16, freeBytes: 25 * gigabyte), at: at(0))
    expect(hostHealthAlarmTitle(report, localized: en) == "Host under pressure: node (geo-12)",
           "the title's culprit carries its session")
    expect(hostHealthLogLine(.alarm, report: report, now: at(0))
            .contains(" cpu=node[geo-12]:104%,mds_stores[system]:90% "), "…and so does the log")
    tracker.lastAlarm?.cpuTop = [HostHealthCPUProcess(name: "llama-server", percent: 70,
                                                      project: nil, system: false)]
    expect(hostHealthAlarmTitle(HostHealthLogic.report(tracker, reading: HostHealthReading(
        load1: 227, cores: 16, freeBytes: 25 * gigabyte), at: at(0)), localized: en)
            == "Host under pressure: llama-server", "an ownerless culprit: no parentheses")

    // Additive on disk: the field is written when known and absent rows still decode.
    let encoded = String(decoding: try! JSONEncoder().encode(inSession), as: UTF8.self)
    expect(encoded.contains(#""session":"geo-12""#), "a known session is written")
    let older = #"{"name":"node","percent":104,"project":"geo","system":false}"#
    let decoded = try? JSONDecoder().decode(HostHealthCPUProcess.self, from: Data(older.utf8))
    expect(decoded != nil && decoded?.session == nil && decoded?.owner(system: "system") == "geo",
           "a row written before the field decodes and keeps its checkout")

    // The three witnesses, first answer wins.
    let chain: [Int32: Int32] = [5: 4, 4: 3, 3: 1, 7: 1, 8: 9, 9: 8]
    func owner(_ pid: Int32, marker: Int32? = nil, ledger: Int32? = nil) -> Int32? {
        hostHealthSessionOwner(of: pid, supervisors: [3], parent: { chain[$0] },
                               marker: { _ in marker }, ledger: { _ in ledger })
    }
    expect(owner(5, marker: 99, ledger: 99) == 3, "the parent chain answers first")
    expect(owner(3) == 3, "a supervisor is its own session")
    expect(owner(7, marker: 3) == 3, "a broken chain falls to the environment marker")
    expect(owner(7, marker: 9, ledger: 3) == 3, "a marker off the board falls to the ledger")
    expect(owner(7, marker: 9, ledger: 9) == nil, "no witness on the board: no session")
    expect(owner(8, marker: 3) == 3, "a looping chain ends and falls to the marker")

    expect(hostHealthClaudeConfigHome(accountID: "claude:.claude5", home: "/h") == "/h/.claude5",
           "an account names its config home")
    expect(hostHealthClaudeConfigHome(accountID: "claude:.claude", home: "/h") == "/h/.claude",
           "…the default one too")
    for refused in ["codex:.codex", "claude:../x", "claude:.claude/x", "claude:x"] {
        expect(hostHealthClaudeConfigHome(accountID: refused, home: "/h") == nil,
               "\(refused) names no config home")
    }
    expect(hostHealthClaudeConfigHome(accountID: nil, home: "/h") == nil, "no account, no home")

    let record = Data(#"{"pid":29410,"name":"geo-12","nameSource":"derived"}"#.utf8)
    expect(hostHealthRegistryName(record, childPid: 29410) == "geo-12", "the registry's name")
    expect(hostHealthRegistryName(record, childPid: 1) == nil, "…only for the pid it names")
    expect(hostHealthRegistryName(Data(#"{"pid":29410,"name":""}"#.utf8), childPid: 29410) == nil,
           "an empty name is no name")
    expect(hostHealthRegistryName(Data("nope".utf8), childPid: 29410) == nil, "not JSON, no name")
}

// The knock's half, next door on size (knockchecks.swift): the sentence, what it repairs, when one
// is owed, and the structural promises a pure harness cannot drive.
runKnockChecks()

print(failures == 0 ? "all host-health checks passed" : "\(failures) host-health checks failed")
exit(failures == 0 ? 0 : 1)
