import Foundation
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

    /// Accounts with a login running right now: two racing each other would write the same
    /// credential twice.
    private(set) var inFlight: Set<String> = []

    /// …and the ones whose login has succeeded but whose discovery has not caught up yet
    /// (AccountSignIn.swift owns that rule and the bug it closes). Observable state, so the moment
    /// an account leaves this set every surface showing it re-renders on its own - the first
    /// version compared a deadline against `Date()` inside a view body, which nothing schedules a
    /// redraw for, so an expired settle could sit on screen until the next poll (codex review,
    /// 2026-08-04).
    private var settling = RenewalSettling()

    /// One deadline task per settling account, so a second renewal replaces the first's rather than
    /// racing it.
    private var settleTasks: [String: Task<Void, Never>] = [:]

    /// Whether a login is happening for this account: running, or succeeded and still settling.
    /// THE question every surface asks - the card's chip, the Settings row, both context menus and
    /// the notification's action all read this one answer rather than each assembling their own.
    func isRenewing(_ accountID: String) -> Bool {
        inFlight.contains(accountID) || settling.contains(accountID)
    }

    /// Whether Tally can renew this account RIGHT NOW: it knows how (a config home to point at, a
    /// login command for the provider, and the name of the variable that selects the home) and
    /// nothing is already doing it.
    ///
    /// Never in demo mode. Those cards are fixtures with no config home behind them, so the entry
    /// could only ever fail, and a menu item that cannot work must not look like one that can.
    ///
    /// The account id is part of the question rather than something each caller checks afterwards:
    /// every entry point that offers a renewal disables itself on this one answer, and the entry
    /// that has no UI to disable (the expiry notification's button) is caught by the same rule
    /// inside `renew` below.
    func canRenew(accountID: String, providerID: String, home: String?) -> Bool {
        !DemoUsage.isActive && home != nil && !isRenewing(accountID)
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
        // `isRenewing`, not the in-flight set: an account whose renewal just succeeded is still
        // being resolved, and the surface that gets here without a button to disable (the expiry
        // notification's action) has nothing else standing between it and a second login.
        guard !isRenewing(accountID),
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
        // A previous success is over: this attempt's own outcome is the only one worth settling,
        // or an old deadline would still be running against a renewal that has since been retried.
        endSettling(accountID)
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
                handOff(accountID, providerID: providerID, home: home)
                inFlight.remove(accountID)
                return
            }
            let outcome = await RenewLoginRunner.run(executable: executable, plan: plan,
                                                    environment: environment)
            // Entered BEFORE the in-flight flag drops, in the same synchronous step: the instant
            // that flag goes every surface re-renders and offers the sign-in again, while discovery
            // still has this account down as signed out (AccountSignIn.swift).
            if case .renewed = outcome { beginSettling(accountID) }
            inFlight.remove(accountID)
            switch outcome {
            case .renewed:
                // The login is in, and that is all the login wrote. Claude Code's first-run wizard
                // is what records having BEEN through it, so a home signed in this way still opens
                // on the theme picker and asks for a sign-in that already happened - which is the
                // first thing the user sees when they launch the account they just added
                // (ClaudeOnboarding.swift). Claude only, this home only, and a no-op for every
                // account that has ever been launched.
                markClaudeOnboardingComplete(providerID: providerID, home: home)
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
                handOff(accountID, providerID: providerID, home: home)
                _ = await SystemAlert.post(
                    title: "\(label) · " + L("Login not renewed"),
                    body: Self.reason(failure) + " " + (opened
                        ? L("A Terminal window is open on the same command, so you can finish it there.")
                        : L("The login command is on the clipboard: paste it into a terminal.")))
            }
        }
    }

    // MARK: The settling window

    /// A renewal reported success. Which accounts that is worth bridging for is the set's own rule
    /// (`RenewalSettling.begin`); all this contributes is what discovery currently says.
    private func beginSettling(_ accountID: String) {
        let isDormant = UsageStore.shared.discoveredAccounts
            .first { $0.id == accountID }?.isDormant == true
        guard settling.begin(accountID, isDormant: isDormant) else { return }
        settleTasks[accountID]?.cancel()
        // The deadline is a scheduled change of state, not a timestamp for a view to compare
        // against: when it fires it MUTATES the set, which is what makes every surface redraw. A
        // view reading a clock would have gone on saying "renewing" until something else happened
        // to redraw it, which at the poll interval the user can set is up to fifteen minutes.
        settleTasks[accountID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RenewalSettling.window))
            guard !Task.isCancelled else { return }
            self?.endSettling(accountID)
        }
    }

    private func endSettling(_ accountID: String) {
        settleTasks.removeValue(forKey: accountID)?.cancel()
        settling.end(accountID)
    }

    /// Discovery spoke, and it is the better witness: an account it no longer calls dormant is
    /// signed in again, so its settling ends now instead of running out the deadline. Called with
    /// the whole round (`UsageStore.refresh`), so no account can be forgotten by a caller.
    func discoveryReported(dormant: Set<String>) {
        guard settling.discovered(dormant: dormant) else { return }
        for id in settleTasks.keys.filter({ !settling.contains($0) }) {
            settleTasks.removeValue(forKey: id)?.cancel()
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
    /// So a ladder runs behind the handoff, on two clocks that are deliberately not the same one.
    /// The person's clock is `LoginProbeGate.handoffPatience` - minutes, because a sign-in is a
    /// browser round trip with a human in it. The probe's clock is the gate's `roundsLeft` - a
    /// handful, for the seconds between a credential appearing and the CLI agreeing that it has.
    ///
    /// Every tick looks at the credential itself first: a `stat` and a Keychain attribute, no CLI
    /// and no network. Only a tick that sees it CHANGE asks for a refresh, which rediscovers the
    /// account (a landed credential makes it live again, which is what clears the chip and the
    /// "Login expired" row together) and carries the forced probe with it. Spending a round per
    /// tick instead made three of them the deadline for the user as well, so anyone slower than
    /// thirty seconds finished their login into a ladder that had already stopped (codex review,
    /// 2026-08-03).
    ///
    /// It stops at the first round that says the account is no longer waiting on a login, and at
    /// the deadline either way, so a login abandoned in that Terminal window costs a file check
    /// every ten seconds for five minutes and nothing else.
    private func handOff(_ accountID: String, providerID: String, home: String) {
        LoginStatusStore.shared.loginHandedOff(accountID)
        handoffPolls[accountID]?.cancel()
        let before = Self.credentialStamp(providerID: providerID, home: home)
        handoffPolls[accountID] = Task {
            let started = Date()
            var landed = false
            while true {
                try? await Task.sleep(for: .seconds(LoginProbeGate.handoffPollDelay))
                guard !Task.isCancelled else { return }
                if !landed, Self.credentialStamp(providerID: providerID, home: home)
                    .landed(after: before) {
                    landed = true
                    // The gate's rounds start HERE, not at the handoff: any spent while the user
                    // was still typing were spent on a question nothing on disk could answer yet.
                    LoginStatusStore.shared.loginHandedOff(accountID)
                }
                let tick = LoginProbeGate.handoffTick(
                    elapsed: Date().timeIntervalSince(started), credentialLanded: landed,
                    awaitingLogin: LoginStatusStore.shared.isAwaitingLogin(accountID))
                if tick == .stop { return }
                guard tick != .wait else { continue }
                await UsageStore.shared.refresh()
                if tick == .askThenStop { return }
            }
        }
    }

    /// Reads the credential fingerprint in one config home. Every part of it is an attribute read:
    /// no credential is opened, and the Keychain query returns no secret and raises no consent
    /// prompt (the same probe discovery uses, AddAccountProbe). What a difference between two of
    /// them means is the gate's (LoginProbeGate.CredentialStamp).
    private static func credentialStamp(providerID: String,
                                        home: String) -> LoginProbeGate.CredentialStamp {
        let dir = URL(fileURLWithPath: home)
        let file = dir.appendingPathComponent(addAccountAuthFile(providerID: providerID))
        // Existence is read on its own rather than inferred from the attributes: a `stat` that
        // fails says nothing about whether the file is there, and a credential appearing where
        // there was none is the whole signal for a provider that keeps no Keychain item.
        let exists = FileManager.default.fileExists(atPath: file.path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        // Only Claude Code keeps a login in the Keychain; asking about a codex one would be asking
        // a question with no answer.
        let service = providerID == "claude" ? claudeKeychainService(forConfigDir: dir) : nil
        return LoginProbeGate.CredentialStamp(
            fileExists: exists,
            fileModifiedAt: attributes?[.modificationDate] as? Date,
            fileSize: (attributes?[.size] as? NSNumber)?.intValue,
            keychain: service.map { KeychainReader.exists(service: $0) } ?? false,
            keychainModifiedAt: service.flatMap { KeychainReader.modifiedAt(service: $0) })
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
