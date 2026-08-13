import AppKit
import Darwin

/// TAKING SOMEBODY TO THE SESSION THEY JUST CLICKED, which is the whole point of a status board: a
/// row that says a session is waiting and cannot be got to has moved the hunt rather than ended it.
///
/// THREE WAYS, in falling order of how precisely each can answer "which surface".
///
///   1. Ask Ghostty for the surface whose `tty` IS the device the session's own process is attached
///      to. A tty belongs to exactly one surface, so this cannot pick the wrong tab: it is the only
///      one of the three that survives the ordinary case of one repository open in several tabs,
///      splits, or windows at once.
///   2. Failing that, ask for the surface whose working directory IS that checkout, breaking ties
///      on the session's name. Right repository, arbitrary tab within it. This is what answers when
///      the session has no child process left to ask about, or is running in a terminal that is not
///      Ghostty at all and therefore appears in no surface's `tty`.
///   3. Failing that, walk the Claude Code process's ancestors until one of them is an application,
///      and activate it. This knows nothing about windows, so it lands the user in the right APP
///      rather than the right tab, and it works for every terminal there is.
///
/// EVERY FAILURE FALLS THROUGH RATHER THAN STOPPING. Driving another app is a permission macOS asks
/// the user for once, and a refusal is permanent and silent from here; a Ghostty too old to be
/// asked answers with an error; a session launched from a terminal that has since closed has no
/// ancestor left. None of those is worth a dialog, and all of them end in the same place: the user
/// is where they were, and the panel is still open.
enum TerminalJump {
    /// Ghostty's bundle id, which is also how "is it even running" is asked before an Apple event
    /// is sent: sending one to an app that is not running LAUNCHES it, and a status board must
    /// never open a terminal nobody asked for.
    private static let ghosttyBundleID = "com.mitchellh.ghostty"

    /// How long the AppleScript may take. Generous rather than tight for one reason: the FIRST call
    /// stops inside osascript while macOS asks whether Tally may control the terminal, and a
    /// watchdog firing mid-question would report a refusal that never happened (the same number,
    /// and the same reasoning, as `LoginTerminalFallback`).
    private static let scriptTimeout: TimeInterval = 120

    /// Focus the terminal this session is running in. `childPid` is the session's own process, whose
    /// controlling terminal names the surface exactly; `hint` is the session's own name (the
    /// repository, or the parallel line), used only to break a tie between several windows standing
    /// in one directory once that exact answer is unavailable.
    static func jump(directory: String?, hint: String?, childPid: Int?) async {
        let tty = childPid.flatMap { controllingTTY(of: pid_t($0)) }
        let directory = directory ?? ""
        // Nothing to match on at all (no live child, no recorded checkout) means nothing to ask, and
        // asking anyway would focus whichever surface happens to stand in "".
        if tty != nil || !directory.isEmpty, runningApplication(ghosttyBundleID) != nil,
           await focusGhostty(directory: directory, hint: hint ?? "", tty: tty) {
            return
        }
        if let childPid, activateOwningApplication(of: pid_t(childPid)) { return }
        // Nothing could be matched, so the last useful act is to put the terminal in front and let
        // the user find the tab: better than a click that visibly does nothing. Only for an app
        // that is ALREADY running, for the reason the bundle id above is checked at all.
        runningApplication(ghosttyBundleID)?.activate(options: [.activateAllWindows])
    }

    // MARK: Ghostty

    private static func runningApplication(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Ask Ghostty to focus the surface this session occupies. Returns whether one was found.
    private static func focusGhostty(directory: String, hint: String, tty: String?) async -> Bool {
        let result = await CLIRunner.run("/usr/bin/osascript",
                                         arguments: ["-e", script(directory: directory, hint: hint,
                                                                  tty: tty)],
                                         timeout: scriptTimeout)
        guard result?.exitCode == 0 else { return false }
        return result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
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
    static func script(directory: String, hint: String, tty: String?) -> String {
        var passes: [String] = []
        if let tty, !tty.isEmpty { passes.append(ttyPass(tty)) }
        if !directory.isEmpty { passes.append(directoryPass(directory: directory, hint: hint)) }
        return """
        tell application "Ghostty"
            set matched to missing value
        \(passes.joined(separator: "\n"))
            if matched is missing value then return ""
            try
                focus matched
            end try
            activate
            return "ok"
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

    /// The exact pass: one device, one surface, so the first hit ends the search outright.
    private static func ttyPass(_ tty: String) -> String {
        pass("""
                            if (tty of t) is equal to \(literal(tty)) then
                                set matched to t
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
                                if matched is missing value then set matched to t
                                if \(literal(hint)) is not "" and (name of t) contains \(literal(hint)) then
                                    set matched to t
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

    // MARK: The process table

    /// The device a process is attached to, in the form Ghostty reports it ("/dev/ttys001").
    ///
    /// ASKED OF THE KERNEL RATHER THAN OF `ps`, because this runs on a click in the panel and a
    /// spawn is both slower and one more thing that can fail; `proc_pidinfo` is the same call the
    /// ancestor walk below already makes.
    ///
    /// nil IS AN ORDINARY ANSWER, not an error: a session whose child has exited, a child owned by
    /// another user (the kernel refuses), and a process with no controlling terminal at all (a
    /// daemon, or anything under launchd) all land here, and all of them are exactly the cases the
    /// directory pass was written for.
    static func controllingTTY(of pid: pid_t) -> String? {
        guard let info = bsdInfo(pid), info.e_tdev != UInt32.max else { return nil }
        guard let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let text = String(cString: name)
        // Older devname reports an unknown device as "??" rather than by returning nothing.
        guard !text.isEmpty, text != "??" else { return nil }
        return text.hasPrefix("/") ? text : "/dev/" + text
    }

    /// A process's kernel record, or nil when the pid is gone or belongs to another user.
    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    // MARK: The universal fallback

    /// Walk up from the Claude Code process until an ancestor is an application, and bring it
    /// forward. Returns whether one was found.
    ///
    /// A TERMINAL EMULATOR IS AN APPLICATION AND A SHELL IS NOT, which is the whole rule and the
    /// reason this needs no list of terminal names: `claude` is a child of a shell, which is a
    /// child of the emulator, and `NSRunningApplication` answers for exactly the last of those.
    /// Bounded, because a cycle in the process table (or a pid reused underneath the walk) would
    /// otherwise be an infinite loop in the app's main actor; eight is the same ceiling the CLI's
    /// own ancestor walk uses.
    private static func activateOwningApplication(of pid: pid_t) -> Bool {
        var current = pid
        for _ in 0 ..< 8 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                return app.activate(options: [.activateAllWindows])
            }
            guard let parent = parentProcess(current), parent > 1, parent != current else {
                return false
            }
            current = parent
        }
        return false
    }

    /// A process's parent, straight from the kernel. nil when the pid is gone or belongs to another
    /// user, both of which end the walk.
    private static func parentProcess(_ pid: pid_t) -> pid_t? {
        bsdInfo(pid).map { pid_t($0.pbi_ppid) }
    }
}
