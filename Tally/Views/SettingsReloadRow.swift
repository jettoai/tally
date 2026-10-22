import AppKit
import Combine
import SwiftUI

/// The Settings face of `tally reload`: one button that asks supervised Claude sessions to restart at
/// its next idle moment, so edited hooks, skills, and instructions take effect without visiting each
/// terminal. This is where the feature is EXPLAINED (the footer button is the fast path for someone
/// who already knows); both go through `ReloadAction.presentConfirm`, which also writes the same
/// request file the command writes.
struct SettingsReloadRow: View {
    /// Read from the roster's published answer rather than scanned here: the scan runs off the main
    /// thread (`ReloadReadinessStore`). Appearing and coming back to the app ask for a fresh scan,
    /// for the one person it matters to: someone who reads the note below, restarts their sessions
    /// in a terminal, and comes back to a Settings window they left open.
    private var readiness: ReloadReadiness? { ReloadReadinessStore.shared.readiness }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Never disabled on the readiness above: it refreshes on appear and on activation, not
            // when a session starts or ends, so a rendered zero would leave the button dead while
            // sessions are running. The press answers with the truth at the moment it happens
            // instead (see ReloadAction.presentConfirm).
            SettingsRow(title: L("Reload running sessions"),
                        subtitle: L("Restarts supervised sessions when idle so changed hooks apply."),
                        icon: "arrow.clockwise.circle",
                        info: L("Each supervised Claude session restarts when it goes idle, so edited hooks and instructions take effect. Conversations continue.")) {
                Button(L("Reload")) { ReloadAction.presentConfirm() }
            }
            // Sessions that predate this feature cannot hear a request, and this row is where
            // the feature is explained, so it is where that has to be said. Same sentence as the
            // command, the alert, and the footer tooltip (ReloadAction.readinessNote).
            if case .legacyOnly(let count) = readiness {
                SettingsSubRow(title: reloadLegacyNotice(count, localize: L), tint: TallyColor.warning)
            }
        }
        .onAppear { SessionRosterStore.shared.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            SessionRosterStore.shared.refresh()
        }
    }
}
