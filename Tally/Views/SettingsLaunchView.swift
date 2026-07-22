import SwiftUI

/// The Launch group of Settings: everything that decides what a `tally` launch does, one
/// sub-group per enabled provider - the launch mode (Off / Manual / Smart), the harness-sharing
/// report it relies on, and the launch defaults (start mode, permissions, model & effort,
/// fallback pairing). Split out of the Accounts pane: "which accounts exist" and "what happens
/// when I launch" are different questions, and one pane answering both buried each.
/// The row builders live in SettingsLaunchRows.swift.
struct SettingsLaunchView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore

    var body: some View {
        let descriptors = ProviderCatalog.descriptors.filter { settings.isEnabled($0.id) }
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
        ModelEffortRow(title: L("Default model & effort"),
                       caption: L("Applies to new sessions and, at the next quiet moment, to running ones; a model you typed yourself always wins."),
                       modelOptions: id == "claude" ? ModelCatalog.claudeAliases : ModelCatalog.codexModels,
                       effortLevels: id == "claude" ? EffortLevels.shared.claude : EffortLevels.shared.codex,
                       model: launchDefaultBinding(id, \.model),
                       effort: launchDefaultBinding(id, \.effort))
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
        return HStack {
            Text(L("Shared configuration")).font(.subheadline)
            Spacer()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .help(detail)
        .settingsRowPadding()
    }
}
