import SwiftUI

/// "Early start": whether Tally opens each Claude account's 5-hour window in the morning, and at
/// what time. It sits near the top of the Launch pane, beside the row about Tally itself starting
/// at login, because both are about something happening without anybody pressing anything.
///
/// The pane also stands in for the panel notice: a user who found this row has been told what the
/// feature does, which is the whole job the notice exists to do, so opening the pane arms the
/// schedule exactly as dismissing the notice does (`EarlyStartStore.acknowledgeNotice`).
///
/// The last-run line is under the time rather than in a tooltip: a schedule that runs while nobody
/// is watching has to be able to show what it did, and a feature whose CLI is missing says so here
/// rather than reading as "on" and doing nothing.
struct SettingsEarlyStartRow: View {
    @Bindable var store: EarlyStartStore
    /// Whether the pane this row sits on is the one Settings is showing. Passed in for the reason
    /// `SettingsLaunchAtLoginRow` gives: every pane is laid out together so the window can size
    /// itself, so a lifecycle hook here runs whether or not anybody opened this section.
    let isVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if store.isEnabled {
                Divider().padding(.leading, 14)
                timeRow
            }
        }
        .onChange(of: isVisible, initial: true) { _, visible in
            guard visible else { return }
            store.acknowledgeNotice()
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Early start")).font(.subheadline)
                Text(L("Opens each Claude account's 5-hour window in the morning, so it resets earlier in your day. Tally sends one short message per account and skips any account whose window is already open."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(isOn: Binding(get: { store.isEnabled }, set: { store.setEnabled($0) })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var timeRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Time")).font(.subheadline)
                Text(lastRunText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
                // THE ONE CONTROL IN SETTINGS THAT FORMATS ITSELF. Everything else on these panes
                // is a string that has already been through `L()`, so nothing had ever needed to
                // hand SwiftUI the app's language before. Left alone this field takes the SYSTEM
                // locale instead: the first capture of this row printed its meridiem marker in the
                // machine's language inside a window that was otherwise entirely in English. The
                // app's own answer is `AppLocale.current`, which is what every date Tally formats
                // by hand already uses.
                .environment(\.locale, AppLocale.current)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The picker edits an hour and a minute; the date around them is only a carrier. Anchored on
    /// today's own trigger instant so the field opens on the value the schedule actually holds.
    private var timeBinding: Binding<Date> {
        Binding(
            get: { store.triggerToday ?? Date() },
            set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                store.setTime(hour: parts.hour ?? EarlyStartLogic.defaultHour,
                              minute: parts.minute ?? EarlyStartLogic.defaultMinute)
            })
    }

    /// What the last morning did, or an honest blank. Never a made-up time: a schedule that has not
    /// run yet says so (`EarlyStartRun` is nil until there has been one).
    private var lastRunText: String {
        guard let run = store.lastRun else { return L("Has not run yet.") }
        let stamp = AppLocale.shortDateTime(run.at)
        if run.failed > 0 {
            return String(format: L("Last run %1$@: %2$d started, %3$d skipped, %4$d could not start."),
                          stamp, run.started, run.skipped, run.failed)
        }
        return String(format: L("Last run %1$@: %2$d started, %3$d skipped."),
                      stamp, run.started, run.skipped)
    }
}
