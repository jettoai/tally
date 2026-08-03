import AppKit
import UserNotifications

/// The app's notification delegate. Two jobs, both of which the system does badly by default for a
/// menu-bar app: it routes an alert's button back to the account it was about (a notification only
/// ever carries an id) - the banked-reset hint's "Use a reset", the expiry alert's "Renew login" -
/// and it keeps alerts visible while the app itself is frontmost. Without a delegate the system
/// swallows the second case entirely, which is exactly when the user is most likely to be looking
/// at Tally's own windows.
///
/// Routing can only ever OPEN the confirmation, or start the provider's own login. No path here
/// spends a credit, and none touches one.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    private override init() { super.init() }

    /// Called at launch, before the first notification can arrive: a delegate installed later
    /// misses a response, and a category registered later shows no button on the alert.
    func install() {
        UNUserNotificationCenter.current().delegate = self
        refreshCategories()
    }

    /// Register every category the app defines, reading them fresh. Their action titles are
    /// localized, and Tally's language can be changed from Settings while it runs, so a set
    /// registered once at launch would keep offering yesterday's language until a restart. Cheap
    /// enough to repeat before each alert that carries a button.
    func refreshCategories() {
        UNUserNotificationCenter.current()
            .setNotificationCategories([ResetHintNotifier.category, LoginStatusStore.category])
    }

    /// Show the alert even while Tally is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Only the id and which button was pressed cross onto the main actor; the notification object
    /// itself stays here, so nothing non-Sendable travels.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let accountID = content.userInfo[ResetHintNotifier.accountKey] as? String
        let action = response.actionIdentifier
        // Which alert it was decides what the press means; the id it carries decides which account
        // it lands on. Tapping the body of an expiry alert opens nothing: renewing takes over the
        // browser, so it happens only when the button that says so is pressed.
        if content.categoryIdentifier == LoginStatusStore.categoryID {
            if action == LoginStatusStore.renewActionID, let accountID {
                Task { @MainActor in RenewLoginStore.shared.renew(accountID: accountID) }
            }
            completionHandler()
            return
        }
        let isRedeem = action == ResetHintNotifier.redeemActionID
        Task { @MainActor in RedeemAction.present(accountID: isRedeem ? accountID : nil) }
        completionHandler()
    }
}
