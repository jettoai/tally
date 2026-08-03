import AppKit

/// What a background login falls back to when it cannot finish on its own: the very same command,
/// in a Terminal window the user drives themselves.
///
/// Shared by both flows that start a provider login without a terminal (renewing an expired account,
/// adding a new one), because the fallback is the part that must never differ: automation the user
/// cannot watch is only acceptable when its failure hands them something they can.
enum LoginTerminalFallback {
    /// How long the window is watched for its success receipt: 300 rounds a second apart. A login
    /// is a browser round trip with a human in it, so the ceiling is generous; past it the window
    /// is simply left alone, which is where this feature started.
    private static let watchRounds = 300
    private static let watchInterval = Duration.seconds(1)

    /// Opens Terminal on the login command for one config home. Returns whether the window opened -
    /// driving Terminal is a permission the user grants once, and a refusal is silent from here, so
    /// a caller says something different when it fails. On refusal the command is put on the
    /// clipboard instead, which is one paste away from doing the job and beats a dead end.
    ///
    /// Returning is not the end of it: a window whose login SUCCEEDS closes itself afterwards (see
    /// `watch`), because an empty shell left over from a finished sign-in is litter the user has to
    /// clear by hand. A window whose login failed always stays.
    @MainActor
    static func openTerminal(executable: String, envKey: String, home: String, providerID: String,
                             plan: RenewLoginCommand.Plan) async -> Bool {
        let command = RenewLoginCommand.shellCommand(
            executable: executable, envKey: envKey,
            home: RenewLoginCommand.isDefaultHome(home, providerID: providerID) ? nil : home,
            arguments: plan.arguments)
        // Unique per window: two fallbacks can be open at once (two accounts, two providers), and a
        // shared path would have the first one to finish close the other's window over its login.
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tally-login-\(UUID().uuidString)")
        let result = await CLIRunner.run(
            "/usr/bin/osascript",
            arguments: ["-e", RenewLoginCommand.terminalScript(
                command: RenewLoginCommand.commandWithReceipt(command, marker: marker.path))],
            // Generous: the first run of this stops inside osascript while macOS asks whether Tally
            // may control Terminal, and a watchdog firing mid-question would report a refusal that
            // never happened.
            timeout: 120)
        guard result?.exitCode == 0 else {
            NSPasteboard.general.clearContents()
            // The command as the user would run it: the receipt is Tally's own bookkeeping, and a
            // paste has nothing to report back to.
            NSPasteboard.general.setString(command, forType: .string)
            return false
        }
        if let windowID = Int(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            watch(windowID: windowID, marker: marker)
        }
        return true
    }

    /// Close the window once the command inside it has said it succeeded, and never otherwise.
    ///
    /// The receipt file is the whole signal. Terminal's own `busy` is not usable for this: it reads
    /// false in the moments right after `do script`, before the command it was given has started,
    /// so a window that had barely opened would be judged finished and closed over a login that was
    /// about to run (measured, 2026-08-03). A file that only exists when the command exited zero
    /// cannot be early.
    private static func watch(windowID: Int, marker: URL) {
        Task.detached {
            for _ in 0 ..< watchRounds {
                try? await Task.sleep(for: watchInterval)
                guard FileManager.default.fileExists(atPath: marker.path) else { continue }
                try? FileManager.default.removeItem(at: marker)
                _ = await CLIRunner.run(
                    "/usr/bin/osascript",
                    arguments: ["-e", RenewLoginCommand.terminalCloseScript(windowID: windowID)],
                    timeout: 30)
                return
            }
            // Out of time: the window stays, because it may still be signing in. The receipt goes,
            // since nothing reads it any more; one written after this point is left to the temp
            // directory's own housekeeping, which is where it lives precisely so that it can be.
            try? FileManager.default.removeItem(at: marker)
        }
    }
}
