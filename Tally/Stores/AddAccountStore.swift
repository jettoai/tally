import Observation

/// Settings' "Add account": prepare the next config home, then hand it to the provider's own login
/// and watch for the answer.
///
/// Every step is the user's: they pick the provider, they decide whether the new account shares the
/// main one's harness, and the sign-in happens on the vendor's own page in their own browser. Tally
/// creates a directory and starts a command; it never sees, moves or stores a credential.
///
/// The same machinery as "Renew login" (RenewLoginRunner + RenewLoginCommand + the Terminal
/// fallback), because the second half of adding an account IS a login. The differences are both
/// upstream of it: which home the login runs against (a brand new one), and the visible surface
/// while it runs (a sheet that stays on screen, rather than a card behind a menu that closes).
@MainActor
@Observable
final class AddAccountStore {
    static let shared = AddAccountStore()

    /// Where the flow is, and what the sheet may offer there (AddAccountFlow.swift). The two ending
    /// states are deliberately different: `added` is an account the user now has, `pending` is a
    /// config home that exists with no login in it.
    private(set) var phase: AddAccountPhase = .idle

    /// The run that is already out there, kept because the sheet's provider picker is the NEXT
    /// run's choice: a Terminal handoff and a re-check both have to act on the home this flow
    /// actually prepared, for the provider it prepared it for.
    private struct Run {
        let providerID: String
        let prepared: AddedAccountHome
    }

    private var run: Run?

    /// The sheet's two choices, kept on the store so reopening it after a run remembers them.
    var providerID = "claude"
    var shareHarness = true

    var isRunning: Bool { phase.isRunning }

    /// Whether Tally can add an account for this provider at all: a login command it knows how to
    /// drive, and the name of the variable that selects a config home.
    ///
    /// Never in demo mode. Those cards are fixtures with no config home behind them, and a button
    /// that could only ever create a stray directory must not look like one that works.
    func canAdd(providerID: String) -> Bool {
        !DemoUsage.isActive
            && RenewLoginCommand.plan(providerID: providerID) != nil
            && IntegrationsStore.Shim(rawValue: providerID) != nil
    }

    /// Back to the start, so the sheet can be used again. Refused whenever a login is still out
    /// there against a home this flow created (mid-run, or handed to a Terminal window): forgetting
    /// it would leave the user with no surface reporting the outcome, and would put the "Add
    /// account" button back in front of a home that is already being signed in to.
    func reset() {
        guard phase.allowsNewRun else { return }
        phase = .idle
        run = nil
    }

    /// Opening the sheet from an entry point that names a provider (Settings has one row per
    /// provider). The provider and the reset move TOGETHER, under the same rule, because they are
    /// one act: choosing what the next run will be.
    ///
    /// Setting `providerID` first and resetting after is what this exists to prevent. `reset()`
    /// refuses while a Terminal handoff is live, so the provider changed while the run did not, and
    /// the sheet then showed - and offered to copy - the OTHER provider's login command for a home
    /// that had been prepared for the first one.
    func beginEntry(providerID: String) {
        guard phase.allowsNewRun else { return }
        self.providerID = providerID
        reset()
    }

    /// The provider the run that is still out there belongs to, for the surfaces that talk about
    /// THAT run rather than the next one. `providerID` is the picker's value, which is a choice
    /// about the next run and must never be read as a fact about this one.
    var runProviderID: String { run?.providerID ?? providerID }

    func start() {
        guard phase.allowsNewRun, canAdd(providerID: providerID),
              let plan = RenewLoginCommand.plan(providerID: providerID),
              // The config-home variable, read from the same place the PATH shims read it, so a
              // third spelling of CLAUDE_CONFIG_DIR / CODEX_HOME can never drift in.
              let envKey = IntegrationsStore.Shim(rawValue: providerID)?.envKey
        else { return }
        let providerID = self.providerID, share = self.shareHarness
        // Before anything asynchronous: the click has to change the sheet in the same frame.
        phase = .preparing
        Task {
            let prepared: AddedAccountHome
            do {
                prepared = try prepareAddedAccountHome(providerID: providerID, share: share)
            } catch {
                phase = .failed(reason: Self.reason(error))
                return
            }
            phase = .signingIn(name: prepared.name)
            run = Run(providerID: providerID, prepared: prepared)
            let executable = ProviderCLI.executable(providerID, devOverrideKey: "TallyRenewLoginCLI")
            let environment = RenewLoginCommand.environment(envKey: envKey, home: prepared.dir.path,
                                                            providerID: providerID)
            // Best-effort, unlike the renewal's: there the notification was the only signal a
            // closed menu left behind, so a refused one had to divert the whole login into a
            // visible Terminal window. Here the sheet is on screen saying the same thing, so a
            // machine with notifications switched off simply reads the sheet.
            _ = await SystemAlert.post(
                title: L("Adding an account") + " · ~/\(prepared.name)",
                body: L("Finish the sign-in in your browser; Tally will say when it lands."))
            let outcome = await RenewLoginRunner.run(executable: executable, plan: plan,
                                                     environment: environment)
            switch outcome {
            case .renewed:
                await land(prepared, providerID: providerID)
            case .failed(let failure):
                // The home STAYS. It holds the share links and the trust seed this run created, the
                // next attempt resumes it rather than burning the next number, and deleting a
                // directory to tidy up after a failure is the one step here that cannot be undone.
                //
                // What does NOT happen here is starting the Terminal fallback on its own. The
                // renewal does that (a closed menu leaves no surface behind), but this sheet is on
                // screen offering "Try again", and a window opened underneath it would put a second
                // login on the same config home the moment the user clicked. So the two ways
                // forward are offered as a choice instead, one at a time.
                phase = .pending(name: prepared.name, reason: Self.reason(failure), handoff: .none)
                _ = await SystemAlert.post(
                    title: L("Account not added") + " · ~/\(prepared.name)",
                    body: Self.reason(failure) + " "
                        + L("The config home is waiting: reopen Add account in Settings to finish the sign-in."))
            }
        }
    }

    /// Hand the unfinished login to a Terminal window the user drives themselves, on the very same
    /// command and the very same config home.
    ///
    /// From here Tally is blind: `openTerminal` waits for the window to OPEN, not for the login
    /// inside it to end. So the in-app retry goes away for as long as that window might be working,
    /// and only `recheck()` brings it back.
    func handOffToTerminal() {
        guard phase.allowsTerminalHandoff, case .pending(let name, let reason, _) = phase,
              let run, let plan = RenewLoginCommand.plan(providerID: run.providerID),
              let envKey = IntegrationsStore.Shim(rawValue: run.providerID)?.envKey
        else { return }
        // Marked BEFORE the window is asked for, in the same frame as the click: an await here
        // would leave "Try again" on screen for as long as macOS takes to answer.
        phase = .pending(name: name, reason: reason, handoff: .terminal)
        let executable = ProviderCLI.executable(run.providerID, devOverrideKey: "TallyRenewLoginCLI")
        Task {
            let opened = await LoginTerminalFallback.openTerminal(
                executable: executable, envKey: envKey, home: run.prepared.dir.path,
                providerID: run.providerID, plan: plan)
            guard !opened, case .pending(let name, _, .terminal) = phase else { return }
            // Refused (driving Terminal is a permission): nothing is running after all, and the
            // command is on the clipboard instead - so the retry comes straight back.
            phase = .pending(
                name: name,
                reason: L("Tally could not open Terminal, so the login command is on the clipboard: paste it into a terminal."),
                handoff: .clipboard)
        }
    }

    /// The user says the Terminal window is finished. Ask the home rather than take their word for
    /// it: a finished login leaves the same credential discovery reads, so the answer is a fact
    /// about the directory, not a claim about the window.
    func recheck() {
        guard phase.allowsRecheck, case .pending(let name, _, _) = phase, let run else { return }
        guard addedAccountHomeHasLogin(providerID: run.providerID, dir: run.prepared.dir) else {
            // Nothing landed. As far as Tally can tell the handoff is over (the user just said so),
            // so the in-app retry comes back rather than leaving the sheet with no way forward -
            // with the one warning Tally cannot check for them.
            phase = .pending(
                name: name,
                reason: L("Tally still sees no signed-in account in this config home. If the Terminal window is still signing in, let it finish before trying again here."),
                handoff: .none)
            return
        }
        Task { await land(run.prepared, providerID: run.providerID) }
    }

    /// The account exists: say so, then tell the rest of the app.
    ///
    /// The provider comes from the RUN, never from the picker: `providerID` is a choice about the
    /// next add, and this is the one that just finished.
    private func land(_ prepared: AddedAccountHome, providerID: String) async {
        // The login wrote a credential and nothing else, so this home would meet its first
        // `tally claude` with Claude Code's first-run wizard - theme picker, sign-in prompt, for an
        // account that is signed in (ClaudeOnboarding.swift). Done here rather than only where the
        // background run succeeds, because a login handed to a Terminal window lands through
        // `recheck()` instead, and it needs the same note.
        markClaudeOnboardingComplete(providerID: providerID, home: prepared.dir.path)
        phase = .added(prepared)
        // The verdict first, the network second: a user who just finished a sign-in should not
        // wait on every other account's usage call to hear whether it worked.
        _ = await SystemAlert.post(title: L("Account added") + " · ~/\(prepared.name)",
                                   body: L("The new account is signed in and showing up now."))
        // Discovery also notices on its own (AccountDirWatcher sees the new home), but this flow
        // knows the login just landed, so it asks immediately rather than waiting for the
        // watcher's debounce.
        await UsageStore.shared.refresh(userInitiated: true)
    }

    private static func reason(_ failure: RenewLoginRunner.Failure) -> String {
        switch failure {
        case .couldNotStart: return L("Tally could not start the login command.")
        case .reported: return L("The login command ended without signing in.")
        case .timedOut: return L("The sign-in did not finish in time.")
        }
    }

    private static func reason(_ error: Error) -> String {
        switch error as? AddAccountFailure {
        case .noFreeSlot:
            return L("Every numbered config home for this provider already has a login.")
        case .couldNotCreateHome(let path):
            return L("Tally could not create the config home") + " (\(path))."
        case nil:
            return L("Tally could not prepare a config home for the new account.")
        }
    }
}
