import Darwin
import Foundation

/// THE READINGS THE RECLAIM NEEDS AND NOTHING ELSE ON THIS PAGE DOES: whether a person is attached
/// to a process, who is connected to it, and which ports the machine is holding as a whole.
///
/// SPLIT FROM `ProcessTreeReaders.swift` RATHER THAN ADDED TO IT, along the line that file already
/// draws: those three calls run on every tick for every card, and these run only when a reclaim
/// round is being taken (once every five minutes at most, and only where there is something to
/// consider). Keeping them apart keeps the cost of the board honest and keeps the expensive one
/// below - a descriptor table for every process on the machine - from looking like something the
/// sampler does twice a second.
///
/// NO DECISIONS HERE, the same as its neighbour: a process that will not answer is absent rather
/// than defaulted, and what an absence MEANS is a rule next door (`OrphanReclaim.vetoes`, where it
/// means this candidate is never touched).
extension ProcessTree {

    /// Whether a `proc_bsdinfo` record's terminal field names an actual terminal.
    ///
    /// `NODEV` IS `(dev_t)-1`, which arrives here as `UInt32.max` because the field is unsigned; a
    /// process with no controlling terminal reports that. Zero is refused as well: it is not a
    /// device this app has ever seen in the field, and reading it as "terminal attached" would veto
    /// candidates for free while reading it as "none" could let one through, so the safe reading is
    /// the one that keeps the process (this returns false only for values that are certainly not
    /// terminals, and false is what lets a reclaim proceed) - hence zero counts as no terminal and
    /// the veto is earned by a real device number.
    static func attached(terminal device: UInt32) -> Bool {
        device != UInt32.max && device != 0
    }

    /// Whether one pid has a controlling terminal, asked on its own.
    ///
    /// The round already has this for every process it walked (`ProcessIdentity.hasTerminal`); this
    /// is for the ANCESTORS, which are outside the stray set and so outside that walk.
    static func hasTerminal(of pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return attached(terminal: info.e_tdev)
    }

    /// EVERY TCP SOCKET THESE PROCESSES HOLD, listening and connected alike.
    ///
    /// `listeningPorts` NEXT DOOR ANSWERS A DIFFERENT QUESTION and deliberately throws this away:
    /// a card wants to say "this session is holding :3000", and a connection is not a fact about
    /// the machine. The reclaim wants the opposite reading - whether anybody is USING the thing
    /// before it is ended - and a browser holding an HMR socket or a tunnel in front of the server
    /// is exactly the evidence that answers it (`OrphanReclaim.inUse`).
    ///
    /// THE FAR END IS CARRIED AS "IS IT THIS MACHINE" rather than as an address. Everything the rule
    /// needs is whether the peer is local (a browser, a tunnel, another worker) or somewhere else,
    /// and an address is a string this app would then have to be careful about. IPv4 loopback is
    /// `127.0.0.0/8`; IPv6 loopback is `::1`.
    /// AND A PID WHOSE DESCRIPTOR TABLE WOULD NOT BE READ COMES BACK NAMED, rather than as nothing.
    ///
    /// THIS WAS THE THIRD FAIL-OPEN IN THE KILL PATH (codex review, 2026-09-02). "Nobody is
    /// connected to it" and "the machine would not say who is connected to it" were the same empty
    /// list, and the first of those is the reading that lets a tree be ended: one transient
    /// `PROC_PIDLISTFDS` failure and the in-use veto is silently not applied at all. Named instead,
    /// the tree gets `OrphanReclaim.Veto.unreadable` and falls to tier C, which is the direction
    /// every other absence in this feature already fails in.
    ///
    /// `proc_pidinfo` REPORTS FAILURE AS ZERO, NOT AS -1, which is why the errno discipline below is
    /// not defensive noise. Measured on this machine (2026-09-02): the sizing call returns 360 for
    /// this process, and **0 with `errno` set** for launchd (EPERM) and for a pid that has been
    /// reaped (ESRCH). So the return value alone cannot separate "no descriptors" from "would not
    /// say", and the only thing that can is `errno`, cleared before each call. A zero WITH a clean
    /// errno is left as an honest empty reading; in practice a live process holds at least its
    /// standard descriptors, so that branch is close to unreachable and is not treated as failure.
    static func connections(of pids: some Sequence<pid_t>) -> OrphanReclaim.Sockets {
        var found = OrphanReclaim.Sockets()
        for pid in pids {
            errno = 0
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if bytes <= 0 {
                if errno != 0 { found.unreadable.insert(pid) }
                continue
            }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
            errno = 0
            let returned = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors,
                                        Int32(descriptors.count * stride))
            guard returned > 0 else {
                found.unreadable.insert(pid)
                continue
            }
            for descriptor in descriptors.prefix(min(Int(returned) / stride, descriptors.count))
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var socket = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                // A DESCRIPTOR THAT WILL NOT DESCRIBE ITSELF IS NOT A DESCRIPTOR THAT IS NOT A
                // SOCKET. This is the same conflation one level down: the fd was listed as a
                // socket, so a read that fails may be hiding the very connection the veto is
                // looking for. Not being TCP, on the other hand, is a successful reading of
                // something this rule has nothing to say about (a unix socket, a UDP one), and is
                // skipped rather than doubted.
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO,
                                     &socket, size) == size else {
                    found.unreadable.insert(pid)
                    continue
                }
                guard socket.psi.soi_kind == SOCKINFO_TCP else { continue }
                let tcp = socket.psi.soi_proto.pri_tcp
                let state = tcp.tcpsi_state
                let listening = state == TSI_S_LISTEN
                // Anything mid-handshake or mid-teardown is neither: a socket in TIME_WAIT says
                // somebody WAS using this, which is not a reason to keep a tree alive, and one in
                // SYN_SENT says this tree is reaching out, which the rule reads from the connected
                // set anyway once it lands.
                guard listening || state == TSI_S_ESTABLISHED else { continue }
                let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
                let remote = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_fport))
                found.connections.append(OrphanReclaim.Connection(
                    pid: pid, localPort: local, remotePort: remote,
                    remoteIsLoopback: isLoopback(tcp.tcpsi_ini), listening: listening))
            }
        }
        return found
    }

    /// Whether a socket's far end is this machine.
    private static func isLoopback(_ info: in_sockinfo) -> Bool {
        if info.insi_vflag & UInt8(INI_IPV4) != 0 {
            // Network byte order: the first octet is the low byte of the big-endian word.
            return UInt32(bigEndian: info.insi_faddr.ina_46.i46a_addr4.s_addr) >> 24 == 127
        }
        let bytes = withUnsafeBytes(of: info.insi_faddr.ina_6) { Array($0) }
        return bytes.count == 16 && bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }

    /// EVERY PORT ANYTHING ON THIS MACHINE IS LISTENING ON.
    ///
    /// THE ONE EXPENSIVE READING IN THIS FEATURE: a descriptor table per process over the whole
    /// table, which is the reading the card's own ports are sampled on one tick in three for a
    /// handful of trees. It is made ONCE per reclaim, after the processes are gone, to answer the
    /// only question that says whether the reclaim worked (`OrphanKill.released`) - and a reclaim
    /// happens when a machine has been left with a runaway on it, which is not a moment to be
    /// counting syscalls.
    static func everyListeningPort() -> [UInt16] {
        Array(listeningPorts(of: liveProcesses().map(\.pid)).keys)
    }
}

extension OrphanReclaim {
    /// THE PROCESSES ABOVE ONE, nearest first, as far as the table can be walked.
    ///
    /// PURE, and bounded twice over: by the walk leaving the table (an orphan's parent is launchd,
    /// whose own parent is itself) and by a visited set, because a parent map assembled from one
    /// moment of a moving table is not guaranteed to be a tree.
    static func ancestry(of pid: pid_t, parents: [pid_t: pid_t]) -> [pid_t] {
        var found: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var here = pid
        while let up = parents[here], up > 1, !seen.contains(up) {
            seen.insert(up)
            found.append(up)
            here = up
        }
        return found
    }
}
