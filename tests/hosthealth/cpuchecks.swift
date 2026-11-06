import Foundation

// B-4094: the alarm is decided on CPU, not on the one-minute load average. This file states the
// truth table of Tally/Core/HostHealthCPU.swift and HostHealthLogic.swift cell by cell (#1 to #13 for
// one sample, S1 to S8 for the run), then the ten-second windows the minute's share is the mean of,
// the limits and their ranges, and what the published document and the text built from it say.

private let physical: UInt64 = 128 * gigabyte

/// One sample the way the table spells it: CPU share (nil = unread) over `windows` windows, free
/// memory as a share of 128 GB, and the load average that no longer decides anything.
private func row(cpu: Double?, windows: Int = 6, free: Double = 36, load: Double = 5) -> HostHealthReading {
    HostHealthReading(load1: load, cores: 16, freeBytes: UInt64(free / 100 * Double(physical)),
                      cpuPercent: cpu, cpuWindows: windows, physicalBytes: physical)
}

private func feed(_ tracker: HostHealthTracker, _ readings: [HostHealthReading], from minute: Int = 0,
                  limits: HostHealthLimits = .standard) -> (HostHealthTracker, [HostHealthEvent?]) {
    var state = tracker
    var events: [HostHealthEvent?] = []
    for (index, reading) in readings.enumerated() {
        let (next, event) = HostHealthLogic.advance(state, reading: reading, at: at(minute + index),
                                                    limits: limits)
        state = next
        events.append(event)
    }
    return (state, events)
}

func runCPUChecks() {
    // MARK: - One sample (#1 to #13)

    let suite = "cpuchecks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    func over(_ r: HostHealthReading, _ limits: HostHealthLimits = .standard) -> Bool {
        HostHealthLogic.exceeds(r, limits)
    }
    expect(!over(row(cpu: 51.5, free: 37, load: 142)), "#1 CPU 51.5, load 142 (the 15:00 reading): not over")
    expect(!over(row(cpu: 64, free: 36, load: 185)), "#2 CPU 64, load 185 (the 14:49 screenshot): not over")
    expect(!over(row(cpu: 50, load: 200)), "#3 CPU 50, load 200: not over")
    expect(!over(row(cpu: 50, load: 244)), "#4 CPU 50, load 244: not over")
    expect(!over(row(cpu: 89.9)), "#5 CPU 89.9: not over (boundary)")
    expect(over(row(cpu: 90.0)), "#6 CPU 90.0: over (boundary, at or above)")
    expect(over(row(cpu: 96)), "#7 CPU 96 with a load of 5: over, a quiet load does not hide it")
    let t8 = feed(HostHealthTracker(), [row(cpu: 96), row(cpu: 96), row(cpu: nil, windows: 0, load: 200)])
    expect(!over(row(cpu: nil, windows: 0, load: 200)) && t8.0.over == 2 && t8.1.allSatisfy { $0 == nil },
           "#8 CPU unread (no ticks), load 200: not over, and the run count stays where it was")
    let t9 = feed(HostHealthTracker(), [row(cpu: 96), row(cpu: nil, windows: 2, load: 200)])
    expect(!over(row(cpu: nil, windows: 2, load: 200)) && t9.0.over == 1 && t9.0.under == 0,
           "#9 CPU unread (2 windows, fewer than 3): counts stay put")
    expect(over(row(cpu: nil, windows: 0, free: 2.9, load: 0)), "#10 CPU unread, 2.9% free: over (memory witness)")
    expect(over(row(cpu: 10, free: 2.9, load: 0)), "#11 CPU 10, 2.9% free: over (memory witness)")
    defaults.set(95, forKey: HostHealthLimits.cpuKey)
    expect(!over(row(cpu: 93, free: 36, load: 0), HostHealthLimits.from(defaults)),
           "#12 CPU 93 with hostHealthCPUPercent=95: not over")
    defaults.set(0, forKey: HostHealthLimits.cpuKey)
    expect(over(row(cpu: 93, free: 36, load: 0), HostHealthLimits.from(defaults)),
           "#13 CPU 93 with hostHealthCPUPercent=0 (illegal): over, the default 90 stands in")

    // MARK: - The limits and their ranges

    for (key, bad, good, pick) in [
        (HostHealthLimits.cpuKey, [49.0, 101, -1], [50.0, 100], \HostHealthLimits.cpuPercent),
        (HostHealthLimits.memoryKey, [0.0, 51], [1.0, 50], \HostHealthLimits.memoryPercent)] {
        let fallback = HostHealthLimits.standard[keyPath: pick]
        for value in bad {
            defaults.set(value, forKey: key)
            expect(HostHealthLimits.from(defaults)[keyPath: pick] == fallback, "\(key)=\(value) falls back")
        }
        for value in good {
            defaults.set(value, forKey: key)
            expect(HostHealthLimits.from(defaults)[keyPath: pick] == value, "\(key)=\(value) is taken")
        }
        defaults.removeObject(forKey: key)
    }
    for value in [0, 31] {
        defaults.set(value, forKey: HostHealthLimits.samplesKey)
        expect(HostHealthLimits.from(defaults).samples == 3, "hostHealthConsecutiveSamples=\(value) falls back")
    }
    defaults.set(5, forKey: HostHealthLimits.samplesKey)
    expect(HostHealthLimits.from(defaults).samples == 5, "…and 5 is taken")
    defaults.set("ninety", forKey: HostHealthLimits.cpuKey)
    expect(HostHealthLimits.from(defaults).cpuPercent == 90, "a non-number falls back")
    expect(HostHealthLimits.standard == HostHealthLimits(cpuPercent: 90, samples: 3, memoryPercent: 3),
           "the defaults are 90 percent, 3 samples, 3 percent")
    let five = feed(HostHealthTracker(), Array(repeating: row(cpu: 96), count: 5),
                    limits: HostHealthLimits(cpuPercent: 90, samples: 5, memoryPercent: 3))
    expect(five.1 == [nil, nil, nil, nil, .alarm], "a longer run (5 samples) alarms on the fifth")

    // MARK: - The run (S1 to S8)

    let albert = [51.0, 52, 54, 49, 56]
    let s1 = feed(HostHealthTracker(), (0..<60).map { row(cpu: albert[$0 % 5], free: 37, load: 142) })
    expect(s1.1.allSatisfy { $0 == nil } && s1.0.state == .normal, "S1 an hour of 49 to 56 percent: no event")

    let s2 = feed(HostHealthTracker(), [row(cpu: 96), row(cpu: 96), row(cpu: 96)])
    expect(s2.1 == [nil, nil, .alarm] && HostHealthLogic.cpuExceeds(row(cpu: 96)),
           "S2 96,96,96: the third alarms, on a reading that asks for the CPU top three")

    let s3 = feed(HostHealthTracker(), [96, 96, 80, 96, 96].map { row(cpu: $0) })
    expect(s3.1.allSatisfy { $0 == nil }, "S3 96,96,80,96,96: the run is interrupted, no event")

    var s4 = feed(HostHealthTracker(), Array(repeating: row(cpu: 96), count: 6)).0
    expect(s4.state == .alarmed, "S4 six samples over: alarmed")
    s4.namedAt = at(2)
    s4.namedLeader = HostHealthLogic.leaderKey([HostHealthCPUProcess(name: "node", percent: 90,
                                                                      project: "geo", system: false)])
    let handed = HostHealthLogic.rename(s4, cpuTop: [HostHealthCPUProcess(name: "ffmpeg", percent: 200,
                                                                          project: "video", system: false)],
                                        at: at(12))
    expect(HostHealthLogic.renameDue(s4, reading: row(cpu: 96), at: at(12)) && handed.1,
           "…and a new leader after ten minutes is a handover, as before")
    expect(!HostHealthLogic.renameDue(s4, reading: row(cpu: 60, load: 200), at: at(12)),
           "…but not once the CPU has come down, whatever the load says")

    let alarmed = feed(HostHealthTracker(), Array(repeating: row(cpu: 96), count: 3)).0
    let s5 = feed(alarmed, [50, 50, 50].map { row(cpu: $0) }, from: 3)
    expect(s5.1 == [nil, nil, .clear], "S5 alarmed, then 50,50,50: clear")

    let s6 = feed(alarmed, Array(repeating: row(cpu: nil, windows: 0), count: 5), from: 3)
    expect(s6.1.allSatisfy { $0 == nil } && s6.0.state == .alarmed && s6.0.under == 0,
           "S6 alarmed, then five unread minutes: still alarmed, nothing cleared")

    let s7 = feed(HostHealthTracker(), [row(cpu: nil, windows: 0), row(cpu: 96), row(cpu: 96), row(cpu: 96)])
    expect(s7.1 == [nil, nil, nil, .alarm], "S7 unread,96,96,96: the unread minute counts for nothing, the fourth alarms")

    let faked = (0..<3).map { _ in HostHealthReading(load1: 4, cores: 16, freeBytes: 40 * gigabyte,
                                                    cpuPercent: 97, cpuWindows: 3, physicalBytes: 64 * gigabyte) }
    let s8 = feed(HostHealthTracker(), faked)
    var tracked = s8.0
    tracked.lastAlarm = HostHealthAlarm(at: at(2), load1: 4, freeBytes: 40 * gigabyte, top: [],
                                        cpuTop: [HostHealthCPUProcess(name: "node", percent: 97,
                                                                      project: nil, system: false)],
                                        cpuPercent: 97)
    let body = hostHealthAlarmBody(HostHealthLogic.report(tracked, reading: faked[0], at: at(2)),
                                   localized: { $0 })
    expect(s8.1 == [nil, nil, .alarm] && body.hasPrefix("CPU 97% (16 cores) · free memory 40 GB · top: node 97%"),
           "S8 the test flag's fake 97 percent three times: alarm, and the banner says CPU 97%")

    // MARK: - The ten-second windows

    func windows(_ counters: [(busy: UInt64, total: UInt64)?], every step: Double = 10) -> HostCPUSample {
        var w = HostCPUWindows()
        for (index, c) in counters.enumerated() {
            w.observe(busy: c?.busy, total: c?.total, at: t0.addingTimeInterval(Double(index) * step))
        }
        return w.take()
    }
    // Seven readings = six windows at 40, 50, 60, 50, 40, 60 percent: mean 50.
    let busy: [UInt64] = [0, 40, 90, 150, 200, 240, 300]
    let six = windows(busy.enumerated().map { (index, b) in (b, UInt64(index) * 100) })
    expect(six.percent == 50 && six.windows == 6 && six.unreadReason == nil,
           "six windows are averaged: 50 percent over 6 windows")
    let two = windows(Array(busy.prefix(3)).enumerated().map { (index, b) in (b, UInt64(index) * 100) })
    expect(two.percent == nil && two.windows == 2 && two.unreadReason == "windows",
           "two windows are too few: unread, reason windows")
    let three = windows(Array(busy.prefix(4)).enumerated().map { (index, b) in (b, UInt64(index) * 100) })
    expect(three.percent != nil && three.windows == 3, "three windows are enough")
    let none = windows([nil, nil, nil])
    expect(none.percent == nil && none.windows == 0 && none.unreadReason == "ticks",
           "counters that cannot be read: unread, reason ticks")
    let slept = windows([(0, 0), (40, 100), (90, 200), (150, 300), (200, 400)], every: 30)
    expect(slept.percent == nil && slept.windows == 0 && slept.unreadReason == "gap",
           "readings 30 seconds apart straddle a gap: each window is dropped, reason gap")
    let backwards = windows([(100, 200), (50, 300)])
    expect(backwards.windows == 0 && backwards.unreadReason == "ticks", "counters that go backwards drop the window")
    var timing = HostCPUWindows()
    expect(timing.due(at: t0), "the first reading is always due")
    timing.observe(busy: 0, total: 0, at: t0)
    expect(!timing.due(at: t0.addingTimeInterval(9)) && timing.due(at: t0.addingTimeInterval(10)),
           "…and the next is due ten seconds later")
    expect(timing.due(at: t0.addingTimeInterval(-5)), "…and at once if the clock went back")
    var reused = HostCPUWindows()
    for index in 0..<4 { reused.observe(busy: UInt64(index) * 90, total: UInt64(index) * 100,
                                        at: t0.addingTimeInterval(Double(index) * 10)) }
    _ = reused.take()
    expect(reused.take().windows == 0, "taking a minute starts the next one empty")

    // MARK: - What is published and written

    var standing = alarmed
    standing.lastAlarm = HostHealthAlarm(at: at(2), load1: 142, freeBytes: gigabyte, top: [], cpuPercent: 96)
    let published = HostHealthLogic.report(standing, reading: row(cpu: 96, free: 36, load: 142), at: at(3))
    expect(published.cpuPercent == 96 && published.cpuOver == true && published.cpuLimit == 90
            && abs((published.memoryAvailablePercent ?? 0) - 36) < 0.001 && published.load1 == 142,
           "the report carries cpuPercent, cpuOver, cpuLimit, memoryAvailablePercent, and keeps load1")
    let unreadReport = HostHealthLogic.report(alarmed, reading: row(cpu: nil, windows: 0), at: at(3))
    expect(unreadReport.cpuPercent == nil && unreadReport.cpuOver == nil,
           "an unread minute leaves cpuPercent and cpuOver out (a reader takes absent as not busy)")
    let text = String(decoding: encodeHostHealthReport(unreadReport) ?? Data(), as: UTF8.self)
    expect(!text.contains("cpuOver") && !text.contains("\"cpuPercent\"") && text.contains("\"cpuLimit\""),
           "…in the document too")
    expect(encodeHostHealthReport(published).flatMap(decodeHostHealthReport) == published,
           "the new fields survive a round trip")
    let old = #"{"cores":16,"freeBytes":1,"load1":227,"sampledAt":"2026-10-02T13:23:45Z","since":"2026-10-02T13:23:45Z","state":"normal"}"#
    let decoded = decodeHostHealthReport(Data(old.utf8))
    expect(decoded != nil && decoded?.cpuOver == nil && decoded?.cpuLimit == nil,
           "a report written before the CPU fields still decodes")
    let line = hostHealthLogLine(.alarm, report: published, now: at(3))
    expect(line.contains(" load=142 cores=16 cpu_pct=96 free="), "the log line keeps load= and gains cpu_pct=")
    expect(hostHealthCPUUnreadLine(reason: "gap", now: at(3)).hasSuffix(" host-health=cpu-unread reason=gap\n"),
           "the unread transition has its own line")
    let knocked = HostHealthKnockLogic.current(published, now: at(3).addingTimeInterval(5))
    expect(knocked.map { hostHealthKnockSentence($0, bytes: 200) }
            == Optional("[host-health] cpu=96% free=\(hostHealthGigabytes(published.freeBytes))GB"),
           "the knock sentence says cpu=, not load=")
}
