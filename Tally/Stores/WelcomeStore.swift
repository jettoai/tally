import AppKit
import Observation

/// One account line on the found and success screens: what the panel's own row says, smaller.
struct WelcomeRow: Identifiable, Equatable {
    struct Meter: Equatable {
        var leftPercent: Int
        var resetText: String
        var severity: MetricSeverity
    }

    var id: String
    var providerID: String
    var name: String
    var plan: String?
    var email: String?
    var session: Meter?
    var weekly: Meter?
    /// No reading yet: the first poll of this account is still on its way.
    var isLoading: Bool { session == nil && weekly == nil }
}

/// What the first-run welcome window shows and does. The screen is DERIVED from three facts - the
/// detection pass, the add-account flow's phase (shared with Settings' sheet), and the user's
/// provider choice - so nothing here can disagree with the flow it is a window onto.
///
/// A held preview (`-TallyWelcomePreview`, Dev builds or demo data only) replaces all three with a
/// fixture screen whose buttons walk the sequence and touch nothing: no clipboard, no Terminal, no
/// login, no config home.
@MainActor
@Observable
final class WelcomeStore {
    static let shared = WelcomeStore()

    private(set) var detected: WelcomeVerdict?
    private(set) var signedIn: [ProviderAccount] = []
    private(set) var preview: WelcomeScreen?
    /// "I use Codex instead": the provider the user picked on the install screen.
    private(set) var chosenProvider: String?

    /// Whether a provider's CLI is on this Mac. A property so the suite can stand in for the disk.
    var cliInstalled: (String) -> Bool = {
        ProviderCLI.resolved($0, devOverrideKey: "TallyRenewLoginCLI") != nil
    }
    /// Set by the window controller: close the window.
    var closeWindow: () -> Void = {}

    private let flow = AddAccountStore.shared
    private var detectEpoch = 0

    // MARK: The screen

    var screen: WelcomeScreen {
        if let preview { return preview }
        switch flow.phase {
        case .needsCLI(let p, let waiting): return waiting ? .waiting(providerID: p) : .needsCLI(providerID: p)
        case .preparing, .signingIn: return .signingIn(providerID: flow.runProviderID)
        case .added: return .success
        case .pending(_, let reason, _):
            if flow.lastFailure == .cancelled { return base }
            return .failed(providerID: flow.runProviderID, reason: Self.failure(flow.lastFailure, reason))
        case .failed(let reason): return .failed(providerID: flow.providerID, reason: .other(reason))
        case .idle: return base
        }
    }

    /// The screen when no login is in flight: what detection found, adjusted by the user's choice.
    private var base: WelcomeScreen {
        guard let detected else { return .detecting }
        switch detected {
        case .found: return .found
        case .signIn(let p): return .signIn(providerID: p)
        case .needsCLI(let p):
            let q = chosenProvider ?? p
            return cliInstalled(q) ? .signIn(providerID: q) : .needsCLI(providerID: q)
        }
    }

    private static func failure(_ failure: RenewLoginRunner.Failure?, _ reason: String) -> WelcomeFailure {
        switch failure {
        case .timedOut: return .timedOut
        case .reported: return .reported
        case .couldNotStart, .notInstalled: return .couldNotStart
        case .cancelled, nil: return .other(reason)
        }
    }

    // MARK: Rows

    /// The accounts the found screen lists, or the one the success screen celebrates.
    var rows: [WelcomeRow] {
        if preview != nil { return Self.fixtureRows(success: screen == .success) }
        if case .added(let prepared) = flow.phase {
            let mine = UsageStore.shared.discoveredAccounts.filter { $0.launchHome == prepared.dir.path }
            return mine.map(row)
        }
        return signedIn.map(row)
    }

    private func row(_ account: ProviderAccount) -> WelcomeRow {
        let usage = UsageStore.shared.accounts.first { $0.id == account.id }
        let columns = UsageMetric.columns(usage?.metrics ?? [])
        func meter(_ metric: UsageMetric?) -> WelcomeRow.Meter? {
            metric.map {
                WelcomeRow.Meter(
                    leftPercent: Int($0.remainingPercent.rounded()),
                    resetText: $0.resetsAt.map { UsageFormat.resetCompact(.countdown($0)) } ?? "",
                    severity: $0.severity)
            }
        }
        return WelcomeRow(id: account.id, providerID: account.providerID, name: account.label,
                          plan: usage?.planName, email: usage?.accountEmail,
                          session: meter(columns.session), weekly: meter(columns.weekly))
    }

    /// Where the provider's CLI was found, as the user writes a path (`~/.local/bin`).
    func installedLocation(_ providerID: String) -> String? {
        if preview != nil { return "~/.local/bin" }
        return ProviderCLI.resolved(providerID, devOverrideKey: "TallyRenewLoginCLI")
            .map { ((($0 as NSString).deletingLastPathComponent) as NSString).abbreviatingWithTildeInPath }
    }

    /// The install screen's Copy button. A held preview copies nothing.
    func copyCommand(_ providerID: String) {
        guard preview == nil else { return }
        AddAccountStore.copyInstallCommand(providerID: providerID)
    }

    /// The providers behind the found rows, for "Tally reads usage from Claude Code".
    var foundProviders: Set<String> { Set(rows.map(\.providerID)) }

    // MARK: Opening and closing

    /// The window is about to be shown. `previewName` is the dev flag's value, already gated.
    func begin(previewName: String?) {
        detectEpoch += 1
        chosenProvider = nil
        if let held = WelcomeFlow.previewScreen(named: previewName) {
            preview = held
            return
        }
        preview = nil
        flow.stopWatchingForCLI()
        flow.reset()   // a success or a stale failure from an earlier visit is not this visit's
        detected = nil
        let epoch = detectEpoch
        Task { await detect(epoch: epoch) }
    }

    func windowClosed() {
        detectEpoch += 1
        flow.stopWatchingForCLI()
    }

    private func detect(epoch: Int) async {
        // A screen that flashes and goes is a glitch; this one has a sentence to read.
        let dwell = Task { try? await Task.sleep(for: .milliseconds(900)) }
        let accounts = await Self.signedInAccounts()
        _ = await dwell.value
        guard epoch == detectEpoch else { return }
        signedIn = accounts
        detected = WelcomeFlow.verdict(signedInAccounts: accounts.count, installed: cliInstalled)
    }

    /// Signed-in accounts on this machine. Demo data answers with its fixtures and reads nothing.
    private static func signedInAccounts() async -> [ProviderAccount] {
        if DemoUsage.isActive { return DemoUsage.discoveredAccounts().filter { !$0.isDormant } }
        await UsageStore.shared.adoptFreshDiscovery()
        return UsageStore.shared.discoveredAccounts.filter { !$0.isDormant }
    }

    // MARK: Buttons

    func primary() {
        if let held = preview {
            if let next = WelcomeFlow.previewNext(after: held) { preview = next } else { closeWindow() }
            return
        }
        switch screen {
        case .detecting, .waiting, .signingIn: break
        case .found, .success: showUsage()
        case .needsCLI(let p):
            flow.showNeedsCLI(providerID: p)
            flow.copyInstallCommandAndWait()
        case .signIn(let p):
            flow.beginEntry(providerID: p)
            flow.start()
        case .failed:
            flow.providerID = flow.runProviderID
            flow.start()
        }
    }

    func secondary() {
        if let held = preview {
            switch held {
            case .needsCLI(let p): preview = .needsCLI(providerID: WelcomeFlow.otherProvider(p))
            case .waiting(let p): preview = .needsCLI(providerID: p)
            case .signingIn(let p), .failed(let p, _): preview = .signIn(providerID: p)
            default: break
            }
            return
        }
        switch screen {
        case .found, .success: addAnotherAccount()
        case .needsCLI(let p):
            flow.reset()
            chosenProvider = WelcomeFlow.otherProvider(p)
        case .waiting: flow.showInstallCommandAgain()
        case .signingIn: flow.cancelSignIn()
        case .failed: flow.reset()
        case .detecting, .signIn: break
        }
    }

    /// "Browser didn't open? Open it again": end this run and start the same account's login anew,
    /// which is what makes the CLI open the browser once more. One login at a time, so it waits for
    /// the cancelled run to be gone before the next one starts.
    func openBrowserAgain() {
        guard preview == nil else { return }
        flow.cancelSignIn()
        Task {
            for _ in 0 ..< 20 where !flow.phase.allowsNewRun { try? await Task.sleep(for: .milliseconds(250)) }
            guard case .pending = flow.phase else { return }
            flow.providerID = flow.runProviderID
            flow.start()
        }
    }

    /// The panel the menu bar item opens, or the main window when the item is not on screen
    /// (hidden by a notch or a crowded bar).
    func showUsage() {
        flow.reset()
        closeWindow()
        guard preview == nil else { return }
        if !(StatusItemController.shared?.openUsageSurfaceOnReopen() ?? false) {
            MainWindowController.shared.show()
        }
    }

    /// A second account is a different act from the first: it asks whether to share the first
    /// one's setup (instructions, history), and that choice is Settings' sheet to put.
    private func addAnotherAccount() {
        guard preview == nil else { return }
        flow.reset()
        closeWindow()
        SettingsWindowController.shared.show()
    }

    // MARK: Preview fixtures

    /// "4h" / "6d" in the app's own units, so a held preview reads in the language it is held in.
    private static func fixtureReset(hours: Double) -> String {
        UsageFormat.durationBody(hours * 3600)
    }

    private static func fixtureRows(success: Bool) -> [WelcomeRow] {
        let first = WelcomeRow(
            id: "welcome:claude", providerID: "claude", name: "Claude", plan: "Max 20x",
            email: "alex@example.com",
            session: .init(leftPercent: 42, resetText: Self.fixtureReset(hours: 4), severity: .normal),
            weekly: .init(leftPercent: 58, resetText: Self.fixtureReset(hours: 6 * 24), severity: .normal))
        let second = WelcomeRow(
            id: "welcome:claude2", providerID: "claude", name: "Claude 2", plan: "Pro",
            email: nil,
            session: .init(leftPercent: 88, resetText: Self.fixtureReset(hours: 4), severity: .normal),
            weekly: .init(leftPercent: 71, resetText: Self.fixtureReset(hours: 6 * 24), severity: .normal))
        return success ? [first] : [first, second]
    }
}
