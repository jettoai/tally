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

    /// Where the flow is. The two ending states are deliberately different: `added` is an account
    /// the user now has, `pending` is a config home that exists with no login in it - which is a
    /// state the CLI already understands (the next add resumes that same home), not a mess.
    enum Phase: Equatable {
        case idle
        /// Creating the home, linking the share, seeding folder trust.
        case preparing
        /// The provider's login is running against `name`; the browser has the user now.
        case signingIn(name: String)
        case added(name: String)
        /// The home is there, the login is not done. Retrying resumes this same home.
        case pending(name: String, reason: String)
        /// Nothing was created (no free slot, or the home could not be made).
        case failed(reason: String)
    }

    private(set) var phase: Phase = .idle

    /// The sheet's two choices, kept on the store so reopening it after a run remembers them.
    var providerID = "claude"
    var shareHarness = true

    var isRunning: Bool {
        switch phase {
        case .preparing, .signingIn: return true
        default: return false
        }
    }

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

    /// Back to the start, so the sheet can be used again. Refused mid-run: a login is still out
    /// there against a home this flow created, and forgetting it would leave the user with no
    /// surface reporting the outcome.
    func reset() {
        guard !isRunning else { return }
        phase = .idle
    }

    func start() {
        guard !isRunning, canAdd(providerID: providerID),
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
                phase = .added(name: prepared.name)
                // The verdict first, the network second: a user who just finished a sign-in should
                // not wait on every other account's usage call to hear whether it worked.
                _ = await SystemAlert.post(title: L("Account added") + " · ~/\(prepared.name)",
                                           body: L("The new account is signed in and showing up now."))
                // Discovery also notices on its own (AccountDirWatcher sees the new home), but this
                // flow knows the login just landed, so it asks immediately rather than waiting for
                // the watcher's debounce.
                await UsageStore.shared.refresh(userInitiated: true)
            case .failed(let failure):
                // The home STAYS. It holds the share links and the trust seed this run created, the
                // next attempt resumes it rather than burning the next number, and deleting a
                // directory to tidy up after a failure is the one step here that cannot be undone.
                phase = .pending(name: prepared.name, reason: Self.reason(failure))
                let opened = await LoginTerminalFallback.openTerminal(
                    executable: executable, envKey: envKey, home: prepared.dir.path,
                    providerID: providerID, plan: plan)
                _ = await SystemAlert.post(
                    title: L("Account not added") + " · ~/\(prepared.name)",
                    body: Self.reason(failure) + " " + (opened
                        ? L("A Terminal window is open on the same command, so you can finish it there.")
                        : L("The login command is on the clipboard: paste it into a terminal.")))
            }
        }
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
