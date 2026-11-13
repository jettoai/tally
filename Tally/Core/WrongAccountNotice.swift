import UserNotifications

/// The notification a login into the wrong account earns (B-4530): what happened, and the two ways
/// forward. "Sign in again" restarts the renewal held to the original address; "Keep the new
/// account" is for the person who switched on purpose and must not be stuck behind a check that
/// only they can overrule. NotificationRouter routes both buttons, so both sides read the ids here.
enum WrongAccountNotice {
    nonisolated static let categoryID = "ai.jetto.tally.wrongAccount"
    nonisolated static let resignActionID = "resignin"
    nonisolated static let keepActionID = "keep"
    /// The same key the other account notifications carry, so the router reads one spelling.
    nonisolated static let accountKey = "accountID"

    /// `.foreground`: both buttons end in the app doing something the user is about to look at (a
    /// browser sign-in, a refreshed account list). Re-registered before each alert, because the
    /// button titles are localized and the language can change while Tally runs.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryID,
            actions: [UNNotificationAction(identifier: resignActionID,
                                           title: L("Sign in again"), options: [.foreground]),
                      UNNotificationAction(identifier: keepActionID,
                                           title: L("Keep the new account"), options: [.foreground])],
            intentIdentifiers: [])
    }

    /// Names both addresses when it has both; with either one missing it says the same thing
    /// without a blank in the sentence.
    static func body(signedIn: String?, expected: String?) -> String {
        guard let signedIn, !signedIn.isEmpty, let expected, !expected.isEmpty else {
            return L("You signed in as a different account than this one. Switch accounts in your browser, then sign in again.")
        }
        return String(format: L("You signed in as %1$@, but this account is %2$@. Switch to %2$@ in your browser, then sign in again."),
                      signedIn, expected)
    }
}
