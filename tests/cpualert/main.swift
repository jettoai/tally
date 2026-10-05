import Foundation

// The CPU watch's rules (Tally/Core/CPUAlertLogic.swift), driven with fixtures, then the monitor,
// readers and timer sources read as text for the structural promises a harness cannot drive.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

typealias L = CPUAlertLogic
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Ticks that make the window from `base` read `busy` percent over 1000 ticks.
func step(_ base: CPUTicks, busy: Int) -> CPUTicks {
    CPUTicks(user: base.user + UInt64(busy * 10), system: base.system,
             idle: base.idle + UInt64((100 - busy) * 10), nice: base.nice)
}

/// Feeds `readings` at ten-second spacing starting from a primed tracker at `start`.
struct Run {
    var tracker = CPUAlertTracker()
    var ticks = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    var now: Date
    var events: [CPUAlertEvent?] = []

    init(start: Date, tracker: CPUAlertTracker? = nil) {
        now = start
        if let tracker {
            self.tracker = tracker
            self.tracker.lastTicks = ticks
            self.tracker.lastSampleAt = start
        } else {
            (self.tracker, _) = L.advance(CPUAlertTracker(), ticks: ticks, leader: nil,
                                          hostAlarmed: false, hostAlarmAt: nil, at: start)
        }
    }

    mutating func feed(_ busy: Int, leader: String? = "bigdata", gap: TimeInterval = 10,
                       hostAlarmed: Bool = false, hostAlarmAt: Date? = nil) -> CPUAlertEvent? {
        now = now.addingTimeInterval(gap)
        ticks = step(ticks, busy: busy)
        let (next, event) = L.advance(tracker, ticks: ticks, leader: leader,
                                      hostAlarmed: hostAlarmed, hostAlarmAt: hostAlarmAt, at: now)
        tracker = next
        events.append(event)
        return event
    }
}

// T1 busyPercent
do {
    let a = CPUTicks(user: 100, system: 100, idle: 100, nice: 100)
    let b = CPUTicks(user: 110, system: 105, idle: 185, nice: 100)
    expect(L.busyPercent(from: a, to: b) == 15.0, "T1 busy is user+system+nice over total")
    expect(L.busyPercent(from: a, to: a) == nil, "T1 no ticks elapsed reads nil")
    expect(L.busyPercent(from: b, to: a) == nil, "T1 a counter going backwards reads nil")
}

// T2 a twenty-second spike does not alarm
do {
    var run = Run(start: t0)
    let events = [run.feed(95), run.feed(95), run.feed(40)]
    expect(events.allSatisfy { $0 == nil } && run.tracker.phase == .normal,
           "T2 twenty seconds over the line and back is silent")
}

// T3 thirty seconds over alarms, counting the first window's start
do {
    var run = Run(start: t0)
    let events = [run.feed(95), run.feed(95), run.feed(95)]
    expect(events[0] == nil && events[1] == nil, "T3 no alarm before thirty seconds")
    expect(events[2] == .alarm(silence: nil), "T3 the third ten-second window over raises the alarm")
    expect(run.tracker.lastBannerAt == run.now && run.tracker.announcedLeader == "bigdata",
           "T3 the banner is recorded with its leader")
    expect(run.tracker.alarmSince == t0, "T3 the alarm dates from the first window's start")
}

// T4 a dip below the entry line resets the run
do {
    var run = Run(start: t0)
    let e = [run.feed(95), run.feed(85), run.feed(95), run.feed(95)]
    expect(e.allSatisfy { $0 == nil }, "T4 a reading under 90 resets the run")
    expect(run.feed(95) == .alarm(silence: nil), "T4 thirty fresh seconds are then needed")
}

func alarmed(_ run: inout Run) {
    _ = run.feed(95); _ = run.feed(95); _ = run.feed(95)
}

// T5 clearing
do {
    var run = Run(start: t0)
    alarmed(&run)
    var none = true
    for _ in 0..<10 { none = none && run.feed(80) == nil }
    expect(none && run.tracker.phase == .alarmed, "T5 80% holds the alarm (exit line is 75)")
    let first = [run.feed(50), run.feed(50), run.feed(50), run.feed(50), run.feed(50)]
    expect(first.allSatisfy { $0 == nil }, "T5 fifty seconds under does not clear")
    expect(run.feed(50) == .clear && run.tracker.phase == .normal, "T5 sixty seconds under clears")

    var dip = Run(start: t0)
    alarmed(&dip)
    _ = dip.feed(50); _ = dip.feed(50); _ = dip.feed(50)
    _ = dip.feed(80)
    let after = [dip.feed(50), dip.feed(50), dip.feed(50), dip.feed(50), dip.feed(50)]
    expect(after.allSatisfy { $0 == nil } && dip.tracker.phase == .alarmed,
           "T5 one reading at 80 resets the clearing run")
    expect(dip.feed(50) == .clear, "T5 and sixty fresh seconds clear it")
}

// T6 cooldown after a clear
do {
    var same = Run(start: t0)
    alarmed(&same)
    let sameBanner = same.tracker.lastBannerAt
    for _ in 0..<6 { _ = same.feed(50) }
    expect(same.tracker.phase == .normal, "T6 cleared")
    for _ in 0..<18 { _ = same.feed(20) }  // three minutes quiet
    _ = same.feed(95); _ = same.feed(95)
    expect(same.feed(95) == .alarm(silence: .cooldown), "T6 same leader within ten minutes is silenced")
    expect(same.tracker.lastBannerAt == sameBanner, "T6 a silenced crossing does not restart the cooldown")

    var other = Run(start: t0)
    alarmed(&other)
    for _ in 0..<6 { _ = other.feed(50) }
    for _ in 0..<18 { _ = other.feed(20) }
    _ = other.feed(95, leader: "tally"); _ = other.feed(95, leader: "tally")
    expect(other.feed(95, leader: "tally") == .alarm(silence: nil),
           "T6 a different leader within ten minutes is announced")
    expect(other.tracker.announcedLeader == "tally", "T6 and becomes the announced leader")
}

// T7 handover while alarmed
do {
    var run = Run(start: t0)
    alarmed(&run)
    let e1 = [run.feed(95, leader: "tally"), run.feed(95, leader: "tally")]
    expect(e1.allSatisfy { $0 == nil }, "T7 a new leader under thirty seconds is not news")
    expect(run.feed(95, leader: "tally") == nil, "T7 thirty seconds but inside the cooldown is not news")
    // Walk to ten minutes after the banner with tally leading.
    for _ in 0..<56 { _ = run.feed(95, leader: "tally") }
    expect(run.feed(95, leader: "tally") == .handover && run.tracker.announcedLeader == "tally",
           "T7 held and past the cooldown is a handover")
    var none = Run(start: t0)
    alarmed(&none)
    var quiet = true
    for _ in 0..<70 { quiet = quiet && none.feed(95, leader: nil) == nil }
    expect(quiet, "T7 a leader going to nil never hands over")
    var back = Run(start: t0)
    alarmed(&back)
    _ = back.feed(95, leader: "tally")
    _ = back.feed(95, leader: "bigdata")
    expect(back.tracker.candidateLeader == nil, "T7 the announced leader returning drops the candidate")

    // Alarmed and past the cooldown, so only the thirty continuous seconds decide a handover.
    func cooled() -> Run {
        var run = Run(start: t0)
        alarmed(&run)
        for _ in 0..<60 { _ = run.feed(95, leader: nil) }
        return run
    }
    var p1 = cooled()
    let e7 = [p1.feed(95, leader: "tally"), p1.feed(50, leader: nil), p1.feed(50, leader: nil),
              p1.feed(95, leader: "tally")]
    expect(e7.allSatisfy { $0 == nil }, "T7 windows under the exit line break the new leader's run")
    var p2 = cooled()
    let e8 = [p2.feed(95, leader: "tally"), p2.feed(95, leader: "tally", gap: 300),
              p2.feed(95, leader: "tally")]
    expect(e8.allSatisfy { $0 == nil }, "T7 a gap while alarmed breaks the new leader's run")
    var p3 = cooled()
    let e9 = [p3.feed(95, leader: "tally"), p3.feed(50, leader: "kooai"),
              p3.feed(95, leader: "tally"), p3.feed(95, leader: "tally")]
    expect(e9.allSatisfy { $0 == nil }, "T7 a low window led by another project breaks the run")
    var c2 = cooled()
    let e10 = [c2.feed(95, leader: "tally"), c2.feed(95, leader: "tally"), c2.feed(95, leader: "tally")]
    expect(e10 == [nil, nil, .handover], "T7 thirty continuous seconds past the cooldown still hand over")
}

// T8 host pressure silences
do {
    var run = Run(start: t0)
    _ = run.feed(95); _ = run.feed(95)
    expect(run.feed(95, hostAlarmed: true) == .alarm(silence: .host), "T8 host in alarm silences")
    expect(run.tracker.lastBannerAt == nil, "T8 a silenced crossing writes no banner")
    var recent = Run(start: t0)
    _ = recent.feed(95); _ = recent.feed(95)
    let hostAt = recent.now.addingTimeInterval(-100)  // 110 s before the reading below
    expect(recent.feed(95, hostAlarmAt: hostAt) == .alarm(silence: .host),
           "T8 a host alarm within 120 seconds silences")
    var old = Run(start: t0)
    _ = old.feed(95); _ = old.feed(95)
    expect(old.feed(95, hostAlarmAt: old.now.addingTimeInterval(-300)) == .alarm(silence: nil),
           "T8 an old host alarm does not")
    var hand = Run(start: t0)
    alarmed(&hand)
    for _ in 0..<60 { _ = hand.feed(95, leader: "tally", hostAlarmed: true) }
    expect(hand.tracker.announcedLeader == "bigdata" && !hand.events.contains(.handover),
           "T8 a handover is silenced by host pressure too")
}

// T9 a gap over maxGap drops the reading
do {
    var run = Run(start: t0)
    _ = run.feed(100); _ = run.feed(100)
    expect(run.feed(100, gap: 30) == nil && run.tracker.runSince == nil,
           "T9 a thirty-second gap is dropped and the run reset")
    expect(run.feed(100) == nil, "T9 the run starts again after it")
}

// T10 projectCulprits
do {
    let c = L.projectCulprits([
        CPUAlertProjectInput(name: "bigdata", oneCorePercent: 976),
        CPUAlertProjectInput(name: "zeta", oneCorePercent: 192),
        CPUAlertProjectInput(name: "tally", oneCorePercent: 192),
        CPUAlertProjectInput(name: "cold", oneCorePercent: nil),
        CPUAlertProjectInput(name: "tiny", oneCorePercent: 40),
    ], cores: 16)
    expect(c.map(\.name) == ["bigdata", "tally", "zeta"], "T10 largest first, ties by name, small and nil dropped")
    expect(c.first?.percent == 61.0, "T10 one-core percent divided by cores")
    expect(L.projectCulprits([CPUAlertProjectInput(name: "x", oneCorePercent: 100)], cores: 0).isEmpty,
           "T10 zero cores is empty")
}

// T13 phrase
do {
    let p = L.phrase([CPUAlertCulprit(name: "bigdata", percent: 61.4),
                      CPUAlertCulprit(name: "ta\nlly", percent: 11.6),
                      CPUAlertCulprit(name: "\u{1B}", percent: 9)], separator: "、")
    expect(p == "bigdata 61%、tally 12%", "T13 separator used, rounded, control characters stripped, empty names left out")
    expect(L.phrase([CPUAlertCulprit(name: "\n", percent: 50)], separator: ", ") == nil, "T13 nothing left reads nil")
    expect(L.phrase([], separator: ", ") == nil, "T13 no culprits reads nil")
}

// T14 logLine
do {
    let line = L.logLine(.alarm(silence: .host), busy: 94.2, cores: 16,
                         culprits: [CPUAlertCulprit(name: "bigdata", percent: 61),
                                    CPUAlertCulprit(name: "tally", percent: 12)], now: t0)
    expect(line.filter { $0 == "\n" }.count == 1 && line.hasSuffix("\n"), "T14 one line, newline last")
    expect(line.contains("cpu-alert=alarm") && line.contains("announced=no reason=host")
           && line.contains("top=bigdata:61,tally:12") && line.contains("cpu=94 cores=16"),
           "T14 fields and names")
    let clear = L.logLine(.clear, busy: 40, cores: 16, culprits: [], now: t0)
    expect(clear.contains("cpu-alert=clear") && !clear.contains("announced") && !clear.contains("top="),
           "T14 a clear carries no announced field")
    let yes = L.logLine(.alarm(silence: nil), busy: 95, cores: 8, culprits: [], now: t0)
    expect(yes.contains("announced=yes"), "T14 an announced alarm says so")
}

// T15 heldSeconds
do {
    expect(L.heldSeconds(since: t0, now: t0.addingTimeInterval(34)) == 30, "T15 34 s reads 30")
    expect(L.heldSeconds(since: t0, now: t0.addingTimeInterval(56)) == 60, "T15 56 s reads 60")
    expect(L.heldSeconds(since: nil, now: t0) == 30, "T15 unknown start reads 30")
}

// T16' namedShares: every name carries its own share either way; `leading` says whether the
// banner opens with "mostly" (the real crossing: cpu=97 top=geo:9,finance:8,VM:7 must not read
// "mostly geo"), and an emptied name drops out without shifting the culprits it pairs with.
do {
    let leading = L.namedShares([CPUAlertCulprit(name: "bigdata", percent: 61.4),
                                 CPUAlertCulprit(name: "tally", percent: 11.6)])
    expect(leading.names.map(\.name) == ["bigdata", "tally"] && leading.names.map(\.share) == [61, 12]
           && leading.leading, "T16 a leading share names every culprit with its own percent")

    let none = L.namedShares([CPUAlertCulprit(name: "geo", percent: 9),
                              CPUAlertCulprit(name: "finance", percent: 8),
                              CPUAlertCulprit(name: "com.apple.Virtualization.VirtualMachine", percent: 7)])
    expect(none.names.map(\.share) == [9, 8, 7] && !none.leading,
           "T16 nobody past leaderShare is no single cause, percents still printed")

    let emptied = L.namedShares([CPUAlertCulprit(name: "\u{1B}", percent: 50),
                                 CPUAlertCulprit(name: "geo", percent: 30, kind: .project)])
    expect(emptied.names.count == 1 && emptied.names[0].culprit.name == "geo" && emptied.names[0].share == 30,
           "T16 an emptied name drops out and the rest stay paired with their culprits")
}

// T17 attribution by checkout (the real crossing: 2026-09-28 07:05 cpu=98 top=python3.13:10,
// python3.13:10,finance:5 read "no single cause: python3.13, python3.13, finance" while both
// interpreters were working in the finance checkout).
do {
    let home = "/Users/a"
    let finance = "/Users/a/workspace/taiwanbigdata/finance"
    let checkouts: Set<String> = [finance, "/Users/a/workspace/geo", "/Users/a/workspace/voice", home]
    func name(_ cwd: String?, _ exe: String) -> String {
        L.processName(cwd: cwd, executable: exe, home: home) { checkouts.contains($0) }
    }
    expect(name(finance, "python3.13") == "finance" && name(finance + "/engine/jobs", "python3.13") == "finance",
           "T17 a process working in a checkout, or below it, is filed under the checkout")
    expect(name(nil, "python3.13") == "python3.13", "T17 an unreadable working directory falls back to the executable")
    expect(name("/tmp/scratch", "node") == "node" && name("/", "launchd") == "launchd",
           "T17 a directory in no checkout falls back to the executable")
    expect(name(home + "/Downloads", "ffmpeg") == "ffmpeg", "T17 a home directory under version control is not a checkout")
}

// T18 to T25, the whole-machine breakdown (CPUAlertBreakdown.swift): breakdownchecks.swift
runBreakdownChecks()

// MARK: - structural promises, read as text

func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
let monitor = read("Tally/Core/CPUAlertMonitor.swift")
let readers = read("Tally/Core/CPUAlertReaders.swift")
let timing = read("Tally/Stores/ProcessFootprintTiming.swift")
expect(!monitor.isEmpty && !readers.isEmpty && !timing.isEmpty, "the sources are readable")

// S1 clock throttle, no timer of its own
expect(monitor.contains("now.timeIntervalSince(last) < CPUAlertLogic.sampleInterval"), "S1 throttled by the clock")
expect(!monitor.contains("Timer(") && !monitor.contains("DispatchSourceTimer") && !monitor.contains("asyncAfter"),
       "S1 no timer of its own")

// S2 rides the footprint heartbeat beside the host watch
expect(timing.contains("CPUAlertMonitor.shared.tick()") && timing.contains("HostHealthMonitor.shared.tick()"),
       "S2 ticked from the footprint timer beside the host watch")

// S3 the process scan has one caller, between the announcing branch's braces
func blockEnd(_ text: String, from: String.Index) -> String.Index? {
    var depth = 1
    var cursor = from
    while cursor < text.endIndex {
        switch text[cursor] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 { return cursor }
        default: break
        }
        cursor = text.index(after: cursor)
    }
    return nil
}
do {
    let calls = monitor.components(separatedBy: "CPUAlertReaders.scan(").count - 1
    expect(calls == 1, "S3 the machine scan has exactly one caller")
    expect(!monitor.contains("unattributed(") && !readers.contains("unattributed("),
           "S3 the partial scan is gone")
    if let branch = monitor.range(of: "if announce, let scan = await Task.detached"),
       let body = monitor.range(of: "}).value {", range: branch.upperBound..<monitor.endIndex),
       let call = monitor.range(of: "CPUAlertReaders.scan("),
       let close = blockEnd(monitor, from: body.upperBound) {
        expect(call.lowerBound > branch.upperBound && call.lowerBound < close,
               "S3 the machine scan sits inside the announcing branch")
    } else {
        expect(false, "S3 the machine scan sits inside the announcing branch")
    }
}

// S4 names, never arguments, and no subprocess
for banned in ["KERN_PROCARGS", "commandLine(", "proc_listallpids", "Process()", "posix_spawn"] {
    expect(!readers.contains(banned), "S4 the readers never use \(banned)")
}

// S5 the seven strings, in every language
do {
    let data = (try? Data(contentsOf: URL(fileURLWithPath: "Tally/Resources/Localizable.xcstrings"))) ?? Data()
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let strings = root?["strings"] as? [String: Any] ?? [:]
    let keys = ["CPU running hot", "CPU still running hot", "CPU running hot: %@",
                "CPU still running hot: %@",
                "CPU %1$@%% for %2$@ seconds · mostly %3$@", "CPU %1$@%% · now mostly %2$@",
                "CPU %1$@%% for %2$@ seconds · no single cause: %3$@",
                "CPU %1$@%% · no single cause: %2$@", "%1$@ (%2$@%% of the machine)", ", ",
                "CPU alert", "Notify when CPU stays above 90% for 30 seconds, naming the project behind it.",
                "System", "Tally itself", "other projects (%@%% of the machine)", "other (%@%% of the machine)"]
    for key in keys {
        let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        let ok = ["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { lang in
            let unit = (locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any]
            return unit?["state"] as? String == "translated" && !((unit?["value"] as? String) ?? "").isEmpty
        }
        expect(ok, "S5 \"\(key)\" is translated in four languages")
    }
    // The format strings keep their placeholders in every language.
    for key in keys where key.contains("%1$@") {
        let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        let needed = key.components(separatedBy: "$@").count - 1
        let ok = locs.values.allSatisfy { loc in
            let value = ((loc as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            return value.components(separatedBy: "$@").count - 1 == needed && value.contains("%%")
        }
        expect(ok, "S5 \"\(key)\" keeps every placeholder and the percent sign")
    }
    for key in keys where key.contains("(%@%%") {
        let locs = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        let ok = !locs.isEmpty && locs.values.allSatisfy { loc in
            let value = ((loc as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            return value.components(separatedBy: "%@").count == 2 && value.contains("%%")
        }
        expect(ok, "S5 \"\(key)\" keeps its placeholder and the percent sign")
    }
}

// S6 the banner prints the rest, and names Tally's and the OS's work in words
for key in ["L(\"other (%@%% of the machine)\")", "L(\"other projects (%@%% of the machine)\")",
            "L(\"Tally itself\")", "L(\"System\")"] {
    expect(monitor.contains(key), "S6 the monitor prints \(key)")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
