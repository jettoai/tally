import Darwin
import Foundation

/// HOW A TREE IS ENDED, once something has decided it should be (`OrphanReclaim.verdict`).
///
/// THE DECISION IS ONLY HALF THE SAFETY. A correct verdict delivered by a careless signal is the
/// same accident: a process group that has picked up a stranger, a pid the machine handed out
/// between the reading and the `kill`, a `SIGKILL` sent to something that was already shutting down
/// cleanly. So the sending is a rule of its own, and every part of it that can be stated without a
/// process around it is stated here.
///
/// PURE, AND THE SENDING IS A PARAMETER (`OrphanKill.Signals`). An assertion harness cannot be asked
/// to produce a process that ignores `SIGTERM` for ten seconds and then dies, so what it drives
/// instead is the state machine: given who is still alive and how long it has been, what happens
/// next. The one thing this file does with the real machine is behind that seam.
enum OrphanKill {

    /// How long a tree is given to end itself before the signal that does not ask.
    ///
    /// TEN SECONDS IS FOR THE SERVER'S OWN SHUTDOWN, not for politeness: a dev server closing its
    /// listener, flushing, and releasing the port is the difference between the port being free for
    /// the next `pnpm dev` and it being held by a socket in `TIME_WAIT` behind a process that was
    /// shot. `/dev-watch`'s own teardown waits one second and then escalates; this waits longer
    /// because nothing is waiting on it.
    static let grace: TimeInterval = 10

    /// How long after the second signal a survivor is called a failure rather than a straggler.
    /// A process that is still there two seconds after `SIGKILL` is unkillable (uninterruptible IO,
    /// a zombie nobody will reap), and reporting that is more use than waiting on it.
    static let finalGrace: TimeInterval = 2

    /// How often the sweep looks while it waits.
    static let pollInterval: TimeInterval = 0.2

    /// WHAT TO SIGNAL AND HOW.
    struct Plan: Equatable {
        /// Process groups every live member of which is inside the reclaim set, signalled with one
        /// call each (`kill(-pgid)`).
        var groups: [pid_t]
        /// And the pids that have to be signalled one at a time, because their group holds somebody
        /// else.
        var pids: [pid_t]
        /// Members deliberately left alone, with nothing to do about it: this process, its family,
        /// and anything whose group is the init group. Kept rather than dropped so a record can say
        /// the tree was not fully ended.
        var spared: [pid_t]

        var isEmpty: Bool { groups.isEmpty && pids.isEmpty }
    }

    /// HOW TO SIGNAL A SET OF PIDS WITHOUT TAKING ANYTHING ELSE WITH THEM.
    ///
    /// A GROUP KILL IS ONE CALL AND CANNOT BE TAKEN BACK. `kill(-pgid)` reaches every process
    /// carrying that group, including ones that joined after the reading - which is exactly what
    /// makes it the right tool for a server that keeps spawning workers, and exactly what makes it
    /// unusable when the group holds anything else. `/dev-watch`'s supervisor relies on the same
    /// property (`kill -- -$SRV`), and its own note says why: a child that dies first re-parents its
    /// grandchildren to launchd, and `pkill -P` can then never find them.
    ///
    /// SO THE GROUP IS ONLY USED WHERE IT IS PROVABLY CLEAN, decided against the machine's whole
    /// live table rather than against the tree: a member of that group missing from the reclaim set
    /// is a stranger, whether it is a worker somebody else's session adopted or a process that
    /// joined a second ago.
    ///
    /// THREE THINGS ARE NEVER SIGNALLED, and the first two are the ones that would be funny if they
    /// were not fatal. Group 0 and group 1 (`kill(-0)` is the CALLER's own group, `kill(-1)` is
    /// every process the user owns) would end this app, this app's supervisors, and every session on
    /// the machine, from a feature whose whole purpose is to be careful. And this process's own
    /// family is out for the reason it is out of every reading on this page (`ProcessTree.
    /// ownFamily`): the meter must never be the thing metered.
    ///
    /// - Parameters:
    ///   - members: the pids to end.
    ///   - groups: what group each LIVE process on the machine carries, out of the table walk the
    ///     round already made. A member missing from it is already gone and needs no signal.
    ///   - ours: this process and anything of Tally's own among the members.
    ///   - ownGroup: this process's own group, which `kill(-pgid)` would reach.
    static func plan(members: Set<pid_t>, groups table: [pid_t: pid_t], ours: Set<pid_t>,
                     ownGroup: pid_t) -> Plan {
        let targets = members.subtracting(ours).filter { table[$0] != nil }
        var byGroup: [pid_t: Set<pid_t>] = [:]
        for pid in targets { byGroup[table[pid] ?? pid, default: []].insert(pid) }
        var plan = Plan(groups: [], pids: [], spared: ours.intersection(members).sorted())
        for (group, held) in byGroup.sorted(by: { $0.key < $1.key }) {
            let everyone = Set(table.filter { $0.value == group }.map(\.key))
            if group > 1, group != ownGroup, everyone.isSubset(of: targets) {
                plan.groups.append(group)
            } else {
                plan.pids.append(contentsOf: held.sorted())
            }
        }
        return plan
    }

    /// WHICH OF THE PIDS A PLAN NAMES ARE STILL THE PROCESSES IT WAS MADE ABOUT.
    ///
    /// THE LAST THING BEFORE THE SIGNAL, and the reason is arithmetic rather than caution: the
    /// verdict was reached over two rounds five minutes apart, the vetoes were re-read this round,
    /// and between all of that and the `kill` the machine is free to have ended one of these
    /// processes and handed its number to something new. Everything else in this feature identifies
    /// a process by its number AND its start time (`ProcessIdentity.startedAt`); this is where that
    /// pair is cashed.
    ///
    /// - Parameter expected: what each pid's start time was when the tree was read.
    /// - Parameter now: what the table says this instant.
    static func confirmed(_ pids: Set<pid_t>, expected: [pid_t: Int64],
                          now: [pid_t: Int64]) -> Set<pid_t> {
        pids.filter { expected[$0] != nil && expected[$0] == now[$0] }
    }

    /// WHAT THE SWEEP DOES NEXT.
    enum Step: Equatable {
        /// Everything is gone.
        case settled
        /// Keep waiting: the grace period has not run out.
        case wait
        /// Send the signal that does not ask.
        case escalate
        /// Something is still there afterwards, and nothing more will help.
        case failed
    }

    /// The sweep, as a function of what is left and how long it has been.
    ///
    /// - Parameters:
    ///   - survivors: how many of the confirmed targets the table still holds.
    ///   - elapsed: since the first signal.
    ///   - escalated: whether `SIGKILL` has already gone out.
    static func step(survivors: Int, elapsed: TimeInterval, escalated: Bool) -> Step {
        if survivors == 0 { return .settled }
        if escalated { return elapsed >= grace + finalGrace ? .failed : .wait }
        return elapsed >= grace ? .escalate : .wait
    }

    /// WHETHER THE PORTS THE TREE WAS HOLDING ARE ACTUALLY FREE, which is what turns "the processes
    /// are gone" into "the reclaim worked".
    ///
    /// A TREE CAN DIE AND LEAVE ITS PORT TAKEN. The listener is inherited by whatever survived - a
    /// worker outside the group, a grandchild re-parented before the sweep started - and the next
    /// `pnpm dev` fails with `EADDRINUSE` against a process nobody can name, which is precisely the
    /// state this whole feature exists to end rather than to create. So a reclaim reports success
    /// only when the ports it named are answering to nobody.
    ///
    /// - Parameter held: which ports are listening now, machine-wide.
    static func released(_ ports: [UInt16], held: Set<UInt16>) -> Bool {
        !ports.contains(where: held.contains)
    }

    /// The seam between the rules above and the machine: sending a signal, and asking who is left.
    /// A struct of closures rather than a protocol for the reason every other reader in this app is
    /// injected the same way - the harness hands over four functions, and no process is harmed.
    struct Signals: Sendable {
        var send: @Sendable (Int32, pid_t) -> Void
        var sendGroup: @Sendable (Int32, pid_t) -> Void
        /// Which of these pids the table still holds, with their start times.
        var alive: @Sendable (Set<pid_t>) -> [pid_t: Int64]
        /// Every port listening on the machine right now.
        var listening: @Sendable () -> Set<UInt16>

        static let real = Signals(
            send: { signal, pid in _ = kill(pid, signal) },
            sendGroup: { signal, group in _ = kill(-group, signal) },
            alive: { pids in
                var found: [pid_t: Int64] = [:]
                for pid in pids {
                    if case .living(let startedAt) = ProcessTree.departure(of: pid),
                       let startedAt { found[pid] = startedAt }
                }
                return found
            },
            listening: { Set(ProcessTree.everyListeningPort()) })
    }

    /// Send one signal, the way the plan says to.
    static func deliver(_ signal: Int32, following plan: Plan, through signals: Signals) {
        for group in plan.groups { signals.sendGroup(signal, group) }
        for pid in plan.pids { signals.send(signal, pid) }
    }
}
