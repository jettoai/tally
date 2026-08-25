import SwiftUI

/// "Early start": whether Tally keeps each Claude account's 5-hour window turning over, and the
/// hours it is asked to stay quiet in. It sits near the top of the Launch pane, beside the row about
/// Tally itself starting at login, because both are about something happening without anybody
/// pressing anything.
///
/// The pane also stands in for the panel notice: a user who found this row has been told what the
/// feature does, which is the whole job the notice exists to do, so opening the pane arms the
/// schedule exactly as dismissing the notice does (`EarlyStartStore.acknowledgeNotice`).
///
/// The day's tally is a row of its own rather than a tooltip: a relay that runs while nobody is
/// watching has to be able to show what it did, and a feature whose CLI is missing says so here
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
                quietHoursRow
                if store.quietHours.isEnabled {
                    Divider().padding(.leading, 14)
                    quietRangeRow
                }
                Divider().padding(.leading, 14)
                tallyRow
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
                Text(L("Whenever a Claude account's 5-hour window is closed, Tally opens it with one short message, so the next reset lands earlier in your day. At most one message per account every 5 hours, and any account already working is left alone. Leaving this on costs very little and always moves the reset earlier."))
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

    private var quietHoursRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Quiet hours")).font(.subheadline)
                Text(store.quietHours.isEnabled
                        ? L("Nothing is sent between these times.")
                        : L("Off, so windows are opened at any hour. Turn this on to keep Tally silent overnight."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(isOn: Binding(
                get: { store.quietHours.isEnabled },
                // Turning it ON adopts the suggested overnight stretch rather than a range of zero
                // length, which would read as a control that does nothing.
                set: { on in
                    var next = store.quietHours.isEnabled ? store.quietHours
                                                          : EarlyStartQuietHours.suggested
                    next.isEnabled = on
                    store.setQuietHours(next)
                })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var quietRangeRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L("From")).font(.subheadline)
            Spacer()
            picker(hour: store.quietHours.startHour, minute: store.quietHours.startMinute) {
                hour, minute in
                let held = store.quietHours
                store.setQuietHours(EarlyStartQuietHours(
                    isEnabled: held.isEnabled, startHour: hour, startMinute: minute,
                    endHour: held.endHour, endMinute: held.endMinute))
            }
            Text(L("to")).font(.caption).foregroundStyle(.secondary)
            picker(hour: store.quietHours.endHour, minute: store.quietHours.endMinute) {
                hour, minute in
                let held = store.quietHours
                store.setQuietHours(EarlyStartQuietHours(
                    isEnabled: held.isEnabled, startHour: held.startHour,
                    startMinute: held.startMinute, endHour: hour, endMinute: minute))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var tallyRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tallyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// One clock field. The picker edits an hour and a minute; the date around them is only a
    /// carrier, anchored on today so the field opens somewhere sensible.
    private func picker(hour: Int, minute: Int,
                        onChange: @escaping (Int, Int) -> Void) -> some View {
        DatePicker("", selection: Binding(
            get: {
                var parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                parts.hour = hour
                parts.minute = minute
                parts.second = 0
                return Calendar.current.date(from: parts) ?? Date()
            },
            set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                onChange(parts.hour ?? hour, parts.minute ?? minute)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .fixedSize()
            // THE ONE CONTROL IN SETTINGS THAT FORMATS ITSELF. Everything else on these panes is a
            // string that has already been through `L()`, so nothing had ever needed to hand
            // SwiftUI the app's language before. Left alone this field takes the SYSTEM locale
            // instead: the first capture of this row printed its meridiem marker in the machine's
            // language inside a window that was otherwise entirely in English. The app's own answer
            // is `AppLocale.current`, which is what every date Tally formats by hand already uses.
            .environment(\.locale, AppLocale.current)
    }

    /// What today has done, or an honest blank. Never a made-up number: a day with nothing on it
    /// says so, and a day whose only content is a failure says that rather than reading as idle.
    private var tallyText: String {
        guard let today = store.today,
              today.day == EarlyStartLogic.dayKey(Date(), calendar: Calendar.current),
              today.started > 0 || today.failed > 0 || today.skippedCount > 0 else {
            return L("Nothing sent today yet.")
        }
        guard let at = today.lastAttemptAt else {
            // No message went out at all, so there is no time to name - what there is, is the
            // reason: an account that could not be reached, or a CLI that is not installed.
            if today.failed > 0 {
                return String(format: L("Today: %1$d skipped, %2$d could not start."),
                              today.skippedCount, today.failed)
            }
            return String(format: L("Today: %1$d skipped."), today.skippedCount)
        }
        let stamp = AppLocale.shortTime(at)
        if today.failed > 0 {
            return String(format: L("Today: %1$d started, %2$d skipped, %3$d could not start. Last message at %4$@."),
                          today.started, today.skippedCount, today.failed, stamp)
        }
        return String(format: L("Today: %1$d started, %2$d skipped. Last message at %3$@."),
                      today.started, today.skippedCount, stamp)
    }
}
