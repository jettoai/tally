import SwiftUI

/// The Settings window's Display pane: what the numbers mean (used vs left, what a menu-bar segment
/// sums), how the panel lays them out, and the two General rows that decide what you read and how
/// fresh it is. Split out of SettingsView.swift at the repo's 500-line cap, along the seam the
/// window already uses - one file per pane (SettingsAccountsView, SettingsLaunchView,
/// SettingsUpdateRows). An extension rather than a child view so the row chrome the panes share
/// (`rowDivider`, `toggleRow`) stays in one place instead of being copied per file.
extension SettingsView {
    // MARK: Display

    /// Not private: the pane switch that renders it (`SettingsView.paneContent`) is in the other
    /// file, and `private` in Swift is file-scoped.
    @ViewBuilder
    var displayRows: some View {
        HStack {
            Text(L("Meters show")).font(.subheadline)
            Spacer()
            // Used before Left, matching the panel footer's toggle (which itself mirrors the
            // meters' geometry: the used portion fills from the track's left edge).
            Picker("", selection: $settings.displayMode) {
                Text(L("Used")).tag(DisplayMode.used)
                Text(L("Left")).tag(DisplayMode.remaining)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        // Directly under "Meters show": both rows answer "what do the numbers mean" rather than
        // "where do things sit", and this one changes what a menu-bar figure sums.
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Menu bar shows")).font(.subheadline)
                Text(L("Pooled sums each provider's accounts into one segment, like the fleet gauge."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $settings.menuBarLayout) {
                Text(L("Accounts")).tag(MenuBarLayout.perAccount)
                Text(L("Pool")).tag(MenuBarLayout.pooled)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        HStack {
            Text(L("Panel density")).font(.subheadline)
            Spacer()
            // The pane's own segmented control, matching the "Meters show" row above it rather than
            // the panel's neutral one: this window has no glass for that variant to be quiet
            // against, and two segmented shapes in one column would read as two kinds of control.
            Picker("", selection: $settings.panelDensity) {
                Text(L("Cards")).tag(PanelDensity.cards)
                Text(L("List")).tag(PanelDensity.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        HStack {
            Text(L("Panel columns")).font(.subheadline)
            Spacer()
            // The same layout tiles the panel's view options show, editing the same per-density
            // count (`densityColumns`): one control, so the two places that set the column count
            // cannot describe it two ways, and each density keeps its own number.
            LayoutColumnPicker(selection: $settings.densityColumns,
                               maxColumns: settings.densityMaxColumns)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        // Directly under the account pages' count, because the two are the same question asked of
        // two pages: the Sessions board keeps its own answer, and spends it on the CARDS rather
        // than on the surface - at most that many columns, dividing up the room they are given and
        // held against the leading edge, inside a panel whose width never changes with the page in
        // front (`SettingsStore.sessionsColumns`, `PopoverRootView.popoverWidth`). A number is a
        // maximum here, which is why the tiles are described as "up to" (`LayoutColumnPicker`).
        HStack {
            Text(L("Sessions columns")).font(.subheadline)
            Spacer()
            LayoutColumnPicker(selection: $settings.sessionsColumns,
                               maxColumns: SettingsStore.maxSessionsColumns,
                               atMost: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        // Next to the column count: both settings answer "how are the cards laid out", and the
        // panel's view options carry the same pair behind one footer icon.
        toggleRow(L("Group by provider"),
                  subtitle: L("Cards sit in a section per provider instead of one continuous grid."),
                  isOn: $settings.groupByProvider)

        // Only shown when some account actually reports more than one model-scoped window -
        // otherwise the toggle is a visual no-op (Anthropic currently reports a single Fable
        // window, which is the always-visible headline) that just invites "is this broken?".
        if store.accounts.contains(where: { $0.metrics.filter(\.isModelScoped).count > 1 }) {
            rowDivider

            toggleRow(L("Show every model tier"),
                      subtitle: L("Off shows only the highest-tier model at a glance."),
                      isOn: $settings.showAllModels)
        }

        rowDivider

        toggleRow(L("Fleet gauge"),
                  subtitle: L("One bar per provider summing the weekly quota across accounts, with a pace forecast."),
                  isOn: $settings.showFleetGauge)

        rowDivider

        toggleRow(L("Usage advisor"),
                  subtitle: L("A one-line verdict per provider: at your pace, do you need another account?"),
                  isOn: $settings.showAdvisor)

        rowDivider

        toggleRow(L("Glass pinned panel"),
                  subtitle: L("The pinned panel shows the desktop through frosted glass."),
                  isOn: $settings.isPanelTranslucent)

        // Language and refresh cadence live here too: language decides what you read, the
        // interval decides how fresh it is - and a two-row General pane buried both.
        rowDivider

        generalRows
    }

    // MARK: General

    @ViewBuilder
    private var generalRows: some View {
        HStack {
            Text(L("Language")).font(.subheadline)
            Spacer()
            Picker("", selection: Binding(
                get: { settings.languageOverride ?? "" },
                set: { settings.languageOverride = $0.isEmpty ? nil : $0 }
            )) {
                Text(L("System")).tag("")
                ForEach(AppLocale.supported, id: \.self) { code in
                    Text(languageName(code)).tag(code)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        HStack {
            Text(L("Refresh every")).font(.subheadline)
            Spacer()
            Picker("", selection: $settings.refreshIntervalMinutes) {
                // Short intervals are safe now that reads go through the providers' own CLIs
                // (first-party identity → the generous rate-limit bucket; Tally's old direct reads
                // 429'd at 1 min). Each poll spawns the CLIs, so 1 min costs a few seconds of
                // background CPU per tick - the user's call.
                ForEach([1, 2, 5, 15], id: \.self) { minutes in
                    Text(String(localized: "\(minutes) min", bundle: AppLocale.bundle)).tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func languageName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh-Hant": return "繁體中文"
        case "zh-Hans": return "简体中文"
        case "ja": return "日本語"
        case "ko": return "한국어"
        default: return code
        }
    }
}
