import SwiftUI

/// The Accounts group of Settings: one sub-group per provider - its enable switch, its launch
/// policy, and one row per discovered account (rename, reorder, menu-bar/enable switches).
/// Split out of SettingsView purely for file size; SettingsView hosts it inside a section card.
struct SettingsAccountsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore

    @State private var renamingAccountID: String?

    var body: some View {
        let descriptors = ProviderCatalog.descriptors
        ForEach(Array(descriptors.enumerated()), id: \.element.id) { index, descriptor in
            if index > 0 { rowDivider }
            providerGroup(id: descriptor.id, name: descriptor.name)
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    /// This provider's accounts by EXISTENCE (discovery), not by fetched usage - a switched-off
    /// account must stay listed or it could never be switched back on.
    private func discovered(for providerID: String) -> [ProviderAccount] {
        let mine = store.discoveredAccounts.filter { $0.providerID == providerID }
        let order = settings.orderedAccountIDs(mine.map(\.id))
        return order.compactMap { id in mine.first { $0.id == id } }
    }

    @ViewBuilder
    private func providerGroup(id: String, name: String) -> some View {
        let items = discovered(for: id)
        Toggle(isOn: Binding(
            // userInitiated:false so toggling one provider can't force-reread another provider's
            // declined Keychain item and re-raise its access prompt.
            get: { settings.isEnabled(id) },
            set: { on in
                settings.setEnabled(id, on)
                // Optimistic: every surface reacts the moment the switch flips - cached rows come
                // straight back on enable, rows drop instantly on disable; the refresh behind
                // converges live data and the CLI snapshot.
                if on { store.showCachedAccounts(providerID: id) }
                else { store.hideAccounts { $0.providerID == id } }
                Task { await store.refresh(userInitiated: false) }
            }
        )) { EmptyView() }
        .labelsHidden()
        .toggleStyle(.switch)
        // Custom layout (no Form): spread the identity and the switch ourselves - a bare Toggle
        // renders its control right beside the label, which parked the switch mid-row.
        .frame(maxWidth: .infinity, alignment: .trailing)
        .overlay(alignment: .leading) {
            HStack(spacing: 10) {
                ProviderIconView(providerID: id, size: 16)
                    .frame(width: 20)
                Text(name).font(.subheadline.weight(.semibold))
                // Count only when there is something to count - a "1" badge said nothing.
                if items.count > 1 {
                    Text("\(items.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        if settings.isEnabled(id) {
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
            ModelEffortRow(title: L("Model & effort"),
                           modelOptions: id == "claude" ? ModelCatalog.claudeAliases : ModelCatalog.codexModels,
                           effortLevels: id == "claude" ? EffortLevels.shared.claude : EffortLevels.shared.codex,
                           model: launchDefaultBinding(id, \.model),
                           effort: launchDefaultBinding(id, \.effort))
            if id == "claude" {
                rowDivider
                ModelSelectRow(title: L("Fallback models"),
                               options: ModelCatalog.claudeAliases,
                               value: launchDefaultBinding(id, \.fallbackModel))
            }
            if items.isEmpty {
                rowDivider
                HStack(spacing: 10) {
                    Color.clear.frame(width: 22, height: 22)
                    Text(L("No signed-in accounts found")).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .padding(.leading, 18)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                rowDivider
                // Same numbering the menu-bar strip uses for same-provider accounts, so the
                // settings row visibly maps to a strip segment. Repeating the provider's brand
                // mark per account (it's already on the group row) said nothing.
                accountRow(
                    item,
                    usage: store.accounts.first { $0.id == item.id },
                    badge: items.count > 1 ? index + 1 : nil,
                    moveUp: index > 0 ? { swapAccounts(items, index, index - 1) } : nil,
                    moveDown: index < items.count - 1 ? { swapAccounts(items, index, index + 1) } : nil)
            }
        }
    }

    /// Which account new `tally` sessions launch on: Off (observe only), Manual (pin a card in
    /// the panel), Auto (most headroom wins, re-picked at every launch).
    private func launchPolicyRow(_ providerID: String) -> some View {
        let launchPolicy = LaunchPolicyStore.shared
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Launch account")).font(.subheadline)
                Text(L("Auto starts new sessions on the account with the most room; Manual uses the card you pick in the panel."))
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
                Text(L("Auto")).tag(LaunchPolicyStore.Mode.auto)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .padding(.leading, 18)   // nested under the provider row, like the account rows
    }

    /// Read-only: whether this provider's homes share their harness (skills/config/transcripts).
    /// Detected live from the filesystem - Tally reports the wiring, it never rewires here.
    private func sharingRow(_ providerID: String, items: [ProviderAccount]) -> some View {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .padding(.leading, 18)   // nested under the provider row
    }

    private func swapAccounts(_ items: [ProviderAccount], _ a: Int, _ b: Int) {
        var ids = items.map(\.id)
        ids.swapAt(a, b)
        settings.applyProviderOrder(orderedProviderIDs: ids,
                                    allIDs: store.discoveredAccounts.map(\.id))
    }

    /// One line per account: number badge, name + rename popover over a live status line, then a
    /// fixed column set (reorder arrows, menu-bar switch, enable switch) that never shifts.
    private func accountRow(_ item: ProviderAccount, usage: AccountUsage?, badge: Int?,
                            moveUp: (() -> Void)?, moveDown: (() -> Void)?) -> some View {
        let enabled = settings.isAccountEnabled(item.id)
        return HStack(spacing: 10) {
            // No reserved column for single-account providers: their name starts where the
            // number badges start, so every row's HEAD lines up on one vertical line.
            if let badge {
                ZStack {
                    Circle().fill(.quaternary)
                    Text("\(badge)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                // Plain Text + a pencil-popover for renaming: an inline TextField can't live in
                // this layout sanely (see RenamePopover) and the popover field behaves normally.
                HStack(spacing: 5) {
                    Text(settings.displayLabel(accountID: item.id, fallback: item.label))
                        .font(.subheadline.weight(.semibold))
                    Button {
                        renamingAccountID = item.id
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Rename"))
                    .popover(isPresented: Binding(
                        get: { renamingAccountID == item.id },
                        set: { if !$0 { renamingAccountID = nil } }
                    )) {
                        RenamePopover(
                            defaultLabel: item.label,
                            override: Binding(
                                get: { settings.accountLabels[item.id] },
                                set: { settings.accountLabels[item.id] = $0 }
                            ),
                            dismiss: { renamingAccountID = nil })
                    }
                }

                HStack(spacing: 8) {
                    if !enabled {
                        Text(L("Disabled")).font(.caption2).foregroundStyle(.tertiary)
                    } else if let usage {
                        if let plan = usage.planName {
                            Text(plan)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                        }
                        if usage.metrics.isEmpty, let error = usage.error {
                            Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            liveStatus(usage)
                        }
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(L("Loading…")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // Constant height across all variants (plan capsule, plain caption, spinner) so
                // toggling an account never changes the row height and shifts its neighbours.
                .frame(height: 17, alignment: .leading)
            }

            Spacer()

            // Reorder arrows (multi-account providers only, column always reserved so the switch
            // columns line up across every card).
            VStack(spacing: 2) {
                reorderArrow("chevron.up", action: moveUp)
                reorderArrow("chevron.down", action: moveDown)
            }
            .frame(width: 16)
            .opacity(moveUp == nil && moveDown == nil ? 0 : 1)

            // Always laid out (dimmed + inert when the account is off) so toggling never shifts
            // the controls around - disappearing chrome made the row jump.
            menuBarToggle(item.id)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
                .padding(.trailing, 10)

            // The account's own switch, mirroring the provider switch one level down: off means
            // not polled, no card, no menu-bar segment, and the CLI skips it. Labeled like the
            // menu-bar switch next to it - two adjacent switches with one label were a coin flip.
            HStack(spacing: 6) {
                Text(L("Enabled")).font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: Binding(
                    get: { settings.isAccountEnabled(item.id) },
                    set: { on in
                        settings.setAccountEnabled(item.id, on)
                        // Optimistic, same as the provider switch above.
                        if on { store.showCachedAccounts(providerID: item.providerID) }
                        else { store.hideAccounts { $0.id == item.id } }
                        Task { await store.refresh(userInitiated: false) }
                    }
                )) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .opacity(enabled ? 1 : 0.6)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .padding(.leading, 18)   // nested under the provider row
    }

    private func reorderArrow(_ symbol: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(action == nil ? Color(nsColor: .quaternaryLabelColor) : .secondary)
                .frame(width: 16, height: 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    /// "● 98% · ● 71%" - session then weekly, dot coloured by the window's severity. Compact
    /// (no window names): the row also carries reorder arrows and two switches, and the full
    /// labels truncated; hover explains each value.
    private func liveStatus(_ account: AccountUsage) -> some View {
        HStack(spacing: 8) {
            ForEach(account.metrics.filter { !$0.isModelScoped }.prefix(2)) { metric in
                HStack(spacing: 3) {
                    Circle().fill(metric.severity.color).frame(width: 5, height: 5)
                    Text(UsageFormat.percent(metric, mode: settings.displayMode))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("\(L(metric.label)) \(UsageFormat.percent(metric, mode: settings.displayMode)) \(UsageFormat.modeWord(settings.displayMode))")
            }
        }
    }

    // A labeled mini switch: an icon-only toggle here read as "no idea what this does".
    private func menuBarToggle(_ accountID: String) -> some View {
        HStack(spacing: 6) {
            Text(L("Menu bar")).font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: Binding(
                get: { settings.isShownInMenuBar(accountID) },
                set: { settings.setShownInMenuBar(accountID, $0); UsageStore.shared.onChange?() }
            )) { EmptyView() }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .help(L("Show in menu bar"))
    }

    /// Rename UI in a popover so the field lives outside the row layout entirely. Clearing (or
    /// typing the default name back) removes the override.
    private struct RenamePopover: View {
        let defaultLabel: String
        @Binding var override: String?
        let dismiss: () -> Void
        @State private var text = ""

        var body: some View {
            TextField("", text: $text, prompt: Text(defaultLabel))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .padding(12)
                .onAppear { text = override ?? "" }
                .onSubmit { commit() }
                .onDisappear { commit() }
        }

        private func commit() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            override = (trimmed.isEmpty || trimmed == defaultLabel) ? nil : trimmed
            dismiss()
        }
    }
}
