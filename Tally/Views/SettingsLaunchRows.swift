import SwiftUI

/// The per-provider launch-default rows (start mode, permissions, model, effort), split out of
/// SettingsLaunchView for file size. All of them write LaunchPolicyStore and follow one
/// contract: empty/default injects nothing, and flags the user types always win (CLI-side).
extension SettingsLaunchView {
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
                Text(verbatim: "new").tag("new")
                Text(verbatim: "continue").tag("continue")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .settingsRowPadding()
    }

    /// Extra flags appended ONLY when the supervisor relaunches the session on the fallback
    /// pairing (e.g. compensating a weaker model with extra system-prompt instructions).
    func fallbackArgsRow(_ providerID: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Fallback args")).font(.subheadline)
                Text(L("Appended only when the session is relaunched on the fallback model."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            TextField("--append-system-prompt …" as String, text: Binding(
                get: { LaunchPolicyStore.shared.policy(providerID).fallbackArgs ?? "" },
                set: { LaunchPolicyStore.shared.setLaunchDefault(providerID, \.fallbackArgs, $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 210)
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
                Text(verbatim: "default").tag(LaunchPolicyStore.PermissionMode.standard)
                Text(verbatim: "plan").tag(LaunchPolicyStore.PermissionMode.plan)
                Text(verbatim: "accept edits").tag(LaunchPolicyStore.PermissionMode.acceptEdits)
                Text(verbatim: "bypass").tag(LaunchPolicyStore.PermissionMode.bypass)
            }
            .labelsHidden()
            .fixedSize()
        }
        .settingsRowPadding()
    }

}

/// Model and effort as ONE pairing (they take effect together - "which brain at which depth"),
/// side by side in a single row. Model options come from each provider's authoritative catalog
/// with a Custom escape; effort levels from the installed claude CLI's help / codex docs.
struct ModelEffortRow: View {
    let title: String
    /// Optional behavior note rendered under the title, in the left column like every other
    /// captioned row (a full-width footnote under the row read as a stray paragraph).
    var caption: String? = nil
    let modelOptions: [String]
    let effortLevels: [String]
    @Binding var model: String?
    @Binding var effort: String?

    @State private var customMode = false

    private var selection: String {
        if customMode { return "custom" }
        guard let model else { return "" }
        return modelOptions.contains(model) ? model : "custom"
    }

    var body: some View {
        // The custom field lives on its own second line: sharing the main line with both pickers
        // squeezed the caption column to ~80pt (an eight-line sliver), and the window follows the
        // tallest pane, so every pane paid for it. Off the line, the main row's geometry is
        // identical in both modes, and the field gets room enough for real model ids.
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                mainLine
            }
            if selection == "custom" {
                TextField("Custom" as String, text: Binding(
                    get: { model ?? "" },
                    set: { model = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
        .settingsRowPadding()
    }

    @ViewBuilder
    private var mainLine: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Picker("", selection: Binding(
                get: { selection },
                set: { picked in
                    switch picked {
                    case "": customMode = false; model = nil
                    case "custom": customMode = true
                    default: customMode = false; model = picked
                    }
                }
            )) {
                Text(verbatim: "Default").tag("")
                ForEach(modelOptions, id: \.self) { Text(verbatim: $0).tag($0) }
                Divider()
                Text(verbatim: "Custom…").tag("custom")
            }
            .labelsHidden()
            .fixedSize()
            Picker("", selection: Binding(
                get: { effort ?? "" },
                set: { effort = $0.isEmpty ? nil : $0 }
            )) {
                Text(verbatim: "Default").tag("")
                ForEach(effortLevels, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
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
