import Darwin
import Foundation

/// WHAT EACH PROJECT ON THIS MACHINE IS COSTING, sessions and everything else included.
///
/// A CARD ANSWERS FOR ONE SESSION AND NOTHING ANSWERS FOR THE MACHINE, which is the gap this
/// closes. The board's cards sum to what its sessions are doing; the machine can be doing a great
/// deal more in the same directories - a dev server nobody is supervising, an `xcodebuild` started
/// from a terminal, a fan-out whose session has since been closed - and a reader comparing the board
/// against Activity Monitor finds twelve cores unaccounted for and no line on the page that admits
/// it (Albert, 2026-08-25 and again 2026-09-01).
///
/// SO THE ROLLUP IS ABOUT DIRECTORIES, NOT ABOUT SESSIONS. A process is this project's when it is
/// WORKING in this project, which is a fact the machine states (`proc_pidvnodepathinfo`) rather than
/// one this app has to infer. The roots are the directories the live sessions are running in, which
/// is the honest limit of what this app has any business measuring: everything else on the machine -
/// a browser, a mail client, somebody's own editor - is not Tally's to account for, and a rollup
/// that tried would be a process monitor with a worse table than the one macOS ships.
///
/// THE UNATTRIBUTED ROW IS THE POINT, not a leftover. It is where the work that IS in one of these
/// directories and belongs to no live session goes, and stating it is the difference between a board
/// that is wrong and a board that says what it cannot see. Silence there is exactly the reading that
/// took a week to notice.
///
/// PURE, so the assertion harness can state every case with no processes around it: what is handed
/// in is a set of readings, and what comes back is the rows a view draws.
struct ProjectLoad: Equatable, Identifiable {
    /// The project's root directory, resolved. The identity, because two spellings of one path are
    /// one project and a name is not unique (`tally` and `tally-wt1` are two, `~/a/api` and
    /// `~/b/api` would collide on a name).
    var root: String
    /// What to call it: the root's last component, which is what the session cards are named after
    /// too (`SessionRosterStore.SessionRow.title`).
    var name: String
    /// The share of one core everything in this project is spending, or nil when no part of it has
    /// been read twice yet - the same rule every rate in this app lives by.
    var cpuPercent: Double?
    /// What everything in this project is holding, in bytes.
    var memoryBytes: UInt64
    /// How many live sessions are working here. ZERO IS THE INTERESTING READING: a project with
    /// load and no session is work nobody on this board is answering for.
    var sessions: Int
    /// How many processes here belong to no live session: the strays.
    var strayProcesses: Int
    var id: String { root }
}

/// The whole machine as this app can account for it: the projects its sessions are working in, and
/// what is left over inside them.
struct MachineLoad: Equatable {
    /// One row per project, in a STABLE order - by name, never by load.
    ///
    /// A LIST THAT RE-ORDERS ITSELF UNDER A READING EYE IS UNREADABLE, which this page has already
    /// been reported for once at the level of a single figure (`SessionCardFootprint.column`). A
    /// rollup sorted by cost would re-seat every row each time two projects crossed, which on a
    /// machine doing anything at all is every few seconds. The heaviest is MARKED instead, so the
    /// eye can find it without the rows moving (`heaviest`).
    var projects: [ProjectLoad] = []
    /// Which project is burning the most, when one is burning enough to be worth pointing at.
    var heaviest: String?
    /// Whether anything here is unaccounted for, which is what decides the section is worth drawing
    /// at all (`MachineLoadRollup.isWorthDrawing`).
    var strayProcesses: Int {
        projects.reduce(0) { $0 + $1.strayProcesses }
    }
}

enum MachineLoadRollup {
    /// How much of one core the busiest project has to be spending before it is marked. One whole
    /// core: below that, "the heaviest" is whichever project happens to have a language server
    /// indexing, and a mark that is always on somebody is a mark that says nothing.
    static let markedAbovePercent = 100.0

    /// One session's contribution to the rollup, as the board already holds it.
    struct SessionReading: Equatable {
        /// The directory this session is working in, resolved.
        var root: String
        var cpuPercent: Double?
        var memoryBytes: UInt64
    }

    /// And one project's leftovers: what is working in that directory and belongs to no session.
    struct StrayReading: Equatable {
        var root: String
        var cpuPercent: Double?
        var memoryBytes: UInt64
        var processes: Int
    }

    /// WHICH PROJECT A WORKING DIRECTORY BELONGS TO: the longest root that CONTAINS it, or none.
    ///
    /// LONGEST WINS, because a worktree lives inside its repository often enough to matter
    /// (`~/workspace/tally` and `~/workspace/tally/.worktrees/feat`): the nearer root is the one
    /// somebody would name, and the outer one would swallow every parallel line into the trunk.
    ///
    /// AND THE MATCH IS ON PATH COMPONENTS, never on characters. `~/workspace/tally-wt1` starts with
    /// `~/workspace/tally` and is a different project; a prefix test alone puts one project's dev
    /// server on another project's row, which is the one error here that produces a confident wrong
    /// number rather than a missing one. The root itself counts as inside itself.
    static func project(of directory: String, roots: some Sequence<String>) -> String? {
        var best: String?
        for root in roots where directory == root || directory.hasPrefix(root + "/") {
            if best == nil || root.count > best!.count { best = root }
        }
        return best
    }

    /// WHAT IS STILL UNATTRIBUTED ONCE EVERY CARD'S FULL MEMBERSHIP IS KNOWN.
    ///
    /// AN ADOPTED JOB'S OWN CHILDREN ARE THE WHOLE REASON THIS EXISTS. The strays have to be picked
    /// out BEFORE the cards are walked, because picking them out is what says which processes no tree
    /// reached; the walk is then seeded with the adopted jobs, and everything descended from one of
    /// them comes back onto a card with it (`ProcessTree.members(root:processes:adopting:)`). A child
    /// that started a process group of its own is in neither set the first pass had: no tree reached
    /// it, and no ledger claim names its group. Left in, one process is drawn twice on one page -
    /// inside a card's figures and again as work nobody is answering for - and the row that exists to
    /// say what the board cannot see says it about work the board can.
    ///
    /// - Parameter counted: every pid the cards will actually draw, the adoptions and their
    ///   descendants included.
    static func leftovers(strays: [pid_t: String], counted: Set<pid_t>) -> [pid_t: String] {
        strays.filter { !counted.contains($0.key) }
    }

    /// The rows a view draws, out of what the sessions read and what was left over.
    ///
    /// A PROJECT IS LISTED WHEN EITHER SIDE HAS SOMETHING TO SAY, so a directory whose session has
    /// just ended still appears for as long as its strays are running - which is the whole state
    /// this rollup exists to make visible.
    ///
    /// THE RATES ADD AND THE ABSENCES DO NOT. A percentage that has not been established yet is nil
    /// rather than zero everywhere else in this app, and summing a nil as zero here would state a
    /// reading nobody took; a project where nothing has been read twice keeps nil, and one where
    /// something has states what that something says.
    static func rows(sessions: [SessionReading], strays: [StrayReading]) -> MachineLoad {
        var byRoot: [String: ProjectLoad] = [:]
        func row(_ root: String) -> ProjectLoad {
            byRoot[root] ?? ProjectLoad(root: root,
                                        name: URL(fileURLWithPath: root).lastPathComponent,
                                        cpuPercent: nil, memoryBytes: 0, sessions: 0,
                                        strayProcesses: 0)
        }
        func add(_ percent: Double?, to total: Double?) -> Double? {
            guard let percent else { return total }
            return (total ?? 0) + percent
        }
        for reading in sessions {
            var held = row(reading.root)
            held.cpuPercent = add(reading.cpuPercent, to: held.cpuPercent)
            held.memoryBytes += reading.memoryBytes
            held.sessions += 1
            byRoot[reading.root] = held
        }
        for stray in strays where stray.processes > 0 {
            var held = row(stray.root)
            held.cpuPercent = add(stray.cpuPercent, to: held.cpuPercent)
            held.memoryBytes += stray.memoryBytes
            held.strayProcesses += stray.processes
            byRoot[stray.root] = held
        }
        let projects = byRoot.values.sorted { ($0.name, $0.root) < ($1.name, $1.root) }
        // TIES ARE BROKEN ON THE ROOT, for the reason the mark exists at all: two projects sitting on
        // the same figure would otherwise swap the mark between them from tick to tick, which is the
        // very flicker the stable row order above was written to stop. The smaller root wins, the
        // same way the card board settles which tree is holding the most memory
        // (`ProcessFootprintStore.sample`).
        let top = projects.max {
            ($0.cpuPercent ?? 0) == ($1.cpuPercent ?? 0)
                ? $0.root > $1.root : ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0)
        }
        return MachineLoad(projects: projects,
                           heaviest: (top?.cpuPercent ?? 0) >= markedAbovePercent ? top?.root : nil)
    }

    /// WHETHER THIS SECTION IS WORTH THE ROOM AT ALL, which is a question the cards below it already
    /// answer most of the time.
    ///
    /// ONE SESSION PER PROJECT AND NOTHING LEFT OVER IS A ROLLUP OF ITS OWN CARDS, and printing it
    /// would spend the top of the page restating the page. The two states where it says something no
    /// card can are the two this returns true for: work in a project that no session accounts for,
    /// and a project running more than one session, where the question "what is this repository
    /// costing me" has no single card to read it off.
    static func isWorthDrawing(_ load: MachineLoad) -> Bool {
        load.strayProcesses > 0 || load.projects.contains { $0.sessions > 1 }
    }

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
