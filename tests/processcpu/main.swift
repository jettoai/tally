import Foundation

// The one-process CPU watch (Tally/Core/ProcessCPUWatchLogic.swift), driven with a fixture clock and
// fake process tables, then the monitor, reader, timer and catalog read as text for the structural
// promises a harness cannot drive.

setvbuf(stdout, nil, _IOLBF, 0)  // a crash must not swallow the lines already printed
var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

typealias W = ProcessCPUWatchLogic
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let std = ProcessCPULimits.standard
let identity: (String) -> String = { $0 }
let baseName: (String) -> String? = { ($0 as NSString).lastPathComponent }
let node = "/usr/local/bin/node"

func row(_ pid: Int32 = 100, start: Date? = nil, cpu: Double, path: String = node) -> ProcessCPURow {
    ProcessCPURow(pid: pid, startedAt: start ?? t0.addingTimeInterval(-3600), cpuSeconds: cpu, path: path)
}

/// One process read at `seconds` spacing, `percent` of a core per window.
struct Sim {
    var watch = ProcessCPUWatch()
    var now = t0
    var cpu = 1000.0
    var limits = std
    var pid: Int32 = 100
    var path = node
    var announcing = true

    init(limits: ProcessCPULimits = std, announcing: Bool = true) {
        self.limits = limits
        self.announcing = announcing
        _ = feed([row(pid, cpu: cpu, path: path)])
    }

    @discardableResult
    mutating func feed(_ rows: [ProcessCPURow]) -> [ProcessCPUEvent] {
        let (next, events) = W.advance(watch, rows: rows, at: now, limits: limits, announcing: announcing)
        watch = next
        return events
    }

    @discardableResult
    mutating func window(_ percent: Double, seconds: TimeInterval = 60, start: Date? = nil,
                         path: String? = nil) -> [ProcessCPUEvent] {
        now = now.addingTimeInterval(seconds)
        cpu += percent / 100 * seconds
        return feed([row(pid, start: start, cpu: cpu, path: path ?? self.path)])
    }

    /// Windows until one produces events, at most `limit`; returns (how many it took, the events).
    mutating func windows(_ percent: Double, upTo limit: Int) -> (Int, [ProcessCPUEvent]) {
        for n in 1...limit {
            let events = window(percent)
            if !events.isEmpty { return (n, events) }
        }
        return (limit, [])
    }
}

// MARK: - T1 the table

let sample = """
    1 06-05:04:56 227:01.72 /sbin/launchd
  105 06-05:04:26 789:43.58 /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd
 8593    19:42:05   4:38.44 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Aperitif Renderer)
 3736       00:59 3736:15.48 /usr/local/bin/long-minutes
   42       12:34    1:02:03.50 /bin/hms
this is not a row
  abc 00:10 0:01.00 /bin/badpid
  77 00:10 0:01.00

  78 xx 0:01.00 /bin/badetime
"""
let parsed = W.parse(sample, now: t0)
let byPid = Dictionary(parsed.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
expect(Set(byPid.keys) == [1, 105, 8593, 3736, 42], "T1 good rows are kept, bad rows (words, bad pid, no path, bad etime, blank) are skipped")
expect(byPid[105]?.cpuSeconds == 789 * 60 + 43.58, "T1 789:43.58 is 47383.58 s (the minutes field is not hours)")
expect(byPid[3736]?.cpuSeconds == 3736 * 60 + 15.48, "T1 unbounded minutes 3736:15.48")
expect(byPid[42]?.cpuSeconds == 3600 + 2 * 60 + 3.5, "T1 hh:mm:ss.ss is accepted defensively")
expect(byPid[1]?.startedAt == t0.addingTimeInterval(-(6 * 86_400 + 5 * 3600 + 4 * 60 + 56)), "T1 dd-hh:mm:ss etime")
expect(byPid[8593]?.startedAt == t0.addingTimeInterval(-(19 * 3600 + 42 * 60 + 5)), "T1 hh:mm:ss etime")
expect(byPid[3736]?.startedAt == t0.addingTimeInterval(-59), "T1 mm:ss etime")
expect(byPid[8593]?.path == "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Aperitif Renderer)",
       "T1 a path with spaces and parentheses is kept whole")
expect(byPid[105]?.path.hasSuffix("/fseventsd") == true, "T1 the root process's row (fseventsd) is read")
expect(W.etimeSeconds("42") == 42 && W.etimeSeconds("1-00:00:01") == 86_401 && W.etimeSeconds("") == nil
       && W.etimeSeconds("1:2:3:4") == nil, "T1 etime forms")

// the real tool on this machine, through the real reader
switch ProcessCPUWatchReaders.table() {
case .failure(let reason):
    expect(false, "T1 the reader ran /bin/ps (failed: \(reason.rawValue))")
case .success(let text):
    let real = W.parse(text, now: t0)
    let lines = text.split(whereSeparator: \.isNewline).count
    expect(real.count > 50 && real.count * 100 >= lines * 98, "T1 real ps: \(real.count) of \(lines) rows parsed")
    expect(real.contains { $0.pid == 1 && $0.path == "/sbin/launchd" }, "T1 real ps: launchd (root) is read with its CPU time")
    expect(real.contains { $0.pid == 1 && $0.cpuSeconds > 0 }, "T1 real ps: a root process's cputime is non-zero")
}

// MARK: - T2 to T6 the clock

do {
    var sim = Sim()
    for n in 1...14 { expect(sim.window(100).isEmpty, "T2 window \(n) is quiet") }
    let events = sim.window(100)
    expect(events.count == 1 && events[0].kind == .alarm && events[0].announced, "T2 window 15 raises the alarm")
    expect(events.first.map { Int($0.percent ?? 0) } == 100 && events.first?.since == t0, "T2 the alarm reports its window and the run's start")
    var more = 0
    for _ in 1...10 { more += sim.window(100).count }
    expect(more == 0, "T2 a process that stays hot says nothing more (no repeat alarm)")
}
do {
    var sim = Sim()
    for _ in 1...9 { sim.window(100) }
    sim.window(50)
    var early = 0
    for _ in 1...14 { early += sim.window(100).count }
    expect(early == 0, "T3 one cool window resets the run: 14 hot windows after it are still quiet")
    expect(sim.window(100).first?.kind == .alarm, "T3 the 15th hot window after the reset alarms")
}
do {
    var sim = Sim()
    _ = sim.windows(100, upTo: 20)
    expect(sim.window(50).isEmpty, "T4 one cool window does not clear")
    expect(sim.window(100).isEmpty, "T4 a hot window after it does not clear")
    expect(sim.window(50).isEmpty, "T4 the first cool window of a new run does not clear")
    let clear = sim.window(50)
    expect(clear.count == 1 && clear[0].kind == .clear && clear[0].announced, "T4 two cool windows in a row (120 s) clear")
    expect(clear.first.map { Int($0.until.timeIntervalSince($0.since) / 60) } == 17, "T4 the clear reports how long it was over the line")
}
do {
    var sim = Sim()
    var exact = 0
    for _ in 1...15 { exact += sim.window(80).count }
    expect(exact == 1, "T5 exactly 80.0% counts as over the line")
    var below = Sim()
    var n = 0
    for _ in 1...30 { n += below.window(79.9).count }
    expect(n == 0, "T5 79.9% does not")
}
do {
    var sim = Sim()
    expect(sim.windows(400, upTo: 20).1.first?.percent == 400, "T6 a four-core virtual machine at 400% alarms")
}

// MARK: - T7 to T10 identity, sleep, exit

do {
    var base = Sim()
    _ = base.windows(100, upTo: 20)
    var byStart = base
    let a = byStart.window(100, start: t0.addingTimeInterval(7200))
    expect(a.count == 1 && a[0].kind == .exited, "T7 a pid whose start time jumped is a new process: the alarm ends as exited")
    expect(byStart.watch.tracks[100]?.alarmedSince == nil && byStart.watch.tracks[100]?.overSince == nil, "T7 the new process is counted from zero")
    var byPath = base
    expect(byPath.window(100, path: "/usr/local/bin/other").first?.kind == .exited, "T7 a changed executable is a new process")
    var byCPU = base
    byCPU.now = byCPU.now.addingTimeInterval(60)
    expect(byCPU.feed([row(100, cpu: 5)]).first?.kind == .exited, "T7 a counter that went backwards is a new process")
    var quiet = Sim()
    for _ in 1...5 { quiet.window(100) }
    expect(quiet.window(100, start: t0.addingTimeInterval(7200)).isEmpty && quiet.watch.tracks[100]?.overSince == nil,
           "T7 an unalarmed pid reuse restarts the run without an event")
}
do {
    var sim = Sim()
    var events = 0
    var got: ProcessCPUEvent?
    for n in 1...15 {
        let jitter = n.isMultiple(of: 2) ? 1.0 : -1.0
        let out = sim.window(100, start: t0.addingTimeInterval(-3600 + jitter))
        events += out.count
        got = out.first ?? got
    }
    expect(events == 1 && got?.kind == .alarm, "T8 a start time that jitters by a second is the same process")
}
do {
    var sim = Sim()
    for _ in 1...5 { sim.window(100) }
    expect(sim.window(100, seconds: 600).isEmpty, "T9 a ten-minute gap is a dropped window, not a run")
    expect(sim.watch.tracks[100]?.overSince == nil, "T9 the gap clears the run")
    var quiet = 0
    for _ in 1...14 { quiet += sim.window(100).count }
    expect(quiet == 0, "T9 after waking, a fresh run needs its own 15 minutes")
    expect(sim.window(100).first?.kind == .alarm, "T9 and then alarms")

    var alarmed = Sim()
    _ = alarmed.windows(100, upTo: 20)
    expect(alarmed.window(0, seconds: 600).isEmpty && alarmed.watch.tracks[100]?.alarmedSince != nil,
           "T9 a sleep leaves an alarm standing instead of clearing it")
    expect(alarmed.window(100).isEmpty, "T9 and the first window after it says nothing")
    alarmed.window(0)
    expect(alarmed.window(0).first?.kind == .clear, "T9 it can still clear afterwards")
    var backwards = Sim()
    expect(backwards.feed([row(100, cpu: 2000)]).isEmpty, "T9 a reading at the same instant is dropped")
}
do {
    var sim = Sim()
    _ = sim.windows(100, upTo: 20)
    sim.now = sim.now.addingTimeInterval(60)
    let gone = sim.feed([])
    expect(gone.count == 1 && gone[0].kind == .exited && gone[0].percent == nil && sim.watch.tracks.isEmpty,
           "T10 an alarmed process that left the table is exited, and its track is gone")
    var cold = Sim()
    cold.window(100)
    cold.now = cold.now.addingTimeInterval(60)
    expect(cold.feed([]).isEmpty && cold.watch.tracks.isEmpty, "T10 an unalarmed one just disappears")
}

// MARK: - T11 to T13 who is told

do {
    var watch = ProcessCPUWatch()
    var now = t0
    var cpus: [Int32: Double] = [1: 100, 2: 100, 3: 100]
    func table(_ percents: [Int32: Double]) -> [ProcessCPURow] {
        percents.keys.sorted().map { pid in
            row(pid, cpu: cpus[pid]!, path: node)
        }
    }
    (watch, _) = W.advance(watch, rows: table([1: 0, 2: 0, 3: 0]), at: now, limits: std, announcing: true)
    var found: [ProcessCPUEvent] = []
    for _ in 1...15 {
        now = now.addingTimeInterval(60)
        cpus[1]! += 60; cpus[2]! += 60; cpus[3]! += 18
        let out: [ProcessCPUEvent]
        (watch, out) = W.advance(watch, rows: table([1: 0, 2: 0, 3: 0]), at: now, limits: std, announcing: true)
        found += out
    }
    expect(found.count == 2 && Set(found.map(\.pid)) == [1, 2], "T11 two processes at 100% alarm in one reading; the one at 30% does not")
    guard found.count == 2 else { print("FAIL  T11 cannot go on without two alarms"); exit(1) }
    let title = W.alarmTitle(found, localized: identity, displayName: baseName)
    expect(title == "Processes running hot: node and 1 more", "T11 several alarms are one title: \(title)")
    let one = W.alarmTitle([found[0]], localized: identity, displayName: baseName)
    expect(one == "Process running hot: node", "T11 one alarm names its process: \(one)")
    let body = W.alarmBody(found, now: now, localized: identity, displayName: baseName)
    expect(body.split(separator: "\n").count == 2 && body.hasPrefix("node at 100% of one core for 15 min"), "T11 the body has a line each: \(body)")
    let many = (1...5).map { ProcessCPUEvent(kind: .alarm, pid: Int32($0), path: node, percent: 100, since: t0, until: now, announced: true) }
    expect(W.alarmBody(many, now: now, localized: identity, displayName: baseName).split(separator: "\n").count == 3
           && W.alarmTitle(many, localized: identity, displayName: baseName).hasSuffix("and 4 more"),
           "T11 the body lists three, the title counts the rest")
}
do {
    var sim = Sim(announcing: false)
    let alarm = sim.windows(100, upTo: 20).1
    expect(alarm.first?.announced == false, "T12 an alarm that came while announcing was off is not announced")
    sim.announcing = true
    sim.window(0)
    let clear = sim.window(0)
    expect(clear.first?.kind == .clear && clear.first?.announced == false, "T12 its clear is not announced either")
    var again = Sim(announcing: true)
    _ = again.windows(100, upTo: 20)
    again.window(0)
    expect(again.window(0).first?.announced == true, "T12 an announced alarm's clear is")
}
do {
    var previous = ProcessCPUWatch()
    for pid in 1...1000 { previous.tracks[Int32(pid)] = ProcessCPUTrack(pid: Int32(pid), startedAt: t0, path: node, lastCPU: 0, lastAt: t0) }
    let rows = { (n: Int) in (1...n).map { row(Int32($0), cpu: 1) } }
    expect(!W.usable(rows(300), previous: previous), "T13 300 rows after 1000 tracks is a cut-short table")
    expect(W.usable(rows(500), previous: previous) && W.usable(rows(900), previous: previous), "T13 half and more is usable")
    expect(!W.usable([], previous: ProcessCPUWatch()), "T13 an empty table is never usable")
    expect(W.usable(rows(3), previous: ProcessCPUWatch()), "T13 the first table, with nothing before it, is usable")
}

// MARK: - T14 to T16 limits, owners, words

do {
    let suite = UserDefaults(suiteName: "ai.jetto.tally.processcpu.test")!
    suite.removePersistentDomain(forName: "ai.jetto.tally.processcpu.test")
    defer { suite.removePersistentDomain(forName: "ai.jetto.tally.processcpu.test") }
    expect(ProcessCPULimits.from(suite) == .standard, "T14 no keys is the standard (80 / 900 / 120 / 60)")
    expect(std.percent == 80 && std.sustain == 900 && std.clearAfter == 120 && std.sampleInterval == 60, "T14 the standard values")
    suite.set(120.0, forKey: ProcessCPULimits.sustainKey)
    suite.set(30, forKey: ProcessCPULimits.clearKey)
    suite.set("10", forKey: ProcessCPULimits.sampleKey)
    suite.set(95, forKey: ProcessCPULimits.percentKey)
    let set = ProcessCPULimits.from(suite)
    expect(set.sustain == 120 && set.clearAfter == 30 && set.sampleInterval == 10 && set.percent == 95,
           "T14 in-range values take effect, a numeric string (a launch argument) included")
    expect(set.maxGap == 150, "T14 the gap limit keeps its floor at 150 s")
    for (key, bad) in [(ProcessCPULimits.percentKey, 0.0), (ProcessCPULimits.percentKey, 99_999.0),
                       (ProcessCPULimits.sustainKey, 5.0), (ProcessCPULimits.clearKey, 99_999.0),
                       (ProcessCPULimits.sampleKey, 1.0)] {
        let fresh = UserDefaults(suiteName: "ai.jetto.tally.processcpu.test2")!
        fresh.removePersistentDomain(forName: "ai.jetto.tally.processcpu.test2")
        fresh.set(bad, forKey: key)
        expect(ProcessCPULimits.from(fresh) == .standard, "T14 \(key)=\(bad) falls back to the default")
        fresh.removePersistentDomain(forName: "ai.jetto.tally.processcpu.test2")
    }
    suite.set("many", forKey: ProcessCPULimits.sustainKey)
    expect(ProcessCPULimits.from(suite).sustain == 900, "T14 a word falls back to the default")
    let off = UserDefaults(suiteName: "ai.jetto.tally.processcpu.test3")!
    expect(W.isEnabled(off), "T14 on by default")
    off.set(false, forKey: W.enabledKey)
    expect(!W.isEnabled(off), "T14 and off when switched off")
    off.removePersistentDomain(forName: "ai.jetto.tally.processcpu.test3")
}
expect(W.logFile(unshipped: false).path.hasSuffix("/.tally/logs/process-cpu.log")
       && W.logFile(unshipped: true).path.hasSuffix("/.tally/logs-dev/process-cpu.log"),
       "T15 a Dev or unshipped build writes its own folder, never the installed app's log")
expect(W.owner(path: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd") == .system, "T15 fseventsd is system")
expect(W.owner(path: "/Applications/Tally.app/Contents/MacOS/tally") == .tally, "T15 Tally")
expect(W.owner(path: "/Applications/Tally Dev.app/Contents/MacOS/Tally Dev") == .tally, "T15 Tally Dev")
expect(W.owner(path: "/Applications/Tally Pro Dev.app/Contents/Resources/tally") == .tally, "T15 Tally Pro Dev")
expect(W.owner(path: "/usr/local/bin/node") == .none, "T15 /usr/local is not system")
expect(W.owner(path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") == .none, "T15 another app is none")
do {
    let event = { (path: String, app: String?) in
        ProcessCPUEvent(kind: .alarm, pid: 105, path: path, percent: 102.4, since: t0,
                        until: t0.addingTimeInterval(900), announced: true, app: app)
    }
    let fseventsd = "/System/Library/CoreServices/fseventsd"
    let at = t0.addingTimeInterval(900)
    expect(W.alarmTitle([event(fseventsd, nil)], localized: identity, displayName: baseName) == "Process running hot: fseventsd (system)",
           "T16 a system process is tagged (system)")
    expect(W.alarmTitle([event(fseventsd, "Docker")], localized: identity, displayName: baseName) == "Process running hot: fseventsd (Docker)",
           "T16 a system process under an app is tagged with the app")
    expect(W.alarmTitle([event("/Applications/Tally.app/Contents/MacOS/tally", nil)], localized: identity, displayName: baseName)
           == "Process running hot: tally (Tally)", "T16 Tally's own process is tagged (Tally)")
    expect(W.alarmBody([event(fseventsd, nil)], now: at, localized: identity, displayName: baseName)
           == "fseventsd (system) at 102% of one core for 15 min", "T16 the alarm line")
    var gone = event(node, nil)
    gone.kind = .exited; gone.percent = nil; gone.until = t0.addingTimeInterval(1200)
    var calm = event(node, nil)
    calm.kind = .clear; calm.percent = 3.2; calm.until = t0.addingTimeInterval(1200)
    expect(W.clearBody([gone], localized: identity, displayName: baseName) == "node exited after 20 min over the line", "T16 exit line")
    expect(W.clearBody([calm], localized: identity, displayName: baseName) == "node is down to 3% after 20 min over the line", "T16 clear line")
    expect(W.clearTitle([calm, gone], localized: identity, displayName: baseName) == "Processes calmed down: node and 1 more", "T16 clear title for several")
    let line = W.logLine(event(fseventsd, nil), now: at, displayName: baseName)
    expect(line.hasSuffix(" name=fseventsd\n") && line.filter { $0 == "\n" }.count == 1
           && line.contains("process-cpu=alarm pid=105 pct=102 since=") && line.contains("announced=yes owner=system"),
           "T16 one log line per event, name last: \(line.dropLast())")
    let dirty = W.logLine(event("/tmp/we\u{1B}[31mird\nname", nil), now: at, displayName: { _ in "we\u{1B}[31mird\nname" })
    expect(dirty.filter { $0 == "\n" }.count == 1 && !dirty.contains("\u{1B}"), "T16 a name with a newline or an escape cannot forge a line")
    expect(W.unreadLine(reason: "timeout", now: at).hasSuffix("process-cpu=unread reason=timeout\n"), "T16 unread line")
    let texts = [W.alarmTitle([event(fseventsd, nil)], localized: identity, displayName: baseName),
                 W.alarmBody([event(fseventsd, nil)], now: at, localized: identity, displayName: baseName),
                 W.clearBody([calm, gone], localized: identity, displayName: baseName), line]
    expect(!texts.contains { $0.contains("\u{2014}") }, "T16 no em dash in what is printed")
}

// MARK: - structural promises, read as text

func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
let monitor = read("Tally/Core/ProcessCPUWatchMonitor.swift")
let readers = read("Tally/Core/ProcessCPUWatchReaders.swift")
let logic = read("Tally/Core/ProcessCPUWatchLogic.swift")
let timing = read("Tally/Stores/ProcessFootprintTiming.swift")
let hostMonitor = read("Tally/Core/HostHealthMonitor.swift")
let hostReaders = read("Tally/Core/HostHealthReaders.swift")
expect(!monitor.isEmpty && !readers.isEmpty && !logic.isEmpty && !timing.isEmpty, "the sources are readable")

// S1 clock throttle, no timer of its own
expect(monitor.contains("now.timeIntervalSince(last) < limits.sampleInterval"), "S1 throttled by the clock")
expect(!monitor.contains("Timer(") && !monitor.contains("DispatchSourceTimer") && !monitor.contains("asyncAfter"),
       "S1 no timer of its own")
// S2 rides the footprint heartbeat
// a code line, not a comment that merely names the call
expect(timing.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "ProcessCPUWatchMonitor.shared.tick()" },
       "S2 ticked from the footprint timer")
// S3 the reading is /bin/ps, read to EOF before waiting, bounded, and never on the main actor
expect(readers.contains("/bin/ps"), "S3 the reader runs /bin/ps (libproc cannot see root processes)")
if let eof = readers.range(of: "readDataToEndOfFile()"), let wait = readers.range(of: "waitUntilExit()") {
    expect(eof.lowerBound < wait.lowerBound, "S3 the pipe is read to the end before waiting")
} else {
    expect(false, "S3 the pipe is read to the end before waiting")
}
expect(readers.contains("SIGTERM") && readers.contains("LC_ALL"), "S3 a watchdog ends a stuck ps, in the C locale")
expect(!logic.contains("proc_pid_rusage") && !monitor.contains("resourceSample") && !monitor.contains("liveProcesses"),
       "S3 the watch does not read through libproc")
if let call = monitor.range(of: "ProcessCPUWatchReaders.table()"), let detached = monitor.range(of: "Task.detached") {
    expect(detached.lowerBound < call.lowerBound
           && monitor[detached.lowerBound..<call.lowerBound].filter { $0 == "\n" }.isEmpty,
           "S3 the reader is called inside a detached task")
} else {
    expect(false, "S3 the reader is called inside a detached task")
}
expect(monitor.contains("guard !inFlight"), "S3 a slow ps is skipped over, not queued")
// S4 the two older watches stay free of subprocesses (their own suites lock it; asserted here too)
expect(!hostMonitor.contains("/bin/ps") && !hostReaders.contains("/bin/ps"), "S4 HostHealth still does not spawn ps")

// S5 every string this watch speaks is translated in all five languages, with the same placeholders
let keys = [
    "Process running hot: %@", "Processes running hot: %1$@ and %2$@ more",
    "%1$@ at %2$@%% of one core for %3$@ min", "Process calmed down: %@",
    "Processes calmed down: %1$@ and %2$@ more", "%1$@ is down to %2$@%% after %3$@ min over the line",
    "%1$@ exited after %2$@ min over the line", "Process CPU alert",
    "Notify when any one process stays above 80% of a core for 15 minutes, and again when it calms down.",
]
func placeholders(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: "%(\\d+\\$)?@|%%")
    let range = NSRange(text.startIndex..., in: text)
    return pattern.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
}
if let data = FileManager.default.contents(atPath: "Tally/Resources/Localizable.xcstrings"),
   let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let strings = catalog["strings"] as? [String: Any] {
    for key in keys {
        let localizations = ((strings[key] as? [String: Any])?["localizations"] as? [String: Any]) ?? [:]
        var good = true
        for language in ["zh-Hant", "zh-Hans", "ja", "ko", "tr"] {
            let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = unit?["value"] as? String ?? ""
            if unit?["state"] as? String != "translated" || value.isEmpty
                || placeholders(value) != placeholders(key) || value.contains("\u{2014}") { good = false }
        }
        expect(good && !key.contains("\u{2014}"), "S5 translated in all five languages with the same placeholders: \(key)")
    }
    for key in ["system", " (%@)", "unknown"] {
        expect(strings[key] != nil, "S5 the reused string exists: \(key)")
    }
} else {
    expect(false, "S5 the catalog is readable")
}

// no em dash in the new sources
expect(![logic, readers, monitor].contains { $0.contains("\u{2014}") }, "no em dash in the new sources")

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
