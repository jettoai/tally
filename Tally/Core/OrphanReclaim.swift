import Darwin
import Foundation

/// WORK NOBODY IS ANSWERING FOR, AND WHETHER IT IS SAFE TO END.
///
/// THE ROLLUP NEXT DOOR SAYS A CHECKOUT IS BURNING TWELVE CORES AND NOBODY IS WATCHING IT
/// (`MachineLoadRollup`). That reading was the whole of the repair for a while, and it is only half:
/// the incident it was written for (2026-09-01, six `next dev` servers in one repository burning six
/// cores for hours) was not that nobody could SEE the load, it was that nobody was in front of the
/// machine to act on it. A page that states a fact perfectly and needs a person to read it is a page
/// that says nothing at three in the morning.
///
/// SO THIS DECIDES, AND THE WHOLE DESIGN IS ABOUT REFUSING TO. Ending somebody's process on a guess
/// is the one error here that cannot be undone by the next tick: a killed build is minutes of work,
/// a killed terminal is a person's session, and a single false positive would rightly end the
/// feature. So the reclaim is written as three tiers of DECREASING certainty and increasing
/// timidity, and the two lower ones can only ever talk:
///
///   A. THE OWNER SAID SO AND THE OWNER IS DEAD. A dev-watch lease names its own server tree
///      (`OrphanLease`); the supervisor that wrote it has gone and the tree it named is still
///      running. Nothing is inferred - a file this machine's own harness wrote says whose these
///      processes are, and whoever they belong to is not there to answer for them.
///   B. STRONG EVIDENCE, TWICE, WITH NOTHING SPEAKING AGAINST IT. A development program, working in
///      one of these checkouts, older than twenty minutes, seen at the same identity across two
///      rounds at least five minutes apart, burning half a core or holding two gigabytes, and with
///      no veto at all (`OrphanVeto`).
///   C. EVERYTHING ELSE THAT LOOKS LIKE IT. Says so and does nothing (`OrphanNotice`).
///
/// PURE, so every case above can be stated in the assertion harness with no processes around it -
/// which matters more here than anywhere else in this app, because the ONE thing that must never be
/// asserted against the real machine is a rule whose failure mode is killing something. The state a
/// verdict needs between rounds is next door (`OrphanReclaimStore`), the readings are in
/// `OrphanReaders.swift`, and the ending itself is `OrphanKill.swift`.
enum OrphanReclaim {

    /// How old a tree has to be before B will look at it at all.
    ///
    /// TWENTY MINUTES IS ABOUT THE THING BEING LEFT BEHIND RATHER THAN ABOUT THE LOAD. A build that
    /// has been running four minutes is somebody waiting for it; a dev server that has been up for
    /// twenty in a checkout with no session on it is the shape this exists for. It also covers the
    /// ordinary way a session ends: a supervisor exits, its server joins the stray pool, and the
    /// person who closed it is still at the keyboard and about to start another one.
    static let minimumAge: TimeInterval = 20 * 60

    /// The share of one core a tree has to be spending to clear B's resource bar.
    static let busyPercent = 50.0

    /// …or what it has to be holding instead. Two gigabytes is the leaked dev server
    /// (`DEVWATCH_RSS_MAX_MB` guards its own at eight, and a leak reaches that in hours).
    static let heldBytes: UInt64 = 2 * 1024 * 1024 * 1024

    /// What a tree with NO listening port has to be burning instead, in both rounds.
    ///
    /// THE 2026-09-01 INCIDENT WAS THIS SHAPE and it is the one that most needs the higher bar. A
    /// dev server holding a port is a thing with a job: the port itself is evidence of what it is,
    /// and a person can name it. A compiler that never listened on anything and is spinning at 100%
    /// is either a runaway or somebody's legitimate long build, and nothing about the process can
    /// tell the two apart - only how long it has been doing it (`minimumAge`) and how hard
    /// (`runawayPercent`, asked of both rounds rather than of one).
    static let runawayPercent = 80.0

    /// The shortest gap between the two readings B is decided on.
    ///
    /// FIVE MINUTES, AND THE GAP IS THE EVIDENCE RATHER THAN THE COUNT. Two ticks two seconds apart
    /// are one moment read twice: a build in its link step is at 100% across both. What separates a
    /// runaway from a busy minute is that it is still doing it five minutes later, which is also
    /// long enough that the interval this app's own sampling error lives on (one tick) is noise
    /// against it.
    static let roundInterval: TimeInterval = 5 * 60

    /// How far apart two rounds have to be before the pair is thrown away rather than believed.
    ///
    /// A LAPTOP THAT SLEPT DID NOT WATCH ANYTHING. The two readings B needs are cumulative CPU
    /// counters differenced over the wall clock between them, and a machine that was closed for six
    /// hours produces a pair whose interval is six hours and whose work is the two minutes before
    /// the lid shut: a rate near zero, which is harmless, and a "sustained across two rounds" that
    /// is a lie, which is not. Anything past this is a first sighting again.
    static let sleepGap: TimeInterval = 15 * 60

    /// A process the scan is considering, with the three readings a verdict needs beyond what the
    /// table walk already carries.
    ///
    /// THE OPTIONALS ARE THE POINT. A field the machine will not answer is not a zero and not a
    /// default: it is the reason this candidate can never be killed (`OrphanVeto.unreadable`), and
    /// spelling it as an absence is what makes that automatic rather than remembered.
    struct Member: Equatable {
        var identity: ProcessIdentity
        /// The program on disk, as `proc_pidpath` states it. Nil when the machine will not say.
        var program: String?
        /// Its working directory. Nil for the same reason, and the same consequence.
        var directory: String?
    }

    /// One connected or listening TCP socket, as the reclaim reads them (`OrphanReaders.swift`).
    struct Connection: Equatable {
        var pid: pid_t
        var localPort: UInt16
        var remotePort: UInt16
        /// Whether the far end is this machine talking to itself. A browser on the dev server and a
        /// tunnel in front of it are both loopback, and both mean somebody is using this.
        var remoteIsLoopback: Bool
        /// Nothing is connected to it yet: it is waiting.
        var listening: Bool
    }

    /// ONE SOCKET WALK: what it found, AND whose descriptor table it could not read.
    ///
    /// THE SECOND FIELD IS THE WHOLE POINT. "Nothing is connected to this tree" is a reading that
    /// lets it be ended, and it used to be spelled the same way as "the machine would not answer" -
    /// an empty list either way. A single transient failure therefore turned the in-use veto off
    /// without anything saying so, on the one code path in this app that sends a signal (codex
    /// review, 2026-09-02). Named, it becomes `Veto.unreadable`, which is soft: the tree is
    /// reported rather than ended.
    struct Sockets: Equatable {
        var connections: [Connection] = []
        /// Pids whose sockets could not be enumerated. Not "pids with no sockets".
        var unreadable: Set<pid_t> = []
    }

    /// ONE READING OF THE SESSION BOARD: which checkouts live sessions are working in, AND whether
    /// the board could say that about every row it holds.
    ///
    /// THE SECOND FIELD IS THERE FOR THE REASON THE ONE ABOVE IS. "No session is working in this
    /// checkout" is the reading that lets a tree be ended, and a roster row whose directory nothing
    /// published is dropped on the way here (`ProjectLoadAccounting.roots`) - so a session this app
    /// simply could not place looked exactly like a machine with no session on it. Named, the round
    /// fails closed: every tree gets `Veto.sessionUnknown`, which is soft, so what happens is a
    /// message rather than either a signal or silence.
    struct Sessions: Equatable {
        /// The directories, as the board holds them
        /// (`MachineLoadRollup.SessionReading.root`).
        var checkouts: Set<String> = []
        /// True when a live row would not say which directory it is in. Not "there are no
        /// sessions".
        var unreadable = false
    }

    /// A group of strays that belong together: one root and everything descended from it.
    struct Tree: Equatable {
        /// The pid nothing else in the stray set is the parent of.
        var root: pid_t
        /// When that pid began, which is the half of its identity a number cannot carry
        /// (`ProcessIdentity.startedAt`). Two rounds are the same tree only when BOTH match.
        var rootStartedAt: Int64
        var members: Set<pid_t>
        /// The checkout the rollup filed these under (`MachineLoadRollup.project`).
        var project: String
    }

    /// WHICH STRAYS BELONG TOGETHER, so a verdict is reached about a server and its workers rather
    /// than about eight unrelated numbers.
    ///
    /// PARENTAGE INSIDE THE STRAY SET AND NOTHING ELSE. A stray whose parent is also a stray of the
    /// SAME project is that parent's; anything else is a root of its own. Deliberately not the group
    /// (`ProcessTree.members` uses it, and it is the right identity there): a re-parented job's
    /// group leader is long gone, so grouping on it would fuse two unrelated orphans that happen to
    /// have been given the same number, and fusing is the direction that kills the innocent one.
    ///
    /// AND THE PROJECT HAS TO MATCH, which is what stops a tree straddling two checkouts from being
    /// reclaimed as one. Such a tree is not fused here; it is two trees, and each of them sees the
    /// other's directory when the vetoes are taken (`OrphanVeto.crossRepo`).
    ///
    /// - Parameter strays: what the rollup could not attribute, by project (`ProjectLoadAccounting`).
    static func trees(of strays: [pid_t: String], among processes: [ProcessIdentity]) -> [Tree] {
        var parent: [pid_t: pid_t] = [:]
        var began: [pid_t: Int64] = [:]
        for one in processes where strays[one.pid] != nil {
            parent[one.pid] = one.parent
            began[one.pid] = one.startedAt
        }
        // Whose tree each stray is in, found by walking up while the walk stays inside the set. A
        // visited set bounds it: the process table cannot hold a cycle, and a map assembled from two
        // moments of it could.
        func rootOf(_ pid: pid_t) -> pid_t {
            var here = pid
            var seen: Set<pid_t> = [pid]
            while let up = parent[here], strays[up] == strays[here], !seen.contains(up) {
                seen.insert(up)
                here = up
            }
            return here
        }
        var members: [pid_t: Set<pid_t>] = [:]
        for pid in parent.keys { members[rootOf(pid), default: []].insert(pid) }
        return members.compactMap { root, held in
            guard let project = strays[root], let startedAt = began[root] else { return nil }
            return Tree(root: root, rootStartedAt: startedAt, members: held, project: project)
        }.sorted { $0.root < $1.root }
    }

    /// The programs a development tree runs, by the name `ProcessTree.displayName` gives them.
    ///
    /// A LIST RATHER THAN A HEURISTIC, and a short one. Everything not on it falls to
    /// `OrphanVeto.unknownProgram`, which is notify-only - so the cost of the list being incomplete
    /// is a message, and the cost of it being too broad is a killed process. That asymmetry is the
    /// whole reason it is spelled out: `node` and `python3` are here because the two incidents this
    /// feature exists for were a `next dev` and a `uv`-dispatched transcription run, and a rule of
    /// the shape "an executable under the checkout" would have matched a person's editor too.
    static let developmentPrograms: Set<String> = [
        "node", "next-server", "bun", "deno", "esbuild", "vite", "rollup", "webpack", "tsc",
        "ts-node", "nodemon", "turbo", "jest", "vitest", "python", "python3", "uv", "ruby",
        "cargo", "rustc", "go", "gradle", "java", "swift-frontend",
    ]

    /// WHY A CANDIDATE MIGHT NOT BE WHAT IT LOOKS LIKE.
    ///
    /// TWO KINDS, AND THE DIFFERENCE IS WHAT HAPPENS NEXT (`hard`). A hard veto says this is not an
    /// orphan at all - somebody is at it, or in it - and the right response is silence: a message
    /// about the terminal the reader is typing in is noise that teaches them to ignore the channel.
    /// A soft veto says this app cannot tell, which is exactly what tier C is for.
    enum Veto: String, CaseIterable, Comparable {
        /// Something in the tree has a controlling terminal: a person is sitting in front of it.
        case terminal
        /// An ancestor is a terminal multiplexer or an editor, so the tree is somebody's workspace
        /// rather than a leftover, even where no member holds the tty itself.
        case ancestor
        /// Somebody is connected to it: a browser holding an HMR socket, a tunnel in front of it, a
        /// request in flight. A server being USED is not a server nobody wants.
        case inUse
        /// A field the machine would not answer. Fail-closed, in the one place in this app where
        /// fail-open means ending a process on a reading nobody took.
        case unreadable
        /// A member is working in a different checkout from the tree's own, so what would be ended
        /// is not one project's leftovers.
        case crossRepo
        /// The program is not one this app recognises as development work
        /// (`developmentPrograms`).
        case unknownProgram
        /// A DEV-WATCH LEASE STILL HAS SOMEBODY ANSWERING FOR THIS TREE (`OrphanLease`): the
        /// supervisor that registered it is running right now.
        ///
        /// THE MIRROR OF TIER A RATHER THAN AN ADDITION TO IT. That tier acts on a lease that is
        /// `abandoned`; this veto is raised by one that is `tended`, and those are two of the four
        /// states a lease can be in. The other two are deliberately outside both and neither is an
        /// oversight: `spent` has no tree left to speak for, and `unsure` is the state where
        /// neither the table nor the kernel would answer about the supervisor - turning THAT into a
        /// veto would put the one shape this feature exists for permanently out of reach on a
        /// machine whose probe is flaky, so it falls to tier B like any other leftover
        /// (`OrphanReclaimStore.leases` states the same split at the code that makes it).
        ///
        /// What sat in the gap before this veto existed was the ordinary case - a
        /// supervisor doing its job - and it fell straight through into the evidence tiers, which
        /// know nothing about leases and judged the supervisor as a leftover `bash` holding two
        /// gigabytes (2026-09-02: three messages about one such tree in thirty minutes).
        ///
        /// HARD, WHICH THE OTHER "SOMEBODY OWNS THIS" VETOES ARE FOR THE SAME REASON. The message
        /// tier C would write ends by advising the reader to run the thing under `/dev-watch`,
        /// whose lease says whose it is - which is advice this tree has already taken, arriving in
        /// the inbox of the project that took it. A statement by this machine's own harness is not
        /// a doubt to be reported; it is an answer.
        case leased
        /// A LIVE SESSION IS WORKING IN THIS TREE'S CHECKOUT, so the tree may well be that
        /// session's own even though no card is counting it.
        ///
        /// THE FILE THAT DECIDES THIS ONE IS NOT THE PROCESS TABLE (`OrphanReclaimStore.round`
        /// takes it, the way it takes a terminal above the root). Everything else here is read off
        /// the tree; this is read off the board, and it is the reading the 2026-09-02 incident was
        /// missing: two dev servers were ended in checkouts a session was sitting in and working,
        /// and both messages said no session was, because the sentence was in the message and the
        /// test behind it was nowhere.
        ///
        /// SOFT, not hard. A session in the checkout does not make this tree that session's: a
        /// stray is by definition work no card reached, and the commonest one is the server left
        /// behind by the session BEFORE this one. So the answer is tier C - say what is running and
        /// leave it - rather than the silence a hard veto buys.
        case sessionPresent
        /// THE BOARD WOULD NOT SAY WHERE ONE OF ITS LIVE SESSIONS IS WORKING, so "nobody is working
        /// in this checkout" could not be established this round for ANY tree (`Sessions`).
        ///
        /// RAISED ON EVERY TREE OR ON NONE, which is what makes it different from every other veto
        /// here: the rest are readings about one tree, and this is a fact about the round. A roster
        /// row with no directory is dropped silently on the way in
        /// (`ProjectLoadAccounting.roots`), and a dropped row is indistinguishable from a machine
        /// with one session fewer - which is the exact shape of the reading the 2026-09-02 incident
        /// was decided on, one layer up (root-cause review, same day).
        ///
        /// SOFT, on the same reasoning as `unreadable`: what this app cannot establish is reported
        /// rather than acted on, and a round that says nothing at all would hide the very state a
        /// reader would want to know about.
        case sessionUnknown

        /// Whether this says "not an orphan" rather than "cannot tell". The first three are
        /// evidence about the world; the rest are the absence of evidence, which is what tier C
        /// exists to report rather than to act on.
        var hard: Bool {
            switch self {
            case .terminal, .ancestor, .inUse, .leased: return true
            case .unreadable, .crossRepo, .unknownProgram, .sessionPresent, .sessionUnknown:
                return false
            }
        }

        static func < (a: Veto, b: Veto) -> Bool { a.rawValue < b.rawValue }
    }

    /// EVERYTHING KNOWN ABOUT ONE TREE AT ONE MOMENT, which is what a verdict is taken on.
    struct Reading: Equatable {
        var tree: Tree
        /// When this was taken. Held on the reading rather than passed beside it, so a verdict and
        /// the sighting it produces cannot be a moment apart.
        var takenAt: Date
        /// How long the root has been running, in seconds.
        var age: TimeInterval
        /// The tree's share of one core since the previous ROUND, or nil on a first sighting.
        var cpuPercent: Double?
        var memoryBytes: UInt64
        /// The ports it is waiting on, ascending. Empty is the runaway shape (`runawayPercent`).
        var listeningPorts: [UInt16]
        /// What to call it: the root's program, or the busiest member's when the root is a shell.
        var name: String?
        var vetoes: Set<Veto>

        /// Whether anything here says "not an orphan" outright.
        var blocked: Bool { vetoes.contains { $0.hard } }
    }

    /// WHAT SPEAKS AGAINST ENDING THIS TREE, out of the readings the scan already has.
    ///
    /// TAKEN OVER THE WHOLE TREE RATHER THAN OVER ITS ROOT. A veto is a reason not to act on any of
    /// it: one member with a terminal makes the whole job somebody's foreground work, and one member
    /// whose directory cannot be read makes the whole set unsafe to end - the unreadable one may be
    /// the very process that matters.
    ///
    /// NOT EVERY VETO IS TAKEN HERE, and the two that are not are the two that are not about the
    /// tree at all: a terminal on an ANCESTOR of the root, and a live session working in the
    /// checkout (`Veto.sessionPresent`). Both are read off things this function is not handed, and
    /// both are added by the caller (`OrphanReclaimStore.read`).
    ///
    /// - Parameters:
    ///   - members: every process in the tree, with what could be read about each.
    ///   - sockets: what the socket walk found, AND whose table it could not read - the second of
    ///     those is a doubt about the tree rather than a quiet nothing (`Sockets`).
    ///   - ancestors: the programs above the tree's root, nearest first, as far as the walk got.
    ///     Empty is ordinary: an orphan's parent is launchd.
    static func vetoes(of tree: Tree, members: [Member], sockets: Sockets,
                       ancestors: [String]) -> Set<Veto> {
        var found: Set<Veto> = []
        let known = Set(members.map(\.identity.pid))
        // A DESCRIPTOR TABLE THAT WOULD NOT BE READ IS THE SAME KIND OF ABSENCE as a program or a
        // directory the machine would not state, and gets the same answer.
        if !sockets.unreadable.isDisjoint(with: tree.members) { found.insert(.unreadable) }
        // A member the walk named and the reader could not describe is the same absence as a
        // member missing from the list altogether: both are the tree holding a process nothing
        // here can speak for.
        if !tree.members.isSubset(of: known) { found.insert(.unreadable) }
        for member in members where tree.members.contains(member.identity.pid) {
            if member.identity.hasTerminal { found.insert(.terminal) }
            guard let directory = member.directory, member.program != nil else {
                found.insert(.unreadable)
                continue
            }
            if directory != tree.project && !directory.hasPrefix(tree.project + "/") {
                found.insert(.crossRepo)
            }
        }
        if ancestors.contains(where: interactiveAncestors.contains) { found.insert(.ancestor) }
        if inUse(sockets.connections, within: tree.members) { found.insert(.inUse) }
        if !recognised(tree, members: members) { found.insert(.unknownProgram) }
        return found
    }

    /// WHICH CHECKOUT A DIRECTORY IS IN, for the one question "is somebody working here".
    ///
    /// A PARALLEL LINE IS ITS REPOSITORY, on the same rule the messages are addressed by
    /// (`OrphanNotice.repository`): a session in the trunk and a leftover in a worktree of it are
    /// one person's business, and answering "two different checkouts" would end a tree that
    /// session's own commands very likely started. The worktree name is dropped here because the
    /// only thing being asked is whether two directories are the same body of work.
    ///
    /// A DIRECTORY WITH NO `.git` ABOVE IT IS ITS OWN CHECKOUT, which is what the strays' own
    /// projects already are: the rollup files a stray under the accounted root that CONTAINS it
    /// (`MachineLoadRollup.project`), and a session's root is that same string, so the ordinary
    /// case compares equal without any of this. The walk is what covers the two that do not: a
    /// worktree, and a session sitting in a subdirectory of the checkout its leftovers are in.
    static func checkout(of directory: String,
                         entry: (String) -> OrphanNotice.GitEntry?) -> String {
        OrphanNotice.repository(of: directory, entry: entry)?.root ?? directory
    }

    /// The programs that make everything under them somebody's workspace.
    static let interactiveAncestors: Set<String> = [
        "tmux", "tmux-server", "screen", "zellij", "Code Helper", "Code", "Cursor", "Xcode",
        "iTerm2", "Terminal", "WezTerm", "kitty", "alacritty", "Warp", "Hyper",
    ]

    /// Whether anybody is connected to this tree from outside it.
    ///
    /// THE INTERNAL TRAFFIC HAS TO COME OUT FIRST, and it is most of what a dev server's socket
    /// table holds: a Next.js dev server talks to its own compiler workers over loopback all day,
    /// and counting that as "somebody is using this" would veto every candidate this feature has.
    /// So a connection is internal when the far end is a port this same tree is holding, and that
    /// is decided from the tree's own endpoints rather than from a name or a range.
    static func inUse(_ connections: [Connection], within members: Set<pid_t>) -> Bool {
        let mine = connections.filter { members.contains($0.pid) }
        let ours = Set(mine.map(\.localPort))
        return mine.contains { one in
            guard !one.listening else { return false }
            // A far end this tree is also holding is one of its own workers, whatever the address.
            if one.remoteIsLoopback && ours.contains(one.remotePort) { return false }
            return true
        }
    }

    /// Whether the tree is running a program this app is willing to end, and what to call it.
    ///
    /// THE ROOT IS ASKED FIRST AND THE MEMBERS ARE THE FALLBACK, because a dev server is often
    /// started through a shell that is still its root (`sh -c "next dev"`): the root's own program
    /// is `sh`, which is on no list, and the work is one level down. A tree is recognised when ANY
    /// member is a development program, which is the same direction the rest of this file leans -
    /// recognition only ever opens the door that the vetoes and the bars still have to let it
    /// through.
    static func recognised(_ tree: Tree, members: [Member]) -> Bool {
        members.contains {
            tree.members.contains($0.identity.pid) && name(of: $0).map(developmentPrograms.contains)
                == true
        }
    }

    /// What to call one member: its program's display name.
    static func name(of member: Member) -> String? {
        member.program.flatMap(ProcessTree.displayName(forPath:))
    }
}
