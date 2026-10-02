import Foundation
import UserNotifications

/// THE CPU WATCH ITSELF: samples, folds, tells. Rides the footprint sampler's timer
/// (`ProcessFootprintTiming.retime`) and throttles itself by the clock; opens no timer of its own.
/// State is memory and not persisted, for the reason HostHealthMonitor gives.
@MainActor
final class CPUAlertMonitor {
    static let shared = CPUAlertMonitor()

    nonisolated static let categoryID = "cpuAlert"
    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [], intentIdentifiers: [])
    }

    private var tracker = CPUAlertTracker()
    private var lastSampledAt: Date?

    private init() {}

    /// Volatile launch flag: `-TallyCPUAlertTest` reports the machine as 97% busy to the rules
    /// instead of its own reading, so a quiet machine walks the alarm branch. The run is NOT
    /// shortened: thirty real seconds, the path a real alarm takes.
    private lazy var testBusy: Bool = UserDefaults.standard.bool(forKey: "TallyCPUAlertTest")

    func tick(now: Date = Date()) {
        guard CPUAlertLogic.isEnabled(.standard), !DemoUsage.isActive else {
            tracker = CPUAlertTracker()
            lastSampledAt = nil
            return
        }
        if let last = lastSampledAt, now.timeIntervalSince(last) < CPUAlertLogic.sampleInterval {
            return
        }
        lastSampledAt = now
        guard var ticks = CPUAlertReaders.ticks() else { return }
        if testBusy, let old = tracker.lastTicks {
            let newTotal = ticks.user + ticks.system + ticks.idle + ticks.nice
            let oldTotal = old.user + old.system + old.idle + old.nice
            if newTotal >= oldTotal {
                // 97 busy for every 3 idle since the last reading, whatever the machine did.
                let total = newTotal - oldTotal
                ticks = CPUTicks(user: old.user + total * 97 / 100, system: old.system,
                                 idle: old.idle + total - total * 97 / 100, nice: old.nice)
            }
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let load = ProcessFootprintStore.shared.machineLoad
        let projects = CPUAlertLogic.projectCulprits(
            load.projects.map { CPUAlertProjectInput(name: $0.name, oneCorePercent: $0.cpuPercent) },
            cores: cores)
        let busy = CPUAlertLogic.lastBusy(tracker, ticks)
        let host = HostHealthMonitor.shared
        let (next, event) = CPUAlertLogic.advance(tracker, ticks: ticks,
                                                  leader: CPUAlertLogic.leader(projects),
                                                  hostAlarmed: host.isAlarmed,
                                                  hostAlarmAt: host.lastAlarmAt, at: now)
        let alarmSince = next.alarmSince ?? tracker.alarmSince
        tracker = next
        guard let event, let busy else { return }
        let roots = Set(load.projects.map(\.root))
        let announce: Bool = switch event {
        case .alarm(let silence): silence == nil
        case .handover: true
        case .clear: false
        }
        Task {
            // THE EXPENSIVE READING HAPPENS ONLY HERE: a banner is going out and the rollup cannot
            // explain most of the load.
            var others: [CPUAlertCulprit] = []
            if announce, CPUAlertLogic.needsProcessScan(projects, busy: busy) {
                others = await Task.detached(priority: .utility) {
                    await CPUAlertReaders.unattributed(roots: roots, cores: cores)
                }.value
            }
            let named = CPUAlertLogic.named(projects: projects, others: others)
            let line = CPUAlertLogic.logLine(event, busy: busy, cores: cores, culprits: named, now: now)
            // A file of its own, so two detached appends never race on host-health.log.
            await Task.detached(priority: .utility) {
                HostHealthMonitor.append(line, to: cpuAlertLogFile)
            }.value
            guard announce else { return }
            post(event, busy: busy, held: CPUAlertLogic.heldSeconds(since: alarmSince, now: now),
                 culprits: named)
        }
    }

    /// The category carries no button, so the set registered at launch
    /// (`NotificationRouter.refreshCategories`) is all the routing needs.
    private func post(_ event: CPUAlertEvent, busy: Double, held: Int, culprits: [CPUAlertCulprit]) {
        let shares = CPUAlertLogic.namedShares(culprits)
        // Empty reads as the existing "unknown" banner (still the "mostly" wording): every other
        // outcome is `share`d or not, never mixed, by `namedShares`' own leader test.
        let names: String
        let hasShares: Bool
        if shares.isEmpty {
            names = L("unknown")
            hasShares = true
        } else if shares[0].share != nil {
            names = shares.map {
                String(format: L("%1$@ (%2$@%% of the machine)"), $0.name, String($0.share!))
            }.joined(separator: L(", "))
            hasShares = true
        } else {
            names = shares.map(\.name).joined(separator: L(", "))
            hasShares = false
        }
        let percent = String(Int(busy.rounded()))
        // The first name rides in the title too: macOS summarises stacked banners from titles.
        let first = shares.first?.name
        let title: String
        let body: String
        if event == .handover {
            title = first.map { String(format: L("CPU still running hot: %@"), $0) }
                ?? L("CPU still running hot")
            body = hasShares
                ? String(format: L("CPU %1$@%% · now mostly %2$@"), percent, names)
                : String(format: L("CPU %1$@%% · no single cause: %2$@"), percent, names)
        } else {
            title = first.map { String(format: L("CPU running hot: %@"), $0) } ?? L("CPU running hot")
            body = hasShares
                ? String(format: L("CPU %1$@%% for %2$@ seconds · mostly %3$@"), percent, String(held), names)
                : String(format: L("CPU %1$@%% for %2$@ seconds · no single cause: %3$@"),
                        percent, String(held), names)
        }
        Task { _ = await SystemAlert.post(title: title, body: body, categoryID: Self.categoryID) }
    }
}
