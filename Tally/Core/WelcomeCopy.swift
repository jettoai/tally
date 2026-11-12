import Foundation

/// The words the welcome window and Settings' install-needed sheet share, per provider. Every
/// sentence is one localized key (`L`), so a language is a table row and never a code change.
enum WelcomeCopy {
    static func cliName(_ providerID: String) -> String { providerID == "codex" ? "Codex" : "Claude Code" }

    /// Where the provider's own sign-in page lives, for the line that says what to approve.
    static func site(_ providerID: String) -> String { providerID == "codex" ? "chatgpt.com" : "claude.ai" }

    static func installTitle(_ providerID: String) -> String {
        if ClaudeInstall.supports(providerID) { return L("Set up Claude Code") }
        return String(format: L("Install %@ to get started"), cliName(providerID))
    }

    static func installBlurb(_ providerID: String) -> String {
        providerID == "codex"
            ? L("Tally reads your usage through Codex, OpenAI's official app for the Terminal. Installing it takes about a minute.")
            : L("Tally reads your usage through Claude Code, Anthropic's official app for the Terminal. Installing it takes about a minute.")
    }

    static func waitingTitle(_ providerID: String) -> String {
        String(format: L("Waiting for %@"), cliName(providerID))
    }

    /// The link that switches the install and sign-in screens to the other provider.
    static func useOtherProvider(_ providerID: String) -> String {
        providerID == "codex" ? L("I use Claude Code instead") : L("I use Codex instead")
    }

    static func stalledTitle(_ providerID: String) -> String {
        String(format: L("Tally can't see %@ yet"), cliName(providerID))
    }

    static var stalledBody: String { L("Look in the Terminal window for an error message, and check that this Mac is online. If nothing ran, choose Open Terminal Again.") }

    static func stalledNote(_ providerID: String) -> String {
        String(format: L("Tally keeps looking and moves on by itself once %@ is installed."), cliName(providerID))
    }

    /// The waiting page's first step, by how far the Terminal install got.
    static func terminalFirstStep(_ start: TerminalInstallStart) -> String {
        switch start {
        case .opening: return L("Opening Terminal…")
        case .running: return L("Terminal opened and started the install")
        case .copied: return L("Install command copied")
        }
    }

    /// Its second step: the install running, or (after a fallback) the paste the user still has to do.
    static func terminalSecondStep(_ start: TerminalInstallStart) -> String {
        start == .copied ? L("Paste it in Terminal and press Return") : L("Installing in Terminal")
    }

    /// The line under the second step. Only Claude Code's installer is known to end on a PATH note.
    static func terminalSecondDetail(_ providerID: String) -> String {
        providerID == "codex"
            ? L("About a minute.")
            : String(format: L("About a minute. A note about PATH at the end is fine to skip: Tally finds %@ anyway."), cliName(providerID))
    }

    /// What the script prints in Terminal around the vendor's command.
    static func terminalScriptWords(_ providerID: String) -> TerminalInstallScript.Words {
        TerminalInstallScript.Words(
            intro: String(format: L("Tally is installing %1$@ with %2$@'s official install script:"),
                          cliName(providerID), providerID == "codex" ? "OpenAI" : "Anthropic"),
            done: String(format: L("Done. Go back to Tally, it finds %@ by itself."), cliName(providerID)),
            failed: L("The install did not finish. The lines above say why. Tally can open this window again."),
            pathNote: providerID == "codex" ? nil : L("A note about PATH above is fine to skip."))
    }

    static func signInTitle(_ providerID: String) -> String {
        providerID == "codex" ? L("Sign in to your Codex account") : L("Sign in to your Claude account")
    }

    static func signInBlurb(_ providerID: String) -> String {
        providerID == "codex"
            ? L("Your browser opens chatgpt.com. Approve there and come back. Use the ChatGPT plan you already pay for.")
            : L("Your browser opens claude.ai. Approve there and come back. Use the Claude Pro or Max plan you already pay for.")
    }

    static func signingInBody(_ providerID: String) -> String {
        String(format: L("Approve the sign-in on %@. This window updates by itself."), site(providerID))
    }

    static func failureBody(_ failure: WelcomeFailure) -> String {
        switch failure {
        case .timedOut:
            return L("No approval came back from the browser within 3 minutes. Nothing was changed, so trying again is safe.")
        case .reported:
            return L("The sign-in command ended without signing in. Nothing was changed, so trying again is safe.")
        case .couldNotStart:
            return L("Tally could not start the sign-in command. Nothing was changed, so trying again is safe.")
        case .other:
            // The flow's own sentence names a config folder; the user needs what happened and that retrying is safe.
            return L("Tally could not set up the new account. Nothing was changed, so trying again is safe.")
        }
    }

    /// The success page's line: the account is in the menu bar, and how to reach it from Terminal.
    static var successBody: String {
        L("This account is in your menu bar now. To start sessions from Terminal, install the command line tool in Settings > Integrations, then type tally claude or tally codex.")
    }

    // MARK: The in-app install

    /// The ready page's first step: what runs and what it does not need. Only claims that were
    /// checked: the script refuses sudo (install.sh:14-36), so it never asks for a password. A
    /// "nothing outside your home folder" half-sentence was not verified on a clean Mac and is left out.
    static var officialScript: String {
        L("Tally runs Anthropic's official install script from claude.ai, the same line their docs give. It never asks for your password.")
    }

    static var installingBody: String { L("About a minute. When it's done, your browser opens claude.ai so you can sign in.") }

    static func installProgress(_ stage: ClaudeInstall.Stage) -> String {
        switch stage {
        case .fetching: return L("Getting the official script from claude.ai")
        case .downloading(let bytes?):
            return String(format: L("Downloading, %lld MB so far. The script checks it against Anthropic's published checksum."), bytes / 1_000_000)
        case .downloading(nil): return L("Downloading. The script checks it against Anthropic's published checksum.")
        case .settingUp: return L("Setting up the claude command. The first run can take up to a minute while macOS checks it.")
        }
    }

    static func installFailureBody(_ failure: ClaudeInstall.Failure) -> String {
        let reason: String
        switch failure {
        case .unreachable: reason = L("Tally couldn't reach downloads.claude.ai. Check your internet connection.")
        case .checksum: reason = L("The download didn't match Anthropic's published checksum, so the script stopped.")
        case .stalled: reason = String(format: L("The install made no progress for %lld seconds."), Int64(ClaudeInstall.stallSeconds))
        case .tooLong: reason = String(format: L("The install was still running after %lld minutes."), Int64(ClaudeInstall.overallSeconds / 60))
        case .notFound: reason = L("The script finished, but Tally can't find the claude command.")
        case .other: reason = L("The install script stopped with an error.")
        }
        return reason + " " + L("Trying again is safe.")
    }

    /// "Claude Code", "Codex" or "Claude Code and Codex", for the line under "Found N accounts".
    static func readFrom(_ providerIDs: Set<String>) -> String {
        let names = WelcomeFlow.providers.filter(providerIDs.contains).map(cliName)
        switch names.count {
        case 0: return cliName("claude")
        case 1: return names[0]
        default: return String(format: L("%1$@ and %2$@"), names[0], names[1])
        }
    }
}
