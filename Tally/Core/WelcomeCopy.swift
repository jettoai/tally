import Foundation

/// The words the welcome window and Settings' install-needed sheet share, per provider. Every
/// sentence is one localized key (`L`), so a language is a table row and never a code change.
enum WelcomeCopy {
    static func cliName(_ providerID: String) -> String { providerID == "codex" ? "Codex" : "Claude Code" }

    /// Where the provider's own sign-in page lives, for the line that says what to approve.
    static func site(_ providerID: String) -> String { providerID == "codex" ? "chatgpt.com" : "claude.ai" }

    static func installTitle(_ providerID: String) -> String {
        String(format: L("Install %@ to get started"), cliName(providerID))
    }

    static func installBlurb(_ providerID: String) -> String {
        providerID == "codex"
            ? L("Tally reads your usage through Codex, OpenAI's official app for the Terminal. Installing it takes about a minute.")
            : L("Tally reads your usage through Claude Code, Anthropic's official app for the Terminal. Installing it takes about a minute.")
    }

    static func waitingTitle(_ providerID: String) -> String {
        String(format: L("Waiting for %@"), cliName(providerID))
    }

    static func stalledTitle(_ providerID: String) -> String {
        String(format: L("Tally can't see %@ yet"), cliName(providerID))
    }

    static var stalledBody: String { L("Look in the Terminal window for an error message, and check that this Mac is online. If nothing ran, paste the command again and press Return.") }

    static func stalledNote(_ providerID: String) -> String {
        String(format: L("Tally keeps looking and moves on by itself once %@ is installed."), cliName(providerID))
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
