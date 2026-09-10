import Foundation
import Observation
import OSLog

/// Read-only login health beyond the local CLI status: live session failures and refresh deadlines.
@MainActor
@Observable
final class LoginHealthStore {
    static let shared = LoginHealthStore()
    private(set) var sessions: [LoginHealthSession] = []
    private(set) var deadlines: [String: Date] = [:]
    private var checkedAt: Date?
    private var reading = false
    private var generations: [String: Int] = [:]
    private var known: Set<String> = []
    private var labels: [String: String] = [:]
    private var alerts: LoginHealthAlerts
    private static let stateKey = "ai.jetto.tally.loginHealth.alerts"
    private static let log = Logger(subsystem: "ai.jetto.tally", category: "login-health")

    private init() {
        if !DemoUsage.isActive,
           let data = UserDefaults.standard.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode(LoginHealthAlerts.self, from: data) {
            alerts = saved
        } else { alerts = LoginHealthAlerts() }
        SessionRosterStore.shared.onLoginHealthChange = { [weak self] in self?.refreshSessions() }
    }

    func problems(_ accountID: String) -> [LoginHealthSession] {
        if DemoUsage.loginHealthPreview && ["claude:demo-Claude 2", "claude:demo-Claude 3"].contains(accountID) {
            return [LoginHealthSession(id: "demo", accountID: accountID, childPid: nil,
                                       directory: nil, failedAt: Date())]
        }
        return sessions.filter { $0.accountID == accountID }
    }

    func deadline(_ accountID: String) -> Date? {
        if DemoUsage.loginHealthPreview {
            if ["claude:demo-Claude 2", "claude:demo-Claude 4"].contains(accountID) { return Date().addingTimeInterval(2 * 86400) }
            if accountID == "claude:demo-Claude" { return Date().addingTimeInterval(-3600) }
        }
        return deadlines[accountID]
    }

    func expiryState(_ accountID: String) -> ClaudeLoginExpiry.State {
        ClaudeLoginExpiry.state(deadline: deadline(accountID))
    }

    func refreshSessions() {
        guard !DemoUsage.isActive else { return }
        sessions = SessionRosterStore.shared.rows.compactMap { row in
            guard let failedAt = row.record?.loginRequiredAt, let accountID = row.accountID else { return nil }
            return LoginHealthSession(id: row.id + ":" + String(row.childPid ?? 0) + ":" + accountID,
                                      accountID: accountID, childPid: row.childPid,
                                      directory: row.directory, failedAt: failedAt)
        }
        announce()
    }

    /// The usage refresh loop checks threshold crossings; metadata reads have a five-minute ceiling.
    func evaluate(accounts: [ProviderAccount], known: Set<String>, userInitiated: Bool) async {
        guard !DemoUsage.isActive else { return }
        self.known = known
        labels = Dictionary(accounts.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        SessionRosterStore.shared.refresh()
        refreshSessions()
        guard !reading else { return }
        let now = Date()
        guard userInitiated || checkedAt == nil || now.timeIntervalSince(checkedAt!) >= 300 else {
            announce()
            return
        }
        reading = true
        defer { reading = false }
        checkedAt = now
        let mark = generations
        var next: [String: Date] = [:]
        await withTaskGroup(of: (String, Date?).self) { group in
            for account in accounts where account.providerID == "claude" {
                guard let home = account.launchHome else { continue }
                group.addTask {
                    let result = await ClaudeLoginExpiry.read(home: home)
                    return (account.id, result.refreshTokenExpiresAt)
                }
            }
            for await (id, deadline) in group { next[id] = deadline }
        }
        deadlines = next.filter { self.known.contains($0.key) && mark[$0.key] == generations[$0.key] }
        announce()
    }

    /// Retire metadata read before a credential change without clearing live session incidents.
    func invalidate(_ accountID: String) {
        deadlines[accountID] = nil
        generations[accountID, default: 0] += 1
        checkedAt = nil
    }

    /// A person explicitly chose the incident. Re-resolve against live rows before focusing it.
    func openSession(_ id: String) {
        guard !DemoUsage.isActive else { return }
        SessionRosterStore.shared.refresh()
        refreshSessions()
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let handover = TerminalJump.prepare()
        Task { await TerminalJump.jump(directory: session.directory, childPid: session.childPid, from: handover) }
    }

    private func announce() {
        guard !BuildVariant.isUnshipped, !DemoUsage.isActive else { return }
        // A roster event can precede discovery. Do not prune persisted account deadlines until known.
        let existing = known.isEmpty ? Set(alerts.deadlines.keys) : known
        let fresh = alerts.advance(sessions: sessions, deadlines: deadlines, known: existing, now: Date())
        save()
        for alert in fresh {
            Self.log.info("state=\(alert.kind.rawValue, privacy: .public) source=login-health account=\(alert.accountID, privacy: .private(mask: .hash)) time=\(Date().timeIntervalSince1970, privacy: .public)")
            let label = SettingsStore.shared.displayLabel(accountID: alert.accountID,
                                                          fallback: labels[alert.accountID] ?? alert.accountID)
            Task { @MainActor in
                guard await LoginHealthNotification.post(alert, label: label) == false else { return }
                alerts.rearm(alert)
                save()
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(alerts) else { return }
        UserDefaults.standard.set(data, forKey: Self.stateKey)
    }
}
