import Foundation

/// What "renew this account's login" runs, and how its output is read.
///
/// Tally never touches the credential. It starts the vendor's own CLI with one variable set (that
/// account's config home), the CLI opens the browser itself, and the OAuth round trip completes
/// inside the CLI. Nothing comes back to the app but a state: renewed, failed, or out of time.
///
/// Split from the runner and the store because this is the part that can be wrong in a way no type
/// check sees - the marker matching, the ANSI the markers arrive wrapped in, and the shell quoting
/// of the visible-Terminal fallback. tests/renewlogin covers all three.
enum RenewLoginCommand {
    /// How one provider's login is started and read.
    struct Plan: Sendable {
        /// The CLI's own re-login entry point.
        let arguments: [String]
        /// The CLI draws a terminal UI and reads keys, so it has to run on a pty: without one it
        /// aborts on raw mode rather than logging anyone in.
        let needsTerminal: Bool
        /// "The browser is up" - past this point the wait is on the human, not on the CLI, so the
        /// short no-output guard stops applying.
        let progressMarkers: [String]
        /// Seen = renewed. Empty means the provider is judged by its exit code alone.
        let successMarkers: [String]
        /// Seen = the CLI itself said no. Empty for a provider judged by exit code alone: a guessed
        /// failure word matched against ordinary progress output would abort a login going fine.
        let failureMarkers: [String]
        /// What to send once the success marker lands, for a UI that waits on a key before it
        /// exits. nil = nothing to send.
        let confirmKeystroke: String?
    }

    /// The plan for a provider, or nil for one Tally cannot log in (which greys the menu entry).
    ///
    /// Claude: `claude auth login` is a real subcommand ("Sign in to your Anthropic account",
    /// present in 2.1.218/219/220), and with the subscription method as its default it goes
    /// straight to the browser with no menu to steer through - verified end to end on this machine
    /// on 2026-08-03, where it printed "Opening browser to sign in…" and opened the browser on a
    /// localhost callback it had already started listening on. That callback is what lets the flow
    /// finish with no terminal for the user to watch. It still needs a pty, because the screen is
    /// drawn with Ink and Ink will not start without one.
    ///
    /// Codex: `codex login` is a plain command (the one Codex's own errors tell users to run, and
    /// the one Tally already prints for adding an account) that starts its own localhost callback,
    /// opens the browser and exits when the round trip lands. No UI, so no pty, and its exit code
    /// is the whole answer.
    ///
    /// The markers are matched loosely (case-insensitively, on ANSI-stripped text) on purpose: a
    /// CLI update is free to reword its own screens, and the cost of a marker going stale has to be
    /// the timeout and the visible-Terminal fallback, never a login reported as something it wasn't.
    static func plan(providerID: String) -> Plan? {
        switch providerID {
        case "claude":
            // --strict-mcp-config: the same guard the usage probe carries (ClaudeUsageCLI). A login
            // has no session to boot MCP servers for today, but a spawned `claude` never gets to
            // inherit the host's MCP config, and the subcommand accepts the flag (verified via
            // `claude auth login --strict-mcp-config --help`, 2026-08-03).
            return Plan(arguments: ["auth", "login", "--strict-mcp-config"],
                        needsTerminal: true,
                        progressMarkers: ["opening browser", "browser didn't open"],
                        successMarkers: ["login successful", "logged in as"],
                        failureMarkers: ["login failed", "authentication failed",
                                         "invalid authorization code", "oauth error"],
                        // Its success screen ends on "Press Enter to continue…".
                        confirmKeystroke: "\r")
        case "codex":
            return Plan(arguments: ["login"], needsTerminal: false,
                        progressMarkers: [], successMarkers: [], failureMarkers: [],
                        confirmKeystroke: nil)
        default:
            return nil
        }
    }

    /// The one environment entry a renewal adds. A nil VALUE means the variable must be REMOVED:
    /// the default home (`~/.claude`, `~/.codex`) runs with it unset, because the CLI namespaces
    /// its Keychain item by the exact variable string, so spelling out the default path makes it
    /// look up an item that does not exist ("Not logged in"). Removing it also beats an export
    /// inherited from the user's own shell profile, which would quietly renew another account.
    static func environment(envKey: String, home: String, providerID: String,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [String: String?] {
        [envKey: isDefaultHome(home, providerID: providerID, userHome: userHome) ? nil : home]
    }

    /// The provider's default config home (`~/.claude`, `~/.codex`). Mirrors `defaultHome` on the
    /// CLI side.
    static func defaultHome(providerID: String,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        userHome.appendingPathComponent(".\(providerID)").standardizedFileURL.path
    }

    static func isDefaultHome(_ home: String, providerID: String,
                              userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        URL(fileURLWithPath: home).standardizedFileURL.path
            == defaultHome(providerID: providerID, userHome: userHome)
    }

    // MARK: Reading the CLI's screen

    /// Whether any marker is present in `output`. A Bool rather than the line that matched, on
    /// purpose: what a login screen printed is compared and dropped, and a yes/no is the only thing
    /// that CANNOT carry a fragment of it into a notification, a log or a file.
    static func contains(anyOf markers: [String], in output: String) -> Bool {
        let text = output.lowercased()
        return markers.contains { text.contains($0.lowercased()) }
    }

    /// Terminal escape sequences removed, so a marker split up by the colour codes and cursor moves
    /// a terminal UI redraws itself with is still one run of plain text.
    static func plainText(_ raw: String) -> String {
        raw
            // CSI: ESC [ … final byte. Colours, cursor moves, line erases.
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "",
                                  options: .regularExpression)
            // OSC: ESC ] … BEL or ESC \ (window titles, hyperlinks).
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "",
                                  options: .regularExpression)
            // Anything else an ESC introduces (charset selects, single-character sequences).
            .replacingOccurrences(of: "\u{1B}[@-Z\\\\-_]", with: "", options: .regularExpression)
    }

    // MARK: The visible-Terminal fallback

    /// `env` prefix + executable + arguments, every field quoted for the shell. Only the fallback
    /// needs this - a background run passes argv and an environment dictionary, where quoting
    /// cannot arise. `home` nil = the default home, which unsets the variable (see `environment`).
    static func shellCommand(executable: String, envKey: String, home: String?,
                             arguments: [String]) -> String {
        let environment = home.map { ["env", "\(envKey)=\($0)"] } ?? ["env", "-u", envKey]
        return (environment + [executable] + arguments).map(shellQuoted).joined(separator: " ")
    }

    /// A shell word. Anything outside the safe set goes inside single quotes, with embedded quotes
    /// broken out the only way single quotes allow (`'\''`). Ordinary paths come through untouched,
    /// because this command is shown to the user in the Terminal window it opens.
    static func shellQuoted(_ value: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./:=,@+")
        if !value.isEmpty, value.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run `command` in a NEW Terminal window and bring it forward. `do script` without a target
    /// always opens its own window, so an existing Terminal session is never typed into.
    static func terminalScript(command: String) -> String {
        """
        tell application "Terminal"
            do script \(appleScriptString(command))
            activate
        end tell
        """
    }

    /// An AppleScript string literal. Runs AFTER the shell quoting, so it also has to survive the
    /// backslashes that `'\''` introduces.
    static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
