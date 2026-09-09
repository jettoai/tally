import SwiftUI

struct SettingsCodexHarness: View {
    var active = true
    @State private var harness = CodexHarnessStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L("Claude and Codex tools")).font(.subheadline)
                        Text(statusTitle).font(.caption2).foregroundStyle(harness.state == "installed" ? TallyColor.normal : .secondary)
                    }
                    Text(L("Installs the Tally harness skill and inbox reminders for Claude Code and Codex together. Ask either assistant to adapt your harness or handle messages in the current project."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !harness.hasInstallation {
                    Button(L("Install")) { harness.install() }
                        .disabled(!harness.mayWrite || harness.busy || harness.state == "not-inspected")
                        .accessibilityIdentifier("harness-install")
                } else {
                    Button(L("Remove")) { harness.remove() }
                        .disabled(!harness.mayWrite || harness.busy).accessibilityIdentifier("harness-remove")
                }
                if harness.busy { ProgressView().controlSize(.small) }
            }.controlSize(.small)
            if harness.hasInstallation {
                Text(L("The skill works across projects and determines the relevant harness from your current directory and request. Existing project adaptations are removed separately."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if harness.nativeHomes.contains(where: { $0["state"] != "trusted-enabled" }) {
                    Text(L("For Codex inbox reminders, review the new hooks in each account's /hooks menu."))
                        .font(.caption).foregroundStyle(TallyColor.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = harness.error {
                Text(error).font(.caption).foregroundStyle(TallyColor.warning).textSelection(.enabled)
            }
            if harness.previewRoot != nil {
                Text(L("Isolated preview: changes stay in the temporary fixture.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .task { harness.inspect() }
        .onChange(of: active) { if active { harness.inspect() } }
    }

    private var statusTitle: String {
        switch harness.state {
        case "installed": return L("Installed")
        case "incomplete": return L("Needs attention")
        case "not-installed": return L("Not installed")
        default: return L("Checking…")
        }
    }
}
