import SwiftUI

/// The one-time "Send crash and error reports?" question at the top of the panel.
///
/// Error reporting is off by default and its only switch lives in Settings > About, so without this
/// strip nobody who does not go looking would ever be asked. Answered means the switch's own
/// defaults key has a value: either button here writes it through `ErrorReporting.setEnabled`, and so
/// does the Settings row, so turning it on or off there counts too. `@AppStorage` observes that key,
/// which is what hides the strip the moment either place answers.
///
/// Demo launches (screenshots) show it but never write the answer into the real defaults, the same
/// rule `EarlyStartStore.acknowledgeNotice` follows; a press there only hides it for that launch.
struct ErrorReportingNoticeStrip: View {
    @AppStorage(ErrorReporting.enabledKey) private var answer: Bool?
    @State private var dismissedInDemo = false

    var body: some View {
        if answer == nil, !dismissedInDemo {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Send crash and error reports?")).font(.caption.weight(.semibold))
                    Text(L("Nothing is sent unless you turn this on. Reports go to Sentry: the stack trace, app and macOS versions, Mac model, language and time zone, and the rough region Sentry infers from the connection. Never your IP address, accounts, usage numbers or file contents. You can change this in Settings."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(L("No thanks")) { reply(false) }
                    .controlSize(.small)
                Button(L("Turn on")) { reply(true) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }

    private func reply(_ on: Bool) {
        if DemoUsage.isActive {
            dismissedInDemo = true
        } else {
            ErrorReporting.setEnabled(on)
        }
    }
}
