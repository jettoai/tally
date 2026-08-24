import SwiftUI

/// The one-time notice that early start is on, at the top of the panel.
///
/// IT IS THE GATE, not decoration. The feature ships on by default because a switch nobody finds is
/// a switch nobody benefits from, and a default that sends a message on somebody's account without
/// them ever having been told is the kind of surprise that costs an app its trust. So nothing is
/// ever sent until this has been read: `EarlyStartStore.isArmed` is false until it is dismissed, or
/// until the Settings row it names has been opened, which teaches the same thing at more length.
///
/// It stands until it is answered rather than fading after a while, launches included, for the
/// reason the Integrations pane's own notices give: nobody was at the machine when the schedule was
/// set up, and a notice they were not there for is not a notice.
extension PopoverRootView {
    @ViewBuilder
    var earlyStartNotice: some View {
        let early = EarlyStartStore.shared
        // Only where the feature has something to act on. A machine with no Claude account on it
        // would be reading an announcement about nothing.
        if early.showsNotice,
           store.accounts.contains(where: { $0.providerID == EarlyStartLogic.providerID }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Early start is on")).font(.caption.weight(.semibold))
                    Text(String(format: L("Each morning at %@, Tally opens each Claude account's 5-hour window with one short message, so the window resets earlier in your day. Accounts already working are left alone."),
                                AppLocale.shortTime(early.triggerToday ?? Date())))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // Both answers acknowledge: whichever is pressed, this has been read. The left one
                // additionally opens the window where the switch and the time live.
                Button(L("Settings")) {
                    early.acknowledgeNotice()
                    StatusItemController.openSettingsWindow()
                }
                .controlSize(.small)
                Button(L("Got it")) { early.acknowledgeNotice() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }
}
