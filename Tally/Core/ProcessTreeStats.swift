import Darwin
import Foundation

/// WHAT A SESSION IS COSTING THE MACHINE, read off its process TREE rather than off the one process
/// the board knows by name.
///
/// A supervised session is never one process: the supervisor spawns a Claude Code, which spawns
/// shells, dev servers, language servers and whatever else a turn asks for, and all of it outlives
/// the turn that started it. So "what is this session doing to my laptop" is a question about the
/// whole subtree under the supervisor pid, and none of it is provider-specific - a Codex session, a
/// Claude one and a plain CLI under supervision are all read the same way.
///
/// EVERYTHING IN THIS FILE IS PURE, so the parts a card actually depends on can be stated in an
/// assertion harness with no processes around them: which pids belong to a tree, what a reading of
/// it holds, and which of those pids are the meter rather than the thing metered. What a PAIR of
/// readings says - every rate on the card, and the blame that goes with it - is next door in
/// `ProcessTreeRates.swift`, which came out of this file when it ran out of room; the rules that
/// decide membership and ownership at one instant are in `ProcessTreeCensus.swift`, which came out
/// of it along the same line. What only an OPEN set needs - what became of a pid that left, and how
/// two readings of a stray pool are paired given that answer - is in `ProcessTreePool.swift`, the
/// third cut along it. The readings themselves - the libproc calls with no decisions in them - are
/// in `ProcessTreeReaders.swift`.
struct ProcessFootprint: Equatable {
    /// How many live processes this session has STARTED: the tree, less Tally's own (`ownFamily`)
    /// and less the provider CLI at its head (`dispatched`). Zero is a reading like any other -
    /// a session that has started nothing.
    var processes: Int
    /// How many of those were ADOPTED BACK rather than reached by the tree walk: a job whose own
    /// shell has exited, re-parented to launchd, matched to this session by the process group it
    /// still carries (`SessionProcessGroups`).
    ///
    /// SAID ON THE CARD, NOT JUST COUNTED. These are the processes a session has left running
    /// BEHIND itself - the dev server, the fan-out that outlived the turn that started it - and
    /// they are the whole reason a session can be idle and still be costing twelve cores. The count
    /// beside them is what says the number above is not all foreground work.
    var backgroundProcesses = 0
    /// How many subagents are working under this session right now, as Claude Code itself reports
    /// them (`SessionAgentsRecord`). ZERO IS BOTH "none" AND "cannot say", and the line treats them
    /// alike on purpose: a session with no fan-out and a Claude Code too old to publish one both
    /// have nothing to show, and a segment reading "0 agents" would be spending the card's narrowest
    /// line saying so all day.
    var agents = 0
    /// The tree's share of one core over the last interval, or nil when there is no interval yet:
    /// a cumulative counter says nothing until it has been read twice.
    var cpuPercent: Double?
    /// What to call the one process that burned more than half of that, when a single one did and it
    /// is still alive to be named.
    ///
    /// A NUMBER SAYS A SESSION IS EXPENSIVE, A NAME SAYS WHAT IS DOING IT. Which project the card
    /// belongs to the board already states; "34% CPU (node)" is the part nothing else in this app
    /// can answer, and it is the difference between knowing to look and knowing where.
    var cpuLeader: String?
    /// What the whole tree is holding in physical memory this instant, in bytes. Zero when nothing
    /// could be read, which is how the line knows to say nothing rather than "0 MB".
    ///
    /// THE WHOLE TREE, INCLUDING THE PROCESS THE COUNT ABOVE LEAVES OUT, and the two are not
    /// inconsistent: what the count answers is "how much did this session start", and what this
    /// answers is "what is this session costing the machine" - which the session's own Claude Code
    /// is very much part of.
    var memoryBytes: UInt64 = 0
    /// What to call the one process holding more than half of that, when a single one is.
    ///
    /// NOT PUT THROUGH `worthNaming`, WHICH THE CPU SEGMENT IS, and the count above is why. With
    /// the session's own CLI out of the count, `1 proc · 3.4 GB` leaves a reader asking whether
    /// those gigabytes are the body or the one thing it started, and this is the only field on the
    /// card that answers it - so `(claude)` here is the answer rather than the noise it would be
    /// beside a CPU figure on every card (`ProcessTree.line`).
    ///
    /// WHAT A NAME CANNOT SAY, stated rather than implied: it is the EXECUTABLE's name
    /// (`displayName`), so an MCP server run by a runtime reads `(bun)` or `(node)` rather than by
    /// the server's own name. Saying which server would mean reading argv (`KERN_PROCARGS2`),
    /// which is a syscall surface this app does not touch and a string that can carry a token.
    var memoryLeader: String?
    /// How fast the tree is writing to disk, in bytes per second, or nil when there is no interval
    /// yet - the same two-readings rule the CPU percentage lives by.
    var diskWriteBytesPerSecond: Double?
    /// What to call the process doing more than half of that writing, on the same terms as
    /// `cpuLeader`.
    var diskLeader: String?
    /// The TCP ports the tree is listening on, ascending. A dev server is the reason this is on the
    /// card at all: it is the one thing a session leaves behind that another session then collides
    /// with, and it is invisible everywhere else in this app.
    var listeningPorts: [UInt16]
    /// What to call the process holding each of those, where the machine would say what it is
    /// running. A number says a port is taken and a name says by what, which is the difference
    /// between "something of mine is on 3000" and "that is the dev server I left running"
    /// (`ProcessTree.portsText`, and `memoryLeader` for what a name cannot say).
    var portNames: [UInt16: String] = [:]
    /// Which of these readings are worth somebody's eye, decided over several ticks and against
    /// what the session is doing rather than against the numbers alone (`FootprintAlerts.swift`).
    var alerts = FootprintAlerts()
}

/// A live process as this file identifies it: itself, who started it, which job it belongs to, and
/// when it began.
///
/// THE GROUP IS THE ONE THAT SURVIVES, which is the whole reason it is carried (see `members`).
struct ProcessIdentity: Equatable {
    var pid: pid_t
    var parent: pid_t
    /// The process group id: the pid of the job's leader, inherited by everything the job spawns and
    /// unchanged by the parent dying.
    var group: pid_t
    /// Microseconds since the epoch, as the kernel recorded the fork.
    ///
    /// THE NUMBER IS NOT AN IDENTITY AND THIS IS WHAT MAKES ONE. A pid is handed out again, so
    /// anything this app holds across ticks and looks up later - a port's holder is the one here
    /// (`ProcessPortHolder`) - is a stale key in a fresh table unless something says the process is
    /// still the same process. Stable for the life of a process and different for the next holder
    /// of its number, which is the same pair of properties the supervisor identifies a Claude Code
    /// by, spelled the same way and in the same unit (`ProcessStamp`,
    /// `TallyCLI/TranscriptIdentity.swift`):
    /// one identity rule for pids in this repository rather than two.
    ///
    /// It costs nothing to carry: it comes out of the very `proc_bsdinfo` record the parent and the
    /// group are read from (`ProcessTree.liveProcesses`).
    var startedAt: Int64
}

/// One reading of what the tree's processes have used, per pid, and the instant it was taken. Four
/// counters out of one `proc_pid_rusage` call per process: two cumulative CPU totals, what the
/// process is holding in memory now, and what it has written to disk since it started.
///
/// PER PID RATHER THAN ONE TOTAL, which is what makes the difference between two of them honest:
/// a total drops when any process in the tree exits, so a tree total differenced against the next
/// one would read as negative work every time a shell finished. Held per pid, an exit simply stops
/// contributing and a process born inside the interval contributes what it has spent, which is all
/// of it by definition.
///
/// AND EVERY PROCESS IS READ TWICE: what it has burned itself, and what the children it has already
/// buried burned (`ri_child_user_time`, the kernel's own accounting for reaped children). A build
/// worker that starts and finishes between two samples is never seen alive by either of them, and
/// without the second counter its half second of a core is simply not in the arithmetic - which is
/// most of what a session's CPU IS, since an agent's work is mostly short commands.
struct ProcessResourceSample: Equatable {
    /// Cumulative CPU seconds each process has spent on its own behalf.
    var times: [pid_t: Double]
    /// Cumulative CPU seconds each process's REAPED children spent, which the kernel folds into the
    /// parent at the moment it collects them (and which itself already includes what those children
    /// had folded in from their own).
    var childTimes: [pid_t: Double]
    /// What each process has resident and dirty right now (`ri_phys_footprint`), in bytes. NOT
    /// cumulative: it is the only counter here that says something on its own.
    var memory: [pid_t: UInt64] = [:]
    /// Cumulative bytes each process has written to disk since it started.
    var diskWritten: [pid_t: UInt64] = [:]
    var at: Date
    /// Which of these pids are Tally's own (`ProcessTree.ownFamily`).
    ///
    /// SAMPLED RATHER THAN SKIPPED, and the difference is not tidiness. Leaving them out of the
    /// reading altogether is what a reader expects to be enough, and it is not: a Tally process
    /// that ends between two ticks has its whole life folded into the counters of whoever REAPED
    /// it, and its reaper is Claude Code - a process this card is very much measuring. Measured on
    /// this machine (2026-08-15): a child burning a known 0.300s put 0.3308s into its parent's
    /// `ri_child_user_time` the instant it was collected, read through the very same
    /// `proc_pid_rusage` call this sampler makes. Filtered by pid alone, that arrival lands on the
    /// session with nothing to cancel it, because the pid it belonged to was never in either
    /// reading and so never departed from one.
    ///
    /// So they are read like everything else and taken out where each number is DECIDED: they
    /// contribute no work of their own and no arrivals of their own, and their departures still
    /// produce the credit that cancels what they left behind in somebody else's counter
    /// (`cpuPercent`).
    var ours: Set<pid_t> = []
    /// When each of these pids began (`ProcessIdentity.startedAt`, microseconds since the epoch).
    ///
    /// WHAT A POOL HOLDS ACROSS TICKS IS A NUMBER, AND A NUMBER IS NOT AN IDENTITY. Every other
    /// field here is answered inside one reading, where a pid means one process. A pool is the one
    /// reader that holds a pid into the next tick - a member that died and was not collected is
    /// waited for, possibly for hours (`pairing(with:departure:)`) - by which time the machine may
    /// have handed its number on. Held so the pairing can tell "still with us" from "that number is
    /// somebody else now", which read identically until this existed. Empty is legal and means the
    /// reader was not asked for identities; the pairing then behaves exactly as it did before this
    /// field. It costs no syscall: a stray pool's stamps come out of the table walk the tick has
    /// already made (`ProjectLoadAccounting.measure`).
    var startedAt: [pid_t: Int64] = [:]

    /// What the tree is holding, which is the number the card shows. Tally's own excluded, on the
    /// terms above: memory is an instant rather than an interval, so nothing has to survive a
    /// process ending and the pid test is the whole of it.
    ///
    /// SHARED PAGES ARE COUNTED ONCE PER PROCESS THAT MAPS THEM: eight node processes sharing a
    /// runtime each carry it in their own footprint, so this sum is larger than what killing the
    /// tree would hand the machine back. Activity Monitor's per-process column adds up exactly the
    /// same way, and as an answer to "which session is the heavy one", which is all the card claims,
    /// it is the right kind of wrong.
    ///
    /// WHICH IS WHY THE MACHINE-LEVEL RULE DOES NOT TRUST THIS RULER ALONE. "Is anything actually
    /// short" is a different claim from "which session is the heavy one", and this number cannot
    /// make it: a fan-out of workers reads as half a machine it has not taken. So the red tier asks
    /// the kernel's own pressure level as well, which counts a shared page once, and lights only
    /// when both agree (`FootprintAlarm`, `MachineMemoryPressure`).
    var memoryBytes: UInt64 {
        memory.reduce(0) { $0 + (ours.contains($1.key) ? 0 : $1.value) }
    }

    /// This reading with everything but these pids dropped. Mechanical: what it is FOR is stated on
    /// `pairing(with:departure:)`, which is the only caller that decides which pids those are.
    func narrowed(to pids: Set<pid_t>) -> ProcessResourceSample {
        ProcessResourceSample(times: times.filter { pids.contains($0.key) },
                              childTimes: childTimes.filter { pids.contains($0.key) },
                              memory: memory.filter { pids.contains($0.key) },
                              diskWritten: diskWritten.filter { pids.contains($0.key) },
                              at: at, ours: ours.intersection(pids),
                              startedAt: startedAt.filter { pids.contains($0.key) })
    }
}

enum ProcessTree {

    // MARK: The pure rules

    /// Every pid in the session rooted at `root`, the root included: its descendants by parentage,
    /// AND everything left in its job.
    ///
    /// PARENTAGE ALONE LOSES THE PROCESS THIS FEATURE EXISTS TO FIND. An agent that starts a server
    /// the way agents do - `sh -c 'npm run dev &'` - leaves a shell that exits within the
    /// millisecond, and macOS re-parents the surviving server to launchd. Its pid is then a child of
    /// pid 1 and a walk down from the supervisor never reaches it, so the card would report neither
    /// the process, nor its CPU, nor the port it is holding: exactly the residue the line is for.
    ///
    /// THE JOB IS THE IDENTITY THAT SURVIVES THAT. A process group is created when the shell starts
    /// the job, is inherited by everything the job spawns, and re-parenting does not touch it; the
    /// leader's pid IS the group number, so no two sessions can collide in it. Measured on this
    /// machine (2026-08-15): every live supervisor leads its own group, its Claude Code and every
    /// node beneath them carry that number, and an orphan keeps it after its parent is gone.
    ///
    /// CONTROLLING TERMINAL WAS THE OTHER CANDIDATE AND IS WORSE, measured the same way: one
    /// session's tty held sixteen processes against its group's eight, the extra eight being
    /// `login`, the supervisor's OWN parent shell, three unrelated shells and another job's helper.
    /// A rule that swallows its root's ancestors is not a tree, and successive sessions in one tab
    /// would inherit each other's leftovers. Both rules lose the same thing, honestly and by name:
    /// a process that calls `setsid` leaves job and terminal alike.
    ///
    /// THE GROUP HALF IS ONLY TRUSTED WHEN THE ROOT LEADS THE GROUP, and the case that guard is for
    /// is not the obvious one. Matching "group number equals the root's pid" already implies the
    /// root leads it, EXCEPT when a group outlives its leader: the members of a group whose leader
    /// has exited keep its number, and pid numbers are reused, so a supervisor that happens to be
    /// given that number later would inherit a dead stranger's processes. Asking whether the root is
    /// in that group at all is what separates the two, and a supervisor that leads no group of its
    /// own degrades to parentage - saying less rather than saying something wrong.
    ///
    /// A ROOT THAT IS NOT LIVE HAS NO TREE, and that is an ordinary answer rather than an error: the
    /// board draws a card for a session the scan found a moment ago, and the supervisor can be gone
    /// by the time this runs. Nothing is drawn for it rather than a "0 procs" that would read as a
    /// measurement.
    ///
    /// Walked from one table for every card on the board, and the visited set is not decoration: pid
    /// numbers are reused, and a parent chain that loops back on itself would otherwise spin here
    /// forever.
    /// THE JOB HALF ONLY REACHES THE GROUPS THE ROOT ITSELF LEADS, which is the whole of what the
    /// ledger next door exists to widen (`SessionProcessGroups`). An agent's command runs in a job
    /// of its own - Claude Code's Bash tool makes one per command so it can signal the job rather
    /// than one process - so a server left behind by such a command carries a group number that is
    /// neither the root's nor anything else this walk can reach, and it leaves the reading entirely
    /// the moment the command's own shell exits. `adopting` is how that job comes back: the pids the
    /// ledger says belong to this session, seeded into the same descent as everything else.
    ///
    /// - Parameter adopting: pids to treat as members whatever their parentage says, decided once
    ///   for the whole board so no process can be adopted onto two cards
    ///   (`SessionProcessGroups.adoptions`).
    static func members(root: pid_t, processes: [ProcessIdentity],
                        adopting adopted: Set<pid_t> = []) -> Set<pid_t> {
        guard let leader = processes.first(where: { $0.pid == root }) else { return [] }
        var seeds: Set<pid_t> = [root]
        if leader.group == root {
            for process in processes where process.group == root { seeds.insert(process.pid) }
        }
        // Seeded with the job and the adoptions as well as the root, so descent continues from the
        // orphan too: a server re-parented to launchd goes on spawning children of its own, and
        // those are as much the session's as it is.
        return progeny(of: seeds.union(adopted), in: processes)
    }

    /// Those pids and everything descended from them.
    ///
    /// Walked from one table, and the visited set is not decoration: pid numbers are reused, and a
    /// parent chain that loops back on itself would otherwise spin here forever.
    static func progeny(of seeds: Set<pid_t>, in processes: [ProcessIdentity]) -> Set<pid_t> {
        guard !seeds.isEmpty else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for process in processes where process.pid != process.parent {
            children[process.parent, default: []].append(process.pid)
        }
        var found = seeds
        var frontier = Array(found)
        while let pid = frontier.popLast() {
            for child in children[pid] ?? [] where found.insert(child).inserted {
                frontier.append(child)
            }
        }
        return found
    }

    /// WHICH OF THESE PIDS ARE TALLY'S OWN, and so are the meter rather than the thing metered.
    ///
    /// Every supervised session's tree holds this app. The supervisor sits at its root by
    /// construction, and whatever else of ours runs inside the session - the status line asked for
    /// on every prompt, a hook answering an event - is a descendant of it. Counting those is not a
    /// rounding error on an unlucky card: the root is in EVERY tree, so a board of ten sessions
    /// carried ten processes, their memory and their CPU that nobody started and nobody can act on.
    /// The line is meant to answer "what is the AI doing to my laptop", and the honest answer when
    /// all of that has gone home is no line at all rather than a card reporting Tally to itself.
    ///
    /// BY THE PROGRAM ON DISK, NEVER BY NAME. A `tally` built in this repository and run under a
    /// session is exactly the work somebody would be watching for, and it is called `tally` too. So
    /// the test is identity with the ROOT's own executable - that binary is the supervisor by
    /// definition - widened to the app bundle around it, because the shipped supervisor runs out of
    /// `Tally.app` and everything else of ours under that same bundle is ours by the same
    /// reasoning. A build under `DerivedData` shares neither, and is measured like any other work.
    ///
    /// THE TREE ITSELF IS NOT NARROWED, which is deliberate: the walk is what finds an orphan
    /// through its job (`members`), and a rule that pruned as it went would lose whatever hangs
    /// below one of ours. This is a filter applied to the answer.
    ///
    /// A ROOT WHOSE PROGRAM CANNOT BE READ still gives up itself, and nothing else: the supervisor
    /// is ours whether or not the machine will say what it is running, and with no path to compare
    /// against there is no ground for calling anything beside it ours too.
    ///
    /// - Parameter executable: the path of the program a pid is running, or nil when the machine
    ///   will not say (`ProcessTree.executablePath`). A function rather than a table so this stays
    ///   pure, which is also what lets the harness state every case with no processes around it.
    static func ownFamily(_ pids: some Sequence<pid_t>, root: pid_t,
                          executable: (pid_t) -> String?) -> Set<pid_t> {
        guard let mine = executable(root) else { return [root] }
        let bundle = appBundle(ofExecutablePath: mine)
        var family: Set<pid_t> = [root]
        for pid in pids where pid != root {
            guard let path = executable(pid) else { continue }
            if path == mine || bundle.map({ path.hasPrefix($0) }) == true { family.insert(pid) }
        }
        return family
    }

    /// The `.app` bundle a program runs out of, as the path prefix ending in its separator, or nil
    /// when it does not run out of one. The separator is kept so the prefix cannot match a sibling
    /// that merely starts with the same letters (`/Applications/Tally.app` against
    /// `/Applications/TallyOther.app/...`).
    static func appBundle(ofExecutablePath path: String) -> String? {
        guard let bundle = path.range(of: ".app/", options: .backwards) else { return nil }
        return String(path[..<bundle.upperBound])
    }
}
