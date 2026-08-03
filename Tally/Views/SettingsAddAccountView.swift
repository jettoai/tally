import SwiftUI

/// The "Add account" sheet: pick a provider, decide whether the new account shares the main one's
/// setup, then watch the provider's own sign-in happen in the browser.
///
/// It says what will happen BEFORE it happens - which directory gets created, and exactly what
/// sharing means - because everything on this sheet touches the user's own filesystem and their own
/// paid subscriptions. Tally reads; the sign-in is the vendor's, in the user's browser.
struct SettingsAddAccountView: View {
    @Bindable var flow: AddAccountStore
    /// The command that does the same thing in a terminal, offered when the in-app run could not
    /// finish. It resumes the very home this run created: an unfinished home is what `tally add`
    /// hands back rather than skipping.
    let fallbackCommand: (String) -> String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Add an account")).font(.headline)
            switch flow.phase {
            case .idle, .failed:
                setup
            case .preparing, .signingIn:
                running
            case .added(let prepared):
                finished(prepared)
            case .pending(let name, let reason, let handoff):
                unfinished(name, reason, handoff)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: Before it starts

    private var setup: some View {
        // Asked ONCE per pass: the probe walks up to 99 directories, and a SwiftUI body is
        // evaluated far more often than the answer changes.
        let nextHome = nextFreeAccountHome(providerID: flow.providerID)?.name
        return VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $flow.providerID) {
                ForEach(ProviderCatalog.descriptors, id: \.id) { descriptor in
                    Text(descriptor.name).tag(descriptor.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            // Looked up with the same probes the creation uses, so the sheet names the directory it
            // is about to make rather than a guess the user has to verify afterwards. The path
            // stands on its own line rather than inside the sentence: a directory glued into
            // running text is the one part of it that does not translate.
            if let nextHome {
                caption(L("Tally will create the next config home and open the provider's sign-in page in your browser."))
                Text(verbatim: "~/\(nextHome)").font(.caption.monospaced())
            } else {
                caption(L("Every numbered config home for this provider already has a login."))
            }

            Toggle(isOn: $flow.shareHarness) {
                Text(L("Share the main account's setup")).font(.subheadline)
            }
            .toggleStyle(.checkbox)
            caption(flow.shareHarness
                ? L("The new account links to your main account's instructions, skills, hooks, agents, settings and conversation history, so one setup serves every account. Every account can then read every account's conversations. Sign-in details are never shared.")
                : L("The new account starts empty: its own instructions, skills, hooks, agents, settings and its own conversation history."))

            if case .failed(let reason) = flow.phase {
                problem(reason)
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Add account")) { flow.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canAdd(providerID: flow.providerID) || nextHome == nil)
            }
        }
    }

    // MARK: While it runs

    @ViewBuilder
    private var running: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(phaseLine).font(.subheadline)
        }
        // Closing is safe and worth saying so: the login is a background process with its own
        // deadlines and its own notifications, not something this window is holding up.
        caption(L("Finish the sign-in in your browser. You can close this window; Tally will notify you either way."))
        HStack {
            Spacer()
            Button(L("Close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var phaseLine: String {
        if case .signingIn(let name) = flow.phase {
            return L("Signing in") + " · ~/\(name)"
        }
        return L("Preparing the config home…")
    }

    // MARK: How it ended

    @ViewBuilder
    private func finished(_ prepared: AddedAccountHome) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(L("Account added") + " · ~/\(prepared.name)").font(.subheadline)
        }
        caption(L("It is signed in and listed above. Rename it, reorder it or switch it off any time."))
        // What preparing the home actually did, whenever that is not what the setup screen
        // promised. A share is best-effort by design (a permission can refuse a link, a resumed
        // home can already hold its own file), so a plain "Account added" over an incomplete one
        // leaves the user believing in a share that never happened.
        if !prepared.failed.isEmpty {
            problem(L("Could not be linked, so the shared setup is incomplete:") + " "
                + prepared.failed.joined(separator: ", "))
        }
        if !prepared.kept.isEmpty {
            caption(L("Already in the new home, so left as they were rather than shared:") + " "
                + prepared.kept.joined(separator: ", "))
        }
        // The privacy line, stated as the FACT it is rather than as this run's intention: shared is
        // shared whether it happened now, on an earlier attempt at this home, or by hand.
        if !prepared.isMainHome {
            caption(prepared.sharesConversations
                ? L("Conversations are shared: every account can read every account's conversations.")
                : L("Conversations are not shared: this account keeps its own history."))
        }
        HStack {
            Spacer()
            Button(L("Done")) { flow.reset(); dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// The home exists, the login does not. The directory is deliberately KEPT: the next attempt
    /// resumes it (share links and carried-over folder trust included) instead of taking the next
    /// number, and deleting it would be the only irreversible step in this flow.
    ///
    /// The two ways forward are offered ONE AT A TIME, which is the whole shape of this screen: the
    /// in-app retry and a Terminal window both sign in to the same config home, and two logins
    /// racing there fight over the credential they each mean to leave behind. So handing off to
    /// Terminal takes the retry away, and only the user can say that window is finished
    /// (AddAccountFlow.swift).
    @ViewBuilder
    private func unfinished(_ name: String, _ reason: String,
                            _ handoff: AddAccountHandoff) -> some View {
        problem(L("Sign-in not finished") + " · ~/\(name)")
        caption(reason + " " + (handoff == .terminal
            ? L("A Terminal window is open on the same command. Finish the sign-in there, then tell Tally to look.")
            : L("The config home is ready and waiting - finishing the sign-in later adds the account, and nothing is created twice.")))
        // The command for the run this screen is about, not for whatever the picker last held: this
        // home was prepared for one provider, and a command naming another would sign the user in
        // somewhere else entirely.
        CopyCommandChip(command: fallbackCommand(flow.runProviderID))
        HStack {
            Spacer()
            // Closing does not forget this: with a Terminal window still out there the flow keeps
            // its state, so reopening the sheet lands right back here rather than on a fresh
            // "Add account" button pointed at the same home.
            Button(L("Close")) { flow.reset(); dismiss() }
                .keyboardShortcut(.cancelAction)
            if flow.phase.allowsTerminalHandoff {
                Button(L("Sign in from Terminal")) { flow.handOffToTerminal() }
            }
            if flow.phase.allowsRecheck {
                Button(L("I finished in Terminal")) { flow.recheck() }
                    .keyboardShortcut(.defaultAction)
            }
            if flow.phase.allowsNewRun {
                Button(L("Try again")) { flow.start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func problem(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Text(text).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
