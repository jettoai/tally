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
    /// What one account has to spend, so the two card surfaces branch in ONE place rather than each
    /// working it out from a provider id and a pair of optionals.
    ///
    /// PROVIDER-AWARE, NOT PROVIDER-BRANCHED. The two offers are different writes with different
    /// mechanisms - Codex spends a banked credit through its own app server, Claude spends a weekly
    /// reset by typing an interactive slash command into a live session - and neither is expressible
    /// in the other's vocabulary. What they share is the rule this file exists for: exactly one
    /// place asks the question, exactly one place performs the write, and no surface can skip
    /// either. So each offer keeps its own confirm-and-spend pair below, and this is the one
    /// question a card asks first.
    enum Offer: Equatable {
        /// Codex reset banking: `n` banked resets, spent soonest-expiry-first.
        case codexCredits(Int)
        /// Claude's own once-a-week session-limit reset (Core/LimitReset.swift). Carries the state
        /// because the card draws all four of them, and only one of them is a button.
        case claudeSessionLimit(LimitResetState)
    }

    /// Which offer this account carries, or nil when it carries none.
    ///
    /// The Codex side is `resetCreditsAvailable`, which the provider reports; the Claude side is the
    /// observed record, which no provider reports and no poll produces (`LimitResetStore` states
    /// where it comes from). An `unknown` Claude account answers nil rather than an offer: nothing
    /// has been observed about it, and a card that drew a control there would be inventing one.
    static func offer(for usage: AccountUsage) -> Offer? {
        if let credits = usage.resetCreditsAvailable, credits > 0 { return .codexCredits(credits) }
        guard usage.providerID == "claude" else { return nil }
        let state = LimitResetStore.shared.state(accountID: usage.id)
        return state == .unknown ? nil : .claudeSessionLimit(state)
    }
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

    // MARK: Claude's weekly session-limit reset

    /// The confirmation's body for the OTHER write, worded from what Claude Code itself says about
    /// the cost: it uses the weekly limit, and there is one a week.
    ///
    /// IT NAMES THE SESSION, which the banked-reset dialog has no equivalent of. This write is not
    /// a request to a server; it is a slash command typed into one particular running conversation,
    /// and that conversation's own composer is where the answer appears. Somebody who presses this
    /// and then watches a different window would have no idea what happened.
    static func sessionLimitMessage(session: LimitResetTarget?) -> String {
        var parts = [
            L("Clears this account's 5-hour session limit now. It uses the weekly limit, and there is one reset a week. This cannot be undone."),
        ]
        if let session {
            parts.append(String(format: L("Tally types /limit-reset into the session running as %@."),
                                session.sessionKey))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Ask, then spend. The question is the detached alert the banked reset uses, under the same
    /// rule: it must NAME the account, because it opens in a window of its own. The write itself is
    /// the store's (it has to reach a CLI and then wait on a file); what belongs here is that
    /// nothing spends without the question having been answered.
    ///
    /// THE PAIR IS ONE CALL rather than two, because both surfaces make it and a card that asked
    /// without spending, or spent without asking, would be one editing slip away. The session the
    /// dialog names is read here rather than handed in, from the very store the write goes to, so
    /// no surface can word the question about a session other than the one about to be typed into.
    static func startSessionLimit(usage: AccountUsage, label: String) {
        let session = LimitResetStore.shared.target(accountID: usage.id)
        guard CentredAlert.confirm(title: "\(label) · \(L("Reset session limit"))",
                                   body: sessionLimitMessage(session: session),
                                   confirmTitle: L("Reset")) else { return }
        Task { _ = await LimitResetStore.shared.spend(accountID: usage.id) }
    }

    /// The outcome in the app's own voice, on the terms `outcomeMessage` states for its neighbour:
    /// every case is a translated sentence, and Claude Code's own wording never reaches a row.
    static func sessionLimitOutcomeMessage(_ outcome: LimitResetStore.LimitResetSpend) -> String {
        switch outcome {
        case .reset: return L("Session limit reset")
        case .alreadyUsed: return L("This week's reset is already used")
        // ONE SENTENCE FOR BOTH, because the difference between them is not one the user can act
        // on: a refusal that names no reason and a login outside the rollout both come to "not yet".
        case .notAvailable, .notEnabled: return L("Not available for this login yet")
        case .noSession: return L("Open a session on this account to use its reset")
        case .noAnswer: return L("No answer yet")
        case .failed: return L("Reset failed")
        }
    }

    /// The tool's own words for a failure, for a hover tooltip: diagnosable without putting a
    /// process id and a refusal in front of everyone.
    static func sessionLimitOutcomeDetail(_ outcome: LimitResetStore.LimitResetSpend) -> String? {
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
