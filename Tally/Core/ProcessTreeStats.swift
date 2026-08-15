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

/// One reading of the tree's cumulative CPU time, per pid, and the instant it was taken.
///
/// PER PID RATHER THAN ONE TOTAL, which is what makes the difference between two of them honest:
/// a total drops when any process in the tree exits, so a tree total differenced against the next
/// one would read as negative work every time a shell finished. Held per pid, an exit simply stops
/// contributing and a process born inside the interval contributes what it has spent, which is all
/// of it by definition.
struct ProcessCPUSample: Equatable {
    var times: [pid_t: Double]
    var at: Date
}

enum ProcessTree {

    // MARK: The pure rules

    /// Every pid in the tree rooted at `root`, the root included, given each live pid's parent.
    ///
    /// A ROOT THAT IS NOT LIVE HAS NO TREE, and that is an ordinary answer rather than an error: the
    /// board draws a card for a session the scan found a moment ago, and the supervisor can be gone
    /// by the time this runs. Nothing is drawn for it rather than a "0 procs" that would read as a
    /// measurement.
    ///
    /// Walked from the parent map rather than recursively per pid, so one pass over the process
    /// table serves every card on the board. The visited set is not decoration: pid numbers are
    /// reused, and a parent chain that loops back on itself would otherwise spin here forever.
    static func members(root: pid_t, parents: [pid_t: pid_t]) -> Set<pid_t> {
        guard parents[root] != nil else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents where pid != parent { children[parent, default: []].append(pid) }
        var found: Set<pid_t> = [root]
        var frontier = [root]
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
    /// Summed over the LATER reading's pids, each against its own earlier value: a pid the earlier
    /// reading never saw counts everything it has spent, because it did not exist before that
    /// instant. A reading that went backwards counts as nothing - the only way that happens is the
    /// number being about a different process that has taken the pid, and a negative is not a
    /// measurement of anything.
    static func cpuPercent(from previous: ProcessCPUSample?, to current: ProcessCPUSample) -> Double? {
        guard let previous else { return nil }
        let elapsed = current.at.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return nil }
        let busy = current.times.reduce(0.0) { total, entry in
            total + max(0, entry.value - (previous.times[entry.key] ?? 0))
        }
        return busy / elapsed * 100
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

    /// Every live pid this user can inspect, with its parent. One pass, because every card on the
    /// board walks the same table and asking per session would be one full scan per card.
    ///
    /// The second `proc_listallpids` returns a COUNT of pids and not the byte count its argument is
    /// given in - dividing it by the pid size ends the walk a quarter of the way through the machine
    /// and hides every process past that point (measured 2026-07-25, `scannedPidCount` in the CLI
    /// carries the same note against the same trap). Clamped to the buffer because processes started
    /// between the sizing call and the fill can push the count past it.
    static func liveParents() -> [pid_t: pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let returned = proc_listallpids(&pids, Int32(Int(capacity) * MemoryLayout<pid_t>.size))
        guard returned > 0 else { return [:] }
        var parents: [pid_t: pid_t] = [:]
        for pid in pids.prefix(min(Int(returned), pids.count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // A process that ended between the listing and this call, or one belonging to another
            // user, simply is not in the map: it can be nobody's descendant here either way.
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            parents[pid] = pid_t(info.pbi_ppid)
        }
        return parents
    }

    /// The cumulative CPU seconds each of these pids has spent, user and system together. A pid that
    /// cannot be read is left out, which is what makes the difference above skip it rather than
    /// count its absence as work.
    static func cpuSample(of pids: some Sequence<pid_t>, at now: Date = Date()) -> ProcessCPUSample {
        var times: [pid_t: Double] = [:]
        for pid in pids {
            var info = rusage_info_current()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard rc == 0 else { continue }
            // Both fields are nanoseconds of CPU time (`rusage_info_v*`), so the two add up and the
            // scale is the same one the interval below is measured in.
            times[pid] = Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000
        }
        return ProcessCPUSample(times: times, at: now)
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
