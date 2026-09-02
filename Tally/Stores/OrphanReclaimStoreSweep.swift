import Darwin
import Foundation

// ENDING IT: the signal, the ten seconds after it, and the second signal that does not ask. Lifted
// out of OrphanReclaimStore.swift (past the repo's 500-line cap) along the seam the class already
// had inside it - the MARK this file is named for. Over there is a ROUND: what the machine is
// asked, which trees are strays, which of them the rules say may be ended, and what is said about
// the ones that may not. Here are the reclaim's own `begin` and `advance` signal paths, which
// cannot be taken back.
//
// THAT IS A SENTENCE ABOUT THIS EXTENSION AND NOT ABOUT THE APP, which is the whole of the
// correction (codex review of 0bbd8ec). It read "the only thing in this app that cannot be taken
// back", and the app has others: `RedeemAction.redeem` spends a reset credit, and
// `RenewLoginRunner` sends a `SIGKILL` of its own. A safety review that takes this file's word for
// being the whole population would never go and look at them.
//
// AND THE TWO HALVES KEEP DIFFERENT CLOCKS, which is the other reason this is the seam. A round is
// taken at most every five minutes; a sweep is looked at five times a second, on a timer of its own
// that exists only while there is one (`watch`). Nothing here runs at all on a machine with nothing
// to reclaim.

extension OrphanReclaimStore {

    /// A kill in flight.
    ///
    /// THE PLAN IS NOT KEPT, and that is the repair rather than a tidy-up: the escalation used to
    /// re-send the plan the `SIGTERM` was made from, which is a set of pids decided a whole grace
    /// period earlier, some of which the machine has handed on since (`advance`).
    struct Sweep {
        var targets: Set<pid_t>
        var expected: [pid_t: Int64]
        var began: Date
        var escalated = false
        var report: OrphanNotice.Report
        var lease: OrphanLease?
    }

    /// SEND THE FIRST SIGNAL, having confirmed one last time that these are the processes the
    /// verdict was about (`OrphanKill.confirmed`).
    func begin(kill tree: OrphanReclaim.Tree, table: [pid_t: ProcessIdentity],
               reason: OrphanReclaim.Reason, lease: OrphanLease?, ports: [UInt16],
               at now: Date) {
        let expected = table.filter { tree.members.contains($0.key) }.mapValues(\.startedAt)
        let confirmed = OrphanKill.confirmed(tree.members, expected: expected,
                                             now: machine.signals.alive(tree.members))
        let ours = ProcessTree.ownFamily(confirmed, root: getpid(), executable: machine.program)
        let plan = OrphanKill.plan(members: confirmed, live: Set(table.keys), ours: ours)
        // The root's name first and the rest by pid, because a Set hands its members over in
        // whatever order it likes and a report that named a different worker each time would read
        // as this app not knowing what it ended.
        let program = ([tree.root] + confirmed.sorted().filter { $0 != tree.root })
            .compactMap { machine.program($0).flatMap(ProcessTree.displayName) }
        let report = OrphanNotice.Report(
            project: tree.project, program: program.first ?? "?", pid: tree.root,
            processes: confirmed.count, cpuPercent: sightings[tree.root]?.cpuPercent,
            memoryBytes: machine.sample(confirmed, now).memoryBytes, listeningPorts: ports,
            ageSeconds: now.timeIntervalSince(
                Date(timeIntervalSince1970: Double(tree.rootStartedAt) / 1_000_000)),
            // WHO THIS IS ABOUT TO BE SENT TO, WRITTEN DOWN BEFORE IT IS SENT (root-cause review,
            // 2026-09-02). While the first signal could reach a whole process group, the set that
            // actually received it was not knowable afterwards from anything this app kept: the
            // record said how MANY processes and the delivery was one call to a number that is not
            // a process. Per-pid delivery makes the plan the list, and a list nobody wrote down is
            // a list an incident cannot be reconstructed from.
            signalled: plan.pids,
            outcome: reason == .leaseOwnerGone ? .reclaimedByLease : .reclaimedBySustained)
        guard !plan.isEmpty else {
            // Nothing left to signal: the tree ended between the verdict and here, which is a
            // reclaim that did not have to happen rather than a failure. The lease still goes,
            // since its files are what leave a green light on a prompt pointing at nothing.
            if let lease { machine.clearLease(lease) }
            return
        }
        OrphanKill.deliver(SIGTERM, following: plan, through: machine.signals)
        sweeps.append(Sweep(targets: confirmed, expected: expected, began: now,
                            report: report, lease: lease))
        watch()
    }

    /// WHILE A KILL IS IN FLIGHT, LOOK AT IT FIVE TIMES A SECOND.
    ///
    /// THE SAMPLER'S OWN BEAT IS TOO SLOW FOR THIS ONE THING. Everything else here happens on a
    /// five-minute round, and the ten seconds a tree is given to end itself is a span the two- (or
    /// ten-) second tick can only round off: a tree that shut down cleanly in two would be recorded
    /// several seconds late, and the escalation to `SIGKILL` would land at whatever tick came
    /// after the grace rather than at its end. A timer of its own runs only while there is a sweep,
    /// and stops itself the moment there is not.
    ///
    /// A repeating timer rather than a one-shot per poll, and a single one however many sweeps are
    /// in flight: the work per fire is one `proc_pidinfo` per surviving target.
    private func watch() {
        guard sweep == nil else { return }
        let timer = Timer(timeInterval: OrphanKill.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(at: Date()) }
        }
        sweep = timer
        // `.common`, so a menu being open does not suspend the one loop in this app that is holding
        // a signal half-sent.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// LOOK AT EVERY KILL IN FLIGHT, which is what the tick is for.
    func advance(at now: Date) {
        guard !sweeps.isEmpty else { return }
        var running: [Sweep] = []
        for var sweep in sweeps {
            let alive = machine.signals.alive(sweep.targets)
            // A pid whose number has been handed on is not a survivor: it is a stranger, and
            // escalating to it would be the recycled-pid accident arriving at the last step.
            let survivors = OrphanKill.confirmed(Set(alive.keys), expected: sweep.expected,
                                                 now: alive)
            switch OrphanKill.step(survivors: survivors.count,
                                   elapsed: now.timeIntervalSince(sweep.began),
                                   escalated: sweep.escalated) {
            case .wait:
                running.append(sweep)
            case .escalate:
                OrphanKill.deliver(SIGKILL,
                                   following: replanned(survivors, expected: sweep.expected),
                                   through: machine.signals)
                sweep.escalated = true
                running.append(sweep)
            case .settled:
                finish(sweep, at: now)
            case .failed:
                var failed = sweep.report
                failed.outcome = .failed(reason: "\(survivors.count) of"
                    + " \(sweep.targets.count) processes survived SIGKILL")
                announce(failed, at: now)
            }
        }
        sweeps = running
        // The timer exists for the sweeps and not the other way round: stopped HERE rather than
        // inside its own block, so a round driven directly (which is how every assertion drives
        // this) leaves the store in the same state a real one does.
        if sweeps.isEmpty {
            sweep?.invalidate()
            sweep = nil
        }
    }

    /// THE PLAN FOR THE SIGNAL THAT DOES NOT ASK, made again from scratch at the moment it is sent.
    ///
    /// THE GRACE PERIOD IS TEN SECONDS OF THE MACHINE MOVING, and re-sending the first plan ignores
    /// all of it (codex review, 2026-09-02). Some of the tree did what it was asked and exited, and
    /// the kernel is free to hand those numbers straight back out; the old plan still named them,
    /// and the `SIGKILL` then landed on a stranger.
    ///
    /// So the survivors are replanned against a FRESH table, which is one walk and happens only for
    /// a tree that ignored `SIGTERM`.
    ///
    /// AND THE IDENTITY TEST IS MADE AGAIN AGAINST THAT TABLE, which is the half the first repair
    /// left open (codex review of 8bfb19c). The survivors were confirmed against the reading
    /// `alive()` took, and this is a SECOND reading of the machine a moment later: a survivor that
    /// exited in between and had its number handed on is present in both readings, alive in both,
    /// and a different process in the second one. `OrphanKill.plan` only asks whether a pid is in
    /// the table, so without this the replacement goes into the plan and takes the `SIGKILL`.
    /// Intersecting BOTH readings against the same recorded start time is what closes it: a pid
    /// survives here only where the round, the sweep and the fresh walk all name one process.
    ///
    /// AND NOTHING IS GROUP-KILLED AT ANY STAGE (`OrphanKill.plan`, which carries the reasoning and
    /// what it costs).
    private func replanned(_ survivors: Set<pid_t>, expected: [pid_t: Int64]) -> OrphanKill.Plan {
        let table = machine.signals.table()
        let still = OrphanKill.confirmed(
            survivors, expected: expected,
            now: Dictionary(table.map { ($0.pid, $0.startedAt) }) { first, _ in first })
        let ours = ProcessTree.ownFamily(still, root: getpid(), executable: machine.program)
        return OrphanKill.plan(members: still, live: Set(table.map(\.pid)), ours: ours)
    }

    /// A KILL THAT WORKED, which is not the same as a kill whose processes are gone.
    ///
    /// THE PORT IS THE TEST (`OrphanKill.released`): a tree can die and leave its listener held by
    /// something that escaped the plan, and reporting success then would put this app's name on the
    /// very state it exists to remove.
    private func finish(_ sweep: Sweep, at now: Date) {
        var report = sweep.report
        if !OrphanKill.released(report.listeningPorts, held: machine.signals.listening()) {
            report.outcome = .failed(reason: "the processes are gone and "
                + report.listeningPorts.map { ":\($0)" }.joined(separator: ", ")
                + " is still held by something else")
        } else if let lease = sweep.lease {
            machine.clearLease(lease)
        }
        announce(report, at: now)
    }

}
