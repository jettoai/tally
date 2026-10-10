import Foundation
import UserNotifications

/// Says out loud that an account's weekly leftovers are about to reset unused (`ClearanceIdleAlert`).
/// Driven by the usage refresh, like the pool and reset-hint alerts; keeps no timer of its own.
@MainActor
final class ClearanceIdleNotifier {
    static let shared = ClearanceIdleNotifier()
    nonisolated static let categoryID = "ai.jetto.tally.clearanceIdle"
    /// Only for routing: the body opens the window rather than falling into the redeem branch.
    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [], intentIdentifiers: [])
    }
    /// Each account's last announced cycle, `[accountID: resetKey]`.
    private let stateKey = "ai.jetto.tally.clearanceIdle.announced"
    private var reading = false

    private init() {}

    func evaluate(accounts: [AccountUsage], now: Date = Date()) {
        guard !reading else { return }
        let candidates = Self.candidates(accounts, now: now)
        guard !candidates.isEmpty else { return }
        reading = true
        Task {
            // Unreadable is not "no sessions": `liveAccountCounts` answers an empty map for a
            // missing directory, which would read as every account idle. Off the main thread, both.
            let live = await Task.detached { () -> [String: Int]? in
                FileManager.default.fileExists(atPath: supervisorStateDir.path)
                    ? ProbeCadence.liveAccountCounts() : nil
            }.value
            defer { self.reading = false }
            for c in ClearanceIdleAlert.due(candidates, live: live, announced: self.load(), now: now) {
                guard await self.post(c) else { continue }
                var state = self.load().filter { _, key in
                    (Double(key) ?? 0) > now.timeIntervalSince1970 - 86_400
                }
                state[c.accountID] = DryPoolLogic.resetKey(c.resetsAt)
                UserDefaults.standard.set(state, forKey: self.stateKey)
            }
        }
    }

    /// The accounts the clearance rule would spend, read the way the auto pick reads them
    /// (`LaunchPolicyStore.autoPickID`): fresh, launchable, and through the owner's reserve.
    private static func candidates(_ accounts: [AccountUsage], now: Date) -> [ClearanceIdleCandidate] {
        let discovered = UsageStore.shared.discoveredAccounts
        let launchable = Set(discovered.compactMap { $0.launchableHome != nil ? $0.id : nil })
        let reserves = PersonalAccount.reserves(accounts, discovered: discovered)
        return accounts.compactMap { u in
            guard u.error == nil, !u.isStale, !u.lastRefreshFailed, launchable.contains(u.id) else {
                return nil
            }
            let windows = LaunchPolicyStore.clearanceWindows(
                u, primaryModel: LaunchPolicyStore.shared.policy(u.providerID).model,
                reserve: reserves[u.id] ?? 0, now: now)
            return clearanceLeftover(windows, now: now).map {
                ClearanceIdleCandidate(accountID: u.id, label: u.accountLabel,
                                       remaining: $0.remaining, resetsAt: $0.resetsAt)
            }
        }
    }

    /// Post one sample (the `-TallyClearanceIdleTest` launch flag): the alert's look, without
    /// touching the persisted announcements.
    func postSampleNotification() {
        let sample = ClearanceIdleCandidate(accountID: "sample", label: "Claude", remaining: 3,
                                            resetsAt: Date().addingTimeInterval(47 * 60))
        Task { _ = await post(sample) }
    }

    private func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: stateKey) as? [String: String] ?? [:]
    }

    private func post(_ c: ClearanceIdleCandidate) async -> Bool {
        let when = UsageFormat.noticeCountdown(c.resetsAt)
        let title = String(format: L("%@ has unused quota about to reset"), c.label)
        let body = String(format: L("%1$@ of its weekly window is left and no session is using it. It resets in %2$@ (%3$@)."),
                          "\(Int(c.remaining.rounded()))%", when.countdown, when.clock)
        return await SystemAlert.post(title: title, body: body, categoryID: Self.categoryID)
    }
}
