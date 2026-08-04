import AppKit
import SwiftUI

/// The account card's right-click menu, split out of AccountCardView for file size: renewing THIS
/// account's login without first working out which config home it lives in, opening that home in
/// Finder, and removing the account altogether.
///
/// The first two entries are launchers and nothing more. Tally never reads, writes or forwards a
/// credential: "Renew login" starts the provider's own login against that account's config home, the
/// CLI opens the browser and completes the round trip itself, and the app only ever learns whether
/// it worked (see RenewLoginStore).
///
/// "Remove account…" is the one destructive entry, which is why it sits below a separator, asks
/// first, and moves the folder to the Trash rather than deleting it (RemoveAccountAction).
extension AccountCardView {
    @ViewBuilder
    var cardContextMenu: some View {
        AccountActionsMenu(accountID: usage.id, providerID: usage.providerID,
                           label: settings.displayLabel(accountID: usage.id,
                                                        fallback: usage.accountLabel),
                           home: configHome)
    }
}

/// The entries themselves, as a view rather than a card-shaped extension, because the Settings
/// account list offers the same three actions from its own "⋯" button. Two surfaces, one
/// implementation: a second copy would drift on exactly the details that matter here (which entry is
/// disabled when, and which home a removal acts on).
///
/// Everything it needs is passed in as plain values, so neither caller has to hold a card's worth of
/// state to show it.
struct AccountActionsMenu: View {
    let accountID: String
    let providerID: String
    /// The user-facing name (nickname applied), for the confirmation dialogs.
    let label: String
    /// The account's config home, or nil when Tally has none to act on (a demo fixture). The
    /// RENEWAL home: a signed-out account keeps it, which is exactly what "Renew login" acts on.
    let home: String?
    /// Start renaming, for the surface that owns a rename field. Absent on the card, which has no
    /// rename of its own; the Settings list passes its popover trigger, and the entry then leads the
    /// menu because it is the one people go looking for.
    var rename: (() -> Void)?
    /// Move this account up or down the order, nil at the ends (and on the card, which reorders by
    /// dragging instead). They live in the menu because a settings row has room for exactly one
    /// occasional-action control, and a permanent pair of arrows spent that room on the rarest of
    /// them: measured on 2026-08-04, the arrows plus this button together squeezed the row until
    /// both the address and the quota percentages truncated.
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let rename {
            Button(L("Rename…")) { rename() }
            Divider()
        }
        if moveUp != nil || moveDown != nil {
            Button(L("Move up")) { moveUp?() }.disabled(moveUp == nil)
            Button(L("Move down")) { moveDown?() }.disabled(moveDown == nil)
            Divider()
        }
        Button(L("Renew login…")) {
            guard let home else { return }
            RenewLoginStore.shared.renew(accountID: accountID, providerID: providerID,
                                         label: label, home: home)
        }
        .disabled(!RenewLoginStore.shared.canRenew(providerID: providerID, home: home)
                  || RenewLoginStore.shared.isRenewing(accountID))
        Button(L("Open config folder")) {
            guard let home else { return }
            // Open the folder itself rather than revealing it inside its parent: every config home
            // is a dotfolder, and revealing one in a Finder that is not showing hidden files
            // selects nothing.
            NSWorkspace.shared.open(URL(fileURLWithPath: home))
        }
        .disabled(home == nil)
        // Absent rather than greyed for the provider's default home (`~/.claude`, `~/.codex`): that
        // one is the user's primary setup and the target of every other account's share links, so
        // "remove" is not a thing it can mean. A greyed entry would only invite the question.
        if let home, accountHomeIsRemovable(providerID: providerID, home: home) {
            Divider()
            Button(L("Remove account…")) {
                RemoveAccountAction.present(accountID: accountID, providerID: providerID,
                                            label: label, home: home)
            }
            // Demo fixtures stand for accounts that do not exist on this machine (a marketing
            // capture must not be able to move a real folder anywhere).
            .disabled(DemoUsage.isActive)
        }
    }
}
