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
/// WHETHER A PID IS THERE, asked of the kernel directly rather than of a table walked earlier.
///
/// THREE ANSWERS BECAUSE THERE ARE THREE, and collapsing them into two is what let a healthy dev
/// server be killed. A process table pass is a snapshot assembled one `proc_pidinfo` at a time, and
/// any one of those can fail transiently; "absent from the walk" therefore means "gone OR the walk
/// missed it", which is a distinction with a process's life on it (codex review, 2026-09-02).
///
/// `kill(pid, 0)` IS THE PROBE THAT SEPARATES THEM, and it is the only one on this platform that
/// does. Measured here (2026-09-02): a live pid answers 0, a reaped pid answers -1/ESRCH, and one
/// belonging to another user answers -1/EPERM - so ESRCH is the single errno that means DEFINITELY
/// GONE, EPERM means definitely there, and anything else means neither. `proc_pid_rusage` cannot be
/// used for this: it answers -1/ESRCH for a reaped pid too, but a failure of any other kind is
/// indistinguishable from it in the return value alone.
enum ProcessPresence: Equatable {
    /// It is there (ours, or somebody else's).
    case running
    /// It is not: the kernel says no such process.
    case gone
    /// The kernel would not say. Never a reason to act.
    case unknown
}

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

    /// WHAT TO SIGNAL.
    struct Plan: Equatable {
        /// The pids, ascending, each signalled with a call of its own.
        var pids: [pid_t]
        /// Members deliberately left alone, with nothing to do about it: this process and its
        /// family. Kept rather than dropped so a record can say the tree was not fully ended. A
        /// member the table no longer holds is in neither list, being nothing to signal or spare.
        var spared: [pid_t]

        var isEmpty: Bool { pids.isEmpty }
    }

    /// HOW TO SIGNAL A SET OF PIDS WITHOUT TAKING ANYTHING ELSE WITH THEM: one process at a time,
    /// for BOTH signals, and never a process group.
    ///
    /// A GROUP KILL IS ONE CALL AND CANNOT BE TAKEN BACK. `kill(-pgid)` reaches every process
    /// carrying that group, including ones that joined after the reading - which is exactly what
    /// makes it the right tool for a server that keeps spawning workers, and exactly what makes it
    /// unusable when the group holds anything else. This used to send the FIRST signal that way
    /// wherever the group read clean, on the argument that a `SIGTERM` is a request rather than an
    /// execution and a stranger receiving one may decline it.
    ///
    /// THAT ARGUMENT SURVIVED THE REVIEW AND ITS EVIDENCE DID NOT (root-cause review, 2026-09-02).
    /// "Every live process carrying this group is being reclaimed" is a completeness claim about
    /// the whole machine, read out of a table walk that is one `proc_pidinfo` per pid, any of which
    /// can fail for a pass. A single such failure on an UNRELATED process sharing the group makes a
    /// dirty group read as clean, and the delivery then reaches somebody nothing here ever looked
    /// at. A request delivered to a stranger is still a request this app cannot account for, and
    /// the whole point of the tier that survives the hold is that it acts on a STATEMENT rather
    /// than on an inference. So the reach goes, and what is signalled is exactly the set that was
    /// confirmed by pid AND start time (`confirmed`).
    ///
    /// WHAT IT COSTS, NAMED: a worker spawned after the round's own walk is in the group and not in
    /// the confirmed member list, so it survives the sweep. It is not lost - it is a stray in that
    /// checkout on the next round, and the round after that can reclaim its tree on the same terms
    /// as any other. A leftover that outlives one sweep by five minutes is a smaller thing than a
    /// signal at somebody's unrelated job.
    ///
    /// TWO THINGS ARE NEVER SIGNALLED. This process's own family is out for the reason it is out of
    /// every reading on this page (`ProcessTree.ownFamily`): the meter must never be the thing
    /// metered. And pid 1 is out because `kill` reads anything at or below zero as a GROUP and 1 is
    /// launchd: neither can ever be a member of a stray tree, and the cost of the guard is a
    /// comparison against the cost of not having it being the whole machine.
    ///
    /// - Parameters:
    ///   - members: the pids to end.
    ///   - live: every process the machine holds, out of the table walk the caller just made. A
    ///     member missing from it is already gone and needs no signal.
    ///   - ours: this process and anything of Tally's own among the members.
    static func plan(members: Set<pid_t>, live: Set<pid_t>, ours: Set<pid_t>) -> Plan {
        let targets = members.subtracting(ours).filter { live.contains($0) && $0 > 1 }
        return Plan(pids: targets.sorted(), spared: ours.intersection(members).sorted())
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
        /// Which of these pids the table still holds, with their start times.
        var alive: @Sendable (Set<pid_t>) -> [pid_t: Int64]
        /// Every port listening on the machine right now.
        var listening: @Sendable () -> Set<UInt16>
        /// Whether ONE pid is there, asked of the kernel rather than of a walk (`ProcessPresence`).
        var presence: @Sendable (pid_t) -> ProcessPresence
        /// The whole table again, for the one moment a plan has to be rebuilt: the escalation from
        /// `SIGTERM` to `SIGKILL`, where the set being signalled is a grace period older than the
        /// plan that was made and some of those numbers have been handed on.
        var table: @Sendable () -> [ProcessIdentity]

        static let real = Signals(
            // A pid at or below zero is a GROUP to `kill(2)`, and nothing here may ever address
            // one. The planner refuses to put such a number in a plan; this refuses to send it, so
            // the guarantee does not rest on one of the two alone.
            send: { signal, pid in if pid > 1 { _ = kill(pid, signal) } },
            alive: { pids in
                var found: [pid_t: Int64] = [:]
                for pid in pids {
                    if case .living(let startedAt) = ProcessTree.departure(of: pid),
                       let startedAt { found[pid] = startedAt }
                }
                return found
            },
            listening: { Set(ProcessTree.everyListeningPort()) },
            presence: { pid in
                // A pid of 0 or below is a GROUP to `kill(2)`, and 0 is the caller's own group.
                // Nothing here should ever ask about one, and asking would be the worst possible
                // way to find out.
                guard pid > 1 else { return .running }
                errno = 0
                if kill(pid, 0) == 0 { return .running }
                switch errno {
                case ESRCH: return .gone
                case EPERM: return .running
                default: return .unknown
                }
            },
            table: { ProcessTree.liveProcesses() })
    }

    /// Send one signal, the way the plan says to: one call per process, in a stated order so a
    /// record of what was sent reads the same way twice.
    static func deliver(_ signal: Int32, following plan: Plan, through signals: Signals) {
        for pid in plan.pids { signals.send(signal, pid) }
    }
}
