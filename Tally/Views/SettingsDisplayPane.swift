import SwiftUI

/// The Settings window's Display pane: what the numbers mean (used vs left, what a menu-bar segment
/// sums), how the panel lays them out, and the General rows that decide what you read and how fresh
/// it is. Five titled groups of at most five rows each (B-2526). Split out of SettingsView.swift at
/// the repo's 500-line cap, along the seam the window already uses - one file per pane.
extension SettingsView {
    // MARK: Display

    /// Not private: the pane switch that renders it (`SettingsView.paneContent`) is in the other
    /// file, and `private` in Swift is file-scoped.
    var displayPane: some View {
        SettingsPage {
            SettingsPageHeader(title: L("Display"),
                               subtitle: L("What the menu bar, panel and pinned window show."))
            generalSection
            menuBarSection
            pinnedSection
            panelSection
            insightsSection
        }
    }

    // MARK: Groups

    private var menuBarSection: some View {
        SettingsSection(L("Menu bar"), symbol: "menubar.rectangle") {
            // Directly under the General rows: both answer "what do the numbers mean" rather than
            // "where do things sit", and this one changes what a menu-bar figure sums.
            SettingsRow(title: L("Menu bar shows"),
                        subtitle: L("Pooled sums each provider's accounts into one segment."),
                        icon: "circle.grid.2x1",
                        info: L("Pooled sums each provider's accounts into one segment, like the fleet gauge.")) {
                Picker("", selection: $settings.menuBarLayout) {
                    Text(L("Accounts")).tag(MenuBarLayout.perAccount)
                    Text(L("Pool")).tag(MenuBarLayout.pooled)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SettingsDivider()
            SettingsToggleRow(title: L("Also show the 5-hour limit on the icon"),
                              subtitle: L("Adds a thinner inner ring for the 5-hour window."),
                              icon: "circle.circle",
                              info: L("Adds a thinner inner ring to each menu bar ring for the 5-hour window."),
                              isOn: $settings.menuBarShowSession)
        }
    }

    /// One card around the two thumbnails: the compact styles are the menu-bar strip moved onto the
    /// desktop, so this sits right after the menu bar group. The sentence above the tiles is the
    /// whole row; the full sentence stays in the hover.
    private var pinnedSection: some View {
        SettingsSection(L("Pinned window"), symbol: "pin") {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Show it in full or as a compact strip like the menu bar."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PinnedStylePicker(selection: $settings.pinnedStyle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsChrome.rowInsetH)
            .tallyTooltip(L("When the panel is pinned, show it in full or as a compact strip like the menu bar."))
        }
    }

    private var panelSection: some View {
        SettingsSection(L("Panel"), symbol: "rectangle.split.3x1") {
            SettingsRow(title: L("Panel density"), icon: "square.grid.2x2") {
                // The pane's own segmented control, matching the "Meters show" row rather than the
                // panel's neutral one: this window has no glass for that variant to be quiet against.
                Picker("", selection: $settings.panelDensity) {
                    Text(L("Cards")).tag(PanelDensity.cards)
                    Text(L("List")).tag(PanelDensity.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SettingsDivider()
            SettingsRow(title: L("Panel columns"), icon: "rectangle.split.3x1") {
                // The same layout tiles the panel's view options show, editing the same per-density
                // count (`densityColumns`): one control, so the two places that set the column count
                // cannot describe it two ways, and each density keeps its own number.
                LayoutColumnPicker(selection: $settings.densityColumns,
                                   maxColumns: settings.densityMaxColumns, roomy: true)
            }
            SettingsDivider()
            // Directly under the account pages' count, because the two are the same question asked
            // of two pages: the Sessions board keeps its own answer, and spends it on the CARDS
            // rather than on the surface - at most that many columns, dividing up the room they are
            // given and held against the leading edge, inside a panel whose width never changes
            // with the page in front (`SettingsStore.sessionsColumns`, `PopoverRootView.popoverWidth`).
            // A number is a maximum here, which is why the tiles are described as "up to".
            SettingsRow(title: L("Sessions columns"), icon: "list.bullet.rectangle") {
                LayoutColumnPicker(selection: $settings.sessionsColumns,
                                   maxColumns: SettingsStore.maxSessionsColumns,
                                   atMost: true, roomy: true)
            }
            SettingsDivider()
            // Next to the column count: both settings answer "how are the cards laid out", and the
            // panel's view options carry the same pair behind one footer icon.
            SettingsToggleRow(title: L("Group by provider"),
                              subtitle: L("Cards sit in a section per provider instead of one continuous grid."),
                              icon: "square.stack.3d.up",
                              isOn: $settings.groupByProvider)
            // Only shown when some account actually reports more than one model-scoped window -
            // otherwise the toggle is a visual no-op (Anthropic currently reports a single Fable
            // window, which is the always-visible headline) that just invites "is this broken?".
            if store.accounts.contains(where: { $0.metrics.filter(\.isModelScoped).count > 1 }) {
                SettingsDivider()
                SettingsToggleRow(title: L("Show every model tier"),
                                  subtitle: L("Off shows only the highest-tier model at a glance."),
                                  icon: "square.3.layers.3d",
                                  isOn: $settings.showAllModels)
            }
        }
    }

    private var insightsSection: some View {
        SettingsSection(L("Insights"), symbol: "chart.bar") {
            SettingsToggleRow(title: L("Fleet gauge"),
                              subtitle: L("One bar per provider with a pace forecast."),
                              icon: "chart.bar.fill",
                              info: L("One bar per provider summing the weekly quota across accounts, with a pace forecast."),
                              isOn: $settings.showFleetGauge)
            SettingsDivider()
            SettingsToggleRow(title: L("Usage advisor"),
                              subtitle: L("A one-line verdict per provider: at your pace, do you need another account?"),
                              icon: "lightbulb",
                              isOn: $settings.showAdvisor)
            SettingsDivider()
            SettingsToggleRow(title: L("CPU alert"),
                              subtitle: L("Notify when CPU stays above 90% for 30 seconds, naming the project behind it."),
                              icon: "cpu",
                              isOn: $settings.cpuAlertEnabled)
        }
    }

    // MARK: General

    /// Language and refresh cadence live here with the two rows that decide what you read: language
    /// decides what you read, the interval decides how fresh it is, the meters' mode what a figure
    /// means, and the glass how the window looks.
    private var generalSection: some View {
        SettingsSection(L("General"), symbol: "gearshape") {
            SettingsRow(title: L("Language"), icon: "globe") {
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
            }
            SettingsDivider()
            SettingsRow(title: L("Refresh every"), icon: "arrow.clockwise") {
                Picker("", selection: $settings.refreshIntervalMinutes) {
                    // Short intervals are safe now that reads go through the providers' own CLIs
                    // (first-party identity: the generous rate-limit bucket; Tally's old direct reads
                    // 429'd at 1 min). Each poll spawns the CLIs, so 1 min costs a few seconds of
                    // background CPU per tick - the user's call.
                    ForEach([1, 2, 5, 15], id: \.self) { minutes in
                        Text(String(localized: "\(minutes) min", bundle: AppLocale.bundle)).tag(minutes)
                    }
                }
                .labelsHidden()
            }
            SettingsDivider()
            SettingsRow(title: L("Meters show"), icon: "percent") {
                // Used before Left, matching the panel footer's toggle (which itself mirrors the
                // meters' geometry: the used portion fills from the track's left edge).
                Picker("", selection: $settings.displayMode) {
                    Text(L("Used")).tag(DisplayMode.used)
                    Text(L("Left")).tag(DisplayMode.remaining)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SettingsDivider()
            SettingsToggleRow(title: L("Frosted glass"),
                              subtitle: L("Off makes the panel, popover and window solid."),
                              icon: "square.on.square.dashed",
                              info: L("The pinned panel, the menu bar popover and the main window show the desktop through frosted glass. Off makes all three solid."),
                              isOn: $settings.isPanelTranslucent)
        }
    }

    private func languageName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh-Hant": return "繁體中文"
        case "zh-Hans": return "简体中文"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "tr": return "Türkçe"
        default: return code
        }
    }
}
