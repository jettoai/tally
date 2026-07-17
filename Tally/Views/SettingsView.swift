import SwiftUI

/// Preferences as hand-built grouped cards over a NON-LAZY VStack - deliberately not SwiftUI's
/// `Form`: the grouped form is List-backed, lazily materializes rows and exposes no intrinsic
/// height, which made "open the window exactly content-fit" unsolvable (a short window keeps rows
/// unbuilt, so the measured height stays short - a self-locking loop). A plain VStack lays out
/// everything at once, so the measured height below IS the true content height, reported to the
/// window controller the same way the pinned panel sizes itself (`onContentSize` pattern).
struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    /// Reports the content's full natural height so the host window can fit itself exactly.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        // The ScrollView is inert at the natural size; it only actually scrolls when the content
        // outgrows the screen cap applied by the controller.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionCard { SettingsAccountsView(store: store, settings: settings) }
                sectionHeader(L("Display"))
                sectionCard { displayRows }
                sectionHeader(L("General"))
                sectionCard { generalRows }
                sectionHeader(L("Integrations"))
                sectionCard { integrationsRows }
                sectionCard { aboutRows }
                    .padding(.top, 8)
            }
            .padding(16)
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                        onContentHeight(height)
                    }
                }
            )
        }
        .frame(width: 500)
        .controlSize(.small)
        // Key `.id` on the language so switching it rebuilds the whole tree and re-localizes every
        // label (see PopoverRootView for why a bare read isn't enough).
        .id(settings.languageOverride ?? "system")
    }

    // MARK: Section chrome

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 10)
            .padding(.leading, 4)
    }

    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    // MARK: Display

    @ViewBuilder
    private var displayRows: some View {
        HStack {
            Text(L("Meters show")).font(.subheadline)
            Spacer()
            Picker("", selection: $settings.displayMode) {
                Text(L("Left")).tag(DisplayMode.remaining)
                Text(L("Used")).tag(DisplayMode.used)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        toggleRow(L("Show every model tier"),
                  subtitle: L("Off shows only the highest-tier model at a glance."),
                  isOn: $settings.showAllModels)

        rowDivider

        toggleRow(L("Glass pinned panel"),
                  subtitle: L("The pinned panel shows the desktop through frosted glass."),
                  isOn: $settings.isPanelTranslucent)
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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

    // MARK: Integrations - everything Tally installs outside its bundle (tracked & reversible).

    @ViewBuilder
    private var integrationsRows: some View {
        let integrations = IntegrationsStore.shared
        integrationRow(
            title: L("Command line tool"),
            caption: L("Links the tally command into /usr/local/bin so any terminal can use it."),
            status: integrations.cliToolStatus,
            install: integrations.installCLITool,
            remove: integrations.removeCLITool)
        rowDivider
        integrationRow(
            title: L("Codex shell integration"),
            caption: L("Routes bare codex commands through your launch policy. Installs one small script and one PATH line; both are removed cleanly."),
            status: integrations.codexShimStatus,
            install: integrations.installCodexShim,
            remove: integrations.removeCodexShim)
        if let error = integrations.lastError {
            rowDivider
            Text(error)
                .font(.caption)
                .foregroundStyle(TallyColor.warning)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private func integrationRow(title: String, caption: String, status: IntegrationsStore.Status,
                                install: @escaping () -> Void,
                                remove: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline)
                    statusBadge(status)
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .installed: Button(L("Remove"), action: remove).controlSize(.small)
            case .notInstalled: Button(L("Install"), action: install).controlSize(.small)
            case .broken: Button(L("Reinstall"), action: install).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBadge(_ status: IntegrationsStore.Status) -> some View {
        switch status {
        case .installed:
            Text(L("Installed"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
        case .notInstalled:
            EmptyView()
        case .broken(let reason):
            Text(L("Needs attention"))
                .font(.caption2)
                .foregroundStyle(TallyColor.warning)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(TallyColor.warning.opacity(0.15)))
                .help(reason)
        }
    }

    // MARK: About - brand + version (brand names stay unlocalized).

    @ViewBuilder
    private var aboutRows: some View {
        HStack(spacing: 6) {
            TallyWordmarkView(glyphHeight: 11)
            Text("by").font(.subheadline)
            ProviderIconShape(pathData: ProviderMarks.jettoWordmark, inset: 0)
                .fill(Color.primary, style: FillStyle(eoFill: true))
                .frame(width: 53, height: 12)
            Spacer()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.caption).foregroundStyle(.secondary)
            Link("jetto.ai", destination: URL(string: "https://jetto.ai")!)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        // Hidden in dev builds (the updater is dormant without a feed URL + ED key).
        if UpdaterController.shared.isActive {
            rowDivider
            HStack {
                Text(L("Check for Updates…")).font(.subheadline)
                Spacer()
                Button(L("Check Now")) { UpdaterController.shared.checkForUpdates() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
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
