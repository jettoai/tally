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
    /// THE STRAYS' OWN SHARE OF THE TWO FIGURES ABOVE, which is what the card ABOUT the leftovers
    /// draws (`SessionGhostCardView`): a total includes the live sessions' own cores, and drawing
    /// one under "nobody is answering for this" states them twice, beside the cards they are on.
    var strayCpuPercent: Double?
    /// And what the strays alone are holding, in bytes.
    var strayMemoryBytes: UInt64 = 0
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
        /// Whether another session on this project is already counting every process this one is
        /// (`nested`). Such a session is still a session working here and its figures are still its
        /// card's; what it is not is a second helping of the same processes.
        var nested: Bool = false
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

    /// EVERY PROCESS A LIVE SESSION IS RUNNING INSIDE, which is the one thing a stray can never be.
    ///
    /// THE SHELL A SUPERVISOR WAS STARTED FROM IS NOT UNATTRIBUTED WORK, and every other test in the
    /// pool says it is: an interactive `-/bin/zsh` whose working directory IS the checkout, in
    /// nobody's tree because the supervisor is its CHILD rather than its parent. Measured on this
    /// machine (2026-09-03): every project on the board read exactly one stray, and in every case it
    /// was that shell - one amber count per project, permanently, for the terminal tab the session is
    /// being read in.
    ///
    /// THE WHOLE CHAIN GOES, not only the parent. A session started from a shell inside `tmux`, or
    /// from a window a script opened, has two or three processes above it, and each is as much the
    /// host of that session as the first one; a rule that stopped at the parent would leave the rest
    /// on the row. The walk itself is the reclaim's (`OrphanReclaim.ancestry`), which is already
    /// bounded by a visited set - a parent map taken from one moment of a moving table is not
    /// guaranteed to be a tree - and stops below pid 1, which is in no checkout anyway.
    ///
    /// - Parameters:
    ///   - supervisors: the live sessions' own pids, as the board keys its rows.
    ///   - parents: who each process's parent is, out of the table walk the tick has already made.
    static func hosts(of supervisors: some Sequence<pid_t>, parents: [pid_t: pid_t]) -> Set<pid_t> {
        supervisors.reduce(into: Set<pid_t>()) {
            $0.formUnion(OrphanReclaim.ancestry(of: $1, parents: parents))
        }
    }

    /// WHICH SESSIONS' FIGURES A PROJECT MUST NOT ADD UP, because another card on the same project
    /// is already counting every process they name.
    ///
    /// A SESSION STARTED INSIDE ANOTHER ONE IS INSIDE ITS PARENT'S TREE. `tally claude` run from a
    /// supervised terminal puts the inner supervisor under the outer one, so the outer card's
    /// members already contain the whole of the inner card's. For a CARD that is a question about
    /// what a session is and both readings are defensible, which is where `ProcessTreeCensus` leaves
    /// it. FOR A PROJECT IT IS NOT: "what is this repository costing me" has one answer, and adding
    /// the two cards states it at twice its size - on exactly the board this section is drawn for,
    /// since a project running several sessions is one of the two states `isWorthDrawing` returns
    /// true for.
    ///
    /// ANY SHARED PID, NOT ONLY A CONTAINED TREE. This test was written as a strict subset, on the
    /// stated ground that two cards share a process only where one tree contains the other. That
    /// sentence is false, and it was false in the ordinary case rather than an exotic one: the
    /// moment the inner session adopts a job of its own (`SessionProcessGroups`, which is the whole
    /// reason the ledger exists), the inner card holds the adopted orphan and the outer card does
    /// not, so the two sets OVERLAP and neither contains the other. The subset test then found no
    /// nesting at all and the project added both cards, counting the inner tree twice - and the
    /// contest rule one file over hands the adoption to the inner session every time, so this was
    /// the main path rather than a corner of it (codex review of 904e540).
    ///
    /// THE LARGER CARD IS THE ONE KEPT, EXCEPT WHERE THERE IS NO LARGER ONE. Two cards holding the
    /// same NUMBER of pids are separated by the sort's second key, which is the map key spelled as a
    /// string, and a string orders pids by their digits: `"9"` sorts above `"10"`. So on an
    /// equal-sized overlap the card a project keeps is decided by how many digits the supervisors'
    /// pids happen to have, which is arbitrary. It is written down rather than repaired because the
    /// property this rule owes anybody is DECIDABILITY - an answer that changed from tick to tick
    /// would move cores between two cards every two seconds - and a key that cannot change while
    /// nothing else does delivers it. The other tie-breaks on this page have meaning behind them
    /// (`rows` orders on the root itself, `SessionProcessGroups.claimant` falls to the supervisor
    /// that started later); this one does not, and a reader should not infer one from the sentence
    /// above.
    ///
    /// What the kept card costs is stated rather than implied: where
    /// the overlap is partial, the dropped card's OWN pids - the job it adopted - are not in the
    /// project's total at all. A project reading nothing about a process is the ordinary shape of
    /// this page (the cards below still count it, and its own card still says `N background`),
    /// while a project counting one process twice is the error this whole rollup exists to refuse,
    /// and the section's own note calls a confident wrong number the worst thing it can print.
    /// Counting each pid exactly once needs per-pid figures, and what reaches here are the cards'
    /// TOTALS - deliberately, because on a capture those totals are fixtures and a rollup built
    /// from the machine's real per-process readings would contradict every card on the page.
    ///
    /// - Parameters:
    ///   - members: the pids each card is counting, keyed as the board keys its rows.
    ///   - roots: which project each of those sessions is working in.
    static func nested(_ members: [String: Set<pid_t>], roots: [String: String]) -> Set<String> {
        // Largest first, and a card is kept only when it shares nothing with a card ALREADY kept.
        // Deciding each card against every other one instead would drop a card for overlapping
        // something that was itself dropped, and take work off the project that nothing was
        // counting twice. Ties are settled on the key, so the answer cannot change from tick to
        // tick while nothing else does, which is the rule every other order on this page follows.
        var kept: [(root: String, members: Set<pid_t>)] = []
        var swallowed: Set<String> = []
        for (key, mine) in members.sorted(by: { ($0.value.count, $0.key) > ($1.value.count, $1.key) }) {
            guard let root = roots[key] else { continue }
            if kept.contains(where: { $0.root == root && !$0.members.isDisjoint(with: mine) }) {
                swallowed.insert(key)
            } else {
                kept.append((root, mine))
            }
        }
        return swallowed
    }

    /// How much a project's leftovers have to be holding to keep it on the books with no session
    /// left on it (`watched`).
    ///
    /// SIXTY-FOUR MEGABYTES, AND IT IS NOT A GAP. An earlier version of this note called it "a gap
    /// rather than a guess" and gave two measurements for it: that the shells it has to exclude
    /// hold 0.7 to 3.1 MB, and that the smallest thing worth a row on the same table is over
    /// 100 MB. Re-measured on this machine with this file's own reader (`ri_phys_footprint`,
    /// 2026-09-02), both are wrong, and the first was wrong about WHICH shells it had looked at:
    ///
    ///     the shell a supervisor was started from       1.3 to  9.1 MB  (12 of them)
    ///     a checkout's shell with no session under it   1.3 to 25.3 MB  (16, five above 21 MB)
    ///     orphans (ppid 1), strays by construction      1.6 to 76.3 MB  (11, FIVE below this line)
    ///
    /// The 0.7 to 3.1 MB figures fit Claude Code's own Bash tool shells, which sit inside a
    /// session's tree and so can never be in a stray pool at all. What this line is actually asked
    /// to separate is the second row from the third, and those two overlap: a terminal tab's shell
    /// reaches 25.3 MB, while the smallest orphans under it are a `cloudflared` tunnel at 28.3 MB,
    /// a Python at 21.3 MB and three polling `bash` loops at 1.6 MB. The number lands inside one
    /// population rather than between two.
    ///
    /// SO THE FLOOR IS NOT WHAT MAKES THIS SAFE, and the grace period below is (`watched`). What
    /// the floor still buys is that anything genuinely heavy is kept whatever its CPU reads, which
    /// is the case somebody closes a session and goes looking for. What it still COSTS, named
    /// rather than implied: a project whose only leftover is a small idle service - that tunnel,
    /// sitting at 0% until a request arrives - stops being watched once it has read idle for the
    /// whole grace period, and comes back the next time a session names that directory. Lowering
    /// the number would keep it and would keep every idle terminal tab with it, which is the row
    /// this rule exists to refuse.
    static let idleMemoryFloor: UInt64 = 64_000_000

    /// How many CONSECUTIVE ticks a project has to read idle before it stops being watched.
    ///
    /// ONE READING WAS ENOUGH BEFORE, AND ONE READING IS NOT EVIDENCE. An idle process reads 0% by
    /// construction rather than by chance, and the tick a session ENDS on is guaranteed to read 0%
    /// for everything it leaves behind: a pid reclassified into a pool is given that reading's own
    /// counters as its baseline, so it contributes nothing to the tick that first sees it
    /// (`ProcessResourceSample.pairing`). The very tick this section exists for - the session
    /// closes, its dev server joins the pool - was therefore the tick most likely to drop the
    /// project, and a project dropped here is never looked for again until some session names that
    /// directory (`ProjectLoadAccounting.strays` matches against the roots this returns, and
    /// nothing else puts one back).
    ///
    /// THREE, because two is the smallest number that could tell a rate apart from a first
    /// sighting and this has to survive one more tick than that: the join tick reads 0% and the
    /// tick after it is the first that could read anything at all.
    static let idleTicksBeforeDropping = 3

    /// WHICH PROJECTS ARE STILL WORTH WATCHING once this tick has been read, which is what decides
    /// whether the next tick looks for them at all (`ProjectLoadAccounting`).
    ///
    /// A ROW IS NOT THE SAME AS WORK, and the difference is a section that never goes away. Keeping
    /// every root that produced a row means keeping every root that has a stray, and the interactive
    /// shell a session was launched from is a stray of its checkout permanently: the Projects
    /// section would sit on the page reading `0 sessions, 0%, 1 stray` under an empty board, once
    /// per checkout a terminal tab is still open in, for as long as the app runs. So a project with
    /// no session on it stays only while its leftovers are DOING something: a rate not yet
    /// established, a rate above zero, or memory at or above the floor above.
    ///
    /// AND "IS IT IDLE" IS ASKED OVER SEVERAL TICKS RATHER THAN ONE, which is the whole of what the
    /// count is for (`idleTicksBeforeDropping` carries the reasoning). A project that reads busy at
    /// any point starts again from nothing.
    ///
    /// WHAT IT COSTS: a project whose only leftover is idle in both senses for the whole grace
    /// period stops being watched, and comes back the next time a session names it. That is the
    /// same standard the rest of this app holds - no line rather than a line reading zero.
    ///
    /// - Parameter idle: how many consecutive ticks each project has read idle so far, as this
    ///   handed them back last tick. A parameter because the rules in this file are pure, and this
    ///   one now needs a memory: one number per project rather than a reading.
    /// - Returns: the roots the next tick looks for, and the counts to hand back in.
    static func watched(_ load: MachineLoad, idle: [String: Int] = [:])
        -> (roots: Set<String>, idle: [String: Int]) {
        var roots: Set<String> = []
        var next: [String: Int] = [:]
        for project in load.projects {
            let working = project.sessions > 0 || project.cpuPercent == nil
                || (project.cpuPercent ?? 0) > 0 || project.memoryBytes >= idleMemoryFloor
            if working {
                roots.insert(project.root)
                continue
            }
            let ticks = (idle[project.root] ?? 0) + 1
            guard ticks < idleTicksBeforeDropping else { continue }
            roots.insert(project.root)
            next[project.root] = ticks
        }
        return (roots, next)
    }

    /// WHAT EACH PROJECT'S SESSIONS READ, out of the footprints the cards will actually draw.
    ///
    /// The one rule applied on the way through is the one above: a session already inside another
    /// one's tree contributes its count and not its figures.
    ///
    /// - Parameters:
    ///   - footprints: what each card will draw, keyed as the board keys its rows.
    ///   - roots: which project each session is working in.
    ///   - members: the pids each card is counting, for the nesting test. Read only for the cards
    ///     that HAVE a footprint: a session whose card was skipped adds nothing to any total, so
    ///     letting its membership swallow another one would take that other session's figures off
    ///     the project without anything putting them back.
    static func readings(of footprints: [String: ProcessFootprint], roots: [String: String],
                         members: [String: Set<pid_t>]) -> [SessionReading] {
        let swallowed = nested(members.filter { footprints[$0.key] != nil }, roots: roots)
        return footprints.compactMap { key, footprint in
            roots[key].map {
                SessionReading(root: $0, cpuPercent: footprint.cpuPercent,
                               memoryBytes: footprint.memoryBytes, nested: swallowed.contains(key))
            }
        }
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
    ///
    /// AND A NESTED SESSION IS COUNTED WITHOUT ITS FIGURES BEING ADDED (`nested`): it is a session
    /// working here, so the count says two, and its processes are already in the outer card's
    /// numbers, so adding them again would state the tree twice.
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
            if !reading.nested {
                held.cpuPercent = add(reading.cpuPercent, to: held.cpuPercent)
                held.memoryBytes += reading.memoryBytes
            }
            held.sessions += 1
            byRoot[reading.root] = held
        }
        for stray in strays where stray.processes > 0 {
            var held = row(stray.root)
            held.cpuPercent = add(stray.cpuPercent, to: held.cpuPercent)
            held.memoryBytes += stray.memoryBytes
            held.strayCpuPercent = add(stray.cpuPercent, to: held.strayCpuPercent)
            held.strayMemoryBytes += stray.memoryBytes
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
