import SwiftUI

/// Preferences as a native System Settings-style grouped form (`.formStyle(.grouped)`) — the current
/// macOS standard: correct insets, row separators, typography and dark/light surfaces for free, and
/// Toggle's built-in title+subtitle layout replaces the hand-rolled two-line rows. The account-first
/// structure stays: one Accounts group per provider with its accounts nested beneath its switch.
struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore

    var body: some View {
        // Key `.id` on the language so switching it rebuilds the whole form and re-localizes every
        // label (see PopoverRootView for why a bare read isn't enough).
        Form {
            accountsSection
            displaySection
            generalSection
            aboutSection
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(width: 460, height: 540)
        .id(settings.languageOverride ?? "system")
    }

    // MARK: Accounts — one group per provider, its accounts nested beneath the provider's own switch.

    private var accountsSection: some View {
        Section(L("Accounts")) {
            ForEach(ProviderCatalog.descriptors, id: \.id) { descriptor in
                providerGroup(id: descriptor.id, name: descriptor.name)
            }
        }
    }

    @ViewBuilder
    private func providerGroup(id: String, name: String) -> some View {
        let accounts = store.accounts.filter { $0.providerID == id }
        Toggle(isOn: Binding(
            // userInitiated:false so toggling one provider can't force-reread another provider's
            // declined Keychain item and re-raise its access prompt.
            get: { settings.isEnabled(id) },
            set: { settings.setEnabled(id, $0); Task { await store.refresh(userInitiated: false) } }
        )) {
            HStack(spacing: 10) {
                ProviderIconView(providerID: id, size: 16)
                    .frame(width: 20)
                Text(name).font(.subheadline.weight(.semibold))
                if !accounts.isEmpty {
                    Text("\(accounts.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
            }
        }

        if settings.isEnabled(id) {
            ForEach(accounts) { account in
                accountRow(account)
            }
        }
    }

    private func accountRow(_ account: AccountUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(account.accountLabel, text: Binding(
                get: { settings.accountLabels[account.id] ?? "" },
                set: { settings.accountLabels[account.id] = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)

            Toggle(isOn: Binding(
                get: { settings.isShownInMenuBar(account.id) },
                set: { settings.setShownInMenuBar(account.id, $0); UsageStore.shared.onChange?() }
            )) {
                Text(L("Show in menu bar")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 30)   // nested under the provider row's icon column
    }

    // MARK: Display

    private var displaySection: some View {
        Section(L("Display")) {
            Picker(selection: $settings.displayMode) {
                Text(L("Left")).tag(DisplayMode.remaining)
                Text(L("Used")).tag(DisplayMode.used)
            } label: {
                Text(L("Meters show")).font(.subheadline)
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $settings.showAllModels) {
                Text(L("Show every model tier")).font(.subheadline)
                Text(L("Off shows only the highest-tier model at a glance."))
            }

            Toggle(isOn: $settings.isPanelTranslucent) {
                Text(L("Glass pinned panel")).font(.subheadline)
                Text(L("The pinned panel shows the desktop through frosted glass."))
            }
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section(L("General")) {
            Picker(selection: Binding(
                get: { settings.languageOverride ?? "" },
                set: { settings.languageOverride = $0.isEmpty ? nil : $0 }
            )) {
                Text(L("System")).tag("")
                ForEach(AppLocale.supported, id: \.self) { code in
                    Text(languageName(code)).tag(code)
                }
            } label: {
                Text(L("Language")).font(.subheadline)
            }

            Picker(selection: $settings.refreshIntervalMinutes) {
                // No 1-minute option: 1 min × 2 accounts tripped the usage endpoint's 429 rate
                // limit (verified 2026-07-16) and every Claude card fell back to stale.
                ForEach([5, 15, 30, 60], id: \.self) { minutes in
                    Text(String(localized: "\(minutes) min", bundle: AppLocale.bundle)).tag(minutes)
                }
            } label: {
                Text(L("Refresh every")).font(.subheadline)
            }
        }
    }

    // MARK: About — brand + version (brand names stay unlocalized).

    private var aboutSection: some View {
        Section {
            HStack(spacing: 6) {
                Text("Tally by").font(.subheadline)
                ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                    .fill(Color.primary, style: FillStyle(eoFill: true))
                    .frame(width: 53, height: 12)
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
                Link("jetto.ai", destination: URL(string: "https://jetto.ai")!)
                    .font(.caption)
            }
            // Hidden in dev builds (the updater is dormant without a feed URL + ED key).
            if UpdaterController.shared.isActive {
                HStack {
                    Text(L("Check for Updates…")).font(.subheadline)
                    Spacer()
                    Button(L("Check Now")) { UpdaterController.shared.checkForUpdates() }
                        .controlSize(.small)
                }
            }
        }
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
