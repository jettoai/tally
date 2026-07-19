import SwiftUI

/// Preferences as a System Settings-style split: a fixed section sidebar on the left, one
/// section's grouped card on the right, window height fitting the visible pane.
///
/// Both columns are hand-built over NON-LAZY stacks - deliberately not SwiftUI's `Form`/`List`:
/// those are lazy, expose no intrinsic height, and made "open the window exactly content-fit"
/// unsolvable (a short window keeps rows unbuilt, so the measured height stays short - a
/// self-locking loop). Plain stacks lay out everything at once, so the measured height below IS
/// the true content height, reported to the window controller the same way the pinned panel
/// sizes itself (`onContentSize` pattern).
struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    /// Reports the content's full natural height so the host window can fit itself exactly.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    enum Section: String, CaseIterable {
        case accounts, launch, display, integrations, about

        var title: String {
            switch self {
            case .accounts: return L("Accounts")
            case .launch: return L("Launch")
            case .display: return L("Display")
            case .integrations: return L("Integrations")
            case .about: return L("About")
            }
        }

        var symbol: String {
            switch self {
            case .accounts: return "person.2"
            case .launch: return "play.circle"
            case .display: return "slider.horizontal.3"
            case .integrations: return "puzzlepiece.extension"
            case .about: return "info.circle"
            }
        }
    }

    @State private var section: Section = .accounts

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: 150, alignment: .top)
            Divider()
            // The ScrollView is inert at the natural size; it only actually scrolls when the
            // content outgrows the screen cap applied by the controller.
            ScrollView {
                pane
                    .padding(16)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                                // The window must also fit the sidebar's five rows.
                                onContentHeight(max(height, 250))
                            }
                        }
                    )
            }
            .frame(width: 500)
        }
        .controlSize(.small)
        // Key `.id` on the language so switching it rebuilds the whole tree and re-localizes every
        // label (see PopoverRootView for why a bare read isn't enough).
        .id(settings.languageOverride ?? "system")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .font(.callout)
                            .frame(width: 18)
                        Text(item.title).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(section == item ? Color.accentColor.opacity(0.18) : .clear)
                    )
                    .foregroundStyle(section == item ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    /// ALL panes are laid out in a ZStack (the inactive ones fully transparent and inert) so the
    /// measured height is the TALLEST pane's: switching tabs then never resizes the window.
    /// A per-pane fit made the window jump on every sidebar click - bad to watch, and worse when
    /// the row under the cursor moved away mid-click.
    private var pane: some View {
        ZStack(alignment: .top) {
            ForEach(Section.allCases, id: \.self) { item in
                paneContent(item)
                    .opacity(section == item ? 1 : 0)
                    .allowsHitTesting(section == item)
                    .accessibilityHidden(section != item)
            }
        }
    }

    @ViewBuilder
    private func paneContent(_ item: Section) -> some View {
        switch item {
        case .accounts: sectionCard { SettingsAccountsView(store: store, settings: settings) }
        case .launch: sectionCard { SettingsLaunchView(store: store, settings: settings) }
        case .display: sectionCard { displayRows }
        case .integrations: sectionCard { integrationsRows }
        case .about: sectionCard { aboutRows }
        }
    }

    // MARK: Section chrome

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

        HStack {
            Text(L("Panel columns")).font(.subheadline)
            Spacer()
            Picker("", selection: $settings.panelColumns) {
                Text(L("Auto")).tag(0)
                Text(verbatim: "2").tag(2)
                Text(verbatim: "3").tag(3)
                Text(verbatim: "4").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

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

        toggleRow(L("Glass pinned panel"),
                  subtitle: L("The pinned panel shows the desktop through frosted glass."),
                  isOn: $settings.isPanelTranslucent)

        // Language and refresh cadence live here too: language decides what you read, the
        // interval decides how fresh it is - and a two-row General pane buried both.
        rowDivider

        generalRows
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
        allIntegrationsRow(integrations)
        rowDivider
        integrationRow(
            title: L("Command line tool"),
            caption: L("Links the tally command into /usr/local/bin so any terminal can use it."),
            status: integrations.cliToolStatus,
            install: integrations.installCLITool,
            remove: integrations.removeCLITool)
        rowDivider
        integrationRow(
            title: L("Claude shell integration"),
            caption: L("Routes bare claude commands through your launch policy. Installs one small script and one PATH line; both are removed cleanly."),
            status: integrations.shimStatus(.claude),
            install: { integrations.installShim(.claude) },
            remove: { integrations.removeShim(.claude) })
        rowDivider
        integrationRow(
            title: L("Codex shell integration"),
            caption: L("Routes bare codex commands through your launch policy. Installs one small script and one PATH line; both are removed cleanly."),
            status: integrations.shimStatus(.codex),
            install: { integrations.installShim(.codex) },
            remove: { integrations.removeShim(.codex) })
        rowDivider
        integrationRow(
            title: L("Claude status line"),
            caption: L("Shows the active account at the bottom of every claude session. An existing custom status line keeps running with the account appended, and is restored exactly on removal."),
            status: integrations.statusLineStatus,
            install: integrations.installStatusLine,
            remove: integrations.removeStatusLine)
        if let error = integrations.lastError {
            rowDivider
            Text(error)
                .font(.caption)
                .foregroundStyle(TallyColor.warning)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    /// One-click whole-set control: install everything missing, or remove everything installed.
    /// Buttons appear only when they have work to do, so the row doubles as an at-a-glance
    /// "is everything on?" answer.
    private func allIntegrationsRow(_ integrations: IntegrationsStore) -> some View {
        let entries: [(IntegrationsStore.Status, () -> Void, () -> Void)] = [
            (integrations.cliToolStatus, integrations.installCLITool, integrations.removeCLITool),
            (integrations.shimStatus(.claude), { integrations.installShim(.claude) },
             { integrations.removeShim(.claude) }),
            (integrations.shimStatus(.codex), { integrations.installShim(.codex) },
             { integrations.removeShim(.codex) }),
            (integrations.statusLineStatus, integrations.installStatusLine,
             integrations.removeStatusLine),
        ]
        let missing = entries.filter { $0.0 != .installed }
        let installed = entries.filter { $0.0 == .installed }
        return HStack {
            Text(L("All integrations")).font(.subheadline.weight(.semibold))
            Spacer()
            if !missing.isEmpty {
                Button(L("Install all")) { missing.forEach { $0.1() } }
                    .controlSize(.small)
            }
            if !installed.isEmpty {
                Button(L("Remove all")) { installed.forEach { $0.2() } }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            // Green, not gray: scanning the badges alone should answer "what's on".
            Text(L("Installed"))
                .font(.caption2)
                .foregroundStyle(TallyColor.normal)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(TallyColor.normal.opacity(0.15)))
        case .notInstalled:
            Text(L("Not installed"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
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

        rowDivider

        // The updater is dormant without a feed URL + ED key (dev builds, or a release built
        // outside the ship pipeline). Say so instead of hiding the section - an invisible
        // update story reads as "updates don't exist".
        if UpdaterController.shared.isActive {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Automatically check for updates")).font(.subheadline)
                    if let last = UpdaterController.shared.lastUpdateCheckDate {
                        Text(L("Last checked") + ": "
                             + last.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                                 .locale(AppLocale.current)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle(isOn: Binding(
                    get: { UpdaterController.shared.automaticallyChecksForUpdates },
                    set: { UpdaterController.shared.automaticallyChecksForUpdates = $0 }
                )) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            rowDivider
            HStack {
                Text(L("Check for Updates…")).font(.subheadline)
                Spacer()
                Button(L("Check Now")) { UpdaterController.shared.checkForUpdates() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(L("This build has no update feed; download new versions from GitHub Releases."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/jettoai/tally/releases")!)
                    .font(.caption)
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
