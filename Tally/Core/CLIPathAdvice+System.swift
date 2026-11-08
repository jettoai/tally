import Foundation

/// The parts of CLIPathAdvice that ask this Mac: the CLI Tally resolved, and the login PATH read so
/// far. Kept apart so the Foundation-only core compiles in the small test suites.
extension CLIPathAdvice {
    /// Whether the user's Terminal finds `cli`. Never waits for the login shell: with nothing read
    /// yet the answer is nil, and callers treat that as "cannot tell".
    static func terminalFinds(_ cli: String, executable: String) -> Bool? {
        terminalFinds(cli: cli, executable: executable,
                      loginPATH: CLISearchPath.shared.loginPATH(waitIfCold: false),
                      isRunnable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// The word to type for `providerID`'s CLI in a command the user copies.
    static func cliWord(_ providerID: String) -> String {
        let executable = ProviderCLI.resolved(providerID, devOverrideKey: "TallyRenewLoginCLI")
        return commandWord(cli: providerID, executable: executable,
                           terminalFinds: executable.flatMap { terminalFinds(providerID, executable: $0) },
                           home: CLISearchPath.shared.home)
    }

    /// The line under Settings' fallback command when it spells out the full path.
    static func fallbackNote(_ providerID: String, tallyInstalled: Bool) -> String? {
        guard !tallyInstalled,
              let executable = ProviderCLI.resolved(providerID, devOverrideKey: "TallyRenewLoginCLI"),
              terminalFinds(providerID, executable: executable) == false else { return nil }
        let directory = display((executable as NSString).deletingLastPathComponent,
                                home: CLISearchPath.shared.home)
        return String(format: L("Uses the full path because your Terminal doesn't look in %@ yet."), directory)
    }
}
