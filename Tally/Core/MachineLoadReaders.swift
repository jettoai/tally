import Darwin
import Foundation

/// WHAT THE ROLLUP READS OFF THE MACHINE: the four syscall-backed answers the pure rules next door
/// are handed (`MachineLoadRollup.swift`).
///
/// SPLIT ON SIZE, ALONG THE ONE SEAM THIS FILE HAS. Everything in the other half is a rule stated
/// about readings handed in, which is what lets the assertion harness state every case with no
/// process table around it; everything here TAKES a reading, so none of it can be asserted that way
/// and all of it needs `Darwin`. The two halves were one file until it reached the length at which
/// this repository splits one (2026-09-03).
extension MachineLoadRollup {

    /// THE CLAUDE CODE SCRATCHPAD A PROCESS WAS STARTED WITH, as the conversation id alone.
    ///
    /// THE SECOND WAY BACK TO A SESSION, and it reaches the case the group ledger cannot: a job
    /// whose own shell exits between two ticks was never once seen inside the tree, so no group of
    /// it was ever claimed (`SessionProcessGroups`). Claude Code hands every session a scratchpad at
    /// `/tmp/claude-<uid>/<project>/<conversation>/`, agents are told to put their working files
    /// there, and a command that touches one carries the path in its arguments - which is how the
    /// 2026-08-25 incident was attributed AFTER the fact, by hand. This is that reading made into a
    /// mechanism.
    ///
    /// ONLY THE CONVERSATION ID EVER LEAVES THIS FUNCTION, and that is the whole reason it is
    /// written as a scan rather than as a reader. A command line is a string that can carry a token
    /// (the rule the card's own culprit names are decided under, `ProcessFootprint.memoryLeader`),
    /// so nothing here returns, stores, logs or draws argv: it looks for one fixed path shape, takes
    /// the component that is a UUID, and drops the buffer. A process whose arguments do not contain
    /// that shape produces nothing at all.
    ///
    /// - Parameter arguments: the process's command line as one blob, as `KERN_PROCARGS2` hands it
    ///   over. A parameter rather than a syscall so this stays pure and testable.
    /// - Parameter uid: whose scratchpad to look for. The directory is named for the user, and
    ///   matching another user's would be matching a path this app can say nothing about.
    static func scratchpadConversation(in arguments: String, uid: uid_t) -> String? {
        let marker = "/claude-\(uid)/"
        var search = Substring(arguments)
        while let hit = search.range(of: marker) {
            let after = search[hit.upperBound...]
            // <project>/<conversation>/… - the project component is the escaped working directory
            // and says nothing this app needs, since the conversation names the session outright.
            let parts = after.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 2, isConversationID(parts[1]) { return String(parts[1]) }
            search = after
        }
        return nil
    }

    /// Whether a path component is a Claude Code conversation id: 8-4-4-4-12 hexadecimal.
    ///
    /// SPELLED OUT RATHER THAN PARSED WITH `UUID(uuidString:)`, which accepts forms this never
    /// produces and would let an arbitrary argument through as a session name.
    static func isConversationID(_ text: some StringProtocol) -> Bool {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5, groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    /// A process's whole command line as one blob, or nothing when the machine will not say.
    ///
    /// THE ONLY CALLER IS THE SCAN ABOVE, and the blob never goes anywhere else: it is read into a
    /// local buffer, scanned for one path shape, and dropped. `KERN_PROCARGS2` is readable for one's
    /// own processes without any additional entitlement, and answers nothing at all for another
    /// user's - which is the same "simply absent" this app's other readings degrade to.
    ///
    /// The layout is an argument count, the executable path, then NUL-separated strings; nothing
    /// here separates them, because a path is a path wherever in the blob it sits.
    static func commandLine(of pid: pid_t) -> String? {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // NULs become separators rather than terminators, so one decode covers every argument.
        return String(decoding: buffer.prefix(size).map { $0 == 0 ? UInt8(ascii: "\n") : $0 },
                      as: UTF8.self)
    }

    /// The path a process started in this directory would report as its own.
    ///
    /// `realpath(3)` rather than `URL.resolvingSymlinksInPath()`, which strips a leading `/private`
    /// and so returns a spelling no process ever reports - the same reason and the same spelling
    /// `WorktreeOrigins.resolvedPath` uses, one comparison over.
    static func resolvedPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The working directory of a process, or nothing when it cannot be read (the process has gone,
    /// or belongs to another user - `login` runs as root and answers nothing).
    ///
    /// The CLI's worktree teardown reads the same field the same way (`TallyCLI/
    /// WorktreeProcessScan.swift`); this is the app's copy rather than a shared file because the two
    /// targets share only what a DRIFTED second spelling would break, and a reading with no decision
    /// in it is not that (project.yml states the rule).
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
        }
        return (path?.isEmpty ?? true) ? nil : path
    }
}
