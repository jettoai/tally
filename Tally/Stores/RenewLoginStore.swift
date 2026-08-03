import AppKit
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
                inFlight.remove(accountID)
                return
            }
            let outcome = await RenewLoginRunner.run(executable: executable, plan: plan,
                                                    environment: environment)
            inFlight.remove(accountID)
            switch outcome {
            case .renewed:
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
                _ = await SystemAlert.post(
                    title: "\(label) · " + L("Login not renewed"),
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

    /// The visible fallback: the same command, in a Terminal window the user drives themselves.
    /// Returns whether the window opened - driving Terminal is a permission the user grants once,
    /// and a refusal is silent from here, so the caller says something different when it fails.
    private func openTerminal(executable: String, envKey: String, home: String, providerID: String,
                              plan: RenewLoginCommand.Plan) async -> Bool {
        let command = RenewLoginCommand.shellCommand(
            executable: executable, envKey: envKey,
            home: RenewLoginCommand.isDefaultHome(home, providerID: providerID) ? nil : home,
            arguments: plan.arguments)
        let result = await CLIRunner.run(
            "/usr/bin/osascript",
            arguments: ["-e", RenewLoginCommand.terminalScript(command: command)],
            // Generous: the first run of this stops inside osascript while macOS asks whether Tally
            // may control Terminal, and a watchdog firing mid-question would report a refusal that
            // never happened.
            timeout: 120)
        guard result?.exitCode == 0 else {
            // One paste away from doing the job, which beats a dead end.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            return false
        }
        return true
    }

    /// The provider CLI (named after the provider), resolved to a REAL binary and never to Tally's
    /// own PATH shim. The shim re-picks an account for any invocation with an empty config-home
    /// variable, and the default home's login is exactly that - so a shimmed `claude` would renew
    /// whichever account the launch policy currently favours (the failure ProviderExecutable.swift
    /// documents on the CLI side). Falling back to the bare name leaves the lookup to the system,
    /// which is all there is when nothing was found.
    private static func providerExecutable(_ cli: String) -> String {
        // Dev-build hook, the same shape as -TallyDryNotifyTest and -TallyResetHintTest: point the
        // renewal at a stand-in CLI so the whole chain (menu → notification → card → runner →
        // verdict → fallback) can be exercised without spending a real credential on a real login.
        // Dev only, and volatile (argument domain): the release app cannot be talked into running
        // something else as its provider CLI.
        if BuildVariant.isDev,
           let standIn = UserDefaults.standard.string(forKey: "TallyRenewLoginCLI"),
           !standIn.isEmpty {
            return standIn
        }
        guard let path = CLIRunner.resolve(cli),
              !path.hasPrefix(IntegrationsStore.binDirURL.path + "/") else { return cli }
        return path
    }
}
