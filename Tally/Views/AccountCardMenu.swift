import AppKit
import SwiftUI

/// The account card's right-click menu, split out of AccountCardView for file size: renewing THIS
/// account's login without first working out which config home it lives in, and opening that home
/// in Finder.
///
/// Both entries are launchers and nothing more. Tally never reads, writes or forwards a credential:
/// "Renew login" starts the provider's own login against that account's config home, the CLI opens
/// the browser and completes the round trip itself, and the app only ever learns whether it worked
/// (see RenewLoginStore).
extension AccountCardView {
    /// The account's config home, or nil when Tally has none to act on (a demo fixture, or an
    /// account discovered without a launchable directory) - which is what greys both entries out.
    private var configHome: String? {
        UsageStore.shared.discoveredAccounts.first { $0.id == usage.id }?.launchHome
    }

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
    }
}
