import SwiftUI

/// "Send anonymous usage data": the one switch for UsagePing. On by default.
struct SettingsUsagePingRow: View {
    @State private var enabled = UsagePing.isEnabled()

    var body: some View {
        SettingsToggleRow(
            title: L("Send anonymous usage data"),
            subtitle: L("On by default. A random device ID and the app version, about once a day."),
            icon: "chart.line.uptrend.xyaxis",
            info: L("On by default. When Tally starts and about once a day, sends a random device ID and the app version to jetto.ai so we can count installs and active users. Never your accounts, usage numbers or file contents. Turning it off stops this and does not change how Tally works."),
            isOn: Binding(get: { enabled },
                          set: { enabled = $0; UsagePing.setEnabled($0) }))
    }
}
