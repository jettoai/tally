import Foundation
import Observation
import UserNotifications

/// Whether each account is still signed in on this machine, asked of the providers' own CLIs after
/// a refresh. Owns three things and nothing else: the per-account verdict the cards read, the
/// email the probe named along the way, and the once-per-outage notification.
///
/// It keeps no timer: the existing refresh loop drives it, throttled to its own interval because a
/// credential does not change as often as a quota does.
///
/// Read-only throughout. The probe runs the provider's status subcommand, which reports a local
/// credential's state; nothing here signs anybody in (that is `RenewLoginStore`, and only from an
/// explicit click) and no credential is ever read, logged or carried.
@MainActor
@Observable
final class LoginStatusStore {
    static let shared = LoginStatusStore()

    /// The account the demo fixtures show expired, so the chip (and its colour) is in the marketing
    /// shot. Demo mode never runs a CLI, so this is the ONLY way a fixture card gets one - and
    /// renewing stays greyed out there, because a fixture has no config home behind it.
    static let demoExpiredAccountID = "claude:demo-Claude 5"

    /// Last verdict per account id. Absent = never probed; `.unknown` = asked and not understood.
    /// Neither shows anything on screen - only `.signedOut` does.
    private var verdicts: [String: LoginStatusCommand.Verdict] = [:]

    /// The last email a probe managed to read, per account id. Kept rather than replaced wholesale,
    /// because a round that could not name the account knows less than the previous one did.
    private var emails: [String: String] = [:]

    /// How often the probe may run. Far longer than the usage interval can be set to, because a
    /// login is not a quota: it changes when the user changes it, and the state that matters
    /// (expired) is not one an extra minute of freshness improves.
    static let probeInterval: TimeInterval = 5 * 60
    private var lastProbeAt: Date?
    /// One round at a time. Two overlapping rounds would each load the dedup state before either
    /// saved it, and an account that just expired would be announced twice.
    private var isProbing = false

    private let stateKey = "ai.jetto.tally.loginStatus.state"

    private init() {}

    /// Whether this account's card should say its login expired. Demo mode answers from the fixture
    /// instead: those cards have no config home, so nothing was ever probed for them.
    func isExpired(_ accountID: String) -> Bool {
        if DemoUsage.isActive { return accountID == Self.demoExpiredAccountID }
        return verdicts[accountID] == .signedOut
    }

    /// The account's email as the CLI named it, which is fresher than the copy in the provider's
    /// config file: a config home that was signed into as somebody else keeps the previous
    /// address until the file is rewritten, and `~/.claude.json` in particular is a file other
    /// tools leave stale copies of. Nil means this round could not tell, and the caller falls back
    /// to the config-derived one rather than showing nothing.
    func email(_ accountID: String) -> String? { emails[accountID] }

    /// Probe every account that has a config home, unless one ran recently. `userInitiated` (an
    /// explicit refresh, or the refresh a finished renewal triggers) always probes: the point of
    /// that refresh is usually to confirm the login just came back.
    func evaluate(accounts: [ProviderAccount], userInitiated: Bool) async {
        guard !DemoUsage.isActive, !isProbing else { return }
        let now = Date()
        if !userInitiated, let last = lastProbeAt,
           now.timeIntervalSince(last) < Self.probeInterval { return }
        lastProbeAt = now
        isProbing = true
        defer { isProbing = false }

        var readings: [String: LoginStatusCommand.Reading] = [:]
        await withTaskGroup(of: (String, LoginStatusCommand.Reading)?.self) { group in
            for account in accounts {
                guard let home = account.launchHome,
                      let arguments = LoginStatusCommand.arguments(providerID: account.providerID),
                      let envKey = IntegrationsStore.Shim(rawValue: account.providerID)?.envKey
                else { continue }
                let id = account.id
                let executable = ProviderCLI.executable(account.providerID,
                                                        devOverrideKey: Self.devCLIKey)
                let environment = RenewLoginCommand.environment(envKey: envKey, home: home,
                                                                providerID: account.providerID)
                group.addTask {
                    let output = await CLIRunner.run(executable, arguments: arguments,
                                                     environment: environment,
                                                     timeout: LoginStatusCommand.timeout)
                    // stdout and stderr together: claude answers on one, codex on the other.
                    return (id, LoginStatusCommand.read(
                        exitCode: output?.exitCode,
                        output: (output?.stdout ?? "") + "\n" + (output?.stderr ?? "")))
                }
            }
            for await result in group {
                if let result { readings[result.0] = result.1 }
            }
        }

        for (id, reading) in readings {
            verdicts[id] = reading.verdict
            if let email = reading.email { emails[id] = email }
        }
        announce(verdicts: readings.mapValues(\.verdict), accounts: accounts)
    }

    /// Dev-build stand-in CLI (`-TallyLoginStatusCLI /path/to/stub`), the same shape as
    /// `-TallyRenewLoginCLI`: it lets the whole chain - probe → verdict → chip → click → renewal →
    /// chip clears - be driven on screen without a real account ever being signed out.
    private static let devCLIKey = "TallyLoginStatusCLI"

    // MARK: The one notification per outage

    private func announce(verdicts: [String: LoginStatusCommand.Verdict],
                          accounts: [ProviderAccount]) {
        // The dev variant never owns the shared surfaces, and two apps watching the same accounts
        // would say everything twice. The chip is per-window and stays.
        guard !BuildVariant.isDev else { return }
        let (next, fresh) = LoginAlertLogic.advance(state: loadState(), verdicts: verdicts,
                                                    known: Set(accounts.map(\.id)))
        saveState(next)
        for id in fresh {
            let fallback = accounts.first { $0.id == id }?.label ?? id
            let label = SettingsStore.shared.displayLabel(accountID: id, fallback: fallback)
            Task { @MainActor in
                // A refusal hands the announcement back so a later round can say it again. State is
                // re-read rather than reused: a refresh can have completed while macOS answered.
                guard await post(accountID: id, label: label) == false else { return }
                saveState(LoginAlertLogic.rearm(state: loadState(), accountID: id))
            }
        }
    }

    /// Post one sample expiry notification (the `-TallyLoginExpiryTest` launch flag): checks the
    /// action button and its routing without waiting for a real account to go stale. It names a
    /// real account when the machine has one, so the button opens the real renewal. No state is
    /// persisted, so a normal launch is unaffected.
    func postSampleNotification() {
        let account = UsageStore.shared.discoveredAccounts.first
        Task { @MainActor in
            _ = await post(accountID: account?.id ?? "", label: account?.label ?? "Claude")
        }
    }

    private func post(accountID: String, label: String) async -> Bool {
        // The category carries the "Renew login" button, and its title is localized while Tally's
        // language can change while it runs - so it is re-registered right before the alert.
        NotificationRouter.shared.refreshCategories()
        return await SystemAlert.post(
            title: "\(label) · " + L("Login expired"),
            body: L("Tally can no longer read this account's usage. Sign in again to bring it back."),
            categoryID: Self.categoryID,
            userInfo: [Self.accountKey: accountID])
    }

    /// Category and action ids, plus the userInfo key naming the account. The delegate routes on
    /// these, so both sides read them from here. Nonisolated because the delegate reads a
    /// notification response off the main actor.
    nonisolated static let categoryID = "ai.jetto.tally.loginExpired"
    nonisolated static let renewActionID = "renew"
    nonisolated static let accountKey = "accountID"

    /// Registered at launch (a category unknown to the system when the notification lands shows no
    /// button at all). `.foreground` because renewing puts a browser sign-in in front of the user
    /// and reports back through the app.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryID,
            actions: [UNNotificationAction(identifier: renewActionID,
                                           title: L("Renew login"), options: [.foreground])],
            intentIdentifiers: [])
    }

    // MARK: State persistence

    private func loadState() -> LoginAlertState {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(LoginAlertState.self, from: data) else {
            return LoginAlertState()
        }
        return state
    }

    private func saveState(_ state: LoginAlertState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }
}
