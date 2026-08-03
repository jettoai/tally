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
        Button(L("Renew login…")) {
            guard let home = configHome else { return }
            RenewLoginStore.shared.renew(
                accountID: usage.id, providerID: usage.providerID,
                label: settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel),
                home: home)
        }
        .disabled(!RenewLoginStore.shared.canRenew(providerID: usage.providerID, home: configHome)
                  || RenewLoginStore.shared.isRenewing(usage.id))
        Button(L("Open config folder")) {
            guard let home = configHome else { return }
            // Open the folder itself rather than revealing it inside its parent: every config home
            // is a dotfolder, and revealing one in a Finder that is not showing hidden files
            // selects nothing.
            NSWorkspace.shared.open(URL(fileURLWithPath: home))
        }
        .disabled(configHome == nil)
        // Absent rather than greyed for the provider's default home (`~/.claude`, `~/.codex`): that
        // one is the user's primary setup and the target of every other account's share links, so
        // "remove" is not a thing it can mean. A greyed entry would only invite the question.
        if let home = configHome,
           accountHomeIsRemovable(providerID: usage.providerID, home: home) {
            Divider()
            Button(L("Remove account…")) {
                RemoveAccountAction.present(
                    accountID: usage.id, providerID: usage.providerID,
                    label: settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel),
                    home: home)
            }
            // Demo fixtures stand for accounts that do not exist on this machine (a marketing
            // capture must not be able to move a real folder anywhere).
            .disabled(DemoUsage.isActive)
        }
    }
}
