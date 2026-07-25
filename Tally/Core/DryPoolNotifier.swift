import Foundation
import UserNotifications

/// Glue between the flagship fleet pool and macOS notifications. Owns the persisted dedup state,
/// runs the pure `DryPoolLogic` after each refresh, and posts a system notification when a tier
/// crosses for the first time this reset cycle. It keeps no timer of its own: the existing refresh
/// loop drives it.
@MainActor
final class DryPoolNotifier {
    static let shared = DryPoolNotifier()

    /// UserDefaults key for the persisted dedup state (one flagship pool: claude).
    private let stateKey = "ai.jetto.tally.dryPool.claude.state"
    private var didRequestAuth = false

    private init() {}

    /// Feed the claude flagship pool after a refresh. An `accountCount` below two disarms the alert
    /// entirely (the lone-account steady state), so nothing is requested, evaluated or posted.
    func evaluate(remaining: Double, capacity: Double, accountCount: Int, resetAt: Date?,
                  windowName: String) {
        guard accountCount >= 2 else { return }
        requestAuthorizationIfNeeded()
        let (next, notification) = DryPoolLogic.advance(
            state: loadState(), remaining: remaining, capacity: capacity,
            accountCount: accountCount, resetAt: resetAt)
        saveState(next)
        if let notification {
            post(notification, remaining: remaining, capacity: capacity, resetAt: resetAt,
                 windowName: windowName)
        }
    }

    /// Post one sample low-tier notification (the `-TallyDryNotifyTest` launch flag): verifies the
    /// permission prompt and the notification's look without touching persisted state.
    func postSampleNotification() {
        requestAuthorizationIfNeeded()
        post(.low, remaining: 9, capacity: 200,
             resetAt: Date().addingTimeInterval(3 * 86_400), windowName: "Fable")
    }

    // MARK: State persistence

    private func loadState() -> DryPoolState {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(DryPoolState.self, from: data) else {
            return DryPoolState()
        }
        return state
    }

    private func saveState(_ state: DryPoolState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }

    // MARK: Notifications

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(_ notification: DryNotification, remaining: Double, capacity: Double,
                      resetAt: Date?, windowName: String) {
        let reset = shortDate(resetAt)
        let remainingText = Self.figure(remaining)
        let capacityText = Self.figure(capacity)
        let title: String
        let body: String
        switch notification {
        case .low:
            title = String(format: L("%@ pool nearly dry"), windowName)
            body = String(format: L("%1$@ of %2$@ left, resets %3$@"),
                          remainingText, capacityText, reset)
        case .dry:
            title = String(format: L("%@ pool is dry across accounts"), windowName)
            body = String(format: L("0 of %1$@ left until %2$@"), capacityText, reset)
        }
        // No category: the pool alert is news, with nothing to press. The delivery result is not
        // consulted because this alert re-arms on its own, as soon as the pool recovers above the
        // re-arm line, so a refused one comes back around without bookkeeping.
        Task { _ = await SystemAlert.post(title: title, body: body) }
    }

    /// Pool figures are whole "accounts' worth" units; show them as rounded integers.
    private static func figure(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private func shortDate(_ date: Date?) -> String {
        guard let date else { return L("soon") }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute()
            .locale(AppLocale.current))
    }
}
