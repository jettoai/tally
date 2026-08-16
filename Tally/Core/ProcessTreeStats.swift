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
/// assertion harness with no processes around them: which pids belong to a tree, what two
/// cumulative readings mean, which process to blame for the number, and how the line reads when a
/// segment has nothing to say. The readings themselves - the libproc calls with no decisions in
/// them - are next door in `ProcessTreeReaders.swift`.
struct ProcessFootprint: Equatable {
    /// How many live processes this session has STARTED: the tree, less Tally's own (`ownFamily`)
    /// and less the provider CLI at its head (`dispatched`). Zero is a reading like any other -
    /// a session that has started nothing.
    var processes: Int
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

/// One field of the card's footprint line, with what it says and whether it is a warning.
///
/// THE LINE IS HANDED OVER IN PIECES because one field of it can be drawn differently from the
/// rest, and a single string cannot say which. The kind is carried so the view can name the
/// condition for VoiceOver in its own words: the bundle is over there, and this stays a pure
/// function of what it is handed (the same division `unit` is already under).
struct ProcessFootprintSegment: Equatable {
    /// THE PORTS ARE NOT ONE OF THESE ANY MORE: they moved to the identity line, where they are
    /// their own element beside the account and the model rather than the last field of a sentence
    /// that truncates (`ProcessTree.portsText`, `SessionCardView.sessionIdentityRow`).
    enum Kind: Equatable { case processes, agents, cpu, memory, disk }
    var kind: Kind
    var text: String
    /// The quieter half of the field: the word a count is counting, or the program blamed for a
    /// rate. Carried apart from `text` rather than parsed back out of it, because the row that
    /// draws figures instead of sentences prints it a shade down from the number
    /// (`SessionCardView.sessionFootprintTrends`) - three heterogeneous facts at one brightness is
    /// a string a reader has to segment for themselves, which is what that row was reported as
    /// (Albert, 2026-08-15: "2 procs · 1% CPU (claude) · 459 MB" is hard to read).
    ///
    /// ONLY THE FIELDS THAT ROW DRAWS CARRY ONE, which is the three trended metrics: the process
    /// count's word, and the program blamed for the CPU or for the memory. The fields with no shape
    /// of their own are drawn as one sentence at one weight
    /// (`SessionCardView.sessionFootprint`), so an aside on them would be a second brightness
    /// nothing reads - which is why the named disk writer is a word inside its own sentence instead.
    var aside: String?
    var alert = false
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

    /// What the tree is holding, which is the number the card shows. Tally's own excluded, on the
    /// terms above: memory is an instant rather than an interval, so nothing has to survive a
    /// process ending and the pid test is the whole of it.
    ///
    /// SHARED PAGES ARE COUNTED ONCE PER PROCESS THAT MAPS THEM: eight node processes sharing a
    /// runtime each carry it in their own footprint, so this sum is larger than what killing the
    /// tree would hand the machine back. Activity Monitor's per-process column adds up exactly the
    /// same way, and as an answer to "which session is the heavy one", which is all the card claims,
    /// it is the right kind of wrong.
    var memoryBytes: UInt64 {
        memory.reduce(0) { $0 + (ours.contains($1.key) ? 0 : $1.value) }
    }
}

/// What a pair of readings says about CPU: the percentage, who to blame for it, and the credit this
/// pair could not settle (see `cpuPercent`).
struct ProcessCPUReading: Equatable {
    var percent: Double?
    var carry: Double = 0
    var leader: pid_t?
}

/// What a pair of readings says about disk writing: the rate and who to blame for it.
struct ProcessDiskReading: Equatable {
    var bytesPerSecond: Double?
    var leader: pid_t?
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
    static func members(root: pid_t, processes: [ProcessIdentity]) -> Set<pid_t> {
        guard let leader = processes.first(where: { $0.pid == root }) else { return [] }
        var found: Set<pid_t> = [root]
        if leader.group == root {
            for process in processes where process.group == root { found.insert(process.pid) }
        }
        var children: [pid_t: [pid_t]] = [:]
        for process in processes where process.pid != process.parent {
            children[process.parent, default: []].append(process.pid)
        }
        // Seeded with the job as well as the root, so descent continues from the orphan too: a
        // server re-parented to launchd goes on spawning children of its own, and those are as much
        // the session's as it is.
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

    /// What share of one core the tree spent between two readings, as a percentage, or nil when the
    /// pair cannot say: no elapsed time, or no earlier reading at all (the first tick after a panel
    /// opens is exactly that, and it draws no CPU segment rather than a zero).
    ///
    /// THREE TERMS, and the second two exist because a session's work is mostly processes that are
    /// born and buried between two ticks:
    ///
    ///   - What the processes still here have spent since the last reading. A pid the earlier
    ///     reading never saw counts everything it has spent, because it did not exist before that
    ///     instant. A reading that went backwards counts as nothing: the only way that happens is
    ///     the number naming a different process now, and a negative is not a measurement.
    ///   - What their REAPED CHILDREN spent, which is the same difference taken over the kernel's
    ///     child counters. This is the whole of a short command's cost: `yes` burning half a core
    ///     for half a second between two ticks was reported as 0.007% before this term existed
    ///     (measured 2026-08-15), because no sample ever saw it alive.
    ///   - MINUS what the processes that have GONE had already been counted for. A child's whole
    ///     life lands in its parent's counter at the instant it is collected, and the part of that
    ///     life before the previous reading was counted then, as its own. Both of its counters come
    ///     off: the child counter too, or the work of a grandchild it had itself already buried
    ///     would be counted once when it collected it and again when it was collected.
    ///
    /// Clamped at zero as a whole, for the two windows where a subtraction has no counter to answer
    /// it: a process that has died and not yet been collected, and one whose collector is outside
    /// the tree (an orphan is buried by launchd, whose counters are nobody's business here). Both
    /// read low for a tick rather than negative, which is the honest price of never double counting
    /// the ordinary case, where the collector is the parent standing right there in the tree.
    ///
    /// AND THE UNSETTLED PART OF THAT SUBTRACTION SURVIVES THE TICK, which is the whole reason this
    /// returns a carry rather than a number. Death and collection are two events, and nothing makes
    /// them land in the same interval: a child that died just before a reading is collected just
    /// after it, so its credit is taken off a tick that has nothing to take it off (clamped to zero,
    /// costing nothing) and its whole life then arrives in the parent's child counter on the NEXT
    /// one, where it is counted a second time. Measured as a single tick reading several hundred
    /// percent for work that was already reported while the child was alive. Handed back and applied
    /// to the next pair, the arrival meets the credit and cancels.
    ///
    /// THE CARRY SURVIVES EXACTLY ONE TICK, and the bound is not tidiness. A credit that nothing
    /// will ever settle is entirely possible - an orphan is collected by launchd, so the seconds it
    /// spent never arrive in any counter this tree can read - and an unbounded carry would then
    /// silently suppress that many seconds of REAL work, which is a worse lie than the spike it was
    /// added to prevent, and a quieter one. So only what departed in THIS interval is handed on;
    /// whatever the previous tick handed in and could not be spent is written off.
    ///
    /// AND TALLY'S OWN ARE IN THE SAMPLE BUT NOT IN THE ANSWER, which is the one asymmetry here that
    /// is not about time. They contribute no work and no arrivals - a card measuring the meter is
    /// the defect `ownFamily` exists for - but every departure counts, theirs included, and that is
    /// the whole repair: a Tally hook that ends between two ticks has its life folded into the
    /// counters of whoever collected it, which is Claude Code, so its seconds arrive on a process
    /// this card IS measuring. Sampled, it departs and the credit cancels the arrival; filtered out
    /// by pid before the sample, it was never in either reading, never departed, and the arrival
    /// stood as session work. (`ProcessResourceSample.ours` carries the measurement.)
    ///
    /// WHAT THAT STILL DOES NOT REACH, said rather than implied: one of ours BORN AND ENDED inside a
    /// single interval appears in neither reading, so there is nothing to depart and its seconds
    /// stay on the collector. Nothing measured from outside the process can see it - the honest
    /// bound is the sampling interval, and closing it would mean Tally's own processes writing down
    /// what they spent as they exit.
    ///
    /// - Parameter carry: what the previous pair could not settle, in seconds. Zero for the first
    ///   pair of a session, and the reason the store keeps one number per session.
    static func cpuPercent(from previous: ProcessResourceSample?, to current: ProcessResourceSample,
                           carry: Double = 0) -> ProcessCPUReading {
        guard let previous else { return ProcessCPUReading(percent: nil) }
        // Per pid rather than one running total, because the same pass has to answer two questions:
        // what the tree burned, and whether one process burned most of it. And OWN WORK IS KEPT
        // APART FROM ARRIVALS, which the blame below depends on: the kernel credits a reaped child
        // to whoever collected it, so a shell that ran the build is named for the build - but the
        // very same counter is where a life ALREADY COUNTED lands when it is finally collected, and
        // those two are the same number until they are held separately.
        var own: [pid_t: Double] = [:]
        var arrived: [pid_t: Double] = [:]
        // Ours are read and then left out of both, which is what makes the departure below able to
        // cancel what one of them left in somebody else's counter (see the note above).
        for (pid, time) in current.times where !current.ours.contains(pid) {
            let mine = max(0, time - (previous.times[pid] ?? 0))
            let buried = max(0, (current.childTimes[pid] ?? 0) - (previous.childTimes[pid] ?? 0))
            // Absent rather than zero, so an idle pid is not a candidate for the blame below.
            if mine > 0 { own[pid] = mine }
            if buried > 0 { arrived[pid] = buried }
        }
        // EVERY departure, ours included: what one of ours was counted for is exactly what has just
        // landed on whoever collected it, and the tick that sees it go is the tick that has to take
        // it off. Judged on the CURRENT reading's answer to who is ours, so a pid is treated the
        // same way on the tick it leaves as on the tick before it.
        var departed = 0.0
        for (pid, time) in previous.times where current.times[pid] == nil {
            departed += time + (previous.childTimes[pid] ?? 0)
        }
        let elapsed = current.at.timeIntervalSince(previous.at)
        // Two readings at the same instant say nothing about a rate, but a departure between them
        // is still a departure: its credit goes forward rather than being lost with the pair.
        guard elapsed > 0 else { return ProcessCPUReading(percent: nil, carry: carry + departed) }
        let arrivals = arrived.values.reduce(0, +)
        let net = own.values.reduce(0, +) + arrivals - carry - departed
        return ProcessCPUReading(percent: max(0, net) / elapsed * 100,
                                 carry: net < 0 ? min(-net, departed) : 0,
                                 leader: net > 0 ? leader(of: blame(own: own, collected: arrived,
                                                                   settling: carry + departed))
                                                 : nil)
    }

    /// WHO IS ACTUALLY DOING THE WORK THIS TICK, which is not the same question as how much work the
    /// tick holds, and the difference is exactly the credit being cancelled.
    ///
    /// A departure's credit cancels an ARRIVAL: the seconds coming off are seconds that were counted
    /// while the child was alive and are now landing in whoever collected it. Left in, they name the
    /// collector - so a parent that reaped a hundred-second child would be blamed for a hundred
    /// seconds it did not spend, over a process beside it that really did spend one (measured as
    /// `percent=50, leader=<the collector>` before this existed). Taking the same seconds off the
    /// arrivals they are cancelling leaves the tick naming the process that actually burned it.
    ///
    /// SHARED OUT IN PROPORTION, because the kernel does not say which collector got which child:
    /// `ri_child_time` is one folded total per process, and the credit is a sum over everything that
    /// left. Proportion is the honest reading of "somewhere in these arrivals", and it degrades the
    /// way it should - a single collector takes the whole cancellation, and a tick with no arrivals
    /// at all cancels nothing here (the seconds still come off the percentage, where they belong,
    /// and the blame is decided on own work alone).
    private static func blame(own: [pid_t: Double], collected: [pid_t: Double],
                              settling credit: Double) -> [pid_t: Double] {
        // Summed here rather than taken as an argument: the caller has the same total for the
        // percentage, and a number that can be passed in is a number that can be passed in stale.
        let arrivals = collected.values.reduce(0, +)
        guard arrivals > 0 else { return own }
        let kept = 1 - min(credit, arrivals) / arrivals
        var blamed = own
        for (pid, seconds) in collected where seconds * kept > 0 {
            blamed[pid, default: 0] += seconds * kept
        }
        return blamed
    }

    /// How fast the tree is writing to disk between two readings, and which process is doing it, or
    /// nothing when the pair cannot say.
    ///
    /// SHORT WRITERS ARE MISSED AND THAT IS THE WHOLE DIFFERENCE FROM CPU. The kernel keeps no
    /// child counterpart of `ri_diskio_byteswritten`, so a command that starts, writes and finishes
    /// between two ticks takes its bytes with it: there is nowhere for them to arrive. A departed
    /// pid is therefore simply dropped - no credit, no carry, no double counting to prevent - and
    /// the reading is an undercount of exactly that traffic. Which is tolerable for what this is
    /// for: the runaway this segment exists to catch (a log loop, a watcher rewriting a bundle) is
    /// long-lived by definition, and short commands write in kilobytes.
    ///
    /// THE SAME ABSENCE IS WHY TALLY'S OWN NEED NOTHING BUT A PID TEST HERE, where the CPU needed a
    /// departure to cancel an arrival. `rusage_info_v6` carries `ri_child_user_time`,
    /// `ri_child_system_time`, `ri_child_pkg_idle_wkups`, `ri_child_interrupt_wkups`,
    /// `ri_child_pageins` and `ri_child_elapsed_abstime`, and NO child counterpart of either disk
    /// counter (read off the SDK header, 2026-08-15). Nothing one of ours wrote can arrive on a
    /// process the card is measuring, so leaving it out of the sum leaves it out entirely.
    static func diskWrite(from previous: ProcessResourceSample?,
                          to current: ProcessResourceSample) -> ProcessDiskReading {
        guard let previous else { return ProcessDiskReading(bytesPerSecond: nil) }
        let elapsed = current.at.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return ProcessDiskReading(bytesPerSecond: nil) }
        // Double before the subtraction: these are unsigned counters, and a pid whose number now
        // names a different process reads backwards - which would trap rather than clamp.
        var written: [pid_t: Double] = [:]
        for (pid, bytes) in current.diskWritten where !current.ours.contains(pid) {
            let delta = Double(bytes) - Double(previous.diskWritten[pid] ?? 0)
            if delta > 0 { written[pid] = delta }
        }
        return ProcessDiskReading(bytesPerSecond: written.values.reduce(0, +) / elapsed,
                                  leader: leader(of: written))
    }

    /// Which single pid accounts for MORE THAN HALF of a set of contributions, or nobody.
    ///
    /// HALF IS NOT ENOUGH, ON PURPOSE. A name beside a number is a claim that one thing is doing
    /// this, and two processes at exactly half each make that claim false about both of them; the
    /// line says nothing rather than picking whichever the dictionary handed over first.
    static func leader(of contributions: [pid_t: Double]) -> pid_t? {
        let total = contributions.values.reduce(0, +)
        guard total > 0, let top = contributions.max(by: { $0.value < $1.value }),
              top.value > total / 2
        else { return nil }
        return top.key
    }
}
