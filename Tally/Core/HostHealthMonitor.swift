import Foundation

/// THE WATCH ITSELF: what runs a sample, what it writes, and who it tells. Glue between the pure
/// rules (HostHealthLogic.swift) and the syscalls (HostHealthReaders.swift), on the division
/// `DryPoolNotifier` keeps from `DryPoolLogic`.
///
/// IT KEEPS NO TIMER OF ITS OWN, which is the point of putting it here rather than in a daemon.
/// The footprint sampler already ticks for the life of the process (every two seconds with the
/// board up, every ten behind it), and this rides that tick and throttles itself to one sample a
/// minute by the clock (`ProcessFootprintTiming.retime` is where it is called). A second timer
/// would be a second thing to get wrong for a reading that is one minute coarse.
///
/// THE STATE IS MEMORY AND IS NOT PERSISTED. A restart begins the run count again, which is the
/// honest reading of "this process has not been watching": the alternative is an app that comes up
/// after an update, reads a run of three from an hour ago and announces a machine that is fine.
///
/// IT ENDS NOTHING. This version samples, publishes, logs and tells. Nothing here kills a process
/// or stops a supervisor, and the incident that produced it wanted that separated so the reporting
/// half could be trusted first.
@MainActor
final class HostHealthMonitor {
    static let shared = HostHealthMonitor()

    private var tracker = HostHealthTracker()
    /// When the last sample was taken, which is the whole of the throttle. Nil before the first,
    /// so the first tick after launch samples at once rather than a minute later.
    private var lastSampledAt: Date?

    private init() {}

    /// Volatile launch flag (argument domain, so nothing persists): `-TallyHostHealthTest`
    /// reports a load of 300 to the rules instead of the machine's own, which walks the alarm
    /// branch on a quiet machine. The memory reading is left alone, so what a run of this proves
    /// is exactly the path a real alarm takes: three samples over the line, one notification, one
    /// log line, one report with the top three in it.
    ///
    /// THE RUN IS NOT SHORTENED WITH IT, deliberately: a flag that also changed the threshold rule
    /// would verify a path the machine never takes. Three samples at one minute each is what it
    /// costs to watch this happen.
    private lazy var testLoad: Double? =
        UserDefaults.standard.bool(forKey: "TallyHostHealthTest") ? 300 : nil

    /// One tick of whatever is driving the sampler. Almost every one of these is a clock comparison
    /// and nothing else.
    func tick(now: Date = Date()) {
        if let last = lastSampledAt, now.timeIntervalSince(last) < HostHealthLogic.sampleInterval {
            return
        }
        lastSampledAt = now
        sample(at: now)
    }

    /// One sample: read, fold, publish, and say something only if the machine has just crossed.
    private func sample(at now: Date) {
        // A machine that will not answer is not a machine that is fine: nothing is folded in,
        // because a reading of zero free bytes would raise an alarm and a reading of zero load
        // would clear one. The next sample asks again.
        guard var reading = HostHealthReaders.reading() else { return }
        if let testLoad { reading.load1 = testLoad }
        let (next, event) = HostHealthLogic.advance(tracker, reading: reading, at: now)
        tracker = next
        // THE EXPENSIVE READING HAPPENS HERE AND NOWHERE ELSE: only the sample that RAISES an alarm
        // walks the process table, so the steady state pays for two syscalls a minute and nothing
        // more (`HostHealthReaders.heaviest`).
        if event == .alarm {
            tracker.lastAlarm = HostHealthAlarm(at: now, load1: reading.load1,
                                                freeBytes: reading.freeBytes,
                                                top: HostHealthReaders.heaviest())
        }
        let report = HostHealthLogic.report(tracker, reading: reading, at: now)
        publish(report)
        guard let event else { return }
        append(hostHealthLogLine(event, report: report, now: now))
        // A RECOVERY IS WRITTEN DOWN AND NOT ANNOUNCED. Somebody reading the log afterwards needs
        // to know when it ended; nobody needs a banner saying their machine is working again.
        if event == .alarm { post(report) }
    }

    // MARK: Publishing

    /// Rewrite `~/.tally/host-health.json`. Atomic, because the readers are other processes: a
    /// `tally status` that read this file mid-write would print a parse failure as an absent
    /// section, which is the one answer this file must never produce by accident.
    private func publish(_ report: HostHealthReport) {
        guard let data = encodeHostHealthReport(report) else { return }
        let file = hostHealthReportFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // `.atomic` is a write to a neighbouring temporary and a `rename(2)` over the destination,
        // which is one act for every reader: nobody sees a half-written document, and nobody sees
        // the file missing either. The same primitive `~/.tally/snapshot.json` is published with
        // (`UsageSnapshot.write`), and for the same reason: another process reads it.
        try? data.write(to: file, options: .atomic)
    }

    /// Append one line to `~/.tally/logs/host-health.log`.
    ///
    /// 0644 LIKE ITS NEIGHBOURS AND UNLIKE `input.log`, which is the distinction that file's own
    /// note draws: this holds events ABOUT the machine (a load average, a free figure, three
    /// executable names), not content out of somebody's conversation.
    private func append(_ line: String) {
        let file = hostHealthLogFile
        let payload = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? payload.write(to: file)
        }
    }

    /// One banner, through the same authorization the other alerts ask for (`SystemAlert.post`
    /// requests it and answers whether the alert will actually be seen).
    ///
    /// THE DELIVERY RESULT IS NOT CONSULTED, on the terms `DryPoolNotifier` states: this alert
    /// re-arms on its own as soon as the machine recovers and crosses again, so a refused one comes
    /// back around without any bookkeeping.
    private func post(_ report: HostHealthReport) {
        let top = hostHealthTopText(report.lastAlarm?.top ?? [], unit: "GB")
        let body = String(format: L("load %1$@ (%2$@ cores) · free %3$@ GB · top: %4$@"),
                          hostHealthFigure(report.load1), String(report.cores),
                          hostHealthGigabytes(report.freeBytes),
                          top.isEmpty ? L("unknown") : top)
        let title = L("Host under pressure")
        Task { _ = await SystemAlert.post(title: title, body: body) }
    }
}
