import Foundation

// The panel's two one-time nudges (B-3784), kept Foundation-only so tests/panelhints can compile
// them alone. The first explains what the bars mean, the second invites the `tally` command. The
// views and the small install window only ask these questions.

enum PanelHints {
    /// UserDefaults keys. None of them is a secret.
    static let seenKey = "panelHintSeen"
    static let opensKey = "panelOpensWithData"
    static let inviteDismissedKey = "tallyInviteDismissed"

    /// The invite waits for this many panel openings that had data, so it never lands on the same
    /// opening the first hint was read on.
    static let invitePanelOpens = 2

    /// Whether one panel appearance counts toward the invite: there are accounts and at least one
    /// has a reading. An empty or still-loading panel is not an opening anyone learned from.
    static func countsAsOpen(hasAccounts: Bool, anyReading: Bool) -> Bool {
        hasAccounts && anyReading
    }

    /// The first hint: until it is answered with "Got it", whenever there is something to point at.
    static func showsBubble(seen: Bool, hasData: Bool) -> Bool {
        !seen && hasData
    }

    /// The invite card. `seenAtAppear` and `opensAtAppear` are read ONCE when the panel appears, so a
    /// "Got it" pressed during this opening does not pop the card in under the cursor. Only the
    /// absent state counts: a link (ours or a package manager's) or a file of someone else's means
    /// there is nothing to invite. The copy talks about Claude, so a Claude account has to exist.
    static func showsInvite(seenAtAppear: Bool, opensAtAppear: Int, dismissed: Bool,
                            commandAbsent: Bool, hasClaudeAccount: Bool) -> Bool {
        seenAtAppear && opensAtAppear >= invitePanelOpens && !dismissed
            && commandAbsent && hasClaudeAccount
    }

    /// The preview flag's value: which hint a held capture shows (`-TallyPanelHintPreview`).
    enum Preview: Equatable { case bubble, invite }
    static func preview(named name: String?) -> Preview? {
        switch name?.lowercased() {
        case "hint": return .bubble
        case "invite": return .invite
        default: return nil
        }
    }
}

/// The screens of the small "Add the tally command" window.
enum TallyCommandScreen: Equatable {
    case confirm
    /// The install is running, possibly behind the administrator password window.
    case installing
    case done
    case failed(TallyCommandFailure)

    /// `-TallyCommandPreview <name>`: a held screen, buttons only walk between screens.
    static func preview(named name: String?) -> TallyCommandScreen? {
        switch name?.lowercased() {
        case "confirm": return .confirm
        case "done": return .done
        case "failed-cancelled": return .failed(.cancelled)
        case "failed": return .failed(.other)
        default: return nil
        }
    }
}

enum TallyCommandFailure: Equatable {
    /// The password prompt was dismissed: nothing was written.
    case cancelled
    /// Anything else that left the command uninstalled.
    case other

    /// `cancelledMessage` is what the install itself reports for a dismissed password prompt
    /// (`IntegrationsStore.cliInstallMessage(.cancelled, ...)`), so the two sentences come from the
    /// one outcome instead of this reading the message's words.
    static func classify(lastError: String?, cancelledMessage: String?) -> TallyCommandFailure {
        guard let lastError, let cancelledMessage, lastError == cancelledMessage else { return .other }
        return .cancelled
    }
}
