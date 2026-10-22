import SwiftUI

/// "Auto redeem Codex resets": whether Tally spends a Codex account's banked reset on its own once
/// that account's weekly quota is used up. The Codex twin of `SettingsLimitResetRow`, and one switch
/// for the same reason: it never decides WHEN, it answers a window that is already empty.
struct SettingsCodexAutoRedeemRow: View {
    @Bindable var store: CodexAutoRedeemStore

    var body: some View {
        SettingsRow(
            title: L("Auto redeem Codex resets"),
            subtitle: L("Redeems a banked Codex reset once the weekly quota runs out."),
            icon: "gift",
            info: L("When a Codex account has used all of its weekly quota and has a banked reset, Tally redeems the one that expires soonest and sends a notification. It redeems once each time the quota runs out (a reset you redeem yourself counts) and never retries a failed redeem; if the quota comes back and runs out again, it redeems again."),
            tooltipPreview: .settingscodexredeem) {
            Toggle(isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }
}
