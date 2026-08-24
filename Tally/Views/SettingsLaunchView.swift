import SwiftUI

/// The Launch group of Settings: everything that decides what a `tally` launch does, one
/// sub-group per enabled provider - the launch mode (Off / Manual / Smart), the harness-sharing
/// report it relies on, and the launch defaults (start mode, permissions, model & effort,
/// fallback pairing). Split out of the Accounts pane: "which accounts exist" and "what happens
/// when I launch" are different questions, and one pane answering both buried each.
/// The row builders live in SettingsLaunchRows.swift.
///
/// One row here is about a different launch: whether macOS starts TALLY at login
/// (SettingsLaunchAtLoginRow). It leads the pane, unindented and outside every provider group,
/// because it is the only setting on it that applies before any provider exists, and it is the
/// one this pane's title reads as first.
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
        SettingsLaunchAtLoginRow(isVisible: visible)
        // The morning schedule, beside the login item because both are about something happening
        // with nobody at the machine. Only while Claude is on: it is the one provider whose limits
        // work this way, so with Claude off the row would be a switch over nothing.
        if settings.isEnabled(EarlyStartLogic.providerID) {
            rowDivider
            SettingsEarlyStartRow(store: EarlyStartStore.shared, isVisible: visible)
        }
        rowDivider
        if descriptors.isEmpty {
            Text(L("Enable a provider in Accounts to configure launches."))
                .font(.caption).foregroundStyle(.secondary)
                .padding(14)
        } else {
            ForEach(Array(descriptors.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 { rowDivider }
                providerGroup(id: descriptor.id, name: descriptor.name)
            }
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    /// This provider's accounts by EXISTENCE (discovery), in the user's order - the launch mode
    /// row only matters once there are two to choose between.
    private func discovered(for providerID: String) -> [ProviderAccount] {
        let mine = store.discoveredAccounts.filter { $0.providerID == providerID }
        let order = settings.orderedAccountIDs(mine.map(\.id))
        return order.compactMap { id in mine.first { $0.id == id } }
    }

    @ViewBuilder
    private func providerGroup(id: String, name: String) -> some View {
        let items = discovered(for: id)
        HStack(spacing: 10) {
            ProviderIconView(providerID: id, size: 16)
                .frame(width: 20)
            Text(name).font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        // Launch policy only surfaces once there are two accounts to choose between - with one
        // account every mode launches the same place, so the control would just be noise.
        if items.count > 1 {
            rowDivider
            launchPolicyRow(id)
            rowDivider
            sharingRow(id, items: items)
        }
        if id == "claude" {
            rowDivider
            startModeRow(id)
            rowDivider
            permissionRow(id)
        }
        rowDivider
        // The caption spells out the follow behavior: defaults bind at launch, and a supervised
        // running session also adopts a changed default at its next quiet moment (a model the
        // user typed themselves is left alone).
        StagedModelEffortRow(providerID: id, title: L("Default model & effort"),
                             caption: L("Applies to new sessions and, at the next quiet moment, to running ones; a model you typed yourself always wins."),
                             modelOptions: id == "claude" ? ModelCatalog.claudeAliases : ModelCatalog.codexModels,
                             effortLevels: id == "claude" ? EffortLevels.shared.claude : EffortLevels.shared.codex)
        if id == "claude" {
            rowDivider
            ModelEffortRow(title: L("Fallback & effort"),
                           modelOptions: ModelCatalog.claudeAliases,
                           effortLevels: EffortLevels.shared.claude,
                           model: launchDefaultBinding(id, \.fallbackModel),
                           effort: launchDefaultBinding(id, \.fallbackEffort))
            rowDivider
            fallbackArgsRow(id)
        }
    }

    /// Which account new `tally` sessions launch on: Off (observe only), Manual (pin a card in
    /// the panel), Smart (burn-rate pick - time and remaining both count - re-run every launch).
    func launchPolicyRow(_ providerID: String) -> some View {
        let launchPolicy = LaunchPolicyStore.shared
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Launch account")).font(.subheadline)
                Text(L("Smart starts new sessions on the account whose quota goes furthest (reset times and remaining both count); Manual uses the card you pick in the panel."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
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
            .fixedSize()
        }
        .settingsRowPadding()
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
        return HStack(spacing: 8) {
            Text(L("Shared configuration")).font(.subheadline)
            Spacer()
            Text(label).font(.caption).foregroundStyle(.secondary)
            Button(L("Manage in Integrations"), action: showIntegrations)
                .buttonStyle(.link)
                .font(.caption)
        }
        .help(detail)
        .settingsRowPadding()
    }
}
