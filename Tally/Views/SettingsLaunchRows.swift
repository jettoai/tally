import SwiftUI

/// The per-provider launch-default rows (start mode, permissions, model, effort), split out of
/// SettingsLaunchView for file size. All of them write LaunchPolicyStore and follow one
/// contract: empty/default injects nothing, and flags the user types always win (CLI-side).
///
/// Each row is a `SettingsRow` (B-2526): a one-line `subtitle`, with the longer explanation in the
/// row's hover (`info`). Anything the user has to act on stays a line of its own.
extension SettingsLaunchView {
    func launchDefaultBinding(_ providerID: String,
                              _ keyPath: WritableKeyPath<LaunchPolicyStore.ProviderPolicy, String?>)
        -> Binding<String?> {
        Binding(
            get: { LaunchPolicyStore.shared.policy(providerID)[keyPath: keyPath] },
            set: { LaunchPolicyStore.shared.setLaunchDefault(providerID, keyPath, $0) }
        )
    }

    /// Bare provider launches start fresh or continue the directory's latest conversation.
    /// One-off escape: `tally <provider> --new`.
    func startModeRow(_ providerID: String) -> some View {
        let launchPolicy = LaunchPolicyStore.shared
        return SettingsRow(
            title: L("Start with"), subtitle: L("Applies to bare launches."), icon: "arrow.uturn.forward",
            info: L("Applies to bare launches; tally claude --new starts fresh once.")
                .replacingOccurrences(of: "tally claude", with: "tally \(providerID)")) {
            Picker("", selection: Binding(
                get: { launchPolicy.policy(providerID).startMode ?? "new" },
                set: { launchPolicy.setLaunchDefault(providerID, \.startMode, $0 == "new" ? nil : $0) }
            )) {
                Text(L("new")).tag("new")
                Text(L("continue")).tag("continue")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Extra flags appended ONLY when the supervisor relaunches the session on the fallback
    /// pairing (e.g. compensating a weaker model with extra system-prompt instructions).
    func fallbackArgsRow(_ providerID: String) -> some View {
        SettingsRow(
            title: L("Fallback args"), subtitle: L("Added only when relaunched on the fallback model."),
            icon: "text.append",
            info: L("Appended only when the session is relaunched on the fallback model.")) {
            TextField("--append-system-prompt …" as String, text: Binding(
                get: { LaunchPolicyStore.shared.policy(providerID).fallbackArgs ?? "" },
                set: { LaunchPolicyStore.shared.setLaunchDefault(providerID, \.fallbackArgs, $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 210)
        }
    }

    /// The permission mode injected by the tally launcher, offered to every provider because it is
    /// ONE setting (one enum, one state.json field) that every provider's CLI has flags for.
    ///
    /// Worded in each CLI's own vocabulary, though, because that is what the person will see the
    /// session come up in - the wording itself is `PermissionMode.displayName`, shared with the
    /// panel chip that reports the same choice.
    func permissionRow(_ providerID: String) -> some View {
        let launchPolicy = LaunchPolicyStore.shared
        let codex = providerID == "codex"
        return SettingsRow(
            title: codex ? L("Codex permissions") : L("Claude permissions"),
            subtitle: L("Flags you type yourself win."), icon: "lock.shield",
            info: L("Applied when launching through tally; flags you type yourself win.")) {
            Picker("", selection: Binding(
                get: { launchPolicy.policy(providerID).permissionMode ?? .standard },
                set: { launchPolicy.setPermissionMode(providerID, $0) }
            )) {
                ForEach(LaunchPolicyStore.PermissionMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.displayName(providerID)).tag(mode)
                }
            }
            .labelsHidden()
        }
    }

}

/// The launch-default model/effort as a STAGED pair with an explicit Apply, so both are written to
/// state.json in one atomic change. Choosing model then effort no longer produces two writes
/// seconds apart that a running session's follow sees as two relaunches; it also makes "this
/// re-points running sessions" a deliberate act, not a side effect of a dropdown. Running-session
/// drift is called out generically (the app has no session registry yet, M3).
struct StagedModelEffortRow: View {
    let providerID: String
    let title: String
    let subtitle: String
    let info: String
    let modelOptions: [String]
    let effortLevels: [String]

    @State private var stagedModel: String?
    @State private var stagedEffort: String?
    @State private var loaded = false

    private var committedModel: String? { LaunchPolicyStore.shared.policy(providerID).model }
    private var committedEffort: String? { LaunchPolicyStore.shared.policy(providerID).effort }
    private var dirty: Bool { stagedModel != committedModel || stagedEffort != committedEffort }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelEffortRow(title: title, subtitle: subtitle, icon: "sparkles", info: info,
                           modelOptions: modelOptions, effortLevels: effortLevels,
                           model: $stagedModel, effort: $stagedEffort)
            if dirty {
                // The next step is the user's, so it is a line of its own, not a hover.
                SettingsSubRow(title: L("Not applied. Running sessions keep the current model and effort until you apply."),
                               tint: TallyColor.warning) {
                    Button(L("Apply")) {
                        LaunchPolicyStore.shared.setLaunchPair(providerID, model: stagedModel,
                                                              effort: stagedEffort)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            // Load the committed pair once; a fresh view (re-shown pane) reloads the current value.
            guard !loaded else { return }
            stagedModel = committedModel
            stagedEffort = committedEffort
            loaded = true
        }
    }
}

/// Model and effort as ONE pairing (they take effect together - "which brain at which depth"),
/// side by side in a single row. Model options come from each provider's authoritative catalog
/// with a Custom escape; effort levels from the installed claude CLI's help / codex docs.
struct ModelEffortRow: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var info: String?
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
        // The custom field lives on its own second line under the two menus, so the row's main line
        // is identical in both modes and the field gets room enough for real model ids.
        SettingsRow(title: title, subtitle: subtitle, icon: icon, info: info) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) { mainLine }
                if selection == "custom" {
                    TextField(L("Custom…"), text: Binding(
                        get: { model ?? "" },
                        set: { model = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                }
            }
        }
    }

    @ViewBuilder
    private var mainLine: some View {
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
            Text(L("Default")).tag("")
            ForEach(modelOptions, id: \.self) { Text(verbatim: $0).tag($0) }
            Divider()
            Text(L("Custom…")).tag("custom")
        }
        .labelsHidden()
        .fixedSize()
        Picker("", selection: Binding(
            get: { effort ?? "" },
            set: { effort = $0.isEmpty ? nil : $0 }
        )) {
            Text(L("Default")).tag("")
            ForEach(effortLevels, id: \.self) { Text(L($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

extension LaunchPolicyStore.PermissionMode {
    /// What the picker and the panel chip show: the store's English label run through the string
    /// catalog (Full access has its own wording); the store's table stays free of the app's string
    /// catalog so the launcher and its tests can compile it alone.
    func displayName(_ providerID: String) -> String {
        self == .bypass ? L("Full access") : L(label(providerID))
    }
}
