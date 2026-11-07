import CoreGraphics
import Foundation

// The panel's two one-time nudges (B-3784), kept free of SwiftUI so tests/panelhints can compile
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

    /// Where the first hint's bubble sits, in the scroll area's space (B-4112, B-3823). `y` is the
    /// bubble's top edge; `above` means it was flipped over the meter, so its arrow is at the bottom.
    struct BubblePlacement: Equatable {
        var y: CGFloat
        var above: Bool
    }

    /// Space between the meter and the bubble's arrow, on either side.
    static let bubbleGap: CGFloat = 2

    /// Below the meter when it fits the scroll area, else above it, else (B-3823) below or above it
    /// using the rest of the panel the bubble is drawn over: `overhang` is the panel under the scroll
    /// area (divider and footer), `headroom` the panel over it (header, divider, notices). Last, it is
    /// clamped inside the whole panel, so its button is never cut off by the window. `meter` and the
    /// result are in the scroll area's own space. A meter scrolled out of the area gets no bubble
    /// (nil), so the hint is neither drawn nor marked seen until the meter is back in view. With no
    /// overhang and no headroom this is the scroll-area-only rule B-4112 shipped.
    static func bubblePlacement(meter: CGRect, bubbleHeight: CGFloat, viewport: CGSize, margin: CGFloat,
                                headroom: CGFloat = 0, overhang: CGFloat = 0) -> BubblePlacement? {
        guard meter.maxY > 0, meter.minY < viewport.height else { return nil }
        let below = meter.maxY + bubbleGap
        if below + bubbleHeight <= viewport.height - margin { return BubblePlacement(y: below, above: false) }
        let over = meter.minY - bubbleGap - bubbleHeight
        if over >= margin { return BubblePlacement(y: over, above: true) }
        let top = margin - headroom, bottom = viewport.height + overhang - margin
        if below + bubbleHeight <= bottom { return BubblePlacement(y: below, above: false) }
        if over >= top { return BubblePlacement(y: over, above: true) }
        return BubblePlacement(y: min(max(below, top), max(top, bottom - bubbleHeight)), above: false)
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
    enum Preview: Equatable { case bubble, invite, off }
    static func preview(named name: String?) -> Preview? {
        switch name?.lowercased() {
        case "hint": return .bubble
        case "invite": return .invite
        case "off": return .off
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
        case "failed-foreign": return .failed(.foreignFile)
        case "failed-unavailable": return .failed(.unavailable)
        default: return nil
        }
    }
}

enum TallyCommandFailure: Equatable {
    /// The password prompt was dismissed: nothing was written.
    case cancelled
    /// A file of somebody else's sits at the link path. The install refused to replace it.
    case foreignFile
    /// This build (Dev, build tree, translocated) is not allowed to install anything.
    case unavailable
    /// Anything else that left the command uninstalled.
    case other

    /// The "Run it yourself in Terminal" line is a `sudo ln -sf`: it would replace the foreign
    /// file, or point the link at a build that must not be linked. Only the other two may offer it.
    var allowsManualCommand: Bool { self == .cancelled || self == .other }

    /// The same two questions the copy action asks again right before it puts the line on the clipboard.
    static func manualCommandAllowed(foreignFile: Bool, unshipped: Bool) -> Bool {
        !foreignFile && !unshipped
    }

    /// `cancelledMessage` is what the install itself reports for a dismissed password prompt
    /// (`IntegrationsStore.cliInstallMessage(.cancelled, ...)`), so the two sentences come from the
    /// one outcome instead of this reading the message's words. `foreignFile` and `unshipped` are read
    /// from the disk and the build, and outrank the message: they are the reasons nothing was written.
    static func classify(lastError: String?, cancelledMessage: String?,
                         foreignFile: Bool, unshipped: Bool) -> TallyCommandFailure {
        if unshipped { return .unavailable }
        if foreignFile { return .foreignFile }
        guard let lastError, let cancelledMessage, lastError == cancelledMessage else { return .other }
        return .cancelled
    }
}
