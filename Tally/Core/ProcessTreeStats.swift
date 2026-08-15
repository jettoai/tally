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
/// PURE WHERE IT CAN BE, so the parts a card actually depends on can be stated in an assertion
/// harness with no processes around them: which pids belong to a tree, what two cumulative CPU
/// readings mean, and how the line reads when a segment has nothing to say. What is left is three
/// thin libproc wrappers, each of which answers "nothing" rather than throwing when a process has
/// ended or belongs to somebody else.
///
/// NATIVE, NEVER A SHELL. `lsof` and `ps` are a fork, an exec and a parse per tick for readings
/// libproc hands over directly, and this samples while a panel is open.
struct ProcessFootprint: Equatable {
    /// How many live processes the tree holds, the supervisor itself included.
    var processes: Int
    /// The tree's share of one core over the last interval, or nil when there is no interval yet:
    /// a cumulative counter says nothing until it has been read twice.
    var cpuPercent: Double?
    /// The TCP ports the tree is listening on, ascending. A dev server is the reason this is on the
    /// card at all: it is the one thing a session leaves behind that another session then collides
    /// with, and it is invisible everywhere else in this app.
    var listeningPorts: [UInt16]
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

/// One reading of the tree's cumulative CPU time, per pid, and the instant it was taken.
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
struct ProcessCPUSample: Equatable {
    /// Cumulative CPU seconds each process has spent on its own behalf.
    var times: [pid_t: Double]
    /// Cumulative CPU seconds each process's REAPED children spent, which the kernel folds into the
    /// parent at the moment it collects them (and which itself already includes what those children
    /// had folded in from their own).
    var childTimes: [pid_t: Double]
    var at: Date
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
    static func cpuPercent(from previous: ProcessCPUSample?, to current: ProcessCPUSample) -> Double? {
        guard let previous else { return nil }
        let elapsed = current.at.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return nil }
        var busy = 0.0
        for (pid, spent) in current.times {
            busy += max(0, spent - (previous.times[pid] ?? 0))
            busy += max(0, (current.childTimes[pid] ?? 0) - (previous.childTimes[pid] ?? 0))
        }
        for (pid, spent) in previous.times where current.times[pid] == nil {
            busy -= spent + (previous.childTimes[pid] ?? 0)
        }
        return max(0, busy) / elapsed * 100
    }

    /// The card's line: how many processes, what they are burning, and what they are listening on.
    ///
    /// EVERY SEGMENT IS OPTIONAL AND THE SEPARATOR FOLLOWS, which is the rule the identity line one
    /// file over already follows (`SessionRow`): a session with no ports says nothing about ports
    /// rather than printing an empty field, and a tree that has not been read twice yet leaves the
    /// CPU out until it has. A tree with no processes has no line at all.
    ///
    /// - Parameters:
    ///   - unit: the word for "processes", already localised, so this stays a pure function of what
    ///     it is handed (the harness compiles it with no bundle around it) and the caller keeps the
    ///     one decision a word carries: whether it is the plural.
    ///   - maxPorts: how many ports are named before the rest become a count. A card is one line
    ///     wide and a dev box can hold a dozen ports; three is what fits beside the other two
    ///     segments at the panel's narrowest column.
    static func line(_ footprint: ProcessFootprint, unit: String, maxPorts: Int = 3) -> String? {
        guard footprint.processes > 0 else { return nil }
        var parts = ["\(footprint.processes) \(unit)"]
        // Rounded to whole points: the reading is a difference of two samples taken about two
        // seconds apart, and decimals on it would be spelling out noise.
        if let cpu = footprint.cpuPercent { parts.append("\(Int(cpu.rounded()))% CPU") }
        if !footprint.listeningPorts.isEmpty {
            let named = footprint.listeningPorts.prefix(maxPorts).map { ":\($0)" }
            let rest = footprint.listeningPorts.count - named.count
            parts.append((named + (rest > 0 ? ["+\(rest)"] : [])).joined(separator: " "))
        }
        return parts.joined(separator: pickEffortSeparator)
    }

    // MARK: What the machine says

    /// Every live process this user can inspect, with its parent and its job. One pass, because
    /// every card on the board reads the same table and asking per session would be one full scan
    /// per card. Both identities come out of the same record, so the job costs nothing to carry.
    ///
    /// The second `proc_listallpids` returns a COUNT of pids and not the byte count its argument is
    /// given in - dividing it by the pid size ends the walk a quarter of the way through the machine
    /// and hides every process past that point (measured 2026-07-25, `scannedPidCount` in the CLI
    /// carries the same note against the same trap). Clamped to the buffer because processes started
    /// between the sizing call and the fill can push the count past it.
    static func liveProcesses() -> [ProcessIdentity] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let returned = proc_listallpids(&pids, Int32(Int(capacity) * MemoryLayout<pid_t>.size))
        guard returned > 0 else { return [] }
        var processes: [ProcessIdentity] = []
        for pid in pids.prefix(min(Int(returned), pids.count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // A process that ended between the listing and this call, or one belonging to another
            // user, simply is not in the list: it can be nobody's descendant here either way.
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            processes.append(ProcessIdentity(pid: pid, parent: pid_t(info.pbi_ppid),
                                             group: pid_t(info.pbi_pgid)))
        }
        return processes
    }

    /// The cumulative CPU seconds each of these pids has spent, user and system together, and the
    /// same for the children it has already buried. A pid that cannot be read is left out, which is
    /// what makes the difference above skip it rather than count its absence as work.
    static func cpuSample(of pids: some Sequence<pid_t>, at now: Date = Date()) -> ProcessCPUSample {
        var times: [pid_t: Double] = [:]
        var childTimes: [pid_t: Double] = [:]
        for pid in pids {
            var info = rusage_info_current()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard rc == 0 else { continue }
            times[pid] = seconds(info.ri_user_time + info.ri_system_time)
            childTimes[pid] = seconds(info.ri_child_user_time + info.ri_child_system_time)
        }
        return ProcessCPUSample(times: times, childTimes: childTimes, at: now)
    }

    /// A `rusage_info` CPU counter in seconds.
    ///
    /// THE COUNTERS ARE MACH ABSOLUTE TIME, NOT NANOSECONDS, and on this hardware those are not the
    /// same thing: the timebase is 125/3, so a tick is about 41.67ns and reading the raw number as
    /// nanoseconds reports a twenty-fourth of the truth. Measured against `getrusage` as an
    /// independent oracle (2026-08-15): a process burning a known 0.300s carried 7,210,935 units,
    /// which is 0.007s read as nanoseconds and 0.300s read as the timebase says. Both the process's
    /// own counters and its children's are in these units.
    ///
    /// The timebase is a property of the machine, so it is asked for once. On Intel it is 1/1, which
    /// is exactly why reading these as nanoseconds looks correct until somebody runs it on an Apple
    /// Silicon Mac - and why the arithmetic must not be written as if the divide were free.
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    private static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * timebase / 1_000_000_000
    }

    /// The TCP ports these processes are LISTENING on, ascending and deduplicated. Not connections:
    /// a session talking to an API has a socket per request and none of them is a fact about the
    /// machine, while a port being held is the thing that makes the next `pnpm dev` fail.
    ///
    /// The most expensive reading here by far - a descriptor table per process, then a call per
    /// socket - which is why it is sampled at its own slower cadence (`ProcessFootprintStore`).
    static func listeningPorts(of pids: some Sequence<pid_t>) -> [UInt16] {
        var ports: Set<UInt16> = []
        for pid in pids {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
            let returned = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors,
                                        Int32(descriptors.count * stride))
            guard returned > 0 else { continue }
            for descriptor in descriptors.prefix(min(Int(returned) / stride, descriptors.count))
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var socket = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO,
                                     &socket, size) == size,
                      socket.psi.soi_kind == SOCKINFO_TCP,
                      socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
                else { continue }
                // The local port is carried in network byte order inside a wider field.
                let raw = socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
                let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
                if port > 0 { ports.insert(port) }
            }
        }
        return ports.sorted()
    }
}
