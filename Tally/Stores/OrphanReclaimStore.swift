import Darwin
import Foundation
import Observation

/// THE ROUND: everything the reclaim does between two moments, with the rules it does it by next
/// door (`OrphanReclaim`, `OrphanVerdict.swift`, `OrphanKill`, `OrphanNotice`).
///
/// THE SEAM IS THE SAME ONE THE REST OF THIS PAGE USES (`ProjectLoadAccounting`): what is pure is
/// pure and asserted with no processes around it, and what touches the machine is one struct of
/// closures the harness can hand over (`Machine`). The difference is what the seam is worth here -
/// everywhere else on this board an injected reader buys an assertion about arithmetic, and here it
/// buys assertions about a code path whose failure mode is ending somebody's work. Nothing in this
/// file signals a real process during a test run, and nothing in it can, because the signalling is
/// a parameter.
///
/// A ROUND IS NOT A TICK. The sampler runs every two seconds; a reclaim ROUND is taken at most every
/// five minutes (`OrphanReclaim.roundInterval`), because the evidence it needs is a pair of readings
/// far enough apart to mean something. What runs on every tick is the sweep - a kill in progress,
/// looked at every fifth of a second while it waits (`OrphanKill.pollInterval`) - and nothing else.
@MainActor
@Observable
final class OrphanReclaimStore {
    static let shared = OrphanReclaimStore()

    /// What the page shows: what this app has done, newest first.
    private(set) var records: [Record] = []

    /// And what it is currently watching but has not acted on - the trees that would qualify if
    /// they read the same way again. Drawn so that the first a reader hears of a reclaim is not the
    /// reclaim itself.
    private(set) var watching: [Watch] = []

    /// One thing that happened.
    struct Record: Equatable, Identifiable {
        var at: Date
        var project: String
        var program: String
        var pid: pid_t
        var processes: Int
        var outcome: OrphanNotice.Outcome
        var id: String { "\(pid)-\(at.timeIntervalSince1970)" }
    }

    /// One tree under consideration.
    struct Watch: Equatable, Identifiable {
        var project: String
        var program: String
        var pid: pid_t
        var cpuPercent: Double?
        var memoryBytes: UInt64
        var doubts: [OrphanReclaim.Veto]
        var id: pid_t { pid }
    }

    /// How many records are kept. A menu bar panel is not a log; what a reader wants is "did
    /// something happen recently", and the inbox messages are the durable record.
    static let keptRecords = 12

    /// EVERYTHING THIS STORE ASKS OF THE MACHINE.
    struct Machine: Sendable {
        var program: @Sendable (pid_t) -> String?
        var directory: @Sendable (pid_t) -> String?
        var connections: @Sendable (Set<pid_t>) -> OrphanReclaim.Sockets
        var sample: @Sendable (Set<pid_t>, Date) -> ProcessResourceSample
        var hasTerminal: @Sendable (pid_t) -> Bool
        var leases: @Sendable () -> [OrphanLease]
        var clearLease: @Sendable (OrphanLease) -> Void
        var signals: OrphanKill.Signals
        var gitEntry: @Sendable (String) -> OrphanNotice.GitEntry?
        var deliver: @Sendable (String, URL, String) -> URL?
        var home: URL

        static let real = Machine(
            program: { ProcessTree.executablePath(of: $0) },
            directory: { MachineLoadRollup.workingDirectory(of: $0) },
            connections: { ProcessTree.connections(of: $0) },
            sample: { ProcessTree.resourceSample(of: $0, at: $1) },
            hasTerminal: { ProcessTree.hasTerminal(of: $0) },
            leases: { OrphanLeases.all() },
            clearLease: { OrphanLeases.clear($0) },
            signals: .real,
            gitEntry: { OrphanNotice.gitEntry($0) },
            deliver: { OrphanNotice.deliver($0, to: $1, named: $2) },
            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private let machine: Machine
    /// What each tree read last round, keyed by its root pid. The identity test is inside the value
    /// (`Sighting.rootStartedAt`), so a recycled number cannot inherit the previous holder's case.
    private var sightings: [pid_t: OrphanReclaim.Sighting] = [:]
    /// And what its counters were then, which is the other half of a rate.
    private var counters: [pid_t: ProcessResourceSample] = [:]
    /// When each fingerprint was last reported, so the same leftover is not announced hourly.
    private var said: [String: Date] = [:]
    /// When the last round was taken, which is what makes a round a round.
    private var lastRound: Date?
    /// Kills in flight.
    private var sweeps: [Sweep] = []
    /// The timer that watches them, which exists only while they do (`watch`).
    @ObservationIgnored private var sweep: Timer?

    init(machine: Machine = .real) {
        self.machine = machine
    }

    /// ONE TICK'S WORTH OF ATTENTION: advance whatever is being killed, and take a round if one is
    /// due.
    ///
    /// - Parameters:
    ///   - strays: what no session accounts for, by project (`MachineLoadRollup.leftovers`).
    ///   - processes: the whole table, out of the walk the tick already made.
    func observe(strays: [pid_t: String], processes: [ProcessIdentity], at now: Date) {
        advance(at: now)
        // A CAPTURE MUST NEVER REACH THIS. The demo flag fabricates the board's readings
        // (`DemoUsage`), and a screenshot run that ended a real process because a fixture said it
        // was busy would be the worst possible version of this feature.
        guard !DemoUsage.isActive else { return }
        if let lastRound, now.timeIntervalSince(lastRound) < OrphanReclaim.roundInterval { return }
        lastRound = now
        // The table by pid, built once and handed down: every step below asks it something, and
        // three copies of one index is three chances for two of them to disagree.
        let table = Dictionary(processes.map { ($0.pid, $0) }) { first, _ in first }
        var acted = leases(among: processes, table: table, at: now)
        acted.formUnion(sweeps.flatMap(\.targets))
        round(strays: strays.filter { !acted.contains($0.key) }, processes: processes,
              table: table, at: now)
    }

    /// TIER A: the leases whose writer has gone (`OrphanLease` carries the whole contract).
    ///
    /// TAKEN BEFORE THE STRAYS AND ITS PIDS TAKEN OUT OF THEM, so one tree cannot be judged twice
    /// in one round - once on the lease and once on two rounds of evidence - and end up signalled
    /// from two places.
    ///
    /// - Returns: every pid this tier claimed, whether or not the kill has finished.
    private func leases(among processes: [ProcessIdentity], table: [pid_t: ProcessIdentity],
                        at now: Date) -> Set<pid_t> {
        var claimed: Set<pid_t> = []
        for lease in machine.leases() {
            // WHERE THE TABLE IS SILENT ABOUT THE SUPERVISOR, THE KERNEL IS ASKED ABOUT IT
            // DIRECTLY, and only a definite "no such process" gets past here (`OrphanReclaim.state`
            // carries the incident). `unsure` claims nothing, so the tree is left in the strays and
            // reaches tier B, which cannot end anything without two rounds and a clean sweep.
            let state = OrphanReclaim.state(
                of: lease, supervisorStartedAt: table[lease.supervisor]?.startedAt,
                presence: { machine.signals.presence(lease.supervisor) },
                childStartedAt: lease.child.flatMap { table[$0]?.startedAt })
            guard case .abandoned(let root) = state else { continue }
            let members = ProcessTree.members(root: root, processes: processes)
            guard !members.isEmpty else { continue }
            claimed.formUnion(members)
            let tree = OrphanReclaim.Tree(root: root, rootStartedAt: table[root]?.startedAt ?? 0,
                                          members: members,
                                          project: machine.directory(root) ?? "")
            begin(kill: tree, table: table, reason: .leaseOwnerGone, lease: lease,
                  ports: ports(of: members), at: now)
        }
        return claimed
    }

    /// TIER B AND C: everything else that is running in one of these checkouts.
    private func round(strays: [pid_t: String], processes: [ProcessIdentity],
                       table: [pid_t: ProcessIdentity], at now: Date) {
        let parents = table.mapValues(\.parent)
        var seen: Set<pid_t> = []
        var watches: [Watch] = []
        for tree in OrphanReclaim.trees(of: strays, among: processes) {
            let reading = read(tree, identities: table, parents: parents, at: now)
            seen.insert(tree.root)
            let decided = OrphanReclaim.verdict(for: reading, previous: sightings[tree.root])
            sightings[tree.root] = decided.keep
            switch decided.verdict {
            case .reclaim:
                begin(kill: tree, table: table, reason: .sustained, lease: nil,
                      ports: reading.listeningPorts, at: now)
            case .notify:
                watches.append(watch(reading))
                report(reading, outcome: .reported(doubts: reading.vetoes.sorted()), at: now)
            case .wait:
                // Worth showing only once it is a candidate rather than merely old: a first
                // sighting of something heavy is exactly what a reader wants warning of.
                if reading.age >= OrphanReclaim.minimumAge, OrphanReclaim.heavy(reading) {
                    watches.append(watch(reading))
                }
            case .leave:
                break
            }
        }
        // A tree that has gone takes its memory with it, so a number handed out again starts from
        // nothing rather than from the previous holder's case (the identity test inside the
        // sighting already refuses it; this keeps the dictionaries from growing all day).
        sightings = sightings.filter { seen.contains($0.key) }
        counters = counters.filter { seen.contains($0.key) }
        if watching != watches { watching = watches }
    }

    /// EVERYTHING KNOWN ABOUT ONE TREE THIS ROUND, out of the readings the machine will state.
    ///
    /// The root's own start time comes off the TREE rather than off the table again: the two are
    /// the same reading (`OrphanReclaim.trees` took it from this very walk), and asking twice is
    /// how two spellings of one fact come to disagree.
    private func read(_ tree: OrphanReclaim.Tree, identities: [pid_t: ProcessIdentity],
                      parents: [pid_t: pid_t], at now: Date) -> OrphanReclaim.Reading {
        let members = tree.members.compactMap { pid -> OrphanReclaim.Member? in
            guard let identity = identities[pid] else { return nil }
            return OrphanReclaim.Member(identity: identity, program: machine.program(pid),
                                        directory: machine.directory(pid))
        }
        var reading = machine.sample(tree.members, now)
        // WHOSE LIFE EACH COUNTER IS, out of the table walk this tick already made.
        // `proc_pid_rusage` carries no birth time, so a rate compared by pid alone would credit a
        // recycled number's work to the process that used to hold it - the one arithmetic error
        // here that ends in a signal (`OrphanReclaim.rate` refuses an unstamped pair outright, so
        // forgetting this line reads as "nothing is ever busy" rather than as a wrong number).
        for pid in reading.times.keys where reading.startedAt[pid] == nil {
            reading.startedAt[pid] = identities[pid]?.startedAt
        }
        let percent = OrphanReclaim.rate(from: counters[tree.root], to: reading)
        counters[tree.root] = reading
        let ancestors = OrphanReclaim.ancestry(of: tree.root, parents: parents)
        // The walk above stops at launchd, so for an ordinary orphan this is empty and costs
        // nothing; a tree still under somebody's terminal is where it earns its calls.
        let named = ancestors.compactMap { machine.program($0).flatMap(ProcessTree.displayName) }
        // Read once and used twice: what the tree is waiting on, and who is talking to it. A
        // descriptor table the machine would not read comes back NAMED rather than empty, and the
        // rule turns that into a doubt about the whole tree (`OrphanReclaim.Sockets`).
        let sockets = machine.connections(tree.members)
        var vetoes = OrphanReclaim.vetoes(of: tree, members: members, sockets: sockets,
                                          ancestors: named)
        if ancestors.contains(where: machine.hasTerminal) { vetoes.insert(.terminal) }
        let began = Date(timeIntervalSince1970: Double(tree.rootStartedAt) / 1_000_000)
        return OrphanReclaim.Reading(
            tree: tree, takenAt: now, age: now.timeIntervalSince(began), cpuPercent: percent,
            memoryBytes: reading.memoryBytes,
            listeningPorts: OrphanReclaim.listening(sockets.connections),
            name: members.first { $0.identity.pid == tree.root }.flatMap(OrphanReclaim.name)
                ?? members.compactMap(OrphanReclaim.name).first,
            vetoes: vetoes)
    }

    private func watch(_ reading: OrphanReclaim.Reading) -> Watch {
        Watch(project: reading.tree.project, program: reading.name ?? "?", pid: reading.tree.root,
              cpuPercent: reading.cpuPercent, memoryBytes: reading.memoryBytes,
              doubts: reading.vetoes.sorted())
    }

    /// The ports a set of processes is waiting on, ascending. A table that would not be read is not
    /// a doubt HERE, only a shorter list: the one caller is tier A, which acts on the lease rather
    /// than on the vetoes, and what these ports are for is the report and the release check
    /// (`OrphanKill.released`) - both of which say less rather than something wrong.
    private func ports(of members: Set<pid_t>) -> [UInt16] {
        OrphanReclaim.listening(machine.connections(members).connections)
    }

    // MARK: ending it

    /// A kill in flight.
    ///
    /// THE PLAN IS NOT KEPT, and that is the repair rather than a tidy-up: the escalation used to
    /// re-send the plan the `SIGTERM` was made from, which is a set of pids and PROCESS GROUPS
    /// decided a whole grace period earlier (`advance`).
    private struct Sweep {
        var targets: Set<pid_t>
        var expected: [pid_t: Int64]
        var began: Date
        var escalated = false
        var report: OrphanNotice.Report
        var lease: OrphanLease?
    }

    /// SEND THE FIRST SIGNAL, having confirmed one last time that these are the processes the
    /// verdict was about (`OrphanKill.confirmed`).
    private func begin(kill tree: OrphanReclaim.Tree, table: [pid_t: ProcessIdentity],
                       reason: OrphanReclaim.Reason, lease: OrphanLease?, ports: [UInt16],
                       at now: Date) {
        let expected = table.filter { tree.members.contains($0.key) }.mapValues(\.startedAt)
        let confirmed = OrphanKill.confirmed(tree.members, expected: expected,
                                             now: machine.signals.alive(tree.members))
        let ours = ProcessTree.ownFamily(confirmed, root: getpid(), executable: machine.program)
        let plan = OrphanKill.plan(members: confirmed, groups: table.mapValues(\.group), ours: ours,
                                   ownGroup: pid_t(getpgrp()))
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
                OrphanKill.deliver(SIGKILL, following: replanned(survivors), through: machine.signals)
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
    /// all of it (codex review, 2026-09-02). Two things go stale in that window and both end with a
    /// `SIGKILL` at a stranger:
    ///
    ///   - THE MEMBERS. Some of the tree did what it was asked and exited, and the kernel is free to
    ///     hand those numbers straight back out. The old plan still named them.
    ///   - THE GROUPS. A group is signalled as a group only where every live process carrying it is
    ///     being reclaimed, and that was true ten seconds ago. A process group leader that exits
    ///     leaves its number reusable too, so a `kill(-pgid)` decided then can now reach a job
    ///     nobody here has ever looked at - and a group kill is one call that cannot be taken back.
    ///
    /// So the survivors (already confirmed by pid AND start time) are replanned against a FRESH
    /// table, which is one walk and happens only for a tree that ignored `SIGTERM`.
    private func replanned(_ survivors: Set<pid_t>) -> OrphanKill.Plan {
        let table = machine.signals.table()
        let ours = ProcessTree.ownFamily(survivors, root: getpid(), executable: machine.program)
        return OrphanKill.plan(members: survivors,
                               groups: Dictionary(table.map { ($0.pid, $0.group) }) { a, _ in a },
                               ours: ours, ownGroup: pid_t(getpgrp()))
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

    // MARK: saying so

    /// Say something about a tree that was NOT ended, subject to not having said it lately.
    private func report(_ reading: OrphanReclaim.Reading, outcome: OrphanNotice.Outcome,
                        at now: Date) {
        let fingerprint = OrphanReclaim.fingerprint(reading)
        guard !OrphanReclaim.silenced(fingerprint, said: said, at: now) else { return }
        said[fingerprint] = now
        announce(OrphanNotice.Report(
            project: reading.tree.project, program: reading.name ?? "?", pid: reading.tree.root,
            processes: reading.tree.members.count, cpuPercent: reading.cpuPercent,
            memoryBytes: reading.memoryBytes, listeningPorts: reading.listeningPorts,
            ageSeconds: reading.age, outcome: outcome), at: now)
    }

    /// PUT IT ON THE PANEL AND IN THE PROJECT'S INBOX. Both, always: the panel is what somebody
    /// sees when they happen to look, and the inbox is what the project's next session reads
    /// whether or not anybody looked.
    private func announce(_ report: OrphanNotice.Report, at now: Date) {
        records.insert(Record(at: now, project: report.project, program: report.program,
                              pid: report.pid, processes: report.processes,
                              outcome: report.outcome), at: 0)
        if records.count > Self.keptRecords { records.removeLast(records.count - Self.keptRecords) }
        deliver(report, at: now)
    }

    /// Write the message into the owning repository's inbox.
    private func deliver(_ report: OrphanNotice.Report, at now: Date) {
        guard !report.project.isEmpty,
              let repository = OrphanNotice.repository(of: report.project, entry: machine.gitEntry)
        else { return }
        let workspace = machine.home.appendingPathComponent("workspace").path
        let key = OrphanNotice.key(for: repository.root, workspace: workspace)
        let text = OrphanNotice.message(report, to: key, worktree: repository.worktree, at: now)
        _ = machine.deliver(text,
                            OrphanNotice.inbox(key, home: machine.home),
                            OrphanNotice.filename(at: now, pid: getpid(),
                                                  random: UInt32.random(in: 0 ..< 100_000)))
    }

}
