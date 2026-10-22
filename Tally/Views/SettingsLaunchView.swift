import SwiftUI

/// The Launch group of Settings: everything that decides what a `tally` launch does, one
/// sub-group per enabled provider - the launch mode (Off / Manual / Smart), the harness-sharing
/// report it relies on, and the launch defaults (start mode, permissions, model & effort,
/// fallback pairing). Split out of the Accounts pane: "which accounts exist" and "what happens
/// when I launch" are different questions, and one pane answering both buried each.
/// The row builders live in SettingsLaunchRows.swift.
///
/// Laid out as a page (B-2526): header, then one titled card per group, none over five rows. The
/// first group is about a different launch: whether macOS starts TALLY at login
/// (SettingsLaunchAtLoginRow). It leads the pane and stands outside every provider group, because
/// it is the only setting on it that applies before any provider exists.
struct SettingsLaunchView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    /// Whether this pane is the one Settings is showing. Only the launch-at-login row needs it,
    /// and only because it collects a report that can be collected once (see that row).
    var visible: Bool = false
    /// Takes Settings to the Integrations section, where sharing is turned on and off. The sharing
    /// row below REPORTS a state it cannot change; this is the way to the control that can.
    var showIntegrations: () -> Void = {}

    var body: some View {
        let descriptors = ProviderCatalog.descriptors.filter { settings.isEnabled($0.id) }
        let claudeOn = settings.isEnabled(EarlyStartLogic.providerID)
        let codexOn = settings.isEnabled(CodexAutoRedeemLogic.providerID)
        SettingsPage {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(title: L("Launch"),
                                   subtitle: L("How tally claude and tally codex start sessions, and what runs while you are away."))
                // The login item is the one row here a dev build may not operate (SettingsLaunchAtLoginRow);
                // a preview launch stands on a fixture and operates it, so it needs no apology.
                if LoginItemPreview.fixture == nil {
                    SettingsDevBanner(message: L("Start at login is managed by the installed release app."))
                }
            }
            SettingsSection(L("Startup"), symbol: "power") {
                SettingsLaunchAtLoginRow(isVisible: visible)
            }
            // The morning schedule and the resets, beside the login item because all of them are about
            // something happening with nobody at the machine. Each sits under its own provider gate:
            // Claude is the one provider whose 5-hour window works this way, and the banked-reset
            // redeem is Codex's counterpart, so with the provider off the row would be a switch over
            // nothing.
            if claudeOn || codexOn {
                SettingsSection(L("Quota windows"), symbol: "clock.arrow.circlepath") {
                    if claudeOn {
                        SettingsEarlyStartRow(store: EarlyStartStore.shared, isVisible: visible)
                        SettingsDivider()
                        SettingsLimitResetRow(store: LimitResetStore.shared)
                    }
                    if claudeOn && codexOn { SettingsDivider() }
                    if codexOn { SettingsCodexAutoRedeemRow(store: CodexAutoRedeemStore.shared) }
                }
            }
            if descriptors.isEmpty {
                SettingsCard {
                    Text(L("Enable a provider in Accounts to configure launches."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(20)
                }
            } else {
                ForEach(descriptors, id: \.id) { descriptor in
                    providerGroup(id: descriptor.id, name: descriptor.name)
                }
            }
        }
    }

    /// This provider's accounts by EXISTENCE (discovery), in the user's order - the launch mode
    /// row only matters once there are two to choose between.
    private func discovered(for providerID: String) -> [ProviderAccount] {
        let mine = store.discoveredAccounts.filter { $0.providerID == providerID }
        let order = settings.orderedAccountIDs(mine.map(\.id))
        return order.compactMap { id in mine.first { $0.id == id } }
    }

    /// One card for the provider's launch behaviour, and for Claude a second card for its models
    /// (a Codex card holds its single model row, which keeps it at five rows).
    @ViewBuilder
    private func providerGroup(id: String, name: String) -> some View {
        let items = discovered(for: id)
        let claude = id == "claude"
        SettingsSection(name, icon: { ProviderIconView(providerID: id, size: 16) }) {
            // Launch policy only surfaces once there are two accounts to choose between - with one
            // account every mode launches the same place, so the control would just be noise.
            if items.count > 1 {
                launchPolicyRow(id)
                SettingsDivider()
                sharingRow(id, items: items)
                SettingsDivider()
            }
            startModeRow(id)
            // Every provider: the permission mode is one setting with a flag on both CLIs
            // (`applyLaunchDefaults`). Each provider resolves the start mode in its own history.
            SettingsDivider()
            permissionRow(id)
            if !claude {
                SettingsDivider()
                defaultModelRow(id, claude: false)
            }
        }
        if claude {
            SettingsSection(L("Claude models"), symbol: "cpu") {
                defaultModelRow(id, claude: true)
                SettingsDivider()
                ModelEffortRow(title: L("Fallback & effort"), icon: "arrow.down.circle",
                               modelOptions: ModelCatalog.claudeAliases,
                               effortLevels: EffortLevels.shared.claude,
                               model: launchDefaultBinding(id, \.fallbackModel),
                               effort: launchDefaultBinding(id, \.fallbackEffort))
                SettingsDivider()
                fallbackArgsRow(id)
            }
        }
    }

    /// The caption spells out the follow behavior: defaults bind at launch, and a supervised
    /// running session also adopts a changed default at its next quiet moment (a model the
    /// user typed themselves is left alone). That follow only holds for claude - codex is a
    /// monitoring-only resident for interactive launches, so a running Codex session never follows.
    private func defaultModelRow(_ id: String, claude: Bool) -> some View {
        StagedModelEffortRow(providerID: id, title: L("Default model & effort"),
                             subtitle: claude
                                 ? L("Also applies to running sessions at their next quiet moment.")
                                 : L("New sessions only; a running session keeps its model."),
                             info: claude
                                 ? L("Applies to new sessions and, at the next quiet moment, to running ones; a model you typed yourself always wins.")
                                 : L("Applies to new sessions only; a running codex session keeps its model and effort until you start it again. A model you typed yourself always wins."),
                             modelOptions: claude ? ModelCatalog.claudeAliases : ModelCatalog.codexModels,
                             effortLevels: claude ? EffortLevels.shared.claude : EffortLevels.shared.codex)
    }

    /// Which account new `tally` sessions launch on: Off (observe only), Manual (pin a card in
    /// the panel), Smart (burn-rate pick - time and remaining both count - re-run every launch).
    func launchPolicyRow(_ providerID: String) -> some View {
        let launchPolicy = LaunchPolicyStore.shared
        return SettingsRow(
            title: L("Launch account"), subtitle: L("Smart picks the account whose quota lasts longest."),
            icon: "person.2.wave.2",
            info: L("Smart starts new sessions on the account whose quota goes furthest (reset times and remaining both count); Manual uses the card you pick in the panel.")) {
            Picker("", selection: Binding(
                get: { launchPolicy.mode(providerID) },
                set: { launchPolicy.setMode(providerID, $0) }
            )) {
                Text(L("Off")).tag(LaunchPolicyStore.Mode.off)
                Text(L("Manual")).tag(LaunchPolicyStore.Mode.manual)
                Text(L("Smart")).tag(LaunchPolicyStore.Mode.auto)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Read-only: whether this provider's homes share their harness (skills/config/transcripts).
    /// Detected live from the filesystem - Tally reports the wiring, it never rewires here.
    ///
    /// Which is exactly why it ends in a way OUT of this pane. A row that states a setting and holds
    /// no control for it reads as a control that is broken or greyed; the switch is one pane away,
    /// in Integrations, and was searched for twice without being found (Albert, 2026-08-14). The
    /// link names its destination rather than saying "Manage", so the row teaches where sharing
    /// lives even to somebody who never presses it.
    func sharingRow(_ providerID: String, items: [ProviderAccount]) -> some View {
        let primary = items.first?.launchHome
        let reports = items.dropFirst().compactMap { account -> HarnessSharing.Report? in
            guard let primary, let home = account.launchHome else { return nil }
            return HarnessSharing.report(primaryHome: primary, secondaryHome: home,
                                         providerID: providerID)
        }
        let shared = reports.reduce(0) { $0 + $1.sharedItems.count }
        let total = reports.reduce(0) { $0 + $1.total }
        let label = shared == 0 || total == 0 ? L("Independent")
            : shared == total ? L("Shared")
            : "\(L("Partially shared")) (\(shared)/\(total))"
        let independent = Set(reports.flatMap(\.independentItems)).sorted().joined(separator: ", ")
        let detail = independent.isEmpty
            ? Set(reports.flatMap(\.sharedItems)).sorted().joined(separator: ", ")
            : "\(L("Independent")): \(independent)"
        return SettingsRow(title: L("Shared configuration"), subtitle: label, icon: "link", info: detail) {
            Button(L("Manage in Integrations"), action: showIntegrations)
                .buttonStyle(.link)
        }
    }
}
