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
        return fullPathNote(display((executable as NSString).deletingLastPathComponent,
                                    home: CLISearchPath.shared.home))
    }

    /// The note's own words, shared by the real answer above and the capture fixture below.
    private static func fullPathNote(_ directory: String) -> String {
        String(format: L("Uses the full path because your Terminal doesn't look in %@ yet."), directory)
    }

    /// `-TallyDemoData YES -TallyDemoCLIOffPath YES` (Debug builds only): Settings' fallback drawn as a
    /// Mac whose Terminal does not look in ~/.local/bin would see it, whatever this Mac's PATH and tally
    /// command line tool say, so the full-path form can be captured. Only the two machine facts are
    /// fixed (where the CLI is, and that Terminal cannot find it); the word and the note still come
    /// from the same rules the real answer uses. nil = no fixture, the real answer applies.
    static func demoOffPath(_ providerID: String) -> (word: String, note: String)? {
        #if DEBUG
        guard DemoUsage.isActive, UserDefaults.standard.bool(forKey: "TallyDemoCLIOffPath") else { return nil }
        let home = CLISearchPath.shared.home
        let directory = home + "/.local/bin"
        return (commandWord(cli: providerID, executable: directory + "/" + providerID,
                            terminalFinds: false, home: home),
                fullPathNote(display(directory, home: home)))
        #else
        return nil
        #endif
    }
}
