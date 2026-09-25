import SwiftUI

/// "Send crash and error reports": the one switch for ErrorReporting. Off by default.
struct SettingsErrorReportingRow: View {
    @State private var enabled = ErrorReporting.isEnabled

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Send crash and error reports")).font(.subheadline)
                Text(L("Off by default. When on, crash and error reports go to Sentry: the stack trace, app and macOS versions, Mac model, language and time zone, and the rough region Sentry infers from the connection. Never your IP address, accounts, usage numbers or file contents."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(isOn: Binding(get: { enabled },
                                 set: { enabled = $0; ErrorReporting.setEnabled($0) })) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
