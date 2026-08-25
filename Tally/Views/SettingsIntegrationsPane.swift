import SwiftUI

/// The Settings window's Integrations pane: everything Tally installs outside its bundle (tracked &
/// reversible). Split out of SettingsView.swift at the repo's 500-line cap, along the seam the window
/// already uses - one file per pane (SettingsDisplayPane, SettingsAccountsView, SettingsLaunchView).
/// An extension rather than a child view so the row chrome the panes share (`rowDivider`,
/// `toggleRow`) stays in one place instead of being copied per file.
extension SettingsView {
    // MARK: Integrations

    /// THE PANE'S OWN TAB BAR, one level in from the window's. A dozen rows, each carrying two to six
    /// lines of caption, made this the pane the whole window sized itself around: on a 1152pt display
    /// it opened at the 1112pt cap `ResizeAnchor` allows and scrolled, which is the one pane here that
    /// ever had to. The rows are unchanged - what changes is how many are on screen at once, and the
    /// three pages measure 544, 707 and 536 (same display, demo fixtures).
    ///
    /// Three pages because that is how the set actually divides: what you type in a terminal, what a
    /// running session shows you, and what Claude Code itself is taught. The rows that answer for the
    /// WHOLE set stay outside the pages (see `integrationsRows`).
    enum IntegrationsGroup: String, CaseIterable {
        case commandLine, sessions, claudeCode

        var title: String {
            switch self {
            case .commandLine: return L("Command line")
            case .sessions: return L("Sessions")
            // A product name, deliberately not a catalog key: every entry that contains it keeps it
            // verbatim in all four languages (see "Claude Code skill"), so a key here would only
            // ever hold four copies of these two words.
            case .claudeCode: return "Claude Code"
            }
        }
    }

    /// Not private: the pane switch that renders it (`SettingsView.paneContent`) is in the other
    /// file, and `private` in Swift is file-scoped.
    @ViewBuilder
    var integrationsRows: some View {
        let integrations = IntegrationsStore.shared
        // Disabled on exactly what the hard gate refuses (`guardNotDev`, IntegrationsStore).
        Group {
            // A build nobody installed observes but never mutates the shared integrations (hard-gated
            // in IntegrationsStore too); say so instead of offering buttons that refuse.
            if BuildVariant.isUnshipped {
                Text(L("Integrations are managed by the installed release app."))
                    .font(.caption).foregroundStyle(TallyColor.warning)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                rowDivider
            }
            autoFollowNotices(integrations)
            // ABOVE THE TAB BAR, and the reload row below it: these two speak for the whole set, so
            // putting either on a page would make it look like the page's own. The all-in-one row in
            // particular is this pane's at-a-glance "is everything on?" answer, which is exactly the
            // answer paging away the rows would otherwise cost.
            allIntegrationsRow(integrations)
        }
        .disabled(BuildVariant.isUnshipped)
        rowDivider
        // OUTSIDE the disable above, on purpose: switching pages installs nothing, and a build that
        // may not install still has to be able to show what this pane holds. Disabling reaches
        // everything under it and cannot be lifted further down (SwiftUI's `disabled` only ever
        // tightens), so the switch has to sit outside rather than opt back in.
        integrationsGroupPicker
        rowDivider
        Group {
            integrationsGroupPages(integrations)
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
        .disabled(BuildVariant.isUnshipped)
    }

    /// The window's own segmented shape rather than the panel's neutral one, for the reason the
    /// Display pane states about its pickers: this window has no glass for that variant to be quiet
    /// against.
    ///
    /// AT THE HEAD OF THE ROWS rather than at the end of a label, which is where every other picker
    /// in this window sits: this one is navigation, so it takes the rows' own left edge and no label
    /// at all. Its natural width, not stretched - three short words pulled across 500pt would put
    /// each label alone in the middle of a wide slab and read as three buttons rather than one
    /// switch.
    private var integrationsGroupPicker: some View {
        Picker("", selection: $integrationsGroup) {
            ForEach(IntegrationsGroup.allCases, id: \.self) { group in
                Text(group.title).tag(group)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// COLLAPSED RATHER THAN REMOVED - the rule `SettingsView.pane` states for the window's five
    /// panes, one level in and for the same reason: a page here is holding work too. The artifact
    /// account picker answers for the person rather than for the app, and a row can be mid-install
    /// with its store still working; building only the selected page would throw both away on a
    /// glance at another page. A waiting page keeps its state and adds no height.
    @ViewBuilder
    private func integrationsGroupPages(_ integrations: IntegrationsStore) -> some View {
        ZStack(alignment: .top) {
            ForEach(IntegrationsGroup.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: 0) {
                    switch group {
                    case .commandLine: commandLineRows(integrations)
                    case .sessions: sessionRows(integrations)
                    case .claudeCode: claudeCodeRows(integrations)
                    }
                }
                .opacity(integrationsGroup == group ? 1 : 0)
                .allowsHitTesting(integrationsGroup == group)
                .accessibilityHidden(integrationsGroup != group)
                .frame(height: integrationsGroup == group ? nil : 0, alignment: .top)
                .clipped()
            }
        }
    }

    /// What `tally`, `claude` and `codex` do when they are typed into a terminal - plus the harness
    /// share, which is the one row about the config homes those commands land in.
    @ViewBuilder
    private func commandLineRows(_ integrations: IntegrationsStore) -> some View {
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
    }

    /// What a session that is already running reports back: who it is on, what it is doing, how many
    /// agents are under it, and when its account is running out. The status line toggle rides with
    /// them because it decides what one of those rows actually prints.
    @ViewBuilder
    private func sessionRows(_ integrations: IntegrationsStore) -> some View {
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
            title: L("Claude subagent count"),
            caption: L("Adds the number of subagents working under each session to its card, which nothing on this machine can see from the outside. Installs three hook entries per Claude account (SubagentStart, SubagentStop and Stop); anything already registered for those events keeps running, and only Tally's entries are removed."),
            status: integrations.agentHookStatus,
            install: integrations.installAgentHooks,
            remove: integrations.removeAgentHooks)
        rowDivider
        integrationRow(
            title: L("Claude quota warning"),
            caption: L("Tells a session that the account under it is running low, in its own context, at the moment it next submits a prompt or calls a tool. Without this the same sentence has to be typed into the terminal, which cannot happen while the session is mid-turn. Installs two hook entries per Claude account (UserPromptSubmit and PostToolUse); anything already registered for those events keeps running, and only Tally's entries are removed."),
            status: integrations.knockHookStatus,
            install: integrations.installKnockHooks,
            remove: integrations.removeKnockHooks)
        rowDivider
        toggleRow(L("Full quota in status line"),
                  subtitle: L("Adds a quota line (bars, percents, resets) even under a custom status line. Turn on if you drop your own quota rendering and rely on Tally's."),
                  isOn: $settings.statuslineFullQuota)
    }

    /// What Claude Code is taught about this machine: which account may publish, and how to answer
    /// quota questions on its own.
    @ViewBuilder
    private func claudeCodeRows(_ integrations: IntegrationsStore) -> some View {
        integrationRow(
            title: L("Artifact publishing account"),
            caption: L("Holds a Claude Code session back from publishing an artifact under an account other than the one you browse with, since a published page is private to the account that published it and opens as Page not found for everyone else. Installs one PreToolUse hook entry per Claude account, matched to the Artifact tool alone; anything already registered for that event keeps running, and only Tally's entry is removed."),
            status: integrations.artifactHookStatus,
            install: integrations.installArtifactHook,
            remove: integrations.removeArtifactHook)
        SettingsArtifactAccountRow(store: store, settings: settings)
        rowDivider
        integrationRow(
            title: L("Claude Code skill"),
            caption: L("Teaches Claude Code sessions to answer quota questions and pick accounts from tally status --json, and adds one command: /tally moves a session to another account or runs it on a different model, without spending a turn. One skill file, one command file and one hook entry per Claude account; all removed just as cleanly."),
            status: integrations.skillStatus,
            install: integrations.installSkill,
            remove: integrations.removeSkill)
    }

    /// What the app did without being asked, said once, with the way back beside it
    /// (IntegrationsAutoFollow.swift).
    ///
    /// A ROW AT THE TOP OF THIS PANE rather than a window, an alert or a badge somewhere else: this
    /// is where the thing it is about lives, so the sentence sits above the row it names and the
    /// Undo beside it is the row's own Remove. It stands until it is dismissed or undone, launches
    /// included, because nobody was at the machine when the install happened and a notice they were
    /// not there for is not a notice.
    @ViewBuilder
    private func autoFollowNotices(_ integrations: IntegrationsStore) -> some View {
        ForEach(integrations.autoFollowNotices, id: \.self) { key in
            if let component = IntegrationsStore.autoFollowComponent(key) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        // The name is an ARGUMENT, never spelled into the key: a message built by
                        // interpolation has a catalog key that only exists for whatever it was
                        // built from that day (localizationchecks.swift).
                        Text(String(format: L("Tally enabled %@ for your Claude accounts."),
                                    component.title()))
                            .font(.subheadline)
                        Text(L("Your other Claude integrations were already installed, so this one followed. Undo removes it again, and Tally will not put it back."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(L("Undo")) { integrations.undoAutoFollow(component) }
                        .controlSize(.small)
                    Button(L("Dismiss")) { integrations.dismissAutoFollowNotice(key) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                rowDivider
            }
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
            (integrations.agentHookStatus, integrations.installAgentHooks,
             integrations.removeAgentHooks),
            (integrations.knockHookStatus, integrations.installKnockHooks,
             integrations.removeKnockHooks),
            (integrations.artifactHookStatus, integrations.installArtifactHook,
             integrations.removeArtifactHook),
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
}
