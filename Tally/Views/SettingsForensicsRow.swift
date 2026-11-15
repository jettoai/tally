import SwiftUI

/// The root evidence helper's row, under the Process CPU alert switch it serves (B-4616): its state,
/// and the one button that shows the system's password window. The same step as `tally forensics
/// setup|remove`; the explanation rides in the hover.
struct SettingsForensicsRow: View {
    @State private var store = ForensicsHelperStore.shared

    var body: some View {
        SettingsSubRow(title: L("Root evidence for runaway system processes"),
                       info: L("Lets Tally run sample and fs_usage as root when a system process such as fseventsd is stuck at full CPU, so the evidence file can say what it was doing. Needs your administrator password once, typed into the system's own window. Only those two read-only tools can run, and Remove takes it all away.")) {
            HStack(spacing: 10) {
                if store.busy { ProgressView().controlSize(.small) }
                SettingsStatusBadge(text: statusTitle, tone: statusTone)
                if store.state == .installed {
                    Button(L("Remove")) { store.remove() }
                        .foregroundStyle(.secondary)
                        .disabled(store.busy)
                } else if store.state != nil {
                    Button(L("Set Up")) { store.setUp() }
                        .disabled(store.busy)
                }
            }
            .buttonStyle(InlineButtonStyle())
        }
        .onAppear { store.refresh() }
    }

    private var statusTitle: String {
        switch store.state {
        case .installed?: return L("Installed")
        case .incomplete?: return L("Needs attention")
        case .notInstalled?: return L("Not installed")
        case nil: return L("Checking…")
        }
    }

    private var statusTone: SettingsStatusBadge.Tone {
        switch store.state {
        case .installed?: return .good
        case .incomplete?: return .attention
        default: return .neutral
        }
    }
}
