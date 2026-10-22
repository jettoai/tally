import SwiftUI

/// "Auto reset session limit": whether Tally answers a Claude account's 5-hour wall by spending that
/// account's own weekly reset instead of moving the conversation to another account.
///
/// It sits in the Launch pane's quota-windows card beside the window relay, because both are about something happening
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
        SettingsRow(
            title: L("Auto reset session limit"),
            subtitle: L("Spends the account's own weekly reset to clear a full 5-hour window."),
            icon: "gauge.with.needle",
            info: L("When a Claude session hits its 5-hour limit, Tally spends one of that account's own resets to clear it instead of moving the conversation to another account. Claude Code says a reset counts toward the weekly limit, so Tally only does this on a 5-hour wall and only while the account still has weekly quota worth using.")) {
            Toggle(isOn: Binding(get: { store.settings.autoReset },
                                 set: { store.setAutoReset($0) })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }
}
