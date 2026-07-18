import SwiftUI

/// The per-provider launch-default rows (start mode, permissions, model, effort), split out of
/// SettingsAccountsView for file size. All of them write LaunchPolicyStore and follow one
/// contract: empty/default injects nothing, and flags the user types always win (CLI-side).
extension SettingsAccountsView {
    func launchDefaultBinding(_ providerID: String,
                              _ keyPath: WritableKeyPath<LaunchPolicyStore.ProviderPolicy, String?>)
        -> Binding<String?> {
        Binding(
            get: { LaunchPolicyStore.shared.policy(providerID)[keyPath: keyPath] },
            set: { LaunchPolicyStore.shared.setLaunchDefault(providerID, keyPath, $0) }
        )
    }

    /// Bare `tally claude` starts fresh or continues the directory's latest conversation.
    /// One-off escape: `tally claude --new`.
    func startModeRow(_ providerID: String) -> some View {
        let launchPolicy = LaunchPolicyStore.shared
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Start with")).font(.subheadline)
                Text(L("Applies to bare launches; tally claude --new starts fresh once."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { launchPolicy.policy(providerID).startMode ?? "new" },
                set: { launchPolicy.setLaunchDefault(providerID, \.startMode, $0 == "new" ? nil : $0) }
            )) {
                Text(verbatim: "New").tag("new")
                Text(verbatim: "Continue").tag("continue")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .settingsRowPadding()
    }

    /// Claude Code permission mode injected by the tally launcher.
    func permissionRow(_ providerID: String) -> some View {
        let launchPolicy = LaunchPolicyStore.shared
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Claude permissions")).font(.subheadline)
                Text(L("Applied when launching through tally; flags you type yourself win."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { launchPolicy.policy(providerID).permissionMode ?? .standard },
                set: { launchPolicy.setPermissionMode(providerID, $0) }
            )) {
                Text(verbatim: "Default").tag(LaunchPolicyStore.PermissionMode.standard)
                Text(verbatim: "Plan").tag(LaunchPolicyStore.PermissionMode.plan)
                Text(verbatim: "Accept edits").tag(LaunchPolicyStore.PermissionMode.acceptEdits)
                Text(verbatim: "Bypass").tag(LaunchPolicyStore.PermissionMode.bypass)
            }
            .labelsHidden()
            .fixedSize()
        }
        .settingsRowPadding()
    }

    /// Reasoning-effort launch default. Claude's list is parsed from the installed CLI's own
    /// --help at runtime (the authoritative enumeration); codex has none, so doc-anchored.
    func effortRow(_ providerID: String) -> some View {
        let launchPolicy = LaunchPolicyStore.shared
        let levels = providerID == "claude" ? EffortLevels.shared.claude : EffortLevels.shared.codex
        return HStack {
            Text(L("Effort")).font(.subheadline)
            Spacer()
            Picker("", selection: Binding(
                get: { launchPolicy.policy(providerID).effort ?? "" },
                set: { launchPolicy.setLaunchDefault(providerID, \.effort, $0.isEmpty ? nil : $0) }
            )) {
                Text(verbatim: "Default").tag("")
                ForEach(levels, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .settingsRowPadding()
    }
}

/// A select-first launch default: the curated/authoritative options in a menu, with a Custom
/// entry that reveals a free-text field - model ids drift server-side, so the menu is a
/// convenience, never a gate.
struct ModelSelectRow: View {
    let title: String
    let options: [String]
    @Binding var value: String?

    @State private var customMode = false

    private var selection: String {
        if customMode { return "custom" }
        guard let value else { return "" }
        return options.contains(value) ? value : "custom"
    }

    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            if selection == "custom" {
                TextField("Custom" as String, text: Binding(
                    get: { value ?? "" },
                    set: { value = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            }
            Picker("", selection: Binding(
                get: { selection },
                set: { picked in
                    switch picked {
                    case "": customMode = false; value = nil
                    case "custom": customMode = true
                    default: customMode = false; value = picked
                    }
                }
            )) {
                Text(verbatim: "Default").tag("")
                ForEach(options, id: \.self) { Text(verbatim: $0).tag($0) }
                Divider()
                Text(verbatim: "Custom…").tag("custom")
            }
            .labelsHidden()
            .fixedSize()
        }
        .settingsRowPadding()
    }
}

extension View {
    /// The shared row inset of the nested provider-group rows in Settings.
    func settingsRowPadding() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .padding(.leading, 18)
    }
}
