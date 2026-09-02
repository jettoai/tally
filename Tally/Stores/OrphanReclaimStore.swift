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
/// The sweep itself is next door in OrphanReclaimStoreSweep.swift, which is where this file was cut
/// when it passed the repo's 500-line cap.
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
        /// What a path really is, symlinks and all. The one reading here that exists to make two
        /// spellings of one checkout compare equal (`round`).
        var resolve: @Sendable (String) -> String
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
            resolve: { MachineLoadRollup.resolvedPath($0) },
            gitEntry: { OrphanNotice.gitEntry($0) },
            deliver: { OrphanNotice.deliver($0, to: $1, named: $2) },
            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    // THE FOUR BELOW ARE NOT `private` BECAUSE THE KILL IS NEXT DOOR. When this file passed the
    // repo's 500-line cap the sweep went into OrphanReclaimStoreSweep.swift, along the seam the
    // class already had: a ROUND stayed here, and ending something went there. Swift's `private` is
    // file-scoped, so the machine, the sightings a report is drawn from and the sweeps themselves
    // are module-visible - the same trade `UsageStore` and `ProcessFootprintStore` made for the
    // same reason.
    let machine: Machine
    /// What each tree read last round, keyed by its root pid. The identity test is inside the value
    /// (`Sighting.rootStartedAt`), so a recycled number cannot inherit the previous holder's case.
    var sightings: [pid_t: OrphanReclaim.Sighting] = [:]
    /// And what its counters were then, which is the other half of a rate.
    private var counters: [pid_t: ProcessResourceSample] = [:]
    /// When each fingerprint was last reported, so the same leftover is not announced hourly.
    private var said: [String: Date] = [:]
    /// And what was last said about each TREE, which is the half `said` cannot hold: a situation
    /// whose ports move under it is a new fingerprint every round (`OrphanReclaim.Told`).
    private var told: [pid_t: OrphanReclaim.Told] = [:]
    /// When the last round was taken, which is what makes a round a round.
    private var lastRound: Date?
    /// Kills in flight.
    var sweeps: [Sweep] = []
    /// The timer that watches them, which exists only while they do (`watch`).
    @ObservationIgnored var sweep: Timer?

    init(machine: Machine = .real) {
        self.machine = machine
    }

    /// ONE TICK'S WORTH OF ATTENTION: advance whatever is being killed, and take a round if one is
    /// due.
    ///
    /// - Parameters:
    ///   - strays: what no session accounts for, by project (`MachineLoadRollup.leftovers`).
    ///   - processes: the whole table, out of the walk the tick already made.
    ///   - sessions: the directories the LIVE sessions are working in, as the board holds them
    ///     (`MachineLoadRollup.SessionReading.root`). A tree in one of these checkouts is never
    ///     ended on inference alone (`OrphanReclaim.Veto.sessionPresent`).
    func observe(strays: [pid_t: String], processes: [ProcessIdentity], sessions: Set<String>,
                 at now: Date) {
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
        let fromLeases = leases(among: processes, table: table, at: now)
        var acted = fromLeases.claimed
        acted.formUnion(sweeps.flatMap(\.targets))
        round(strays: strays.filter { !acted.contains($0.key) }, processes: processes,
              table: table, sessions: sessions, leased: fromLeases.tended, at: now)
    }

    /// TIER A: the leases whose writer has gone (`OrphanLease` carries the whole contract).
    ///
    /// TAKEN BEFORE THE STRAYS AND ITS PIDS TAKEN OUT OF THEM, so one tree cannot be judged twice
    /// in one round - once on the lease and once on two rounds of evidence - and end up signalled
    /// from two places.
    ///
    /// AND THE SAME FILES READ FOR THE OPPOSITE ANSWER, which is the other thing this pass is the
    /// only one able to say. A lease whose supervisor is running names a tree the harness itself is
    /// answering for; before this it simply fell out of tier A and into the evidence tiers, which
    /// know nothing about leases and judged the supervisor on what it looks like - a `bash` holding
    /// two gigabytes, reported as a leftover three times in thirty minutes while `/dev-watch` was
    /// doing exactly its job (2026-09-02). Gathered here rather than re-read below because the
    /// verdict about a lease is this function's, and two readings of one file are two chances to
    /// disagree.
    ///
    /// - Returns: every pid this tier claimed, whether or not the kill has finished, and the pids
    ///   a live lease still speaks for (`OrphanReclaim.Veto.leased`).
    private func leases(among processes: [ProcessIdentity], table: [pid_t: ProcessIdentity],
                        at now: Date) -> (claimed: Set<pid_t>, tended: Set<pid_t>) {
        var claimed: Set<pid_t> = []
        var tended: Set<pid_t> = []
        for lease in machine.leases() {
            // WHERE THE TABLE IS SILENT ABOUT THE SUPERVISOR, THE KERNEL IS ASKED ABOUT IT
            // DIRECTLY, and only a definite "no such process" gets past here (`OrphanReclaim.state`
            // carries the incident). `unsure` claims nothing, so the tree is left in the strays and
            // reaches tier B, which cannot end anything without two rounds and a clean sweep.
            let state = OrphanReclaim.state(
                of: lease, supervisorStartedAt: table[lease.supervisor]?.startedAt,
                presence: { machine.signals.presence(lease.supervisor) },
                childStartedAt: lease.child.flatMap { table[$0]?.startedAt })
            guard case .abandoned(let root) = state else {
                // ONLY `tended`, AND THE OTHER TWO DELIBERATELY NOT. `spent` has no tree left to
                // speak for; `unsure` is the state where neither the table nor the kernel would
                // answer, and turning "cannot tell" into a veto would put the one shape this
                // feature exists for permanently out of reach on a machine whose probe is flaky.
                // It already goes to tier B, which cannot end anything without two rounds and a
                // clean sweep.
                if state == .tended {
                    tended.insert(lease.supervisor)
                    if let child = lease.child { tended.insert(child) }
                }
                continue
            }
            let members = ProcessTree.members(root: root, processes: processes)
            guard !members.isEmpty else { continue }
            claimed.formUnion(members)
            let tree = OrphanReclaim.Tree(root: root, rootStartedAt: table[root]?.startedAt ?? 0,
                                          members: members,
                                          project: machine.directory(root) ?? "")
            begin(kill: tree, table: table, reason: .leaseOwnerGone, lease: lease,
                  ports: ports(of: members), at: now)
        }
        return (claimed, tended)
    }

    /// TIER B AND C: everything else that is running in one of these checkouts.
    ///
    /// TIER A IS DELIBERATELY NOT SUBJECT TO THE SESSION VETO. A lease is a statement rather than
    /// an inference - the harness's own supervisor named that tree and is no longer running - and
    /// a session in the checkout says nothing about a server whose owner is provably gone. It is
    /// only the evidence-based tier that has to defer to somebody being here.
    private func round(strays: [pid_t: String], processes: [ProcessIdentity],
                       table: [pid_t: ProcessIdentity], sessions: Set<String>,
                       leased: Set<pid_t>, at now: Date) {
        let parents = table.mapValues(\.parent)
        // THE CHECKOUTS SOMEBODY IS WORKING IN, folded to their repositories once for the round
        // rather than once per tree: the fold is a walk of the filesystem, and the answer is the
        // same for every tree on the round (`OrphanReclaim.checkout`).
        //
        // AND BOTH SIDES OF THE COMPARISON THROUGH ONE CALL (`checkout(of:)`), which is where the
        // resolving lives and why it is a method rather than two expressions.
        let occupied = Set(sessions.map(checkout(of:)))
        var seen: Set<pid_t> = []
        var watches: [Watch] = []
        for tree in OrphanReclaim.trees(of: strays, among: processes) {
            let reading = read(tree, identities: table, parents: parents, occupied: occupied,
                               leased: leased, at: now)
            seen.insert(tree.root)
            let decided = OrphanReclaim.verdict(for: reading, previous: sightings[tree.root])
            sightings[tree.root] = decided.keep
            switch decided.verdict {
            case .reclaim:
                begin(kill: tree, table: table, reason: .sustained, lease: nil,
                      ports: reading.listeningPorts, at: now)
            case .notify:
                watches.append(watch(reading))
                report(reading, at: now)
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
        told = told.filter { seen.contains($0.key) }
        if watching != watches { watching = watches }
    }

    /// EVERYTHING KNOWN ABOUT ONE TREE THIS ROUND, out of the readings the machine will state.
    ///
    /// The root's own start time comes off the TREE rather than off the table again: the two are
    /// the same reading (`OrphanReclaim.trees` took it from this very walk), and asking twice is
    /// how two spellings of one fact come to disagree.
    private func read(_ tree: OrphanReclaim.Tree, identities: [pid_t: ProcessIdentity],
                      parents: [pid_t: pid_t], occupied: Set<String>, leased: Set<pid_t>,
                      at now: Date) -> OrphanReclaim.Reading {
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
        // AND WHETHER ANYBODY IS WORKING IN THE CHECKOUT THIS TREE IS IN, which is the one reading
        // here that comes off the BOARD rather than off the process table - and the one the
        // 2026-09-02 incident was decided without. Two servers were ended in checkouts whose
        // sessions were sitting right there, under a message that said no session was.
        if occupied.contains(checkout(of: tree.project)) { vetoes.insert(.sessionPresent) }
        // AND WHETHER A LEASE IS STILL ANSWERING FOR IT, which comes off the same files tier A
        // reads and is that tier's mirror: it acts on a lease whose writer is gone, and this is the
        // ordinary case it used to drop on the floor (`OrphanReclaim.Veto.leased`).
        if !tree.members.isDisjoint(with: leased) { vetoes.insert(.leased) }
        let began = Date(timeIntervalSince1970: Double(tree.rootStartedAt) / 1_000_000)
        return OrphanReclaim.Reading(
            tree: tree, takenAt: now, age: now.timeIntervalSince(began), cpuPercent: percent,
            memoryBytes: reading.memoryBytes,
            listeningPorts: OrphanReclaim.listening(sockets.connections),
            name: members.first { $0.identity.pid == tree.root }.flatMap(OrphanReclaim.name)
                ?? members.compactMap(OrphanReclaim.name).first,
            vetoes: vetoes)
    }

    /// WHICH CHECKOUT A DIRECTORY IS IN, as the session veto compares them: the repository above it
    /// (`OrphanReclaim.checkout`), resolved.
    ///
    /// A METHOD BECAUSE BOTH SIDES HAVE TO GO THROUGH IT. They arrive spelled differently - a
    /// session's root has been through `realpath` before it ever reaches this store
    /// (`ProjectLoadAccounting.roots`), and a worktree's repository is the text of a `.git` file,
    /// which nothing resolves - so where the workspace sits behind a symlink they are one checkout
    /// under two names, compare unequal, and the veto is missed in the one direction that ends a
    /// process (codex review, 2026-09-02). Written twice, one of them could go on being the
    /// resolved one alone; written once, that cannot happen.
    private func checkout(of directory: String) -> String {
        machine.resolve(OrphanReclaim.checkout(of: directory, entry: machine.gitEntry))
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

    // MARK: saying so

    /// Say something about a tree that was NOT ended, subject to not having said it lately.
    private func report(_ reading: OrphanReclaim.Reading, at now: Date) {
        // TWO GATES, AND THEY CATCH DIFFERENT REPEATS. The tree's own memory refuses a second
        // message about one unchanged tree however much moves around it (`OrphanReclaim.Told`); the
        // fingerprint refuses a second message about one SITUATION however many pids pass through
        // it (`OrphanReclaim.fingerprint`). Neither covers the other's case, and the machine has
        // now produced both.
        let doubts = reading.vetoes.sorted()
        guard OrphanReclaim.worthSaying(told[reading.tree.root],
                                        rootStartedAt: reading.tree.rootStartedAt,
                                        doubts: doubts) else { return }
        told[reading.tree.root] = OrphanReclaim.Told(rootStartedAt: reading.tree.rootStartedAt,
                                                     doubts: doubts)
        let fingerprint = OrphanReclaim.fingerprint(reading)
        guard !OrphanReclaim.silenced(fingerprint, said: said, at: now) else { return }
        said[fingerprint] = now
        announce(OrphanNotice.Report(
            project: reading.tree.project, program: reading.name ?? "?", pid: reading.tree.root,
            processes: reading.tree.members.count, cpuPercent: reading.cpuPercent,
            memoryBytes: reading.memoryBytes, listeningPorts: reading.listeningPorts,
            ageSeconds: reading.age, outcome: .reported(doubts: doubts)), at: now)
    }

    /// PUT IT ON THE PANEL AND IN THE PROJECT'S INBOX. Both, always: the panel is what somebody
    /// sees when they happen to look, and the inbox is what the project's next session reads
    /// whether or not anybody looked.
    ///
    /// Not `private` because a sweep ends here too (OrphanReclaimStoreSweep.swift): what this app
    /// did is written down in one place whether the tree was ended or only mentioned.
    func announce(_ report: OrphanNotice.Report, at now: Date) {
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
