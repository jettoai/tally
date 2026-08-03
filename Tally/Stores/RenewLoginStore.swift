import Observation

/// The account cards' "Renew login": start the provider's own login for ONE account in the
/// background, keep the card honest about it while it runs, and say how it ended.
///
/// Nothing is silent. A renewal that nobody can see is a process holding an account's config home
/// with no way to tell whether it worked, so it announces itself when it starts, marks the card
/// while it runs, and posts its verdict either way. A verdict of "no" opens a real Terminal window
/// on the same command, because the fallback for automation the user cannot watch has to be
/// something they can.
@MainActor
@Observable
final class RenewLoginStore {
    static let shared = RenewLoginStore()

    /// Accounts with a login running right now: what greys the menu entry (one login per account -
    /// two racing each other would write the same credential twice) and marks the card.
    private(set) var inFlight: Set<String> = []

    func isRenewing(_ accountID: String) -> Bool { inFlight.contains(accountID) }

    /// Whether Tally knows how to renew this account at all: a config home to point at, a login
    /// command for the provider, and the name of the variable that selects the home.
    ///
    /// Never in demo mode. Those cards are fixtures with no config home behind them, so the entry
    /// could only ever fail, and a menu item that cannot work must not look like one that can.
    func canRenew(providerID: String, home: String?) -> Bool {
        !DemoUsage.isActive && home != nil
            && RenewLoginCommand.plan(providerID: providerID) != nil
            && IntegrationsStore.Shim(rawValue: providerID) != nil
    }

    /// Renew from an account id alone, resolving the provider, the display name and the config home
    /// from the stores. What the surfaces that only ever HAVE an id need: the expiry notification's
    /// button and the card's "Login expired" chip. An account that has since gone (a config home
    /// deleted while the alert sat on screen) simply does nothing.
    func renew(accountID: String) {
        guard let account = UsageStore.shared.discoveredAccounts.first(where: { $0.id == accountID }),
              let home = account.launchHome else { return }
        renew(accountID: accountID, providerID: account.providerID,
              label: SettingsStore.shared.displayLabel(accountID: accountID,
                                                       fallback: account.label),
              home: home)
    }

    func renew(accountID: String, providerID: String, label: String, home: String) {
        guard !inFlight.contains(accountID),
              let plan = RenewLoginCommand.plan(providerID: providerID),
              // The config-home variable, read from the same place the PATH shims read it, so a
              // third spelling of CLAUDE_CONFIG_DIR / CODEX_HOME can never drift in.
              let envKey = IntegrationsStore.Shim(rawValue: providerID)?.envKey
        else { return }
        let executable = Self.providerExecutable(providerID)
        let environment = RenewLoginCommand.environment(envKey: envKey, home: home,
                                                        providerID: providerID)
        // Before anything asynchronous can happen, so the card is already marked by the time the
        // menu closes: a click that produces no visible change reads as a broken button.
        inFlight.insert(accountID)
        Task {
            let announced = await SystemAlert.post(
                title: "\(label) · " + L("Renewing login"),
                body: L("Finish the sign-in in your browser; Tally will say when it lands."))
            // The card's own line is the other signal, but it is only a signal where a card is on
            // screen - the popover closes along with the menu that was clicked in it. With
            // notifications switched off there would be nothing left to see AND nothing to hear
            // at the end either, so the renewal is done where it cannot be missed instead: a
            // Terminal window the user watches, running the very same command.
            guard announced else {
                _ = await openTerminal(executable: executable, envKey: envKey, home: home,
                                       providerID: providerID, plan: plan)
                // Tally is blind from here (LoginTerminalFallback waits for the WINDOW, not for the
                // login in it), so the login-status probe is told to stop skipping rounds for this
                // account - otherwise a sign-in finished in that window leaves the "Login expired"
                // chip up for the rest of the probe interval.
                handOff(accountID)
                inFlight.remove(accountID)
                return
            }
            let outcome = await RenewLoginRunner.run(executable: executable, plan: plan,
                                                    environment: environment)
            inFlight.remove(accountID)
            switch outcome {
            case .renewed:
                // Before anything asynchronous: the card's "Login expired" chip is read off the
                // last probe's verdict, and the CLI that just signed in knows better than a probe
                // that ran before it. The forced round behind this replaces the assumption with an
                // answer within seconds (LoginProbeGate.swift).
                LoginStatusStore.shared.loginRenewed(accountID)
                // The verdict goes out FIRST. The refresh below re-reads every account through
                // their CLIs and takes seconds, and a user who just finished a sign-in should not
                // wait on unrelated network calls to hear whether it worked.
                _ = await SystemAlert.post(title: "\(label) · " + L("Login renewed"),
                                           body: L("This account is signed in again."))
                // The reason to renew is usually that this account stopped reading, so ask again
                // now rather than leaving a recovered account looking broken until the next tick.
                await UsageStore.shared.refresh(userInitiated: true)
            case .failed(let failure):
                let opened = await openTerminal(executable: executable, envKey: envKey, home: home,
                                                providerID: providerID, plan: plan)
                // Same reason as the announcement-refused path above, and this is the one the user
                // actually hit: the first attempt failed, they finished the login in the Terminal
                // window (or retried), and the chip has to come down on its own.
                handOff(accountID)
                _ = await SystemAlert.post(
                    title: "\(label) · " + L("Login not renewed"),
                    body: Self.reason(failure) + " " + (opened
                        ? L("A Terminal window is open on the same command, so you can finish it there.")
                        : L("The login command is on the clipboard: paste it into a terminal.")))
            }
        }
    }

    /// Rounds a handed-off login has asked for on its own, one task per account, so a second
    /// handoff replaces the first ladder rather than running beside it.
    private var handoffPolls: [String: Task<Void, Never>] = [:]

    /// A login Tally handed to a Terminal window and cannot watch. Two things follow, and the
    /// second is why the first is not enough on its own:
    ///
    /// The probe gate stops skipping rounds for this account, so whichever round happens next is
    /// allowed to ask rather than being held by the five-minute throttle. But FORCING a round is
    /// not the same as having one: this call returns while the user is still typing in a window
    /// Tally cannot see, and the only thing that would otherwise notice the login landing is the
    /// config-dir watcher, whose whole contract is to be fail-open (AccountDirWatcher). With
    /// neither, the account sits dormant with its red chip until the poll timer comes round, which
    /// is up to fifteen minutes at the interval the user can set (codex review, 2026-08-03).
    ///
    /// So a short bounded ladder of refreshes runs behind the handoff: a refresh rediscovers the
    /// account (a landed credential makes it live again, which is what clears the chip and the
    /// "Login expired" row together) and carries the forced probe with it. It stops at the first
    /// round that says the account is no longer waiting on a login, and it is bounded by the same
    /// patience the gate has, so a login abandoned in that Terminal window costs a fixed handful of
    /// rounds rather than a permanent poll.
    private func handOff(_ accountID: String) {
        LoginStatusStore.shared.loginHandedOff(accountID)
        handoffPolls[accountID]?.cancel()
        handoffPolls[accountID] = Task {
            for _ in 0 ..< LoginProbeGate.handedOff.roundsLeft {
                try? await Task.sleep(for: .seconds(LoginProbeGate.handoffPollDelay))
                guard !Task.isCancelled,
                      LoginStatusStore.shared.isAwaitingLogin(accountID) else { return }
                await UsageStore.shared.refresh()
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

    /// The visible fallback: the same command, in a Terminal window the user drives themselves.
    /// Shared with the add-account flow (LoginTerminalFallback), which needs the identical escape
    /// hatch for the identical reason.
    private func openTerminal(executable: String, envKey: String, home: String, providerID: String,
                              plan: RenewLoginCommand.Plan) async -> Bool {
        await LoginTerminalFallback.openTerminal(executable: executable, envKey: envKey, home: home,
                                                 providerID: providerID, plan: plan)
    }

    /// The provider CLI (named after the provider), resolved to a REAL binary and never to Tally's
    /// own PATH shim - the shared rule, because the login-status probe has to spawn the very same
    /// binary against the very same account (see ProviderCLI).
    ///
    /// `-TallyRenewLoginCLI` is the dev-build hook, the same shape as -TallyDryNotifyTest and
    /// -TallyResetHintTest: point the renewal at a stand-in CLI so the whole chain (menu →
    /// notification → card → runner → verdict → fallback) can be exercised without spending a real
    /// credential on a real login.
    private static func providerExecutable(_ cli: String) -> String {
        ProviderCLI.executable(cli, devOverrideKey: "TallyRenewLoginCLI")
    }
}
