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

    /// Who an account is signed in as, for a surface that wants to show it: the probe's live answer
    /// first, then whatever the provider could read out of its own config home (`accountEmail`,
    /// which for Codex is the only source there is - its CLI names no account). Nil when neither
    /// knows, and a caller that renders this shows NOTHING there rather than an empty line.
    ///
    /// One chain, asked from every surface. The card's tooltip and the Settings row are the same
    /// question about the same account, and a second copy of the ordering would eventually answer
    /// it differently on one of them.
    func identityEmail(_ usage: AccountUsage) -> String? {
        email(usage.id) ?? usage.accountEmail
    }

    /// Accounts a login was just attempted on, which may force a round past the interval
    /// (LoginProbeGate.swift - it owns the whole rule and the bug it closes).
    private var gate = LoginProbeGate.State()
    /// A forced round that arrived while another was out, kept rather than dropped.
    private var queuedRound: (accounts: [ProviderAccount], known: Set<String>)?
    /// Which rounds a landing has overtaken. A round already out when a login lands asked its
    /// question before the credential existed, so it does not get to answer it
    /// (LoginProbeGate.Landings).
    private var landings = LoginProbeGate.Landings()

    /// A renewal reported success for this account. The stale verdict goes NOW - the CLI that just
    /// signed in is a better witness than a probe from before it ran - and the next round is forced,
    /// so the card is corrected by data within seconds either way. A round already in flight is the
    /// same probe from before it ran, so it is retired here too.
    func loginRenewed(_ accountID: String) {
        verdicts[accountID] = nil
        landings.land([accountID])
        gate.forced[accountID] = LoginProbeGate.renewed
    }

    /// A login was handed to a Terminal window Tally cannot watch. Nothing is assumed about the
    /// outcome; the next few rounds simply stop being skipped, so the refresh the finished login
    /// triggers (AccountDirWatcher sees the credential land) is allowed to ask.
    func loginHandedOff(_ accountID: String) {
        gate.forced[accountID] = LoginProbeGate.handedOff
    }

    /// Whether this account is still owed an answer about a login attempt. Read by the handoff's
    /// own poll (RenewLoginStore), which is asking "is there still anything to wait for" - the
    /// forcing is cleared by the round that reads a verdict other than signed out.
    func isAwaitingLogin(_ accountID: String) -> Bool { gate.forced[accountID] != nil }

    /// Discovery found these accounts signed in again after they had gone dormant, which is the
    /// login landing. Discovery is credential-shaped, so it knows better than the last probe: the
    /// stale "signed out" verdict goes now (that is the chip), and the forcing stays so the round
    /// behind it can re-read the email the same probe carries.
    ///
    /// Clearing the verdict is only half of it: a round that STARTED before the credential landed is
    /// still out there, and it would write its "signed out" over this the moment it returned, which
    /// is the chip back for another interval. So the landing is recorded as well, and that round's
    /// readings are dropped when it comes home (LoginProbeGate.Landings).
    func loginLanded(_ accountIDs: Set<String>) {
        for id in accountIDs { verdicts[id] = nil }
        landings.land(accountIDs)
    }

    /// Probe every account that has a config home, unless one ran recently. `userInitiated` (an
    /// explicit refresh, or the refresh a finished renewal triggers) always probes: the point of
    /// that refresh is usually to confirm the login just came back.
    ///
    /// `known` is every account that still exists on this machine, which is a WIDER set than the
    /// one being probed (that one is filtered by enablement). Only the dedup state reads it - see
    /// `announce`.
    func evaluate(accounts: [ProviderAccount], known: Set<String>, userInitiated: Bool) async {
        guard !DemoUsage.isActive else { return }
        let now = Date()
        switch LoginProbeGate.decide(state: gate, isProbing: isProbing, userInitiated: userInitiated,
                                     lastProbeAt: lastProbeAt, now: now,
                                     interval: Self.probeInterval) {
        case .skip:
            return
        case .queue:
            // Held rather than dropped: this is the round a just-renewed account is waiting on, and
            // returning here used to leave its chip up for the rest of the interval.
            queuedRound = (accounts, known)
            return
        case .run:
            break
        }
        lastProbeAt = now
        isProbing = true
        defer { isProbing = false }
        // Taken before a single CLI is spawned: everything this round says is about the machine as
        // it is right now, and a login that lands while it runs makes all of it a memory.
        let mark = landings.mark

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

        // Whole readings, not just their verdicts: an account that signed in while this round ran
        // has an email to go with the new credential, and this round read the old one. Dropped here
        // rather than at the three places below, so the chip, the notification and the gate can
        // never disagree about which accounts this round spoke for.
        let fresh = readings.filter { !landings.isStale($0.key, since: mark) }
        for (id, reading) in fresh {
            verdicts[id] = reading.verdict
            if let email = reading.email { emails[id] = email }
        }
        let roundVerdicts = fresh.mapValues(\.verdict)
        announce(verdicts: roundVerdicts, accounts: accounts, known: known)

        let (next, retrySoon) = LoginProbeGate.afterRound(state: gate, verdicts: roundVerdicts,
                                                          known: known)
        gate = next
        let queued = queuedRound
        queuedRound = nil
        // Both follow-ups start AFTER this call returns (its `defer` has to clear `isProbing` first,
        // or the round they ask for would be queued behind the one that is finishing).
        if let queued {
            Task { @MainActor in
                await evaluate(accounts: queued.accounts, known: queued.known, userInitiated: true)
            }
        } else if retrySoon {
            // The CLI said the login landed and the probe still says signed out: the credential is
            // most likely still being written. One short re-ask, rather than five minutes of a red
            // chip on an account that works.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(LoginProbeGate.retryDelay * 1_000_000_000))
                await evaluate(accounts: accounts, known: known, userInitiated: true)
            }
        }
    }

    /// Dev-build stand-in CLI (`-TallyLoginStatusCLI /path/to/stub`), the same shape as
    /// `-TallyRenewLoginCLI`: it lets the whole chain - probe → verdict → chip → click → renewal →
    /// chip clears - be driven on screen without a real account ever being signed out.
    private static let devCLIKey = "TallyLoginStatusCLI"

    // MARK: The one notification per outage

    private func announce(verdicts: [String: LoginStatusCommand.Verdict],
                          accounts: [ProviderAccount], known: Set<String>) {
        // The dev variant never owns the shared surfaces, and two apps watching the same accounts
        // would say everything twice. The chip is per-window and stays.
        guard !BuildVariant.isDev else { return }
        // Pruned against every account that still EXISTS, not against the ones probed this round.
        // The probe list is filtered by enablement, so an account switched off for longer than a
        // probe interval would be dropped from the state as though its outage had ended - and
        // switching it back on without signing in would announce the same outage a second time.
        let (next, fresh) = LoginAlertLogic.advance(state: loadState(), verdicts: verdicts,
                                                    known: known)
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
        // Discovered on the spot rather than read off the store: this runs from
        // `applicationDidFinishLaunching`, where the launch refresh has only just been queued, so
        // the store's list is still empty and the alert would carry no account id at all - leaving
        // its "Renew login" button, the one thing this flag exists to check, nothing to route to.
        let account = UsageStore.shared.discoveredAccountsNow().first
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
