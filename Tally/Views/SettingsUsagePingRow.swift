import SwiftUI

/// "Send anonymous usage ping": the one switch for UsagePing. On by default.
struct SettingsUsagePingRow: View {
    @State private var enabled = UsagePing.isEnabled()

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Send anonymous usage ping")).font(.subheadline)
                Text(L("Once a day, sends a random device ID and the app version to jetto.ai so we can count installs and active users. Never your accounts, usage numbers or file contents."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(isOn: Binding(get: { enabled },
                                 set: { enabled = $0; UsagePing.setEnabled($0) })) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
