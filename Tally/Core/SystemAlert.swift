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
    ///
    /// `at` is when the thing being reported happened; the body opens with its clock time so an alert
    /// read later still says when. It defaults to now, which is the event time for every
    /// caller that posts the moment it detects; a caller that posts a queued event passes its time.
    @MainActor
    static func post(title: String, body: String, categoryID: String? = nil,
                     userInfo: [String: String] = [:], at: Date = Date()) async -> Bool {
        let body = stampedBody(body, at: at)
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

    /// `post`, but never waits longer than `seconds` for the answer: on a Mac that has not yet
    /// decided on notifications `post` blocks until the user clicks the system's permission banner,
    /// and the caller's next step (a login process) must not hang on that. The banner is on screen
    /// by then, which is itself the signal, so an unanswered post counts as delivered; an answer
    /// that arrives in time (a denial included) is passed on as it is.
    @MainActor
    static func postWithin(_ seconds: Double, title: String, body: String) async -> Bool {
        await withCheckedContinuation { continuation in
            var settled = false
            func settle(_ delivered: Bool) {
                guard !settled else { return }
                settled = true
                continuation.resume(returning: delivered)
            }
            Task { settle(await post(title: title, body: body)) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                settle(true)
            }
        }
    }

    /// `post`, but only when the user has already decided on notifications: a Mac that has not
    /// decided gets no alert and no permission banner from this call (answers false). For an
    /// announcement the open window already makes, whose banner would land on the user mid-step.
    @MainActor
    static func postIfAllowed(title: String, body: String) async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus != .notDetermined else { return false }
        return await post(title: title, body: body)
    }

    /// The body as delivered: the event's clock time first, in the app's language like every other
    /// time Tally shows, then the words.
    static func stampedBody(_ body: String, at: Date) -> String {
        String(format: L("%1$@ · %2$@"), AppLocale.shortTime(at), body)
    }
}
