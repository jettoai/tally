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

/// What the signIn screen tells a user whose Terminal cannot find the CLI Tally found (B-3745).
struct PathAdvice: Equatable {
    /// Where the CLI lives, as the user writes a path (`~/.local/bin`).
    var directory: String
    /// The command word (`claude`, `codex`).
    var cliName: String
    /// The one line that puts `directory` on the shell's PATH; nil when no safe line exists.
    var fixCommand: String?
    /// What to type instead: the CLI's full path.
    var fullPath: String
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
    /// The provider "Check again" looked for and still did not find; the install screen then lists
    /// where Tally looked.
    private(set) var recheckedMissing: String?
    /// Which path-guidance fixture a held preview shows (WelcomeFlow.previewPathState).
    private var previewPath = (offPath: false, notFound: false)

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
        case .needsCLI(let p, let waiting):
            if !waiting { return .needsCLI(providerID: p) }
            return flow.cliWaitStalled ? .waitingStalled(providerID: p) : .waiting(providerID: p)
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
        case .signIn(let p), .needsCLI(let p):
            return WelcomeFlow.screen(forChoice: chosenProvider ?? p, installed: cliInstalled)
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

    /// Set when the user's Terminal cannot find the provider's CLI although Tally did; nil when it
    /// can, or when that cannot be told (the login PATH is not read yet).
    func pathAdvice(_ providerID: String) -> PathAdvice? {
        if preview != nil { return previewPath.offPath && providerID == "claude" ? Self.fixtureAdvice : nil }
        guard let executable = ProviderCLI.resolved(providerID, devOverrideKey: "TallyRenewLoginCLI"),
              CLIPathAdvice.terminalFinds(providerID, executable: executable) == false else { return nil }
        let home = CLISearchPath.shared.home
        let directory = (executable as NSString).deletingLastPathComponent
        let shell = (CLISearchPath.shared.loginShell as NSString).lastPathComponent
        return PathAdvice(
            directory: CLIPathAdvice.display(directory, home: home), cliName: providerID,
            fixCommand: CLIPathAdvice.fixCommand(directory: directory, home: home, shell: shell),
            fullPath: CLIPathAdvice.commandWord(cli: providerID, executable: executable,
                                                terminalFinds: false, home: home))
    }

    /// The signIn card's second line: where the CLI was found, unless the Terminal cannot see it.
    func installedDetail(_ providerID: String) -> CLIPathAdvice.InstalledDetail {
        CLIPathAdvice.installedDetail(location: installedLocation(providerID),
                                      terminalFinds: pathAdvice(providerID) == nil)
    }

    /// The Copy button on the path card. A held preview copies nothing.
    func copyText(_ text: String) {
        guard preview == nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        previewPath = WelcomeFlow.previewPathState(named: previewName)
        recheckedMissing = previewPath.notFound ? "claude" : nil
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
        recheckedMissing = nil
        flow.stopWatchingForCLI()
    }

    private func detect(epoch: Int) async {
        // A screen that flashes and goes is a glitch; this one has a sentence to read.
        let dwell = Task { try? await Task.sleep(for: .milliseconds(900)) }
        // The shell's PATH is read before anyone asks whether a CLI is installed: off the main
        // thread the lookup waits for it, on the main thread it cannot, and a CLI that only the
        // user's shell finds (nvm, a custom npm prefix) would read as missing.
        async let loginRead: Void = Self.readLoginPATH()
        let accounts = await Self.signedInAccounts()
        await loginRead
        _ = await dwell.value
        guard epoch == detectEpoch else { return }
        signedIn = accounts
        detected = WelcomeFlow.verdict(signedInAccounts: accounts.count, installed: cliInstalled)
    }

    private nonisolated static func readLoginPATH() async {
        await Task.detached(priority: .utility) { _ = CLISearchPath.shared.loginPATH(waitIfCold: true) }.value
    }

    /// "Check again" on the install screen: look once more, after the login PATH has been read.
    /// `base` asks `cliInstalled` on every render, so a CLI found now moves the screen on by itself.
    func checkAgain(_ providerID: String) {
        guard preview == nil else { recheckedMissing = providerID; return }
        recheckedMissing = nil
        detectEpoch += 1
        let epoch = detectEpoch
        Task {
            await Self.readLoginPATH()
            guard epoch == detectEpoch else { return }
            detected = WelcomeFlow.verdict(signedInAccounts: signedIn.count, installed: cliInstalled)
            if !cliInstalled(providerID) { recheckedMissing = providerID }
        }
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
        case .detecting, .waiting, .waitingStalled, .signingIn: break
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
            case .needsCLI(let p), .signIn(let p): preview = .needsCLI(providerID: WelcomeFlow.otherProvider(p))
            case .waiting(let p), .waitingStalled(let p): preview = .needsCLI(providerID: p)
            case .signingIn(let p), .failed(let p, _): preview = .signIn(providerID: p)
            default: break
            }
            return
        }
        switch screen {
        case .found, .success: addAnotherAccount()
        case .needsCLI(let p), .signIn(let p):
            flow.reset()
            chosenProvider = WelcomeFlow.otherProvider(p)
        case .waiting, .waitingStalled: flow.showInstallCommandAgain()
        case .signingIn: flow.cancelSignIn()
        case .failed: flow.reset()
        case .detecting: break
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

    private static let fixtureAdvice = PathAdvice(
        directory: "~/.local/bin", cliName: "claude",
        fixCommand: #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc"#,
        fullPath: "~/.local/bin/claude")

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
