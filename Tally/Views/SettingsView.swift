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

    @State private var section: Section = LoginItemPreview.settingsOpening.onLaunchPane ? .launch : .accounts

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
        // The sharing row reports a state whose switch lives on another pane; it is handed the way
        // there rather than describing it, because a reader who has to be told where a control is
        // has already lost the time this saves them.
        case .launch: sectionCard { SettingsLaunchView(store: store, settings: settings,
                                                       visible: section == item,
                                                       showIntegrations: { section = .integrations }) }
        case .display: sectionCard { displayRows }
        // Disabled on exactly what the hard gate refuses (`guardNotDev`, IntegrationsStore).
        case .integrations: sectionCard { integrationsRows.disabled(BuildVariant.isUnshipped) }
        case .about: sectionCard { aboutRows }
        }
    }

    // MARK: Section chrome

    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
    }

    /// The row chrome every pane shares. Not private: the Display pane lives in its own file
    /// (SettingsDisplayPane.swift) and `private` in Swift is file-scoped - copying these per file
    /// is how two panes end up with rows that no longer line up.
    var rowDivider: some View {
        Divider().padding(.leading, 14)
    }


    func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
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

    // MARK: Integrations - everything Tally installs outside its bundle (tracked & reversible).

    @ViewBuilder
    private var integrationsRows: some View {
        let integrations = IntegrationsStore.shared
        // A build nobody installed observes but never mutates the shared integrations (hard-gated in
        // IntegrationsStore too); say so instead of offering buttons that refuse.
        if BuildVariant.isUnshipped {
            Text(L("Integrations are managed by the installed release app."))
                .font(.caption).foregroundStyle(TallyColor.warning)
                .padding(.horizontal, 14).padding(.vertical, 8)
            rowDivider
        }
        allIntegrationsRow(integrations)
        rowDivider
        integrationRow(
            title: L("Command line tool"),
            caption: integrations.cliToolCaption,
            status: integrations.cliToolStatus,
            install: integrations.installCLITool,
            remove: integrations.removeCLITool,
            // The one row whose broken state is not always ours to undo: a `tally` somebody else
            // put in /usr/local/bin reads broken here, and Remove would delete their program
            // (`IntegrationsStore.CLIToolPresence`). The store refuses that press whatever this
            // says; leaving the button off is how the row stops offering it in the first place.
            removable: integrations.cliToolPresence.mayBeRemoved)
        // Absent rather than empty on a one-account machine: this row's whole subject is the other
        // accounts, and a permanently grey button is a worse answer than no row (`detectSharedHarness`).
        if let sharedHarness = integrations.sharedHarnessStatus {
            rowDivider
            integrationRow(
                title: L("Shared harness"),
                caption: L("Points your other accounts at the main account's instructions, skills, hooks, agents, settings and conversation record, so one setup serves them all. Nothing is deleted: conversations, inboxes and memory notes merge into the main account, anything else in the way is renamed to <name>.local-<date> beside it, and Remove unlinks without touching those backups. Every account can then read every account's conversations."),
                status: sharedHarness,
                install: integrations.installSharedHarness,
                remove: integrations.removeSharedHarness)
        }
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
            caption: L("Shows the active account at the bottom of every claude session, with its remaining quota when Tally is the only status line. An existing custom status line keeps running with the signal appended, and is restored exactly on removal."),
            status: integrations.statusLineStatus,
            install: integrations.installStatusLine,
            remove: integrations.removeStatusLine)
        rowDivider
        integrationRow(
            title: L("Claude session board"),
            caption: L("Lets the panel show which sessions are working, waiting on you, or idle, and puts a red dot in the menu bar while one is waiting. Installs one Notification hook entry per Claude account; anything already registered for that event keeps running, and only Tally's entry is removed."),
            status: integrations.notificationHookStatus,
            install: integrations.installNotificationHook,
            remove: integrations.removeNotificationHook)
        rowDivider
        integrationRow(
            title: L("Claude Code skill"),
            caption: L("Teaches Claude Code sessions to answer quota questions and pick accounts from tally status --json, and adds one command: /tally moves a session to another account or runs it on a different model, without spending a turn. One skill file, one command file and one hook entry per Claude account; all removed just as cleanly."),
            status: integrations.skillStatus,
            install: integrations.installSkill,
            remove: integrations.removeSkill)
        rowDivider
        toggleRow(L("Full quota in status line"),
                  subtitle: L("Adds a quota line (bars, percents, resets) even under a custom status line. Turn on if you drop your own quota rendering and rely on Tally's."),
                  isOn: $settings.statuslineFullQuota)
        rowDivider
        // An ACTION, not an install: it sits after the install/remove set so that group stays
        // whole, and here rather than in the panel footer, where a second circular-arrow control
        // next to the quota refresh would read as the same thing.
        SettingsReloadRow()
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
    ///
    /// THE SHARED HARNESS IS DELIBERATELY NOT IN THIS SET. Every entry below writes files of its
    /// own - a symlink, a shell block, a key in settings.json - and one press putting them all in
    /// place is a small promise. That one moves the user's conversations between config homes, and
    /// leaves a backup behind for whatever it could not merge; it is the same act only in the sense
    /// that both are reversible. A press meaning "turn everything on" may not also mean that.
    private func allIntegrationsRow(_ integrations: IntegrationsStore) -> some View {
        let entries: [(IntegrationsStore.Status, () -> Void, () -> Void)] = [
            (integrations.cliToolStatus, integrations.installCLITool, integrations.removeCLITool),
            (integrations.shimStatus(.claude), { integrations.installShim(.claude) },
             { integrations.removeShim(.claude) }),
            (integrations.shimStatus(.codex), { integrations.installShim(.codex) },
             { integrations.removeShim(.codex) }),
            (integrations.statusLineStatus, integrations.installStatusLine,
             integrations.removeStatusLine),
            (integrations.notificationHookStatus, integrations.installNotificationHook,
             integrations.removeNotificationHook),
            (integrations.skillStatus, integrations.installSkill, integrations.removeSkill),
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

    /// - Parameter removable: whether what is installed is this app's to take away. True for every
    ///   integration that only ever writes files of its own; the command line tool is the exception
    ///   (it links into a shared directory that another `tally` may already own).
    private func integrationRow(title: String, caption: String, status: IntegrationsStore.Status,
                                install: @escaping () -> Void,
                                remove: @escaping () -> Void,
                                removable: Bool = true) -> some View {
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
            // Both answers, whenever both apply. A broken row used to offer the repair alone, which
            // reads as the only thing worth doing and is not: what makes a row broken can be a
            // registration in a home the app can no longer reach, and the pass that clears one is
            // behind Remove (`Status.offersRemoval`).
            //
            // REMOVE SAYS THIS IS OURS, which is why it takes a second answer as well as the
            // status. Both have to hold: the status says there is something to take back, and
            // `removable` says the something is this app's (see the parameter's note).
            if status.offersInstall {
                Button(status == .notInstalled ? L("Install") : L("Reinstall"), action: install)
                    .controlSize(.small)
            }
            if status.offersRemoval, removable {
                Button(L("Remove"), action: remove).controlSize(.small)
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
            // Which of the look-alike builds is this? DEV for the Debug flavour, "Local build"
            // for a source-built release (dormant updater, stuck on its version forever); the
            // installed stable shows nothing extra, its update rows below are the tell.
            if BuildVariant.isDev {
                Text(verbatim: "DEV")
                    .font(.caption2)
                    .foregroundStyle(TallyColor.warning)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(TallyColor.warning.opacity(0.15)))
                    .help(L("Development build - runs beside the installed app and never self-updates"))
            } else if !UpdateAvailability.shared.updaterActive {
                Text(L("Local build"))
                    .font(.caption2)
                    .foregroundStyle(TallyColor.warning)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(TallyColor.warning.opacity(0.15)))
                    .help(L("Built from source without an update feed - it cannot update itself"))
            }
            Text("v\(BuildVariant.version ?? "—")")
                .font(.caption).foregroundStyle(.secondary)
            Link("jetto.ai", destination: URL(string: "https://jetto.ai")!)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        // The Sparkle rows live in their own file (SettingsUpdateRows): the two switches carry a
        // hidden Sparkle-side dependency that needs truthful local state, not computed bindings.
        SettingsUpdateRows()
    }

}
