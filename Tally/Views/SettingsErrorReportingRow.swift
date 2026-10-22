import SwiftUI

/// "Send crash and error reports": the one switch for ErrorReporting. Off by default.
struct SettingsErrorReportingRow: View {
    @State private var enabled = ErrorReporting.isEnabled

    var body: some View {
        SettingsToggleRow(
            title: L("Send crash and error reports"),
            subtitle: L("Off by default. Never your IP address, accounts, usage numbers or file contents."),
            icon: "ladybug",
            info: L("Off by default. When on, crash and error reports go to Sentry: the stack trace, app and macOS versions, Mac model, language and time zone, and the rough region Sentry infers from the connection. Never your IP address, accounts, usage numbers or file contents."),
            isOn: Binding(get: { enabled },
                          set: { enabled = $0; ErrorReporting.setEnabled($0) }))
    }
}
