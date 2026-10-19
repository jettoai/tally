import Foundation

// WHO AN ALARM THAT IS STILL ON NAMES NEXT, and what an app that restarts into one remembers
// (B-2238). The state machine and the report are HostHealthLogic.swift; this half is only the app's
// (TallyCLI never names a leader or resumes a watch), so it is a file of its own rather than more
// lines in the one both targets compile.

extension HostHealthLogic {

    /// How long an alarm waits before it looks at the CPU list again: ten minutes, the CPU watch's
    /// own cooldown, so a machine that stays over the line is re-read at that pace and no faster.
    static let renameInterval: TimeInterval = 600

    /// Whose work a CPU list leads with, at the grain a person acts on: the checkout, else the
    /// session, else the responsible app, else the program's own name. A different session in the
    /// same checkout is the same leader.
    static func leaderKey(_ cpuTop: [HostHealthCPUProcess]?) -> String? {
        cpuTop?.first.map { $0.project ?? $0.session ?? $0.app ?? $0.name }
    }

    /// Whether an alarm that is still on should look at the CPU list again: only while the LOAD
    /// witness is still over the line (a memory alarm has no CPU list to refresh), and only once
    /// `renameInterval` has passed since the last time a leader was named.
    static func renameDue(_ tracker: HostHealthTracker, reading: HostHealthReading,
                          at now: Date) -> Bool {
        guard tracker.state == .alarmed, loadExceeds(reading), let named = tracker.namedAt else {
            return false
        }
        return now.timeIntervalSince(named) >= renameInterval
    }

    /// Fold a fresh CPU list into an alarm that is still on. The look is spent either way
    /// (`namedAt`), and the answer is true only when the leader is somebody else than the one last
    /// named: the same leader is never announced twice, and an empty list says nothing.
    static func rename(_ tracker: HostHealthTracker, cpuTop: [HostHealthCPUProcess],
                       at now: Date) -> (HostHealthTracker, Bool) {
        var next = tracker
        next.namedAt = now
        guard let key = leaderKey(cpuTop), key != tracker.namedLeader else { return (next, false) }
        next.namedLeader = key
        return (next, true)
    }

    /// The report a handover banner and its log line are written from: the published one with its
    /// alarm replaced by what is burning now. The tracker's own `lastAlarm` is left as the alarm
    /// raised it, so the published document never changes the meaning of a field.
    static func handoverReport(_ report: HostHealthReport, cpuTop: [HostHealthCPUProcess],
                               at now: Date) -> HostHealthReport {
        var out = report
        out.lastAlarm = HostHealthAlarm(at: now, load1: report.load1, freeBytes: report.freeBytes,
                                        top: [], cpuTop: cpuTop)
        return out
    }

    /// The watch to resume from the report a previous run of this app published, or nil for a fresh
    /// start. Only an ALARM that is still news (`staleAfter`) is resumed: an app that restarts into
    /// the same alarm it was announcing must not announce it again, while one that was closed for an
    /// hour starts counting again, as it always has. A machine that has since recovered clears the
    /// resumed alarm in the usual three samples.
    static func restore(_ report: HostHealthReport?, at now: Date) -> HostHealthTracker? {
        guard let report, report.state == .alarmed else { return nil }
        let age = now.timeIntervalSince(report.sampledAt)
        guard age >= -sampleInterval, age <= staleAfter else { return nil }
        var tracker = HostHealthTracker(state: .alarmed, since: report.since,
                                        lastAlarm: report.lastAlarm)
        tracker.namedAt = report.sampledAt
        tracker.namedLeader = leaderKey(report.lastAlarm?.cpuTop)
        return tracker
    }

    /// `restore` out of the report file itself. The read lives here, off the main actor's type, so
    /// the monitor's sample never touches the disk on the main thread.
    nonisolated static func restoreFromDisk(at now: Date) -> HostHealthTracker? {
        restore(decodeHostHealthReport(try? Data(contentsOf: hostHealthReportFile)), at: now)
    }
}
