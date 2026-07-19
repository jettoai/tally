import SwiftUI
import AppKit

/// The popover's launch-control chrome, split out of PopoverRootView for file size: the header
/// summary strip (what the next launch will do) and the "?" help popover (how to launch, live
/// shell-integration state). Both render from LaunchPolicyStore so they can never teach or
/// summarize a stale contract.
extension PopoverRootView {
    /// One caption chip-set per provider with NON-DEFAULT launch settings (continue, permission
    /// mode, model, effort) - "what will I get when I launch" at a glance. Providers on all
    /// defaults contribute nothing, so an untouched install never shows the strip at all.
    /// Clicking it opens Settings, where the values are edited.
    private var launchSummaryItems: [(String, [String], String?)] {
        ProviderCatalog.descriptors.compactMap { descriptor in
            guard settings.isEnabled(descriptor.id) else { return nil }
            let policy = LaunchPolicyStore.shared.policy(descriptor.id)
            var chips: [String] = []
            if policy.startMode == "continue" { chips.append("continue") }
            switch policy.permissionMode {
            case .plan: chips.append("plan")
            case .acceptEdits: chips.append("accept edits")
            case .bypass: chips.append("bypass")
            case .standard, nil: break
            }
            if let model = policy.model { chips.append(model) }
            if let effort = policy.effort { chips.append(effort) }
            // Fallback is a conditional path, so it enriches the tooltip only - a chip here
            // would read as "the next launch uses opus", which it doesn't.
            let fallback = policy.fallbackModel.map { model in
                ([model] + [policy.fallbackEffort].compactMap { $0 }).joined(separator: " ")
            }
            return chips.isEmpty ? nil : (descriptor.id, chips, fallback)
        }
    }

    private func launchSummaryTooltip(_ items: [(String, [String], String?)]) -> String {
        L("Next launch") + "\n" + items.map { providerID, chips, fallback in
            var line = ProviderCatalog.displayName(for: providerID) + ": "
                + chips.joined(separator: " · ")
            if let fallback { line += " · " + L("fallback") + " → " + fallback }
            return line
        }.joined(separator: "\n")
    }

    @ViewBuilder
    var launchSummaryStrip: some View {
        let items = launchSummaryItems
        if !items.isEmpty {
            Button {
                StatusItemController.openSettingsWindow()
            } label: {
                HStack(spacing: 12) {
                    ForEach(items, id: \.0) { provider, chips, _ in
                        HStack(spacing: 5) {
                            ProviderIconView(providerID: provider, size: 11)
                            Text(chips.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(launchSummaryTooltip(items))
            Divider()
        }
    }

    /// The "?" popover: every launch command with what it does, the LIVE shell-integration state
    /// (a claim like "bare commands follow the policy" is only true when the shims are actually
    /// installed, so say which), and what clicking a card does.
    var launchHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Launch account")).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                // The claude rows follow the configured start mode, so the help never teaches a
                // flag the user's own default already made redundant.
                if LaunchPolicyStore.shared.policy("claude").startMode == "continue" {
                    commandRow("tally claude", caption: L("Continue the latest session (your default)"))
                    commandRow("tally claude --new", caption: L("New session"))
                } else {
                    commandRow("tally claude", caption: L("New session"))
                    commandRow("tally claude --continue", caption: L("Continue the latest session"))
                }
                commandRow("tally codex", caption: L("New session"))
                // The cross-account conversation mover is only taught where it has a job:
                // with every claude home sharing one projects tree (detected, not assumed),
                // conversations are visible everywhere and a bare launch already continues them.
                if !HarnessSharing.allShare(
                    item: "projects",
                    homes: UsageStore.shared.discoveredAccounts
                        .filter { $0.providerID == "claude" }
                        .compactMap(\.launchHome)) {
                    commandRow("tally resume", caption: L("Move this directory's latest conversation to another account and continue there"))
                }
            }
            integrationStatusLine
            Text(L("A ✦ in the status line means the session was launched by Tally."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Pin an account with the ◯ on its card; click the pin badge to go back to Smart."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .onAppear { IntegrationsStore.shared.refresh() }
    }

    private func commandRow(_ command: String, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CopyCommandChip(command: command)
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Live shim state: installed (both) / partial / none, with the none case pointing at where
    /// to fix it. Refreshed every time the popover opens.
    private var integrationStatusLine: some View {
        let integrations = IntegrationsStore.shared
        let installed = IntegrationsStore.Shim.allCases.filter {
            integrations.shimStatus($0) == .installed
        }
        let icon: String, color: Color, text: String
        if installed.count == IntegrationsStore.Shim.allCases.count {
            (icon, color) = ("checkmark.circle.fill", .green)
            text = L("Shell integration installed: plain claude and codex follow the policy.")
        } else if installed.isEmpty {
            (icon, color) = ("circle.dashed", .secondary)
            text = L("Shell integration not installed: enable it in Settings → Integrations so plain claude and codex follow the policy.")
        } else {
            (icon, color) = ("circle.lefthalf.filled", .orange)
            text = L("Shell integration partially installed: see Settings → Integrations.")
        }
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
