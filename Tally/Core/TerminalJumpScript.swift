import AppKit

/// THE HALF OF THE JUMP THAT IS A CONVERSATION WITH ANOTHER APP: the AppleScript sent to Ghostty,
/// the version gate that decides which passes may be built at all, and the marker that comes back
/// saying which pass answered. Split out of `TerminalJump.swift` because the two halves fail for
/// unrelated reasons and are read for unrelated reasons - this one is pure text against a
/// dictionary that is not this app's, and can be asserted without a desktop; the other is a fact
/// about a real foreground on a real screen and cannot.
extension TerminalJump {
    /// How long the AppleScript may take. Generous rather than tight for one reason: the FIRST call
    /// stops inside osascript while macOS asks whether Tally may control the terminal, and a
    /// watchdog firing mid-question would report a refusal that never happened (the same number,
    /// and the same reasoning, as `LoginTerminalFallback`).
    private static let scriptTimeout: TimeInterval = 120

    /// WHICH PASS ANSWERED, which is the difference between "this is the surface" and "this is the
    /// repository, pick a tab". Carried out of the script rather than reduced to a bool on the way,
    /// because one of the two has never once answered on a shipped Ghostty (`readsSurfaceTTY`) and
    /// a bool is unable to say so: a jump reporting success while its precise pass is dead code
    /// looks exactly like a jump that worked.
    enum SurfaceMatch: String, Sendable {
        case tty
        case directory = "dir"
    }

    /// Ask Ghostty to focus the surface this session occupies. Returns which pass found it, or nil
    /// when none did - and nil is also what a REFUSED focus reports, because to everything upstream
    /// those are one answer: no surface was focused, so the exits below this one are still owed.
    static func focusGhostty(directory: String, hint: String, tty: String?) async -> SurfaceMatch? {
        let result = await CLIRunner.run("/usr/bin/osascript",
                                         arguments: ["-e", script(directory: directory, hint: hint,
                                                                  tty: tty)],
                                         timeout: scriptTimeout)
        guard result?.exitCode == 0, let stdout = result?.stdout else { return nil }
        return SurfaceMatch(rawValue: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The first Ghostty whose scripting dictionary answers `tty` on a surface
    /// (ghostty-org/ghostty#11592, added by #11922 for the 1.4.0 milestone). EVERY RELEASE BEFORE
    /// IT CARRIES THREE PROPERTIES on a terminal - id, name, working directory - so a pass written
    /// on the device raises on every surface, is swallowed by the wraps, and matches nothing: the
    /// jump has been a directory match all along, on precisely the machines whose several tabs on
    /// one repository the device pass was written for.
    private static let ttyDictionaryVersion = [1, 4, 0]

    /// Whether THIS Ghostty can be asked for a surface's device.
    ///
    /// READ OFF THE BUNDLE THAT IS RUNNING rather than asked over an Apple event: `version` in the
    /// scripting dictionary is this same string, and asking for it would be a second round trip -
    /// and a second thing that can stop inside the permission question - before the first one can
    /// be built at all.
    @MainActor
    static func readsSurfaceTTY(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return false }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        return readsSurfaceTTY(version: version)
    }

    /// COMPONENT BY COMPONENT rather than as text, or 1.10 would read as older than 1.4; missing
    /// components count as zero, so "2" is newer than 1.4.0 and "1.4" IS 1.4.0.
    ///
    /// A VERSION THAT CANNOT BE READ IS AN OLD ONE, which is the safe direction of a wrong guess:
    /// the device pass is the precision and the directory pass is the floor, so treating a new
    /// Ghostty as old costs a tie-break on a machine that would still be taken to its repository,
    /// while the reverse spends a scan on a lookup that raises on every surface.
    static func readsSurfaceTTY(version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !parts.isEmpty else { return false }
        for (index, floor) in ttyDictionaryVersion.enumerated() {
            let component = index < parts.count ? parts[index] : 0
            if component != floor { return component > floor }
        }
        return true
    }

    /// The script, built rather than templated because every value comes from a file on disk or
    /// from the process table.
    ///
    /// EVERY LOOKUP IS WRAPPED, because this is written against a scripting dictionary that is not
    /// this app's: a Ghostty without `terminals`, or without `working directory` or `tty` on one,
    /// raises rather than returning nothing, and an unhandled raise is an osascript that exits
    /// non-zero with the user staring at a row that did nothing. Wrapped, the same version simply
    /// reports no match and the pass below it (or the ancestor walk) takes over.
    ///
    /// THE PASSES ARE ORDERED AND EACH ONE STANDS DOWN FOR AN EARLIER ANSWER, which is the whole
    /// reason the tty pass exists: a match on the device is the surface, and a match on the
    /// directory is only the repository, so the second must never be allowed to overwrite the
    /// first. Every pass is guarded by `if matched is missing value`, so the order of the passes IS
    /// the precedence and nothing downstream can quietly invert it.
    ///
    /// IT SAYS WHICH PASS ANSWERED, and it says nothing at all when none did. The word it used to
    /// return meant "a surface was found" while every reader took it for "the terminal has the
    /// keyboard now", and it was returned even when `focus` had raised inside its own wrap - three
    /// different outcomes wearing one word, one of which then SKIPPED the ancestor walk that was
    /// the fallback for it. A refused focus now leaves by the same door as no match at all.
    static func script(directory: String, hint: String, tty: String?) -> String {
        var passes: [String] = []
        if let tty, !tty.isEmpty { passes.append(ttyPass(tty)) }
        if !directory.isEmpty { passes.append(directoryPass(directory: directory, hint: hint)) }
        return """
        tell application "Ghostty"
            set matched to missing value
            set hit to ""
        \(passes.joined(separator: "\n"))
            if matched is missing value then return ""
            try
                focus matched
            on error
                return ""
            end try
            activate
            return hit
        end tell
        """
    }

    /// One scan over Ghostty's surfaces, running `test` against each and standing down entirely
    /// for an answer an earlier pass already found.
    ///
    /// THE GUARD AND THE TWO WRAPS LIVE HERE AND NOWHERE ELSE, so a pass added later cannot be the
    /// one that forgets either: not the guard (and so overwrites a precise match with a vaguer
    /// one), nor the wrap (and so lets an older dictionary's raise out of the script).
    private static func pass(_ test: String) -> String {
        """
            if matched is missing value then
                try
                    repeat with t in terminals
                        try
        \(test)
                        end try
                    end repeat
                end try
            end if
        """
    }

    /// The exact pass: one device, one surface, so the first hit ends the search outright. Built
    /// only for a Ghostty that has the property at all (`readsSurfaceTTY`), which is what makes its
    /// marker below worth reading: `pass=dir` on a machine whose session HAS a live child is the
    /// old dictionary saying so, out loud, instead of a raise being swallowed.
    private static func ttyPass(_ tty: String) -> String {
        pass("""
                            if (tty of t) is equal to \(literal(tty)) then
                                set matched to t
                                set hit to "tty"
                                exit repeat
                            end if
        """)
    }

    /// The approximate pass, kept for the session whose child is gone or is not in Ghostty at all.
    ///
    /// THE HINT ONLY BREAKS TIES. The directory is the match; the name is consulted to choose
    /// AMONG windows that already matched it, and the first match is kept as the answer for when
    /// none of them carries the name. A tie broken arbitrarily is still the right repository.
    private static func directoryPass(directory: String, hint: String) -> String {
        pass("""
                            if (working directory of t) is equal to \(literal(directory)) then
                                if matched is missing value then
                                    set matched to t
                                    set hit to "dir"
                                end if
                                if \(literal(hint)) is not "" and (name of t) contains \(literal(hint)) then
                                    set matched to t
                                    set hit to "dir"
                                    exit repeat
                                end if
                            end if
        """)
    }

    /// An AppleScript string literal. Both interpolated values are read off disk (a checkout path,
    /// a repository name), so neither is trusted to be free of the two characters that would end
    /// the literal early and turn the rest into script.
    static func literal(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
