import AppKit
import Darwin

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

    /// How long a title written to the device is given to reach the scripting dictionary before it
    /// is looked for. Measured rather than guessed: a mark written to a live session's device was
    /// answering as that surface's `name` within 0.4s (2026-08-15, Ghostty 1.3.1). Short enough to
    /// sit inside a click, long enough that the answer is the terminal's rather than the race's.
    private static let titleGrace: Duration = .milliseconds(400)

    /// WHICH PASS ANSWERED, which is the difference between "this is the surface" and "this is the
    /// repository, pick a tab". Carried out of the script rather than reduced to a bool on the way,
    /// because one of the three has never once answered on a shipped Ghostty (`readsSurfaceTTY`)
    /// and a bool is unable to say so: a jump reporting success while its precise pass is dead code
    /// looks exactly like a jump that worked.
    enum SurfaceMatch: String, Sendable {
        case tty
        case nonce
        case directory = "dir"
    }

    /// Ask Ghostty to focus the surface this session occupies. Returns which pass found it, or nil
    /// when none did - and nil is also what a REFUSED focus reports, because to everything upstream
    /// those are one answer: no surface was focused, so the exits below this one are still owed.
    ///
    /// THE MARK IS HOW A SURFACE IS ASKED ITS OWN IDENTITY on a Ghostty that publishes no device.
    /// A title written to the session's device comes back as that surface's `name` a moment later
    /// (`titleGrace`), so a name nobody else can be carrying names exactly one surface - which is
    /// the answer `tty` will give directly from 1.4.0 and gives nowhere today. The device is the
    /// session's own (`controllingTTY`), so this asks the session where it is rather than guessing
    /// from the checkout it stands in.
    ///
    /// NOTHING IS WRITTEN THAT CANNOT BE PUT BACK. The scan that precedes the write is what the
    /// title is restored from, so a scan that answered nothing stands the whole pass down rather
    /// than leaving somebody's tab called `tally-jump-…`.
    ///
    /// AND NOT EVERY JUMP WRITES AT ALL (`shouldMark`): a dictionary that publishes the device is
    /// asked rather than written to, and a device with a mark already in flight is left to the jump
    /// that put it there.
    @MainActor
    static func focusGhostty(directory: String, hint: String, tty: String?,
                             device: String?) async -> SurfaceMatch? {
        var titles: [String: String] = [:]
        var mark: String?
        // The device this jump may rename a surface through, or nil for each of the three reasons
        // not to (`shouldMark`). Claimed for as long as the mark is out there, and released on
        // every way out of here - including the one that never got an answer out of osascript,
        // since a claim left behind would stand every later jump to this device down for good.
        let inFlight = device.map(markingDevices.contains) ?? false
        let marking = shouldMark(device: device, tty: tty, inFlight: inFlight) ? device : nil
        defer { if let marking { markingDevices.remove(marking) } }
        if let marking {
            markingDevices.insert(marking)
            titles = restorableTitles(await osascript(surfaceScanScript()) ?? "")
            let candidate = nonce()
            if !titles.isEmpty, write(title: candidate, to: marking) {
                mark = candidate
                try? await Task.sleep(for: titleGrace)
            }
        }
        guard let stdout = await osascript(script(directory: directory, hint: hint, tty: tty,
                                                  nonce: mark)) else { return nil }
        let answer = parseFocus(stdout)
        // The mark is taken off the surface it named, and only off that one: the title it replaced
        // is the one this app read a moment ago, so a session that has rewritten its own title in
        // between gets one stale title back and rewrites it on its next turn anyway. A pass that
        // did NOT answer leaves no mark to remove - either the write never landed, or it landed on
        // a terminal this app cannot see, and in neither case is there a title here to restore.
        if answer.match == .nonce, let marking, let id = answer.surface, let title = titles[id] {
            write(title: title, to: marking)
        }
        return answer.match
    }

    /// WHETHER THIS JUMP MAY RENAME A TAB TO FIND ITS SURFACE. A value rather than a condition
    /// buried in the flow above, because none of the three refusals can be reached from a test that
    /// has no Ghostty to talk to, and each of them leaves a tab renamed for good when it is missed.
    ///
    ///   - NO DEVICE: nothing to write to, and nothing this app has read a title off to put back.
    ///   - THE DICTIONARY ALREADY ANSWERS `tty` (1.4.0 and later): that pass is built, stands above
    ///     the marked one and wins the script outright - and only the MARKED answer carries the
    ///     surface the title is put back on, so a mark written beside a device pass is a mark
    ///     nothing ever names and nothing ever removes. Every click would then leave one more
    ///     `tally-jump-…` on a tab that accepts the escape.
    ///   - A MARK IS ALREADY IN FLIGHT ON THIS DEVICE (`markingDevices`).
    ///
    /// All three fall to the passes that READ rather than write, which is where this jump was
    /// heading anyway: the device pass for the first case, the checkout for the other two.
    static func shouldMark(device: String?, tty: String?, inFlight: Bool) -> Bool {
        device != nil && tty == nil && !inFlight
    }

    /// The devices a marked pass is out on right now, so two jumps to one surface cannot cross.
    ///
    /// NOT A QUEUE, DELIBERATELY. Two clicks on one card inside the grace are one intention - the
    /// same session, the same surface - so the second does not wait for the first: it stands its own
    /// mark down and takes the checkout pass, which lands in the right repository while the first
    /// click is already on its way to the exact tab. Queued instead, the second would rename the tab
    /// again after the first had put the title back, for a destination already reached.
    ///
    /// WHAT CROSSING WOULD COST, in the order it happens: the second scan reads the first mark as
    /// the tab's own title and writes a second mark over it; the first jump then finds its mark gone
    /// and falls to the checkout pass, restoring nothing; the second finishes and puts back what it
    /// took for the title - which is the first mark, or nothing at all now that a mark is never a
    /// restorable title (`restorableTitles`). Either way the tab keeps a `tally-jump-…` name that
    /// nobody is left holding the real one for.
    @MainActor
    private static var markingDevices: Set<String> = []

    /// Run one script and hand back its stdout, or nil for a Ghostty that raised, refused or was
    /// never asked. ONE PLACE THE TIMEOUT AND THE EXIT CODE ARE READ, because this is now asked
    /// twice per jump and a second copy of the rule is the copy that forgets to check the code.
    private static func osascript(_ source: String) async -> String? {
        let result = await CLIRunner.run("/usr/bin/osascript", arguments: ["-e", source],
                                         timeout: scriptTimeout)
        guard result?.exitCode == 0 else { return nil }
        return result?.stdout
    }

    /// WHAT A MARK LOOKS LIKE, in one place because two readers depend on it: the name a jump
    /// writes, and the scan that has to recognise one it did not write (`restorableTitles`). Spelled
    /// twice, a mark this app failed to recognise would be handed back to a tab as though it were
    /// somebody's own title.
    static let markPrefix = "tally-jump-"

    /// A name no surface can already be carrying. Random rather than derived from the session,
    /// because two jumps a second apart must not be able to mark the same title and read each
    /// other's answer; the prefix is there for the one person who sees it on a tab during the
    /// grace and wants to know what wrote it.
    static func nonce() -> String {
        markPrefix + UUID().uuidString.prefix(8).lowercased()
    }

    /// The scan read as a restore table: every surface's title EXCEPT the ones already carrying a
    /// mark.
    ///
    /// A MARK IS NOBODY'S TITLE. A name beginning `tally-jump-` was written by this app moments ago
    /// and is owed back to whoever wrote it; restoring one would make another jump's borrowed name
    /// the tab's permanent one. Dropped rather than kept, which costs nothing that is not already
    /// lost: the surface's real title lives in the scan of the jump that marked it, and that jump
    /// puts it back itself.
    ///
    /// A SCAN THAT IS ALL MARKS THEREFORE ANSWERS NOTHING, and the caller stands its own mark down
    /// on an empty table rather than writing a name it could not undo - the same refusal a Ghostty
    /// that answered nothing already gets.
    static func restorableTitles(_ stdout: String) -> [String: String] {
        parseSurfaces(stdout).filter { !$0.value.hasPrefix(markPrefix) }
    }

    /// Every surface's identity and title, read BEFORE anything is written, which makes it two
    /// things at once: the record the mark is restored from, and the proof that this Ghostty
    /// answers `id` and `name` at all. Wrapped like every other lookup against a dictionary that
    /// is not this app's.
    ///
    /// THE SEPARATOR IS SPELLED OUT rather than written `tab`, because inside `tell application
    /// "Ghostty"` that word is the terminal's own term for a tab and comes back as the LETTERS
    /// "tab": every line would then carry no separator at all, every surface would be dropped as
    /// unreadable, and the pass built on this scan would stand itself down forever while looking
    /// exactly like a Ghostty that had nothing to report (measured 2026-08-15, Ghostty 1.3.1).
    static func surfaceScanScript() -> String {
        """
        tell application "Ghostty"
            set out to ""
            try
                repeat with t in terminals
                    try
                        set out to out & ((id of t) as text) & (character id 9) & (name of t) & linefeed
                    end try
                end repeat
            end try
            return out
        end tell
        """
    }

    /// The scan's answer as identity to title. A line that carries no tab is not a surface and is
    /// dropped rather than guessed at; an empty title is kept, because a surface really can have
    /// one and restoring it is still restoring it.
    static func parseSurfaces(_ stdout: String) -> [String: String] {
        var titles: [String: String] = [:]
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let id = String(line[..<tab])
            guard !id.isEmpty else { continue }
            titles[id] = String(line[line.index(after: tab)...])
        }
        return titles
    }

    /// What the script said: which pass answered, and which surface the marked pass found. TWO
    /// VALUES BECAUSE THE SECOND IS OWED BACK - a mark that is placed and not taken off is a tab
    /// left renamed, so the surface's identity has to travel out of the script with the marker.
    static func parseFocus(_ stdout: String) -> (match: SurfaceMatch?, surface: String?) {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let marker = String(lines.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = lines.count > 1
            ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (SurfaceMatch(rawValue: marker), surface.isEmpty ? nil : surface)
    }

    /// The escape a terminal reads as "this tab is now called X" (OSC 2, ended by BEL).
    ///
    /// THE TITLE CANNOT END THE SEQUENCE EARLY, for the same reason `literal` exists: a title is
    /// read back off another app, and a BEL or an ESC inside one would close this escape and hand
    /// the rest to the terminal as a command of its own. Control characters are dropped rather
    /// than escaped, because a tab title has no use for one.
    static func titleEscape(_ title: String) -> String {
        var safe = title.unicodeScalars
        safe.removeAll { CharacterSet.controlCharacters.contains($0) }
        return "\u{1B}]2;" + String(safe) + "\u{07}"
    }

    /// Write a title to a device, answering whether it went. FAILURE IS ORDINARY: the device may
    /// belong to another user, may have gone with the session that owned it, or may be a terminal
    /// that ignores the escape entirely, and every one of those simply means the pass below this
    /// one answers instead.
    ///
    /// OPENED WITHOUT TAKING IT ON. `O_NOCTTY` keeps a device this app merely writes to from
    /// becoming this app's controlling terminal, and `O_NONBLOCK` keeps a terminal that has
    /// stopped reading from stalling a click; a write that would block is abandoned rather than
    /// retried, because the mark is an optimisation and the directory pass is still there.
    @discardableResult
    static func write(title: String, to device: String) -> Bool {
        let descriptor = device.withCString { open($0, O_WRONLY | O_NONBLOCK | O_NOCTTY) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bytes = Array(titleEscape(title).utf8)
        var written = 0
        while written < bytes.count {
            let sent = bytes[written...].withUnsafeBufferPointer {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            guard sent > 0 else { return false }
            written += sent
        }
        return true
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
    ///
    /// IT ALSO SAYS WHICH SURFACE, on the line below, and only the marked pass fills it in: that
    /// pass renamed a tab to find it, and the name has to be put back (`focusGhostty`).
    static func script(directory: String, hint: String, tty: String?, nonce: String?) -> String {
        var passes: [String] = []
        if let tty, !tty.isEmpty { passes.append(ttyPass(tty)) }
        if let nonce, !nonce.isEmpty { passes.append(noncePass(nonce)) }
        if !directory.isEmpty { passes.append(directoryPass(directory: directory, hint: hint)) }
        return """
        tell application "Ghostty"
            set matched to missing value
            set hit to ""
            set found to ""
        \(passes.joined(separator: "\n"))
            if matched is missing value then return ""
            try
                focus matched
            on error
                return ""
            end try
            activate
            return hit & linefeed & found
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

    /// The marked pass: the surface carrying the name this app just wrote to the session's own
    /// device IS the session's surface, so the first hit ends the search like the device pass does.
    /// It answers with the surface's identity as well as its marker, because the name it matched on
    /// is one this app put there and owes back.
    ///
    /// BELOW THE DEVICE AND ABOVE THE CHECKOUT, which is exactly its precision: it names one
    /// surface rather than one repository, but it gets there by writing to the terminal instead of
    /// reading a property, so a Ghostty that can simply be asked (1.4.0) is asked.
    private static func noncePass(_ nonce: String) -> String {
        pass("""
                            if (name of t) is equal to \(literal(nonce)) then
                                set matched to t
                                set hit to "nonce"
                                try
                                    set found to ((id of t) as text)
                                end try
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
