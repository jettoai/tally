import AppKit

/// What a background login falls back to when it cannot finish on its own: the very same command,
/// in a Terminal window the user drives themselves.
///
/// Shared by both flows that start a provider login without a terminal (renewing an expired account,
/// adding a new one), because the fallback is the part that must never differ: automation the user
/// cannot watch is only acceptable when its failure hands them something they can.
enum LoginTerminalFallback {
    /// Opens Terminal on the login command for one config home. Returns whether the window opened -
    /// driving Terminal is a permission the user grants once, and a refusal is silent from here, so
    /// a caller says something different when it fails. On refusal the command is put on the
    /// clipboard instead, which is one paste away from doing the job and beats a dead end.
    @MainActor
    static func openTerminal(executable: String, envKey: String, home: String, providerID: String,
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            return false
        }
        return true
    }
}
