import Foundation

/// The one confirm-and-write behind every "use a reset" control (the account card's button and the
/// banked-reset notification's action). Redeeming is the only write Tally ever performs, so it has
/// exactly one path: one place the waste warning is worded, one place the credit is spent, and no
/// surface that can skip the question.
///
/// The spending itself is `CodexAppServerClient.consumeSoonestResetCredit`, which always picks the
/// soonest-expiring credit; nothing here chooses for the user beyond that.
@MainActor
enum RedeemAction {
    /// The confirmation's body: cost + irreversibility, the nearest expiry (an expiring credit is
    /// nearly free to spend), and an escalation when redeeming would be a WASTE, because clearing
    /// counters that are mostly empty gains almost nothing.
    static func confirmMessage(for usage: AccountUsage) -> String {
        var parts: [String] = []
        // The binding window and the waste line come from `ResetHintLogic`, so the hint can never
        // offer a redeem that this dialog then calls mostly wasted.
        let bindingRemaining = ResetHintLogic.binding(usage)?.remainingPercent ?? 0
        if bindingRemaining > ResetHintLogic.wasteRemainingPercent {
            parts.append(L("This account still has plenty of quota left; redeeming now would mostly be wasted."))
        }
        parts.append(L("Clears this account's current usage counters and consumes 1 banked reset. This cannot be undone."))
        if let expiry = usage.resetCreditsNextExpiry {
            parts.append(L("Nearest banked reset expires") + " "
                         + AppLocale.shortDateTime(expiry) + ".")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Ask before spending. True means go ahead. The alert lives in its own window, detached from
    /// the card (CentredAlert), so it must NAME the account it is about to reset.
    static func confirm(usage: AccountUsage, label: String) -> Bool {
        CentredAlert.confirm(title: "\(label) · \(L("Use a reset"))",
                             body: confirmMessage(for: usage), confirmTitle: L("Redeem"))
    }

    /// Spend the soonest-expiring credit. Nil when this account has no CLI home to talk to, which
    /// leaves nothing to report: no request was ever made. Callers own the refresh behind it, so a
    /// card can show its outcome line before waiting on a 10-20s poll.
    static func redeem(usage: AccountUsage) async -> CodexAppServerClient.RedeemOutcome? {
        // `launchableHome`, not the renewal home: a signed-out account has no session for the app
        // server to spend a credit on, and asking anyway would report a failure about a request
        // that never should have been made.
        guard let home = UsageStore.shared.discoveredAccounts
            .first(where: { $0.id == usage.id })?.launchableHome else { return nil }
        return await CodexAppServerClient.consumeSoonestResetCredit(codexHome: home)
    }

    /// The refresh every redeem is followed by, in one place so no caller can pair a success with
    /// a plain re-read. A success hands off to `RedeemPropagationStore`, which owns that first
    /// refresh AND the retries behind it: the provider keeps serving the spent numbers for a few
    /// more seconds, which would otherwise leave a green "Reset redeemed" sitting over a red
    /// "Limit reached" at 0%. Anything else spent nothing, so one re-read says all there is.
    static func followThrough(outcome: CodexAppServerClient.RedeemOutcome?,
                              usage: AccountUsage) async {
        if outcome == .redeemed {
            RedeemPropagationStore.shared.begin(usage: usage)
        } else {
            await UsageStore.shared.refresh(userInitiated: true)
        }
    }

    /// The outcome in the app's own voice. Every case is a translated sentence: the server's own
    /// wording never reaches a row, only the tooltip.
    static func outcomeMessage(_ outcome: CodexAppServerClient.RedeemOutcome) -> String {
        switch outcome {
        case .redeemed: return L("Reset redeemed")
        case .alreadyUsed: return L("That credit was already used")
        case .noCredit: return L("No reset credit available")
        case .failed: return L("Redeem failed")
        }
    }

    /// The server's own words for a failure, for a hover tooltip: diagnosable without putting a
    /// protocol token in front of everyone.
    static func outcomeDetail(_ outcome: CodexAppServerClient.RedeemOutcome) -> String? {
        if case .failed(let detail) = outcome { return detail }
        return nil
    }

    /// Where the banked-reset notification's action lands: the same confirmation the card opens,
    /// never a redeem. The notification only ever knows an account id, so the account is resolved
    /// here, and everything that cannot resolve to one live account opens the app instead of doing
    /// nothing: a tap on the notification body rather than its button, a hint that outlived its
    /// account (signed out, switched off), or a click so soon after launch that the first refresh
    /// has not landed yet. The panel it opens carries the same button on the card.
    static func present(accountID: String?) {
        guard let accountID,
              let usage = UsageStore.shared.accounts.first(where: { $0.id == accountID }) else {
            MainWindowController.shared.show()
            return
        }
        let label = SettingsStore.shared.displayLabel(accountID: usage.id,
                                                      fallback: usage.accountLabel)
        guard confirm(usage: usage, label: label) else { return }
        Task {
            let outcome = await redeem(usage: usage)
            // With no card on screen the answer has nowhere else to go, and a redeem that failed
            // must never pass for a quiet success. A success needs no alert: the panel, the menu
            // bar numbers and the status line all move on the refresh right behind it.
            if outcome != .redeemed {
                CentredAlert.notice(title: "\(label) · \(L("Use a reset"))",
                                    body: outcomeMessage(outcome ?? .failed(nil)))
            }
            await followThrough(outcome: outcome, usage: usage)
        }
    }
}
