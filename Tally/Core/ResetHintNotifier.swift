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
            if await post(hint) == false { rearm(hint) }
        }
    }

    /// Hand back the one announcement this hint just spent, because the system refused to deliver
    /// it. The cycle bookkeeping in `advance` has to be saved either way (it tracks which window
    /// this is, not what was said), so only the fired flag is undone: someone with notifications
    /// switched off who turns them on later in the same cycle still has a banked credit sitting on
    /// an empty account, and that is exactly who this feature exists for.
    private func rearm(_ hint: ResetHint) {
        var state = loadState()
        switch hint.reason {
        case .drained: state.accounts[hint.accountID]?.firedDrained = false
        case .expiring: state.accounts[hint.accountID]?.firedExpiring = false
        }
        saveState(state)
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
        case .expiring:
            title = String(format: L("%@ has a banked reset expiring"), hint.accountLabel)
            body = String(format: L("Expires %@. Redeeming it now would not go to waste."),
                          expiryText(hint.creditExpiresAt))
        }
        // The category carries the "Use a reset" button; the account id rides along so pressing it
        // lands on the account the hint was about. Re-registered right here because that button's
        // title is localized and the language can have changed since launch.
        NotificationRouter.shared.refreshCategories()
        return await SystemAlert.post(title: title, body: body, categoryID: Self.categoryID,
                                      userInfo: [Self.accountKey: hint.accountID])
    }

    /// The same stamp the redeem confirmation prints, and a word for the credit whose expiry the
    /// provider never told us.
    private func expiryText(_ date: Date?) -> String {
        guard let date else { return L("soon") }
        return AppLocale.shortDateTime(date)
    }
}
