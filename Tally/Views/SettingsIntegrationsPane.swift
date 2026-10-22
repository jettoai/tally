import SwiftUI

/// The Settings window's Integrations pane: everything Tally installs outside its bundle (tracked &
/// reversible). Split out of SettingsView.swift at the repo's 500-line cap, along the seam the window
/// already uses - one file per pane (SettingsDisplayPane, SettingsAccountsView, SettingsLaunchView).
///
/// ONE PAGE, FIVE GROUPS (B-2526). It used to be four pages behind a segmented control inside one
/// card, which hid half of a pane whose whole job is "is everything on?". Now the page scrolls and
/// each group is a card of at most five rows under its own title. The long explanations moved into
/// each row's hover; anything that needs the user (an error, a broken install, a hook to review)
/// stays on the row as a line of its own.
extension SettingsView {
    // MARK: Integrations

    /// Not private: the pane switch that renders it (`SettingsView.paneContent`) is in the other
    /// file, and `private` in Swift is file-scoped.
    @ViewBuilder
    var integrationsRows: some View {
        let integrations = IntegrationsStore.shared
        let entries = allIntegrationEntries(integrations)
        let statuses = IntegrationsCapture.statuses(entries.map(\.0))
        let locked = BuildVariant.isUnshipped && !IntegrationsCapture.simulating
        SettingsPage {
            VStack(alignment: .leading, spacing: 16) {
                // The two whole-set buttons live in the header. The Shared harness is deliberately
                // NOT in their set (see `allIntegrationEntries`).
                IntegrationsHeader(
                    missing: zip(statuses, entries).filter { $0.0 != .installed }.map { $0.1.1 },
                    installed: zip(statuses, entries).filter { $0.0 == .installed }.map { $0.1.2 })
                    .disabled(locked)
                // A build nobody installed observes but never mutates the shared integrations (hard-gated
                // in IntegrationsStore too); say so instead of offering buttons that refuse.
                if !IntegrationsCapture.simulating {
                    SettingsDevBanner(message: L("Integrations are managed by the installed release app."))
                }
                autoFollowNotices(integrations)
                if let error = integrations.lastError {
                    SettingsNoticeBar(kind: .warning, title: error)
                }
            }
            // Disabled on exactly what the hard gate refuses (`guardNotDev`, IntegrationsStore).
            // The Harness group is outside it, on purpose: it has its own receipt and is the one
            // part of this page a build that may not install still has to be able to show.
            Group {
                commandLineGroup(integrations)
                statusLineGroup(integrations)
                sessionsGroup(integrations)
                claudeCodeGroup(integrations)
            }
            .disabled(locked)
            SettingsSection(L("Harness"), symbol: "wrench.and.screwdriver") {
                SettingsCodexHarness(active: section == .integrations)
            }
        }
    }

    // MARK: Groups

    /// What `tally`, `claude` and `codex` do when they are typed into a terminal - plus the harness
    /// share, which is the one row about the config homes those commands land in. The Launch pane's
    /// "Manage in Integrations" link scrolls here (`scrollTarget`).
    private func commandLineGroup(_ integrations: IntegrationsStore) -> some View {
        SettingsSection(L("Command line"), symbol: "terminal") {
            integrationRow(
                title: L("Command line tool"), icon: "terminal",
                subtitle: integrations.cliToolCaption,
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
                SettingsDivider()
                integrationRow(
                    title: L("Shared harness"), icon: "link",
                    subtitle: L("Points your other accounts at the main one's setup."),
                    info: L("Points your other accounts at the main account's instructions, skills, hooks, agents, settings and conversation record, so one setup serves them all. Nothing is deleted: conversations, inboxes and memory notes merge into the main account, anything else in the way is renamed to <name>.local-<date> beside it, and Remove unlinks without touching those backups. Every account can then read every account's conversations."),
                    status: sharedHarness,
                    install: integrations.installSharedHarness,
                    remove: integrations.removeSharedHarness)
            }
            SettingsDivider()
            integrationRow(
                title: L("Claude shell integration"), icon: "chevron.left.forwardslash.chevron.right",
                subtitle: L("Bare claude follows your launch policy too."),
                info: L("Routes bare claude commands through your launch policy. Installs one small script and one PATH line; both are removed cleanly."),
                status: integrations.shimStatus(.claude),
                install: { integrations.installShim(.claude) },
                remove: { integrations.removeShim(.claude) })
            SettingsDivider()
            integrationRow(
                title: L("Codex shell integration"), icon: "chevron.left.forwardslash.chevron.right",
                subtitle: L("Bare codex follows your launch policy too."),
                info: L("Routes bare codex commands through your launch policy. Installs one small script and one PATH line; both are removed cleanly."),
                status: integrations.shimStatus(.codex),
                install: { integrations.installShim(.codex) },
                remove: { integrations.removeShim(.codex) })
        }
        .id(Self.sharedHarnessAnchor)
    }

    /// The status line, with the toggle that decides what it prints riding in the same card.
    private func statusLineGroup(_ integrations: IntegrationsStore) -> some View {
        SettingsSection(L("Status line"), symbol: "rectangle.bottomthird.inset.filled") {
            integrationRow(
                title: L("Claude status line"), icon: "text.line.last.and.arrowtriangle.forward",
                subtitle: L("Shows the active account and its quota under each session."),
                info: L("Shows the active account at the bottom of every claude session, with its remaining quota when Tally is the only status line. An existing custom status line keeps running with the signal appended, and is restored exactly on removal."),
                status: integrations.statusLineStatus,
                install: integrations.installStatusLine,
                remove: integrations.removeStatusLine,
                warning: statusLineOverrideWarning(integrations.statusLineStatus))
            SettingsDivider()
            SettingsToggleRow(
                title: L("Full quota in status line"), subtitle: L("Adds bars, percents and resets under a custom status line too."),
                icon: "chart.bar.xaxis",
                info: L("Adds a quota line (bars, percents, resets) even under a custom status line. Turn on if you drop your own quota rendering and rely on Tally's."),
                isOn: $settings.statuslineFullQuota)
        }
    }

    /// What a session that is already running reports back: who it is on, what it is doing, how many
    /// agents are under it, and when its account is running out.
    private func sessionsGroup(_ integrations: IntegrationsStore) -> some View {
        SettingsSection(L("Sessions"), symbol: "rectangle.stack") {
            integrationRow(
                title: L("Claude session board"), icon: "circle.dotted.circle",
                subtitle: L("Shows which sessions are working, waiting on you or idle."),
                info: L("Lets the panel show which sessions are working, waiting on you, or idle, and puts a red dot in the menu bar while one is waiting. Installs one Notification hook entry per Claude account; anything already registered for that event keeps running, and only Tally's entry is removed."),
                status: integrations.notificationHookStatus,
                install: integrations.installNotificationHook,
                remove: integrations.removeNotificationHook)
            SettingsDivider()
            integrationRow(
                title: L("Codex session status"), icon: "circle.dotted.circle",
                subtitle: L("Working and idle states for sessions started with tally codex."),
                info: L("Shows working and idle states for interactive sessions started with tally codex. Install the hooks, then review them in Codex /hooks. Until trusted events arrive, status stays unknown. Changing accounts or models requires restarting the session."),
                status: integrations.codexSessionHookStatus,
                install: integrations.installCodexSessionHooks,
                remove: integrations.removeCodexSessionHooks)
            SettingsDivider()
            integrationRow(
                title: L("Claude subagent count"), icon: "person.3",
                subtitle: L("Adds each session's working subagents to its card."),
                info: L("Adds the number of subagents working under each session to its card, which nothing on this machine can see from the outside. Installs three hook entries per Claude account (SubagentStart, SubagentStop and Stop); anything already registered for those events keeps running, and only Tally's entries are removed."),
                status: integrations.agentHookStatus,
                install: integrations.installAgentHooks,
                remove: integrations.removeAgentHooks)
            SettingsDivider()
            integrationRow(
                title: L("Claude quota warning"), icon: "exclamationmark.bubble",
                subtitle: L("Tells a session when its account runs low."),
                info: L("Tells a session that the account under it is running low, in its own context, at the moment it next submits a prompt or calls a tool. Without this the same sentence has to be typed into the terminal, which cannot happen while the session is mid-turn. Installs two hook entries per Claude account (UserPromptSubmit and PostToolUse); anything already registered for those events keeps running, and only Tally's entries are removed."),
                status: integrations.knockHookStatus,
                install: integrations.installKnockHooks,
                remove: integrations.removeKnockHooks)
            SettingsDivider()
            // An ACTION, not an install: last in its card so the install/remove set stays whole, and
            // here rather than in the panel footer, where a second circular-arrow control next to
            // the quota refresh would read as the same thing.
            SettingsReloadRow()
        }
    }

    /// What Claude Code is taught about this machine: which account Claude in Chrome is signed in to,
    /// and how to answer quota questions on its own.
    private func claudeCodeGroup(_ integrations: IntegrationsStore) -> some View {
        // A product name, deliberately not a catalog key: every entry that contains it keeps it
        // verbatim in all four languages (see "Claude Code skill").
        SettingsSection("Claude Code", icon: { ProviderIconView(providerID: "claude", size: 16) }) {
            integrationRow(
                title: L("Claude Code skill"), icon: "wand.and.stars",
                subtitle: L("Adds /tally and lets sessions answer quota questions."),
                info: L("Teaches Claude Code sessions to answer quota questions and pick accounts from tally status --json, and adds one command: /tally moves a session to another account or runs it on a different model, without spending a turn. One skill file, one command file and one hook entry per Claude account; all removed just as cleanly."),
                status: integrations.skillStatus,
                install: integrations.installSkill,
                remove: integrations.removeSkill)
            SettingsDivider()
            SettingsChromeAccountRow(store: store, settings: settings)
        }
    }

    // MARK: Notices

    /// What the app did without being asked, said once, with the way back beside it
    /// (IntegrationsAutoFollow.swift).
    ///
    /// A STRIP AT THE TOP OF THIS PANE rather than a window, an alert or a badge somewhere else: this
    /// is where the thing it is about lives, so the sentence sits above the group it names and the
    /// Undo beside it is the row's own Remove. It stands until it is dismissed or undone, launches
    /// included, because nobody was at the machine when the install happened and a notice they were
    /// not there for is not a notice.
    @ViewBuilder
    private func autoFollowNotices(_ integrations: IntegrationsStore) -> some View {
        ForEach(integrations.autoFollowNotices, id: \.self) { key in
            if let component = IntegrationsStore.autoFollowComponent(key) {
                // The name is an ARGUMENT, never spelled into the key: a message built by
                // interpolation has a catalog key that only exists for whatever it was
                // built from that day (localizationchecks.swift).
                SettingsNoticeBar(
                    kind: .info,
                    title: String(format: L("Tally enabled %@ for your Claude accounts."), component.title()),
                    message: L("Your other Claude integrations were already installed, so this one followed. Undo removes it again, and Tally will not put it back.")) {
                    Button(L("Undo")) { integrations.undoAutoFollow(component) }
                        .buttonStyle(.borderless).font(.system(size: 13, weight: .medium))
                    Button(L("Dismiss")) { integrations.dismissAutoFollowNotice(key) }
                        .buttonStyle(.borderless).font(.system(size: 13, weight: .medium))
                }
            }
        }
    }

    // MARK: Whole-set control

    /// Every entry the header's Install all / Remove all act on.
    ///
    /// THE SHARED HARNESS IS DELIBERATELY NOT IN THIS SET. Every entry below writes files of its
    /// own - a symlink, a shell block, a key in settings.json - and one press putting them all in
    /// place is a small promise. That one moves the user's conversations between config homes, and
    /// leaves a backup behind for whatever it could not merge; it is the same act only in the sense
    /// that both are reversible. A press meaning "turn everything on" may not also mean that.
    private func allIntegrationEntries(_ integrations: IntegrationsStore)
        -> [(IntegrationsStore.Status, () -> Void, () -> Void)] {
        [
            (integrations.cliToolStatus, integrations.installCLITool, integrations.removeCLITool),
            (integrations.shimStatus(.claude), { integrations.installShim(.claude) },
             { integrations.removeShim(.claude) }),
            (integrations.shimStatus(.codex), { integrations.installShim(.codex) },
             { integrations.removeShim(.codex) }),
            (integrations.statusLineStatus, integrations.installStatusLine,
             integrations.removeStatusLine),
            (integrations.notificationHookStatus, integrations.installNotificationHook,
             integrations.removeNotificationHook),
            (integrations.codexSessionHookStatus, integrations.installCodexSessionHooks,
             integrations.removeCodexSessionHooks),
            (integrations.agentHookStatus, integrations.installAgentHooks,
             integrations.removeAgentHooks),
            (integrations.knockHookStatus, integrations.installKnockHooks,
             integrations.removeKnockHooks),
            (integrations.skillStatus, integrations.installSkill, integrations.removeSkill),
        ]
    }

    // MARK: Rows

    /// - Parameter removable: whether what is installed is this app's to take away. True for every
    ///   integration that only ever writes files of its own; the command line tool is the exception
    ///   (it links into a shared directory that another `tally` may already own).
    /// - Parameter info: the long explanation, for the hover; `subtitle` is the one-line version.
    private func integrationRow(title: String, icon: String, subtitle: String? = nil, info: String? = nil,
                                status: IntegrationsStore.Status,
                                install: @escaping () -> Void,
                                remove: @escaping () -> Void,
                                removable: Bool = true,
                                warning: (text: String, paths: String)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: title, subtitle: subtitle, icon: icon, info: info) {
                HStack(spacing: 10) {
                    statusBadge(status, overridden: warning != nil)
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
                    }
                    if status.offersRemoval, removable {
                        Button(L("Remove"), action: remove)
                    }
                }
            }
            // Why a row is broken, or that a project folder wins over it: said on the row, because
            // it is the user's next step and a hover is not where a next step lives.
            if case .broken(let reason) = status, !reason.isEmpty {
                SettingsSubRow(title: reason, tint: TallyColor.warning)
                    .tallyTooltip(reason)
            }
            if let warning {
                SettingsSubRow(title: warning.text, tint: TallyColor.warning)
                    .tallyTooltip(warning.paths)
            }
        }
    }

    /// "Installed" speaks for the user's settings.json, and a project folder's own `statusLine`
    /// wins over it (ProjectStatusLine.swift, jettoai/tally#12). Counted over the folders of the
    /// Claude sessions already on the roster (no scan of its own); nil, and so no change to the row,
    /// when none is overridden.
    private func statusLineOverrideWarning(_ status: IntegrationsStore.Status) -> (text: String, paths: String)? {
        guard status == .installed else { return nil }
        let files = Set(SessionRosterStore.shared.rows.filter { $0.providerID != "codex" }
            .compactMap { ($0.cwd ?? $0.directory).flatMap { ProjectStatusLine.overridingFile(cwd: $0) } })
        guard !files.isEmpty else { return nil }
        let text = files.count == 1
            ? L("Installed; overridden in 1 project folder")
            : String(format: L("Installed; overridden in %lld project folders"), files.count)
        return (text, files.sorted().joined(separator: "\n"))
    }

    /// A not-installed row shows no badge, only its Install button.
    @ViewBuilder
    private func statusBadge(_ status: IntegrationsStore.Status, overridden: Bool) -> some View {
        switch status {
        case .installed:
            // Green, not gray: scanning the badges alone should answer "what's on".
            SettingsStatusBadge(text: L("Installed"), tone: overridden ? .goodMuted : .good)
        case .notInstalled:
            EmptyView()
        case .broken:
            SettingsStatusBadge(text: L("Needs attention"), tone: .attention)
        }
    }
}

/// The page header with its two whole-set buttons. A struct of its own because the confirmation
/// dialog needs state, and an extension of `SettingsView` cannot hold any.
private struct IntegrationsHeader: View {
    let missing: [() -> Void]
    let installed: [() -> Void]
    @State private var confirmingRemoveAll = IntegrationsCapture.confirm

    var body: some View {
        SettingsPageHeader(title: L("Integrations"),
                           subtitle: L("Hooks, status lines and tools Tally adds to your CLIs. Each one removes cleanly.")) {
            // Buttons appear only when they have work to do, so the pair doubles as an at-a-glance
            // "is everything on?" answer.
            if !missing.isEmpty {
                PageActionButton(title: L("Install all"), symbol: "arrow.down.circle") {
                    missing.forEach { $0() }
                }
                .tallyTooltipAroundControl(wholeSetTip, forced: IntegrationsCapture.tip == "install")
            }
            if !installed.isEmpty {
                PageActionButton(title: L("Remove all"), symbol: "trash", destructive: true) {
                    confirmingRemoveAll = true
                }
                .tallyTooltipAroundControl(wholeSetTip, forced: IntegrationsCapture.tip == "remove")
            }
        }
        // Removing every integration used to be one press with no question; it is the one action on
        // this page that undoes several installs at once.
        .confirmationDialog(L("Remove all integrations?"), isPresented: $confirmingRemoveAll,
                            titleVisibility: .visible) {
            Button(L("Remove all"), role: .destructive) { installed.forEach { $0() } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Tally removes the hooks, status lines and shell lines it added to every account. Your own settings stay as they are, and you can install them again anytime."))
        }
    }

    private var wholeSetTip: String { L("Applies to every integration on this page except Harness tools.") }
}

/// Debug-only capture flags for this pane (Dev build or demo data only, like `-TallyChipPhase`), so
/// the header's states can be photographed without touching the real integrations or synthesizing
/// input: `-TallyDemoIntegrations missing:N|installed` reports the first N entries as not installed
/// (header only, the rows keep their real state) and unlocks the Dev build's greyed controls;
/// `-TallyIntegrationsConfirm YES` opens the Remove all question; `-TallyIntegrationsTip install|remove`
/// holds that button's hover callout open. Release builds compile all of it to the plain values.
enum IntegrationsCapture {
    #if DEBUG
    private static func value(_ key: String) -> String? {
        guard DemoUsage.isActive || BuildVariant.isDev else { return nil }
        return UserDefaults.standard.string(forKey: key)?.lowercased()
    }
    static var simulating: Bool { value("TallyDemoIntegrations") != nil }
    static var confirm: Bool { value("TallyIntegrationsConfirm") == "yes" }
    static var tip: String? { value("TallyIntegrationsTip") }

    static func statuses(_ real: [IntegrationsStore.Status]) -> [IntegrationsStore.Status] {
        guard let raw = value("TallyDemoIntegrations") else { return real }
        let missing = raw.hasPrefix("missing:") ? Int(raw.dropFirst(8)) ?? 0 : 0
        return real.indices.map { $0 < missing ? .notInstalled : .installed }
    }
    #else
    static var simulating: Bool { false }
    static var confirm: Bool { false }
    static var tip: String? { nil }
    static func statuses(_ real: [IntegrationsStore.Status]) -> [IntegrationsStore.Status] { real }
    #endif
}
