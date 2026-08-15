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
    /// How many live processes the tree holds, the supervisor itself included.
    var processes: Int
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
    var memoryBytes: UInt64 = 0
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
    enum Kind: Equatable { case processes, cpu, memory, disk, ports }
    var kind: Kind
    var text: String
    var alert = false
}

/// A live process as this file identifies it: itself, who started it, and which job it belongs to.
///
/// THE GROUP IS THE ONE THAT SURVIVES, which is the whole reason it is carried (see `members`).
struct ProcessIdentity: Equatable {
    var pid: pid_t
    var parent: pid_t
    /// The process group id: the pid of the job's leader, inherited by everything the job spawns and
    /// unchanged by the parent dying.
    var group: pid_t
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

    /// What the tree is holding, which is the number the card shows.
    ///
    /// SHARED PAGES ARE COUNTED ONCE PER PROCESS THAT MAPS THEM: eight node processes sharing a
    /// runtime each carry it in their own footprint, so this sum is larger than what killing the
    /// tree would hand the machine back. Activity Monitor's per-process column adds up exactly the
    /// same way, and as an answer to "which session is the heavy one", which is all the card claims,
    /// it is the right kind of wrong.
    var memoryBytes: UInt64 { memory.values.reduce(0, +) }
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
        for (pid, time) in current.times {
            let mine = max(0, time - (previous.times[pid] ?? 0))
            let buried = max(0, (current.childTimes[pid] ?? 0) - (previous.childTimes[pid] ?? 0))
            // Absent rather than zero, so an idle pid is not a candidate for the blame below.
            if mine > 0 { own[pid] = mine }
            if buried > 0 { arrived[pid] = buried }
        }
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
    static func diskWrite(from previous: ProcessResourceSample?,
                          to current: ProcessResourceSample) -> ProcessDiskReading {
        guard let previous else { return ProcessDiskReading(bytesPerSecond: nil) }
        let elapsed = current.at.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return ProcessDiskReading(bytesPerSecond: nil) }
        // Double before the subtraction: these are unsigned counters, and a pid whose number now
        // names a different process reads backwards - which would trap rather than clamp.
        var written: [pid_t: Double] = [:]
        for (pid, bytes) in current.diskWritten {
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

    /// What to call a process, given the path of the program it is running.
    ///
    /// THE LAST COMPONENT IS THE NAME, EXCEPT WHEN IT IS A VERSION NUMBER, and that exception is
    /// not an edge case here: Claude Code installs itself as
    /// `~/.local/share/claude/versions/2.1.233`, where the executable FILE is the version, so the
    /// one process this line most often has to name would be printed as "40% CPU (2.1.233)"
    /// (measured on this machine, 2026-08-15). A version is not a name, so the walk continues up
    /// through the installer's own container words until something that names a program appears.
    ///
    /// AN ORDINARY NAME IS NEVER WALKED PAST, because the walk only starts on a version: `bin` and
    /// `versions` are stepped over on the way up and never used to reject a name a program actually
    /// has (`/opt/homebrew/Cellar/uv/0.9.2/bin/uv` is `uv`, and `python3.12` keeps its digits
    /// because letters make it a name rather than a number).
    static func displayName(forPath path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        guard var name = parts.popLast() else { return nil }
        while isVersionNumber(name) || installerContainers.contains(name.lowercased()) {
            guard let next = parts.popLast() else { return nil }
            name = next
        }
        return name
    }

    /// The directories an installer puts a versioned build in, which name nothing on their own.
    /// Both are ones this machine actually holds a program under (measured 2026-08-15).
    private static let installerContainers: Set<String> = ["versions", "bin"]

    /// Digits and dots, optionally led by a `v`: `2.1.233`, `v20.11.0`. Anything with a letter in
    /// it is a name that happens to carry a number, which is most of the interpreters on a machine.
    private static func isVersionNumber(_ name: String) -> Bool {
        var digits = Substring(name)
        if digits.hasPrefix("v") { digits = digits.dropFirst() }
        return digits.contains(where: \.isNumber) && digits.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// The card's line: how many processes, what they are burning, what they are holding, what they
    /// are writing and what they are listening on.
    ///
    /// EVERY SEGMENT IS OPTIONAL AND THE SEPARATOR FOLLOWS, which is the rule the identity line one
    /// file over already follows (`SessionRow`): a session with no ports says nothing about ports
    /// rather than printing an empty field, and a tree that has not been read twice yet leaves the
    /// CPU out until it has. A tree with no processes has no line at all.
    ///
    /// DISK APPEARS ONLY WHEN IT IS A FACT ABOUT THE SESSION. Every process writes something, and a
    /// card that carried "0 MB/s" on every session all day would be spending a fifth of its one
    /// line saying nothing. Past a megabyte a second it is the answer to a question somebody is
    /// actually asking - which of these is filling my disk - so that is where it becomes visible.
    ///
    /// ONE NAME PER LINE, AND DISK TAKES IT. Both blamed segments can have a culprit at once, and
    /// two parentheticals is what turns a line into a paragraph on a card one line wide. Disk wins
    /// because it is the rarer sighting: the CPU segment is on every card, while a session writing
    /// megabytes a second is the anomaly somebody opened the panel to find. Memory carries no name
    /// at all - what holds memory persistently is the long-lived process the count and the ports
    /// already point at.
    ///
    /// - Parameters:
    ///   - unit: the word for "processes", already localised, so this stays a pure function of what
    ///     it is handed (the harness compiles it with no bundle around it) and the caller keeps the
    ///     one decision a word carries: whether it is the plural.
    ///   - maxPorts: how many ports are named before the rest become a count. A card is one line
    ///     wide and a dev box can hold a dozen ports; three is what fits beside the other two
    ///     segments at the panel's narrowest column.
    static func line(_ footprint: ProcessFootprint, unit: String, maxPorts: Int = 3) -> String? {
        let parts = segments(footprint, unit: unit, maxPorts: maxPorts)
        guard !parts.isEmpty else { return nil }
        return parts.map(\.text).joined(separator: pickEffortSeparator)
    }

    /// The same line in the pieces it is drawn from, each saying what it is and whether it is a
    /// warning. `line` is these joined, and stays the sentence a reader hears.
    ///
    /// A WARNING COMES FORWARD, AND THE ORDER MOVING IS THE POINT. A card is 182pt of content at
    /// the panel's narrowest and the line is truncated at its tail, so a full line does not fit:
    /// measured (2026-08-15) at 11pt, `4 procs · 100% CPU · 3.9 GB · ` alone is 165.6pt and the
    /// whole sentence with a warned disk segment is 312.9pt. Left in reading order the warning's
    /// mark survives and its NUMBER does not - a triangle stranded beside the memory figure, which
    /// reads as a warning about the memory and gives no reason for either. So the warned fields are
    /// drawn first and the healthy ones are what falls off the end, which is the right thing to
    /// lose: those are the ones nobody opened the panel for.
    ///
    /// THE COUNT STAYS AT THE FRONT REGARDLESS, because it is not a reading in the same sense - it
    /// is the context every other field is about ("12 MB/s" means something different under 2
    /// processes than under 40), and a line that opened on a warning would say what is wrong before
    /// saying what it is wrong about. Everything else keeps its reading order inside its group, so
    /// a card only ever reorders across the warning line, never within it.
    static func segments(_ footprint: ProcessFootprint, unit: String,
                         maxPorts: Int = 3) -> [ProcessFootprintSegment] {
        guard footprint.processes > 0 else { return [] }
        var parts = [ProcessFootprintSegment(kind: .processes,
                                             text: "\(footprint.processes) \(unit)")]
        // Decided before the CPU segment is built, because whether disk is on the line at all is
        // what decides which segment gets to carry a name.
        let disk = footprint.diskWriteBytesPerSecond.flatMap(diskRateText)
        let diskName = disk == nil ? nil : footprint.diskLeader
        // Rounded to whole points: the reading is a difference of two samples taken about two
        // seconds apart, and decimals on it would be spelling out noise.
        if let cpu = footprint.cpuPercent {
            parts.append(.init(kind: .cpu,
                               text: blamed("\(Int(cpu.rounded()))% CPU",
                                            on: diskName == nil ? footprint.cpuLeader : nil),
                               alert: footprint.alerts.cpu))
        }
        if let memory = memoryText(footprint.memoryBytes) {
            parts.append(.init(kind: .memory, text: memory, alert: footprint.alerts.memory))
        }
        if let disk {
            parts.append(.init(kind: .disk, text: blamed(disk, on: diskName),
                               alert: footprint.alerts.disk))
        }
        if !footprint.listeningPorts.isEmpty {
            let named = footprint.listeningPorts.prefix(maxPorts).map { ":\($0)" }
            let rest = footprint.listeningPorts.count - named.count
            parts.append(.init(kind: .ports,
                               text: (named + (rest > 0 ? ["+\(rest)"] : [])).joined(separator: " ")))
        }
        // Built in reading order above and reordered here in one place, so every field is written
        // where it belongs in the sentence and only one rule decides what a narrow card keeps.
        let readings = parts.dropFirst()
        return Array(parts.prefix(1)) + readings.filter(\.alert) + readings.filter { !$0.alert }
    }

    private static func blamed(_ segment: String, on name: String?) -> String {
        guard let name else { return segment }
        return "\(segment) (\(name))"
    }

    /// What the tree is holding, in the units a Mac states memory in: DECIMAL, because that is what
    /// Activity Monitor and every spec sheet the number will be compared against use. Whole
    /// megabytes below a gigabyte and one decimal above it, so the segment is four characters wide
    /// either way and a card's line does not reflow as a session grows.
    ///
    /// Under a megabyte is nothing rather than "0 MB": either the tree is a single sleeping shell,
    /// or nothing could be read at all, and neither is worth a segment.
    private static func memoryText(_ bytes: UInt64) -> String? {
        let megabytes = (Double(bytes) / 1_000_000).rounded()
        guard megabytes >= 1 else { return nil }
        // Decided on the rounded number, so 999.7 MB prints as 1.0 GB rather than as "1000 MB".
        guard megabytes >= 1000 else { return "\(Int(megabytes)) MB" }
        return String(format: "%.1f GB", megabytes / 1000)
    }

    /// Where writing becomes a fact about the session rather than the background noise every
    /// process makes: a megabyte a second (see `line`). The warning rules count from the same
    /// number, so "the segment is visible" and "the segment is worth watching" cannot drift apart.
    static let diskFloor: Double = 1_000_000

    /// The write rate, or nothing below the threshold the segment exists above (see `line`).
    private static func diskRateText(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond >= diskFloor else { return nil }
        return "\(Int((bytesPerSecond / 1_000_000).rounded())) MB/s"
    }
}
