import Foundation
import UserNotifications

/// The one way Tally raises a macOS notification. Each notifier decides WHEN to speak and composes
/// its own words; the delivery mechanics (and their two subtleties) live here once.
enum SystemAlert {
    /// Post one alert. `categoryID` is what puts an action button on it, and `userInfo` is what the
    /// delegate routes that button on; an alert with neither is read-only news.
    ///
    /// Returns whether the alert will actually reach the user, which a caller that only ever says a
    /// thing ONCE has to know: authorization is asked first (it answers true when already granted),
    /// and a denial is not a delivery. Turning notifications on an hour later must not find that the
    /// one announcement was spent on a system that refused to show it.
    ///
    /// The content is built here rather than by the caller so no non-Sendable notification value
    /// crosses an actor boundary.
    @MainActor
    static func post(title: String, body: String, categoryID: String? = nil,
                     userInfo: [String: String] = [:]) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryID { content.categoryIdentifier = categoryID }
        content.userInfo = userInfo
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                       content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }
}
