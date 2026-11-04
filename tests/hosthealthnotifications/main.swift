import Foundation
import Synchronization

// Exercise the real monitor with deterministic machine readers and a recording notification sink.
// No real notifications, account access, or writes to the user's Tally directory.
enum HostAlarmMirror { static let isAlarmed = Mutex(false) }
@MainActor struct SessionRosterStore {
    static let shared = SessionRosterStore()
    var rows: [Row] { [] }
    struct Row { var id: String; var childPid: Int?; var accountID: String }
}
enum HostHealthReaders {
    static let scans = Mutex(0)
    static func reading() -> HostHealthReading? {
        if ProcessInfo.processInfo.environment["TALLY_TEST_MEMORY"] == "1" {
            return HostHealthReading(load1: 1, cores: 8, freeBytes: 1_073_741_824)
        }
        return HostHealthReading(load1: 157, cores: 8, freeBytes: 9 * 1_073_741_824)
    }
    static func heaviest() -> [HostHealthProcess] { [] }
    static func threadCensus() -> HostHealthThreads {
        HostHealthThreads(running: 5, uninterruptible: 0, total: 50, processes: 10, top: [])
    }
    static func busiest(sessions: [HostHealthSession]) async -> [HostHealthCPUProcess] {
        let scan = scans.withLock { count in count += 1; return count }
        if ProcessInfo.processInfo.environment["TALLY_TEST_SCAN_MUTE"] == "1" {
            // Model a user switching off while the culprit scan is suspended.
            await MainActor.run { UserDefaults.standard.set(false, forKey: "hostHealthAlertEnabled") }
        }
        return [HostHealthCPUProcess(name: scan == 1 ? "Slack" : "Chrome", percent: 18, system: false)]
    }
}
func L(_ value: String) -> String { value }
@MainActor enum SystemAlert {
    static var titles: [String] = []
    static func post(title: String, body: String) async -> Bool {
        titles.append(title)
        return true
    }
}

@main struct Check {
    @MainActor static func main() async throws {
        guard FileManager.default.homeDirectoryForCurrentUser.path == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            fatalError("test home is not isolated")
        }
        let suiteName = "host-health-alert-tests-" + UUID().uuidString
        let isolated = UserDefaults(suiteName: suiteName)!
        defer { isolated.removePersistentDomain(forName: suiteName) }
        precondition(HostHealthLogic.alertsEnabled(isolated), "fresh installs keep existing alerts")
        isolated.set(false, forKey: "cpuAlertEnabled")
        precondition(!HostHealthLogic.alertsEnabled(isolated), "legacy CPU opt-out is respected")
        // The same seed SettingsStore writes during initialization, before either switch changes.
        isolated.set(HostHealthLogic.alertsEnabled(isolated), forKey: HostHealthLogic.alertEnabledKey)
        isolated.set(true, forKey: "cpuAlertEnabled")
        precondition(!HostHealthLogic.alertsEnabled(isolated), "CPU changes cannot undo a seeded opt-out")
        isolated.set(true, forKey: HostHealthLogic.alertEnabledKey)
        isolated.set(false, forKey: "cpuAlertEnabled")
        precondition(HostHealthLogic.alertsEnabled(isolated), "explicit host opt-in is independent")
        precondition(HostHealthLogic.alertsEnabled(UserDefaults(suiteName: suiteName)!), "choice survives reopening defaults")
        let store = try String(contentsOfFile: "Tally/Stores/SettingsStore.swift", encoding: .utf8)
        let pane = try String(contentsOfFile: "Tally/Views/SettingsDisplayPane.swift", encoding: .utf8)
        precondition(store.contains("defaults.set(hostAlerts, forKey: HostHealthLogic.alertEnabledKey)"), "SettingsStore seeds the independent preference")
        precondition(pane.contains("isOn: $settings.hostHealthAlertEnabled"), "the native switch is bound to the preference")
        let defaults = UserDefaults.standard
        for key in ["cpuAlertEnabled", "hostHealthAlertEnabled"] {
            defaults.removeObject(forKey: key)
            if let value = ProcessInfo.processInfo.environment[key] {
                defaults.set(value == "1", forKey: key)
            }
        }
        let start = Date()
        // The final sample changes the leader after the ten-minute handover interval.
        for minute in [0, 1, 2, 12] {
            let now = start.addingTimeInterval(Double(minute) * 60)
            HostHealthMonitor.shared.tick(now: now)
            var published = false
            for _ in 0..<200 {
                try await Task.sleep(for: .milliseconds(10))
                if let data = try? Data(contentsOf: hostHealthReportFile),
                   let report = decodeHostHealthReport(data),
                   abs(report.sampledAt.timeIntervalSince(now)) < 1 {
                    published = true
                    break
                }
            }
            guard published else { fatalError("monitor did not publish sample \(minute)") }
        }
        // Let the main-actor notification task run after the final publish.
        try await Task.sleep(for: .milliseconds(20))
        let expected = Int(ProcessInfo.processInfo.environment["TALLY_TEST_EXPECTED"]!)!
        let report = decodeHostHealthReport(try Data(contentsOf: hostHealthReportFile))!
        guard report.state == .alarmed else { fatalError("muting must not stop health reporting") }
        guard SystemAlert.titles.count == expected else {
            print("FAIL: expected \(expected) host-health notifications, got \(SystemAlert.titles.count); report remains alarmed")
            exit(1)
        }
        print("PASS: \(expected) host-health notifications; alarm report still published")
    }
}
