import SwiftUI

/// "Auto redeem Codex resets": whether Tally spends a Codex account's banked reset on its own once
/// that account's weekly quota is used up. The Codex twin of `SettingsLimitResetRow`, and one switch
/// for the same reason: it never decides WHEN, it answers a window that is already empty.
struct SettingsCodexAutoRedeemRow: View {
    @Bindable var store: CodexAutoRedeemStore

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Auto redeem Codex resets")).font(.subheadline)
                Text(L("When a Codex account has used all of its weekly quota and has a banked reset, Tally redeems the one that expires soonest and sends a notification. It tries once per weekly window and never retries a failed redeem."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
