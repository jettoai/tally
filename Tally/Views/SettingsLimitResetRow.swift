import SwiftUI

/// "Auto reset session limit": whether Tally answers a Claude account's 5-hour wall by spending that
/// account's own weekly reset instead of moving the conversation to another account.
///
/// It sits on the Launch pane beside the window relay, because both are about something happening
/// without anybody pressing anything, and because both are about the same window - one keeps it
/// turning over, this one clears it when it fills.
///
/// ONE SWITCH AND NO SCHEDULE, which is the whole difference from its neighbour. The relay decides
/// WHEN to act and therefore needs quiet hours and a day's tally; this one never decides when: it
/// acts on a wall the session has already hit, or not at all. So the row is the switch, the
/// sentence that says what it costs, and nothing else.
struct SettingsLimitResetRow: View {
    @Bindable var store: LimitResetStore

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Auto reset session limit")).font(.subheadline)
                Text(L("When a Claude session hits its 5-hour limit, Tally spends that account's own weekly reset to clear it instead of moving the conversation to another account. Claude gives one reset a week and it uses the weekly limit, so Tally only does this on a 5-hour wall and only while the account still has weekly quota worth using."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(isOn: Binding(get: { store.settings.autoReset },
                                 set: { store.setAutoReset($0) })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
