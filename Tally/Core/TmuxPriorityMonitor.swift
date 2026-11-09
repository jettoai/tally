import Foundation

/// THE TMUX PRIORITY WATCH ITSELF (B-4266): rides the footprint sampler's tick
/// (`ProcessFootprintTiming.retime`), the way `HostHealthMonitor` and `CPUAlertMonitor` do, and
/// throttles itself to one scan a minute by the clock. It opens no timer of its own, ends nothing
/// and only tells: restarting tmux closes every window under it, which is the user's decision.
///
/// It speaks through the host-health banner switch (`HostHealthLogic.alertsEnabled`) and writes
/// to the same `host-health.log`. State is memory: a restart of Tally announces a server that is
/// still low once more, which is the honest reading of "this process has not told anyone".
@MainActor
final class TmuxPriorityMonitor {
    static let shared = TmuxPriorityMonitor()

    private var tracker = TmuxPriorityTracker()
    private var lastSampledAt: Date?
    private var inFlight: Task<Void, Never>?

    private init() {}

    func tick(now: Date = Date()) {
        guard HostHealthLogic.alertsEnabled(.standard), !DemoUsage.isActive else {
            tracker = TmuxPriorityTracker()
            lastSampledAt = nil
            return
        }
        if let last = lastSampledAt, now.timeIntervalSince(last) < TmuxPriorityLogic.sampleInterval {
            return
        }
        lastSampledAt = now
        guard inFlight == nil else { return }
        inFlight = Task {
            defer { inFlight = nil }
            // The process-table walk is off the main actor: it is the one reading here that grows
            // with the machine.
            let readings = await Task.detached(priority: .utility) { TmuxPriorityReaders.scan() }.value
            for reading in tracker.fold(readings) {
                let line = tmuxPriorityLogLine(reading, now: now)
                await Task.detached(priority: .utility) { HostHealthMonitor.append(line) }.value
                // A refused banner is not retried: the log line is written and the next server
                // (or the restart that fixes this one) re-arms the guard.
                _ = await SystemAlert.post(title: tmuxPriorityAlertTitle(localized: L),
                                           body: tmuxPriorityAlertBody(priority: reading.priority ?? 0,
                                                                       localized: L),
                                           at: now)
            }
        }
    }
}
