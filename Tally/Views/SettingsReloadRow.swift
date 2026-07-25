import SwiftUI

/// The Settings face of `tally reload`: one button that asks every supervised session to restart at
/// its next idle moment, so edited hooks, skills, and instructions take effect without visiting each
/// terminal. This is where the feature is EXPLAINED (the footer button is the fast path for someone
/// who already knows); both go through `ReloadAction.presentConfirm`, which also writes the same
/// request file the command writes.
struct SettingsReloadRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Reload running sessions")).font(.subheadline)
                Text(L("Each supervised session restarts when it goes idle, so edited hooks and instructions take effect. Conversations continue."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Never disabled on a live count: nothing invalidates this view when a session starts or
            // ends, so a rendered zero would leave the button dead forever. The press answers with
            // the truth instead (see ReloadAction.presentConfirm).
            Button(L("Reload")) { ReloadAction.presentConfirm() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
