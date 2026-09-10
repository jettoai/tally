import Foundation
import UserNotifications

@MainActor
enum LoginHealthNotification {
    nonisolated static let categoryID = "ai.jetto.tally.sessionLogin"
    nonisolated static let openActionID = "openSession"
    nonisolated static let sessionKey = "sessionID"

    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID,
            actions: [UNNotificationAction(identifier: openActionID,
                                           title: L("Open session"), options: [.foreground])],
            intentIdentifiers: [])
    }

    static func post(_ alert: LoginHealthAlert, label: String) async -> Bool {
        NotificationRouter.shared.refreshCategories()
        let title: String
        let body: String
        switch alert.kind {
        case .session:
            title = L("Session needs sign-in")
            body = L("A session on this account needs /login. Open that session to sign in again.")
        case .expiring:
            title = L("Login expires soon")
            body = L("This account's login expires within three days. Renew it before it interrupts a session.")
        case .expired:
            title = L("Login expired")
            body = L("This account's login deadline has passed. Renew the login to keep using it.")
        }
        return await SystemAlert.post(title: label + " · " + title, body: body,
            categoryID: alert.kind == .session ? categoryID : LoginStatusStore.categoryID,
            userInfo: [LoginStatusStore.accountKey: alert.accountID, sessionKey: alert.sessionID ?? ""])
    }
}
