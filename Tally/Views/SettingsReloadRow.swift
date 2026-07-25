import AppKit
import Combine
import SwiftUI

/// The Settings face of `tally reload`: one button that asks every supervised session to restart at
/// its next idle moment, so edited hooks, skills, and instructions take effect without visiting each
/// terminal. This is where the feature is EXPLAINED (the footer button is the fast path for someone
/// who already knows); both go through `ReloadAction.presentConfirm`, which also writes the same
/// request file the command writes.
struct SettingsReloadRow: View {
    /// Held rather than read inside `body`: a process scan there would re-run on every unrelated
    /// redraw, and its answer would still never refresh for the one person it matters to, someone
    /// who reads the note below, restarts their sessions in a terminal, and comes back to a
    /// Settings window they left open. Coming back is the activation notification.
    @State private var readiness: ReloadReadiness?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Reload running sessions")).font(.subheadline)
                Text(L("Each supervised session restarts when it goes idle, so edited hooks and instructions take effect. Conversations continue."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Sessions that predate this feature cannot hear a request, and this row is where
                // the feature is explained, so it is where that has to be said. Same sentence as the
                // command, the alert, and the footer tooltip (ReloadAction.readinessNote).
                if case .legacyOnly(let count) = readiness {
                    Text(reloadLegacyNotice(count, localize: L))
                        .font(.caption)
                        .foregroundStyle(TallyColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            // Never disabled on the readiness above: it refreshes on appear and on activation, not
            // when a session starts or ends, so a rendered zero would leave the button dead while
            // sessions are running. The press answers with the truth at the moment it happens
            // instead (see ReloadAction.presentConfirm).
            Button(L("Reload")) { ReloadAction.presentConfirm() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear { readiness = currentReloadReadiness() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            readiness = currentReloadReadiness()
        }
    }
}
