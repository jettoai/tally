import Foundation

/// THE ONE-PROCESS CPU WATCH ITSELF (B-4496): reads the process table once a minute, folds it, tells.
/// The rules are ProcessCPUWatchLogic.swift's, the one reading is ProcessCPUWatchReaders.swift's.
///
/// THREE THINGS A READER OF THIS FILE WOULD OTHERWISE GET WRONG:
///
/// 1. `/bin/ps`, not libproc: libproc cannot read another user's process, and the process this
///    exists for (fseventsd, root, one core for an hour) is exactly that (see the readers file).
///    HostHealthMonitor and CPUAlertMonitor are locked against spawning anything, for a reason that
///    still holds for them; this watch is a separate file so those locks stay as they are.
/// 2. The clear is announced, unlike the other two watches, which log theirs: a single-process
///    alarm sends somebody to deal with that process, and the clear is what tells them to stop.
/// 3. State is memory only. After a relaunch a process that is still burning is counted again from
///    zero and announced a quarter of an hour later, which is still news for a process that has not
///    stopped; persisting would need pid-reuse and staleness handling for no better outcome.
///
/// Rides the footprint timer (`ProcessFootprintTiming.retime`) and throttles itself by the clock;
/// it opens no timer of its own.
@MainActor
final class ProcessCPUWatchMonitor {
    static let shared = ProcessCPUWatchMonitor()

    private var watch = ProcessCPUWatch()
    private var lastSampledAt: Date?
    private var inFlight = false
    private var unreadLogged = false
    /// Identities that already have an evidence file, so a process that alarms, clears and alarms
    /// again is captured once (B-4616). Memory only, like the watch.
    private var capturedIdentities = Set<String>()

    private init() {}

    func tick(now: Date = Date()) {
        guard ProcessCPUWatchLogic.isEnabled(.standard), !DemoUsage.isActive else {
            watch = ProcessCPUWatch()
            lastSampledAt = nil
            return
        }
        let limits = ProcessCPULimits.from(.standard)
        if let last = lastSampledAt, now.timeIntervalSince(last) < limits.sampleInterval { return }
        // A slow `ps` is skipped over, never queued behind itself.
        guard !inFlight else { return }
        lastSampledAt = now
        inFlight = true
        Task {
            await sample(limits: limits)
            inFlight = false
        }
    }

    private func sample(limits: ProcessCPULimits) async {
        // The instant before `ps` runs is the reading's time: CPU times are read a moment after it.
        let at = Date()
        let result = await Task.detached(priority: .utility) { ProcessCPUWatchReaders.table() }.value
        // Switched off while the table was being read: forget it, as `tick` would have.
        guard ProcessCPUWatchLogic.isEnabled(.standard) else { return }
        var rows: [ProcessCPURow] = []
        var failure: String?
        switch result {
        case .failure(let reason): failure = reason.rawValue
        case .success(let text):
            rows = ProcessCPUWatchLogic.parse(text, now: at)
            if !ProcessCPUWatchLogic.usable(rows, previous: watch) { failure = "short" }
        }
        if let failure {
            // A watch that cannot see must say so once, or a broken `ps` reads as a quiet machine.
            if !unreadLogged {
                unreadLogged = true
                let line = ProcessCPUWatchLogic.unreadLine(reason: failure, now: at)
                await Task.detached(priority: .utility) { Self.append(line) }.value
            }
            return
        }
        unreadLogged = false
        let (next, found) = ProcessCPUWatchLogic.advance(watch, rows: rows, at: at, limits: limits,
                                                         announcing: true)
        watch = next
        guard !found.isEmpty else { return }
        let seen = capturedIdentities
        let (events, plans) = await Task.detached(priority: .utility) {
            Self.record(found, at: at, seen: seen)
        }.value
        capturedIdentities.formUnion(plans.map(\.identity))
        // Started before the banner and not awaited: the banner names the file, never waits for it.
        Self.capture(plans)
        await post(events, at: at)
    }

    /// Off the main actor: who is responsible for each system alarm, which alarms get an evidence
    /// file (and under what name), then one log line per event.
    nonisolated private static func record(_ events: [ProcessCPUEvent], at now: Date,
                                           seen: Set<String>) -> ([ProcessCPUEvent], [ProcessForensicsPlan]) {
        var events = events
        var plans: [ProcessForensicsPlan] = []
        let existing = ProcessForensicsReaders.entries(
            in: ProcessForensicsLogic.directory(unshipped: BuildVariant.isUnshipped))
        for index in events.indices where events[index].kind == .alarm {
            let event = events[index]
            if ProcessCPUWatchLogic.owner(path: event.path) == .system {
                // Only at the moment of an alarm, not on every minute's reading.
                events[index].app = CPUAlertReaders.responsiblePath(of: event.pid).flatMap(CPUAlertLogic.appName)
            }
            let id = ProcessForensicsLogic.identity(pid: event.pid, startedAt: event.startedAt ?? event.since)
            switch ProcessForensicsLogic.decide(identity: id, seen: seen.union(plans.map(\.identity)),
                                                entries: existing, accepted: plans.count, now: now) {
            case .repeated: events[index].evidence = .skipped("repeat")
            case .rateLimited: events[index].evidence = .skipped("rate")
            case .capture:
                let name = ProcessCPUWatchLogic.name(event.path) { ProcessTree.displayName(forPath: $0) }
                let file = ProcessForensicsLogic.fileName(pid: event.pid, name: name, at: now)
                plans.append(ProcessForensicsPlan(pid: event.pid, name: name, path: event.path, percent: event.percent,
                                                  since: event.since, identity: id, fileName: file, capturedAt: now))
                events[index].evidence = .file(file, partial: !ProcessForensicsReaders.canRead(event.pid))
            }
        }
        for event in events {
            append(ProcessCPUWatchLogic.logLine(event, now: now) { ProcessTree.displayName(forPath: $0) })
        }
        return (events, plans)
    }

    /// A plain dispatch block each, not a Swift task: a capture holds its thread for the 10 s it
    /// watches, and the cooperative pool is not the place for that.
    nonisolated private static func capture(_ plans: [ProcessForensicsPlan]) {
        let directory = ProcessForensicsLogic.directory(unshipped: BuildVariant.isUnshipped)
        for plan in plans {
            DispatchQueue.global(qos: .utility).async {
                ProcessForensicsReaders.write(plan, probes: ProcessForensicsReaders.live(seconds: 10), directory: directory)
            }
        }
    }

    nonisolated private static func append(_ line: String) {
        HostHealthMonitor.append(line, to: ProcessCPUWatchLogic.logFile(unshipped: BuildVariant.isUnshipped))
    }

    /// At most one banner for the alarms of a reading and one for its clears, so eight workers of one
    /// program crossing together are one notification. A clear is sent only for an alarm that was.
    private func post(_ events: [ProcessCPUEvent], at now: Date) async {
        // Checked at delivery, as HostHealthMonitor does: the switch may have moved during the read.
        guard ProcessCPUWatchLogic.isEnabled(.standard) else { return }
        let displayName: (String) -> String? = { ProcessTree.displayName(forPath: $0) }
        let alarms = events.filter { $0.kind == .alarm && $0.announced }
        if !alarms.isEmpty {
            _ = await SystemAlert.post(
                title: ProcessCPUWatchLogic.alarmTitle(alarms, localized: L, displayName: displayName),
                body: ProcessCPUWatchLogic.alarmBody(alarms, now: now, localized: L, displayName: displayName))
        }
        let clears = events.filter { $0.kind != .alarm && $0.announced }
        if !clears.isEmpty {
            _ = await SystemAlert.post(
                title: ProcessCPUWatchLogic.clearTitle(clears, localized: L, displayName: displayName),
                body: ProcessCPUWatchLogic.clearBody(clears, localized: L, displayName: displayName))
        }
    }
}
