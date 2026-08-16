import Darwin
import Foundation

/// THE THREE THINGS THE MACHINE IS ASKED, for the session footprint the file next door reasons
/// about (`ProcessTreeStats.swift`): who is alive and whose job they belong to, what each of them
/// has used, and what they are listening on. Plus the one string a number needs to mean something,
/// which is what to call a process.
///
/// SPLIT FROM THE RULES RATHER THAN FROM EACH OTHER. Everything here is a libproc call with no
/// decision in it, answering "nothing" rather than throwing when a process has ended or belongs to
/// somebody else; everything there is arithmetic an assertion harness can state with no processes
/// around it. One exception is asserted rather than trusted, because the trap is silent and
/// hardware-specific: what UNIT the CPU counters are in (`seconds`).
///
/// NATIVE, NEVER A SHELL. `lsof` and `ps` are a fork, an exec and a parse per tick for readings
/// libproc hands over directly, and this samples while a panel is open.
extension ProcessTree {

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

    /// Everything the card's numbers are made of, for each of these pids: the cumulative CPU seconds
    /// it has spent, the same for the children it has already buried, what it is holding in memory
    /// and what it has written to disk. ONE CALL PER PROCESS - all four counters come out of the
    /// same `rusage_info` record, so the memory and disk segments cost the tree walk nothing extra.
    ///
    /// A pid that cannot be read is left out, which is what makes the differences above skip it
    /// rather than count its absence as work.
    ///
    /// - Parameter ours: which of these pids are Tally's own. THE WHOLE TREE IS READ, ours included,
    ///   and each number decides for itself what to do with them - not because the meter belongs in
    ///   the reading, but because a process that is never sampled can never be seen to LEAVE, and
    ///   leaving is what cancels the seconds it hands to its collector
    ///   (`ProcessResourceSample.ours`).
    static func resourceSample(of pids: some Sequence<pid_t>, ours: Set<pid_t> = [],
                               at now: Date = Date()) -> ProcessResourceSample {
        var times: [pid_t: Double] = [:]
        var childTimes: [pid_t: Double] = [:]
        var memory: [pid_t: UInt64] = [:]
        var diskWritten: [pid_t: UInt64] = [:]
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
            // Bytes, not mach units: only the two CPU counters are in the timebase (see `seconds`).
            memory[pid] = info.ri_phys_footprint
            diskWritten[pid] = info.ri_diskio_byteswritten
        }
        // Narrowed to what was actually read, so a pid that would not answer is not carried here as
        // one of ours either: the two lists then describe the same set of processes.
        return ProcessResourceSample(times: times, childTimes: childTimes, memory: memory,
                                     diskWritten: diskWritten, at: now,
                                     ours: ours.filter { times[$0] != nil })
    }

    /// The program each of these pids is running. ONE PASS FOR THE WHOLE TREE, because the tick
    /// needs the same answer twice: to tell Tally's own processes from the session's work
    /// (`ownFamily`) and to put a name beside the number (`displayName`). Asking twice would be two
    /// calls per process per tick for one string.
    ///
    /// A pid that will not answer is simply absent, which is what makes both readers above treat it
    /// as "cannot say" rather than as a program called "".
    static func executablePaths(of pids: some Sequence<pid_t>) -> [pid_t: String] {
        var paths: [pid_t: String] = [:]
        for pid in pids { paths[pid] = executablePath(of: pid) }
        return paths
    }

    /// The path of the program one pid is running (the rule for turning that path into a NAME is
    /// next door, `ProcessTree.displayName`).
    ///
    /// `proc_pidpath` RATHER THAN `proc_name`, whose answer is truncated to fifteen characters -
    /// which is a limit the names this is for sit right on top of ("next-server", "esbuild",
    /// "node") - and which is the same truncation for a program installed under a version number,
    /// leaving nothing to walk up from. It is also the only one of the two that can be compared
    /// with another process's, which is the whole of how `ownFamily` decides anything.
    ///
    /// NOTHING RATHER THAN A GUESS when the process is gone, which is ordinary here rather than an
    /// error: the culprit of an interval can be a command that finished inside it, and the card
    /// simply shows the number with no name beside it.
    static func executablePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` itself does not survive the import into Swift, and it is
        // defined as four path lengths - which is the size `proc_pidpath` documents as required.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(PATH_MAX))
        // The call returns how many bytes it wrote, which is what the path is decoded from: the
        // rest of the buffer is zeros, and decoding those too would put them in the string.
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(written)), as: UTF8.self)
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

    /// The TCP ports these processes are LISTENING on, each with the process holding it. Not
    /// connections: a session talking to an API has a socket per request and none of them is a fact
    /// about the machine, while a port being held is the thing that makes the next `pnpm dev` fail.
    ///
    /// THE PID COMES BACK WITH THE PORT, which it did not use to: the walk knows whose descriptor
    /// table it is reading and threw that away, so the card could say a port was taken and never by
    /// what. It costs nothing to carry - the pid is the loop variable - and the one decision it
    /// needs (a port two processes share) is a pure rule next door (`ProcessTree.holders`).
    ///
    /// The most expensive reading here by far - a descriptor table per process, then a call per
    /// socket - which is why it is sampled at its own slower cadence (`ProcessFootprintStore`).
    static func listeningPorts(of pids: some Sequence<pid_t>) -> [UInt16: pid_t] {
        var found: [(port: UInt16, pid: pid_t)] = []
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
                found.append((port: UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)), pid: pid))
            }
        }
        return holders(of: found)
    }
}
