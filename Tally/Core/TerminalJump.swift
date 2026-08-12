import AppKit
import Darwin

/// TAKING SOMEBODY TO THE SESSION THEY JUST CLICKED, which is the whole point of a status board: a
/// row that says a session is waiting and cannot be got to has moved the hunt rather than ended it.
///
/// TWO WAYS, and the second is what makes the first optional.
///
///   1. Ask the terminal emulator to focus the window whose working directory IS that checkout.
///      Ghostty is the one that can be asked in v1 (its scripting dictionary exposes `terminals`
///      with a `working directory`, and `focus`), and asking is precise: a repository with four
///      parallel lines open has four windows, and only this tells them apart.
///   2. Failing that, walk the Claude Code process's ancestors until one of them is an application,
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

    /// Focus the terminal this session is running in. `hint` is the session's own name (the
    /// repository, or the parallel line), used to break a tie between several windows standing in
    /// one directory - the ordinary case for a repository somebody has two shells open in.
    static func jump(directory: String?, hint: String?, childPid: Int?) async {
        if let directory, !directory.isEmpty, runningApplication(ghosttyBundleID) != nil,
           await focusGhostty(directory: directory, hint: hint ?? "") {
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

    /// Ask Ghostty to focus the terminal standing in `directory`. Returns whether one was found.
    private static func focusGhostty(directory: String, hint: String) async -> Bool {
        let result = await CLIRunner.run("/usr/bin/osascript",
                                         arguments: ["-e", script(directory: directory, hint: hint)],
                                         timeout: scriptTimeout)
        guard result?.exitCode == 0 else { return false }
        return result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    /// The script, built rather than templated because both values come from a file on disk.
    ///
    /// EVERY LOOKUP IS WRAPPED, because this is written against a scripting dictionary that is not
    /// this app's: a Ghostty without `terminals`, or without `working directory` on one, raises
    /// rather than returning nothing, and an unhandled raise is an osascript that exits non-zero
    /// with the user staring at a row that did nothing. Wrapped, the same version simply reports no
    /// match and the ancestor walk takes over.
    ///
    /// THE HINT ONLY BREAKS TIES. The directory is the match; the name is consulted to choose
    /// AMONG windows that already matched it, and the first match is kept as the answer for when
    /// none of them carries the name. A tie broken arbitrarily is still the right repository.
    static func script(directory: String, hint: String) -> String {
        """
        tell application "Ghostty"
            set matched to missing value
            try
                repeat with t in terminals
                    try
                        if (working directory of t) is equal to \(literal(directory)) then
                            if matched is missing value then set matched to t
                            if \(literal(hint)) is not "" and (name of t) contains \(literal(hint)) then
                                set matched to t
                                exit repeat
                            end if
                        end if
                    end try
                end repeat
            end try
            if matched is missing value then return ""
            try
                focus matched
            end try
            activate
            return "ok"
        end tell
        """
    }

    /// An AppleScript string literal. Both interpolated values are read off disk (a checkout path,
    /// a repository name), so neither is trusted to be free of the two characters that would end
    /// the literal early and turn the rest into script.
    static func literal(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
