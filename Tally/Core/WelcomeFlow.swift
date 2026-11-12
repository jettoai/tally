import Foundation

// The first-run welcome window's rules, kept Foundation-only so tests/welcome can compile them alone:
// which screen the user is on, when the window may open by itself, what to copy for an install.
// The store (Tally/Stores/WelcomeStore.swift) and the views only ask these questions.

/// One screen of the welcome window. Exactly one is on screen at a time, and each does one job.
enum WelcomeScreen: Equatable {
    /// Looking for signed-in accounts and for the CLIs, usually under a second.
    case detecting
    /// At least one signed-in account was found: nothing to set up.
    case found
    /// The provider's CLI is not on this Mac: show its official install command.
    case needsCLI(providerID: String)
    /// "Install in Terminal" opened Terminal on the install command: wait for the CLI to appear.
    case waiting(providerID: String)
    /// The wait has run past `WelcomeFlow.installStallSeconds` with no CLI in sight: say so, with
    /// the usual causes, and keep looking.
    case waitingStalled(providerID: String)
    /// The CLI is there but nobody is signed in.
    case signIn(providerID: String)
    /// The provider's own login is running in the browser.
    case signingIn(providerID: String)
    /// The first account landed.
    case success
    /// The login ended without an account.
    case failed(providerID: String, reason: WelcomeFailure)
}

/// Why a sign-in ended without an account, in the user's words (the copy lives in the store).
enum WelcomeFailure: Equatable {
    case timedOut
    case reported
    case couldNotStart
    /// Tally could not prepare a home at all; carries the sentence the flow already wrote.
    case other(String)
}

/// What the detection pass decided to do about this Mac.
enum WelcomeVerdict: Equatable {
    case found
    case signIn(providerID: String)
    case needsCLI(providerID: String)
}

/// How far "Install in Terminal" got, for the waiting page's first step.
enum TerminalInstallStart: Equatable {
    /// Terminal was asked to open the script; its receipt has not appeared yet.
    case opening
    /// The receipt appeared: the script is running.
    case running
    /// The script could not be written or opened: the command was copied and Terminal opened instead.
    case copied
}

enum WelcomeFlow {
    /// The providers the welcome window knows how to install, in the order it offers them.
    static let providers = ["claude", "codex"]

    /// Detection: a signed-in account wins; else a CLI that is already there goes straight to its
    /// sign-in; else the first provider's install screen. `installed` answers per provider.
    static func verdict(signedInAccounts: Int, installed: (String) -> Bool) -> WelcomeVerdict {
        if signedInAccounts > 0 { return .found }
        if let ready = providers.first(where: installed) { return .signIn(providerID: ready) }
        return .needsCLI(providerID: providers[0])
    }

    /// The official one-line installers (the vendors' own docs): Claude Code's install page and the
    /// Codex README. Shown verbatim, and run verbatim by the script "Install in Terminal" opens
    /// (TerminalInstallScript).
    static func installCommand(providerID: String) -> String {
        providerID == "codex"
            ? "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
            : "curl -fsSL https://claude.ai/install.sh | bash"
    }

    /// The other provider, for the "I use Codex instead" link.
    static func otherProvider(_ providerID: String) -> String {
        providerID == "codex" ? "claude" : "codex"
    }

    /// The screen for a provider the user picked ("I use X instead"): its sign-in when its CLI is on
    /// this Mac, else its install.
    static func screen(forChoice providerID: String, installed: (String) -> Bool) -> WelcomeScreen {
        installed(providerID) ? .signIn(providerID: providerID) : .needsCLI(providerID: providerID)
    }

    /// How long the install wait may run before the window stops promising it will move on by itself.
    static let installStallSeconds: TimeInterval = 180

    /// Whether an install wait of `waited` seconds has stalled. A CLI that showed up always wins.
    static func isInstallStalled(waited: TimeInterval, installed: Bool) -> Bool {
        !installed && waited >= installStallSeconds
    }

    /// How long "Opening Terminal…" may show before the step says macOS may be asking first.
    static let terminalOpenNudgeSeconds: TimeInterval = 15

    // MARK: When the window opens by itself

    /// Whether the welcome window opens at this launch.
    ///
    /// `forced` / `preview` are the dev flags, already gated by the caller on a Dev build or demo
    /// data, so a release launch passes false for both. Otherwise it opens once, for a Mac that has
    /// never shown it, never ran this app before (`hadLaunchedBefore` is the login-item default's
    /// record, so an update does not welcome an existing user), when no window came back from the
    /// last quit, and only on a launch that is allowed to write window state (a capture launch
    /// leaves the user's Mac exactly as it found it).
    static func shouldShow(seen: Bool, hadLaunchedBefore: Bool, restoredWindow: Bool,
                           mayRecordWindowState: Bool, forced: Bool, preview: Bool) -> Bool {
        if forced || preview { return true }
        return !seen && !hadLaunchedBefore && !restoredWindow && mayRecordWindowState
    }

    /// Whether showing it now should be remembered, so it is not shown again. A dev preview is a
    /// look, never a first run.
    static func shouldRecordSeen(forced: Bool, preview: Bool, mayRecordWindowState: Bool) -> Bool {
        !forced && !preview && mayRecordWindowState
    }

    // MARK: Dev preview

    /// `-TallyWelcomePreview <name>`: the screen to hold on, with fixture content and no side effects.
    static func previewScreen(named name: String?) -> WelcomeScreen? {
        switch name?.lowercased() {
        case "detecting": return .detecting
        case "found": return .found
        case "needs-claude": return .needsCLI(providerID: "claude")
        case "needs-codex": return .needsCLI(providerID: "codex")
        case "waiting", "waiting-opening", "waiting-copied": return .waiting(providerID: "claude")
        case "waiting-stalled": return .waitingStalled(providerID: "claude")
        case "signin", "signin-offpath": return .signIn(providerID: "claude")
        case "needs-claude-notfound": return .needsCLI(providerID: "claude")
        case "signing-in", "signing-in-waiting": return .signingIn(providerID: "claude")
        case "success": return .success
        case "failed": return .failed(providerID: "claude", reason: .timedOut)
        default: return nil
        }
    }

    /// `signing-in-waiting` holds the sign-in page before the CLI has said the browser is up (B-4392);
    /// every other name, `signing-in` included, shows that step as done.
    static func previewBrowserWaiting(named name: String?) -> Bool {
        name?.lowercased() == "signing-in-waiting"
    }

    /// The Terminal fixture a held waiting page shows: `waiting-opening` and `waiting-copied` hold the
    /// other two states of the first step; every other name shows it running.
    static func previewTerminalStart(named name: String?) -> TerminalInstallStart {
        switch name?.lowercased() {
        case "waiting-opening": return .opening
        case "waiting-copied": return .copied
        default: return .running
        }
    }

    /// The path guidance a held preview adds to its screen (B-3745): `signin-offpath` shows the
    /// card for a CLI Terminal cannot find, `needs-claude-notfound` the card after "Check again"
    /// found nothing. Every other name shows neither.
    static func previewPathState(named name: String?) -> (offPath: Bool, notFound: Bool) {
        switch name?.lowercased() {
        case "signin-offpath": return (true, false)
        case "needs-claude-notfound": return (false, true)
        default: return (false, false)
        }
    }

    /// Where a preview's primary button leads, so a held preview can be walked by hand without any
    /// install, login or clipboard write behind it. nil = the walk is over.
    static func previewNext(after screen: WelcomeScreen) -> WelcomeScreen? {
        switch screen {
        case .detecting: return .found
        case .found, .success: return nil
        case .needsCLI(let p): return .waiting(providerID: p)
        case .waiting(let p), .waitingStalled(let p): return .signIn(providerID: p)
        case .signIn(let p): return .signingIn(providerID: p)
        case .signingIn: return .success
        case .failed(let p, _): return .signingIn(providerID: p)
        }
    }
}
