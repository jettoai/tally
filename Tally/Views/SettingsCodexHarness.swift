import SwiftUI

/// The Harness group's one row: the shared harness skill and inbox reminders for Claude Code and
/// Codex together. Everything the user has to act on (an error, a hook to review) is its own line
/// under the row; the explanations ride in the row's hover.
struct SettingsCodexHarness: View {
    var active = true
    @State private var harness = CodexHarnessStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: L("Harness tools"), subtitle: L("Skill and inbox reminders for Claude Code and Codex together."),
                        icon: "wrench.and.screwdriver", info: info) {
                HStack(spacing: 10) {
                    if harness.busy { ProgressView().controlSize(.small) }
                    SettingsStatusBadge(text: statusTitle, tone: statusTone)
                    if !harness.hasInstallation {
                        Button(L("Install")) { harness.install() }
                            .disabled(!harness.mayWrite || harness.busy || harness.state == "not-inspected")
                            .accessibilityIdentifier("harness-install")
                    } else {
                        Button(L("Remove")) { harness.remove() }
                            .disabled(!harness.mayWrite || harness.busy).accessibilityIdentifier("harness-remove")
                    }
                }
            }
            if harness.hasInstallation, harness.nativeHomes.contains(where: { $0["state"] != "trusted-enabled" }) {
                SettingsSubRow(title: L("For Codex inbox reminders, review the new hooks in each account's /hooks menu."),
                               tint: TallyColor.warning)
            }
            if let error = harness.error {
                SettingsSubRow(title: error, tint: TallyColor.warning)
                    .textSelection(.enabled)
            }
            if harness.previewRoot != nil {
                SettingsSubRow(title: L("Isolated preview: changes stay in the temporary fixture."))
            }
        }
        .task { harness.inspect() }
        .onChange(of: active) { if active { harness.inspect() } }
    }

    private var info: String {
        let what = L("Installs the Tally harness skill and inbox reminders for Claude Code and Codex together. Ask either assistant to adapt your harness or handle messages in the current project.")
        guard harness.hasInstallation else { return what }
        return what + " " + L("The skill works across projects and determines the relevant harness from your current directory and request. Existing project adaptations are removed separately.")
    }

    private var statusTitle: String {
        switch harness.state {
        case "installed": return L("Installed")
        case "incomplete": return L("Needs attention")
        case "not-installed": return L("Not installed")
        default: return L("Checking…")
        }
    }

    private var statusTone: SettingsStatusBadge.Tone {
        switch harness.state {
        case "installed": return .good
        case "incomplete": return .attention
        default: return .neutral
        }
    }
}
