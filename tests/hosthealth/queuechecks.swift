import Foundation

// B-4171: the run queue per core (1-minute load / cores) and its level, published in the report.
// Display only: none of this may change what the alarm decides.

func runQueueChecks() {
    let physical: UInt64 = 128 * gigabyte
    func reading(load: Double, cores: Int) -> HostHealthReading {
        HostHealthReading(load1: load, cores: cores, freeBytes: 36 * gigabyte / 100 * 100,
                          cpuPercent: 47.6, cpuWindows: 6, physicalBytes: physical)
    }
    func report(load: Double, cores: Int) -> HostHealthReport {
        HostHealthLogic.report(HostHealthTracker(), reading: reading(load: load, cores: cores), at: t0)
    }

    // The 2026-11-07 18:33 sample: CPU 47.6%, load 68.6 on 16 cores, which the card could not show.
    let jam = report(load: 68.6, cores: 16)
    expect(abs((jam.queuePerCore ?? 0) - 4.2875) < 0.001 && jam.queueLevel == .red,
           "queue: load 68.6 on 16 cores is 4.29 per core, red")
    expect(report(load: 8, cores: 16).queueLevel == .green, "queue: load 8 on 16 cores is green")
    expect(report(load: 32, cores: 16).queueLevel == .green, "queue: exactly 2 per core is still green")
    expect(report(load: 33, cores: 16).queueLevel == .yellow, "queue: over 2 per core is yellow")
    expect(report(load: 64, cores: 16).queueLevel == .yellow, "queue: exactly 4 per core is still yellow")
    expect(HostHealthLogic.queuePerCore(load1: 10, cores: 0) == nil
            && HostHealthLogic.queuePerCore(load1: 10, cores: -4) == nil
            && HostHealthLogic.queuePerCore(load1: -1, cores: 16) == nil,
           "queue: zero or negative cores, negative load give nil (no division by zero)")
    let noCores = report(load: 10, cores: 0)
    expect(noCores.queuePerCore == nil && noCores.queueLevel == nil, "queue: the report leaves both fields out")

    expect(encodeHostHealthReport(jam).flatMap(decodeHostHealthReport) == jam, "queue: survives a round trip")
    let old = #"{"cores":16,"freeBytes":1,"load1":227,"sampledAt":"2026-10-02T13:23:45Z","since":"2026-10-02T13:23:45Z","state":"normal"}"#
    let decoded = decodeHostHealthReport(Data(old.utf8))
    expect(decoded != nil && decoded?.queuePerCore == nil && decoded?.queueLevel == nil,
           "queue: a report written before the fields still decodes")
}
