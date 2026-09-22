import Foundation
import UserNotifications

/// Glue between the banked-reset reminder and macOS notifications. Owns the persisted dedup state,
/// runs the pure `ResetHintLogic` after each refresh, and posts at most one notification naming one
/// account. It keeps no timer of its own: the existing refresh loop drives it.
///
/// The notification's only action opens the card's confirmation. Nothing here can spend a credit.
@MainActor
final class ResetHintNotifier {
    static let shared = ResetHintNotifier()

    /// Category and action ids, plus the userInfo key carrying the account the hint is about. The
    /// delegate routes on these, so both sides read them from here. Nonisolated because the
    /// delegate reads a notification response off the main actor.
    nonisolated static let categoryID = "ai.jetto.tally.resetHint"
    nonisolated static let redeemActionID = "redeem"
    nonisolated static let accountKey = "accountID"

    /// Registered at launch (a category unknown to the system when the notification lands shows no
    /// button at all). `.foreground` because the action opens a modal confirmation, which needs
    /// the app in front of the user.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryID,
            actions: [UNNotificationAction(identifier: redeemActionID,
                                           title: L("Use a reset"), options: [.foreground])],
            intentIdentifiers: [])
    }

    /// UserDefaults key for the persisted per-account dedup state.
    private let stateKey = "ai.jetto.tally.resetHint.state"

    private init() {}

    /// Feed one refresh's accounts. Accounts whose provider does not bank resets fall out inside
    /// the pure logic, so every provider can be handed over as-is.
    func evaluate(accounts: [AccountUsage]) {
        let (next, hint) = ResetHintLogic.advance(state: loadState(), accounts: accounts,
                                                  now: Date())
        saveState(next)
        guard let hint else { return }
        Task { @MainActor in
            // A refusal hands the announcement back so a later refresh can say it again. The state
            // is re-read rather than reused: the refresh loop can have run while macOS answered.
            guard await post(hint) == false else { return }
            saveState(ResetHintLogic.rearm(state: loadState(), hint: hint))
        }
    }

    /// Post one sample drained hint (the `-TallyResetHintTest` launch flag): checks the action
    /// button, its routing and the confirmation it lands on without waiting for a real drought. It
    /// names a real Codex account when the machine has one, so the button opens the real dialog.
    /// No state is persisted, so a normal launch is unaffected.
    func postSampleNotification() {
        let account = CodexAccounts.discover().first
        Task { @MainActor in
            _ = await post(ResetHint(accountID: account?.id ?? "",
                                     accountLabel: account?.label ?? "Codex",
                                     reason: .drained, bindingRemainingPercent: 0,
                                     creditExpiresAt: Date().addingTimeInterval(12 * 3_600)))
        }
    }

    // MARK: State persistence

    private func loadState() -> ResetHintState {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(ResetHintState.self, from: data) else {
            return ResetHintState()
        }
        return state
    }

    private func saveState(_ state: ResetHintState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }

    // MARK: Notifications

    /// Compose and deliver, answering whether it will actually be seen (see `SystemAlert.post`).
    private func post(_ hint: ResetHint) async -> Bool {
        let title: String
        let body: String
        switch hint.reason {
        case .drained:
            title = String(format: L("%@ is out of quota"), hint.accountLabel)
            body = L("A banked reset can clear its counters now.")
        case .expiryEarly, .expiryPreReset, .expiryFinal:
            title = String(format: L(hint.reason == .expiryFinal
                                     ? "%@ has a banked reset expiring within hours"
                                     : "%@ has a banked reset expiring"), hint.accountLabel)
            body = Self.expiryBody(hint)
        }
        // The category carries the "Use a reset" button; the account id rides along so pressing it
        // lands on the account the hint was about. Re-registered right here because that button's
        // title is localized and the language can have changed since launch.
        NotificationRouter.shared.refreshCategories()
        return await SystemAlert.post(title: title, body: body, categoryID: Self.categoryID,
                                      userInfo: [Self.accountKey: hint.accountID])
    }

    /// The body says what spending now is worth (`ResetHintLogic.value`), never "no waste" when
    /// plenty is left: whether to wait depends on the refill, and the sentence says which.
    private static func expiryBody(_ hint: ResetHint) -> String {
        let expires = hint.creditExpiresAt.map(AppLocale.shortDateTime) ?? L("soon")
        let used = "\(Int((100 - hint.bindingRemainingPercent).rounded()))%"
        switch ResetHintLogic.value(remaining: hint.bindingRemainingPercent,
                                    expiresAt: hint.creditExpiresAt,
                                    bindingResetsAt: hint.bindingResetsAt) {
        case .recovers:
            return String(format: L("Expires %@. Redeeming now recovers %@."), expires, used)
        case .refillsFirst(let refill):
            return String(format: L("Expires %@. Best used before %@; after that the counters refill on their own."),
                          expires, AppLocale.shortDateTime(refill))
        case .lostUnused:
            return String(format: L("Expires %@. Unused, it is lost; redeeming now recovers %@."),
                          expires, used)
        }
    }
}
