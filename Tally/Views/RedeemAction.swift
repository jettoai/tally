import AppKit

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

    /// Ask before spending. True means go ahead.
    ///
    /// An AppKit alert in its OWN window: presenting SwiftUI's `.alert` inside the borderless
    /// pinned panel forced the host window opaque for the duration, turning the transparent
    /// rounded corners square (2026-07-19). NSAlert leaves the panel untouched.
    static func confirm(usage: AccountUsage, label: String) -> Bool {
        let alert = NSAlert()
        // The alert lives in its own window, detached from the card - it must NAME the account
        // it is about to reset.
        alert.messageText = "\(label) · \(L("Use a reset"))"
        alert.informativeText = confirmMessage(for: usage)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Redeem")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        return runCentred(alert) == .alertFirstButtonReturn
    }

    /// Spend the soonest-expiring credit. Nil when this account has no CLI home to talk to, which
    /// leaves nothing to report: no request was ever made. Callers own the refresh behind it, so a
    /// card can show its outcome line before waiting on a 10-20s poll.
    static func redeem(usage: AccountUsage) async -> CodexAppServerClient.RedeemOutcome? {
        guard let home = UsageStore.shared.discoveredAccounts
            .first(where: { $0.id == usage.id })?.launchHome else { return nil }
        return await CodexAppServerClient.consumeSoonestResetCredit(codexHome: home)
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
                presentNotice("\(label) · \(L("Use a reset"))",
                              outcomeMessage(outcome ?? .failed(nil)))
            }
            await UsageStore.shared.refresh(userInitiated: true)
        }
    }

    /// One button and a dismissal, in the same centred window the confirmation uses.
    private static func presentNotice(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        _ = runCentred(alert)
    }

    /// Centred on the window the user actually clicked in (panel or popover), falling back to the
    /// screen under the pointer, never on some other monitor's main screen. The activation also
    /// covers the notification path, where the app may have nothing on screen at all.
    private static func runCentred(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        alert.layout()
        let mouse = NSEvent.mouseLocation
        let anchor = NSApp.windows.first { $0.isVisible && $0.frame.contains(mouse) }?.frame
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame
        if let anchor {
            let window = alert.window
            let size = window.frame.size
            let origin = NSPoint(x: anchor.midX - size.width / 2,
                                 y: anchor.midY - size.height / 2)
            window.setFrameOrigin(origin)
            // runModal re-centres the alert window as it shows, clobbering the origin above
            // (live multi-monitor incident 2026-07-20). Re-assert it from inside the modal
            // run loop, right after the show.
            RunLoop.main.perform(inModes: [.modalPanel]) {
                // A RunLoop.main callout always executes on the main thread; the closure just
                // isn't annotated, so tell the compiler rather than hop actors.
                MainActor.assumeIsolated {
                    window.setFrameOrigin(origin)
                }
            }
        }
        return alert.runModal()
    }
}
