import Foundation

// ONE FOOTPRINT PASS, next door to what it keeps (ProcessFootprintStore.swift) since its reading
// moved off the main thread (2026-09-26): what the pass asks the machine goes out in detached hops,
// and everything it decides and publishes stays on the main actor.
extension ProcessFootprintStore {
    /// One pass: the process table once, then each session's own tree out of it.
    ///
    /// THE ROSTER SAYS WHICH TREES THERE ARE, so this never has to decide what a session is - it
    /// reads the board's own rows and asks the machine about their pids. A board with nothing on it
    /// costs a dictionary assignment.
    func sample() async {
        // THE ROSTER IS NOT SCANNING BEHIND THE PANEL, and this pass consumes it. Its own timer
        // runs only while a surface is up; with nothing open it is refreshed by the supervisors'
        // knock, which is not a delivery anything can rely on (a session killed outright never
        // knocks). So a session that ended while nobody was looking would stay on this list, and
        // the walk below would go on reading a process GROUP the machine is free to hand out again
        // - appending an unrelated job's readings to a dead session's series. One scan, awaited,
        // at the rate this pass already runs at, rather than a second timer: the roster's own note
        // says a scan is cheap enough to make on a knock with no window open at all.
        if viewers == 0 { await SessionRosterStore.shared.scanNow() }
        // Each root with what its session is DOING, because a warning is about the mismatch between
        // the two (`FootprintAlarm`). The state is the supervisor's own published word rather than
        // anything guessed here, and `unknown` is not idle: a session that has not said yet is not
        // a session that said "nothing is running".
        //
        // AND WITH THE CHILD THE SUPERVISOR SPAWNED, which the count below is taken without: that
        // process is the session rather than something the session started (`ProcessTree.
        // dispatched`). Published rather than guessed, and simply absent on a supervisor too old to
        // publish it.
        let board = SessionRosterStore.shared.rows
        let roots = board.compactMap { row in
            pid_t(row.id).map { ($0, row.state == .idle || row.state == .blocked,
                                 row.childPid.flatMap { pid_t(exactly: $0) }) }
        }
        // WHICH DIRECTORIES THIS MACHINE'S SESSIONS ARE WORKING IN, settled before the table is
        // walked because it is what decides whether to walk it: a project goes on being accounted
        // for while anything is running in it, which outlives the session that put it there and is
        // the one state the Projects section exists to show (`ProjectLoadAccounting.accounted`).
        let rootOfSession = rollup.roots(of: board)
        // A board with nothing on it is not a special case, only an empty one: no table is walked,
        // the loop below does not run, and everything held falls out through the same three lines
        // that retire a single session that ended. A project still being watched keeps the pass
        // alive on its own, and stops it again on the first tick that finds nothing left in it.
        //
        // READ OFF THE MAIN THREAD, with the rest of what the pass asks the machine before it decides
        // anything (`FootprintMachineRead`): on a loaded machine the table alone held the menu bar
        // for seconds (2026-09-26). The reclaim's leases come along only when its round is due.
        let walk = !(roots.isEmpty && rollup.accounted.isEmpty)
        let now = Date()
        let leaseReader = OrphanReclaimStore.shared.leaseReaderIfDue(at: now)
        let readLedger = groupLedger == nil && !roots.isEmpty
        let machine = await Task.detached(priority: .utility) {
            FootprintMachineRead(processes: walk ? ProcessTree.liveProcesses() : [],
                                 pressure: MachineMemoryPressure.current,
                                 leases: leaseReader?(),
                                 ledger: readLedger ? SessionProcessGroups.load() : nil)
        }.value
        let processes = machine.processes
        // EVERY LIVE PROCESS BY PID, out of the walk that has just been made anyway. Two readings
        // need it: a port held across a few ticks is compared against when its holder BEGAN, since
        // the number alone cannot say whether the pid still belongs to the process that opened the
        // port (`ProcessPortHolder`); and the group ledger identifies a job by when its leader
        // began, for the same reason one number over (`SessionProcessGroup.leaderStartedAt`).
        //
        // BUILT BEHIND A CLOSED PANEL TOO, which it was not: the ports are the one reading a closed
        // panel switches off, but the ledger is written whether or not anybody is looking - a
        // session detaches a dev server at three in the morning, and a claim not written then is a
        // claim that can never be made afterwards.
        //
        // AND EVERY GROUP ANYTHING ON THE MACHINE IS STILL IN, which is what says a claim is worth
        // keeping: taken over the whole table rather than over the trees, because a job that has
        // left its tree is the case the ledger exists for (`SessionProcessGroups.swept`).
        var identities: [pid_t: ProcessIdentity] = [:]
        var liveGroups: Set<pid_t> = []
        for one in processes { identities[one.pid] = one; liveGroups.insert(one.group) }
        func began(_ pid: pid_t) -> Int64? { identities[pid]?.startedAt }
        // THE LIVE SESSIONS AS THE LEDGER SPELLS THEM: the supervisor pid the board keys its rows
        // by, with the instant that supervisor started. The pair is the identity, because the
        // ledger outlives the sessions in it and a pid is handed out again
        // (`SessionProcessGroup.sessionStartedAt`). A root the process table does not hold is
        // simply absent, which is the same answer the loop below gives it.
        var sessions: [String: Int64] = [:]
        for (root, _, _) in roots {
            if let at = began(root) { sessions[String(root)] = at }
        }
        // WHAT THE TREE WALK REACHES ON ITS OWN, taken for every card before any of them is
        // measured, because the adoption below is decided against ALL of them at once: a process
        // already inside somebody's tree must never be adopted onto a second card, and a process
        // outside every tree is the only kind there is anything to decide about.
        var reached: [pid_t: Set<pid_t>] = [:]
        var claimed: Set<pid_t> = []
        for (root, _, _) in roots {
            let found = ProcessTree.members(root: root, processes: processes)
            reached[root] = found
            claimed.formUnion(found)
        }
        // THE JOBS THAT HAVE LEFT THEIR TREES, matched back by the group they still carry. Read from
        // memory rather than from the file (see `groupLedger`), and skipped entirely on a board with
        // nothing on it - an empty roster is "not asked" rather than "nothing is running".
        let ledger = sessions.isEmpty ? SessionProcessGroups.Index()
            : (groupLedger ?? SessionProcessGroups.Index(machine.ledger ?? []))
        let adopted = ledger.entries.isEmpty ? [:] : SessionProcessGroups.adoptions(
            unclaimed: processes.lazy.filter { !claimed.contains($0.pid) },
            in: ledger, sessions: sessions, startedAt: began)
        // HOW LONG EACH CLAIMED GROUP HAS BEEN GONE, counted only on a walk that saw something: an
        // empty table is a question nobody asked, and retiring a job on it would be reading the
        // silence for an answer (`SessionProcessGroups.absences`).
        let absences = processes.isEmpty
            ? SessionProcessGroups.Absences(ticks: groupAbsentTicks, expired: false)
            : SessionProcessGroups.absences(in: ledger, seeing: liveGroups, after: groupAbsentTicks,
                                            stillAlive: SessionProcessGroups.stillAlive)
        groupAbsentTicks = absences.ticks
        // The claims this tick has to add to the ledger, gathered across every card and written
        // once: each write is a lock and a whole-file rewrite, and a board of ten sessions starting
        // commands would otherwise take ten of them in one tick.
        var claims: [SessionProcessGroup] = []
        // WHAT IS RUNNING IN THOSE DIRECTORIES THAT NO CARD ACCOUNTS FOR: the rollup's own work,
        // next door, being a second reading of the pass just made rather than another pass, and
        // this file had run out of room (`ProjectLoadAccounting.strays`, which is also where the
        // scratchpad signal is).
        // The stamps and the hosts are this store's state and stay here; the per-pid reads go off
        // the main thread (`ProjectLoadAccounting.strayScan`).
        let taken = rollup.strayCandidates(among: processes, claimed: claimed, adopted: adopted,
                                           board: board, roots: rollup.accounted)
        let accounted = rollup.accounted
        let (strayRoot, adoptions) = await Task.detached(priority: .utility) {
            ProjectLoadAccounting.strayScan(among: processes, taken: taken, adopted: adopted,
                                            board: board, roots: accounted)
        }.value
        // THE FULL MEMBERSHIP OF EVERY CARD, settled before any of them is measured: an adopted job's
        // own children come in with it, and those must come OUT of the strays below or the page
        // would count them twice - once on a card and once as work nobody is answering for. The
        // subtraction itself is a rule next door (`MachineLoadRollup.leftovers`), which is where the
        // case that needs it is stated.
        //
        // AND THE WALK IS ONLY MADE AGAIN WHERE IT COULD ANSWER DIFFERENTLY. The adoptions are the
        // only seeds `members` takes beyond the root's own tree and job, so with nothing adopted the
        // second walk rebuilds the whole table's parent index to arrive at the set already in hand -
        // per card, on the ordinary board where nothing is adopted at all.
        var membership: [String: Set<pid_t>] = [:]
        var counted: Set<pid_t> = []
        for (root, _, _) in roots {
            let orphans = adoptions[String(root)] ?? []
            let full = orphans.isEmpty
                ? (reached[root] ?? [])
                : ProcessTree.members(root: root, processes: processes, adopting: orphans)
            membership[String(root)] = full
            counted.formUnion(full)
        }
        // On screen only, and see the file's note for why: this is the one reading here that costs
        // enough to be worth switching off, and nothing behind a closed panel draws it.
        let readPorts = viewers > 0 && ticks % Self.portsEveryNTicks == 0
        let readAgents = viewers > 0
        // EVERY TREE'S OWN READINGS, taken off the main thread in one hop before any card is built
        // (`FootprintTreeReads`): per tree a program table, a resource sample, and on screen the
        // ports and the subagent count.
        let targets = roots.map { ($0.0, membership[String($0.0)] ?? []) }
        let trees = await Task.detached(priority: .utility) {
            FootprintTreeReads.take(targets, readPorts: readPorts, readAgents: readAgents, at: now)
        }.value
        /// When this tick LOOKED, which is what a claim written below records - the same
        /// distinction the worktree ledger draws between observing and writing.
        let observedAt = SessionProcessGroups.timestamp(now)
        // WHAT THE MACHINE SAYS ABOUT ITS OWN MEMORY, once for the whole tick: it is a fact about
        // the machine rather than about any card, so ten cards must not produce ten readings at ten
        // instants - "the machine was short when this session was measured" has to mean the same
        // instant on every card of one board (`MachineMemoryPressure`). It is the second witness
        // the memory tier needs, because the per-process figures below count a shared page once per
        // mapper and the kernel counts it once (`FootprintAlarm.saturatedMemoryShare`).
        let pressure = machine.pressure
        var readings: [String: ProcessResourceSample] = [:]
        var carried: [String: ProcessCPUCarry] = [:]
        var trends = history
        // Every session that turned out to HAVE a reading, in the order the board listed them, held
        // until the loop is done rather than published inside it. Only one thing needs that (the
        // fixtures are keyed by the cards that will actually be drawn), and it is worth the one
        // array: keyed by the roster instead, a root the two guards below skip took its fixture
        // with it and the warned card simply was not in the capture.
        var measurements: [FootprintMeasurement] = []
        for (root, idle, child) in roots {
            let key = String(root)
            // THE TREE, PLUS THE JOBS THAT HAVE LEFT IT. The adoptions were decided for the whole
            // board above, so nothing here can take a process another card is already counting; fed
            // back into the same walk, an adopted server's own children come with it.
            let orphans = adoptions[key] ?? []
            let members = membership[key] ?? []
            guard !members.isEmpty, let tree = trees[root] else { continue }
            // Every program in the tree, once: the same table answers which of these processes are
            // Tally's own and what to call the one that earned a name.
            let paths = tree.paths
            // WHAT THE AI IS DOING, WHICH IS NOT WHAT THE METER IS DOING. The supervisor is in
            // every tree by construction, so Tally's own processes come out before anything is
            // counted (`ProcessTree.ownFamily` says why the test is the program rather than the
            // name). A tree with nothing left is a session whose Claude Code has gone home: no
            // entry, so the card draws no line at all, which is the honest reading of it.
            let ours = tree.ours
            let measured = members.subtracting(ours)
            guard !measured.isEmpty else { continue }
            // What to call whichever pid an interval blamed, out of the same table: nothing when
            // the program could not be read, which is ordinary here rather than an error - the
            // culprit can be a command that finished inside the interval.
            func name(of pid: pid_t?) -> String? {
                pid.flatMap { paths[$0].flatMap(ProcessTree.displayName) }
            }
            // EVERY JOB THIS TREE IS CARRYING, WRITTEN DOWN WHILE IT IS STILL REACHABLE. This is the
            // whole of the repair: by the time a job matters - its own shell gone, its survivors
            // re-parented to launchd - nothing alive is in the tree to say whose it was
            // (`SessionProcessGroups`). Taken over the members INCLUDING the adopted ones, which
            // costs nothing and keeps the claim's own identity fresh; the ledger drops what it
            // already answers for, so the steady state adds nothing and writes nothing.
            if let sessionStartedAt = sessions[key] {
                let seen = SessionProcessGroups.observed(
                    members: members.compactMap { identities[$0] }, startedAt: began,
                    name: { paths[$0].flatMap(ProcessTree.displayName) })
                claims += SessionProcessGroups.claims(seen, session: key,
                                                      sessionStartedAt: sessionStartedAt,
                                                      against: ledger, at: observedAt)
            }
            // Held rather than looked up twice, because the ring needs the INSTANT it was taken as
            // well as the counters: how long the rate below covers is the gap between the two
            // readings, and that is not the sampler's interval on the tick a surface opened
            // (`FootprintTrendSample.seconds`).
            let previous = previousSample[key]
            // THE WHOLE TREE IS SAMPLED AND OURS ARE TAKEN OUT INSIDE EACH READING, rather than
            // filtered off the pid list first. Filtering here looks equivalent and is not: one of
            // ours that ends between two ticks leaves its seconds in the counters of whoever
            // collected it, which is Claude Code, and a pid that was never sampled can never be
            // seen to depart - so nothing cancels them (`ProcessResourceSample.ours`).
            let reading = tree.reading
            readings[key] = reading
            let cpu = ProcessTree.cpuPercent(from: previous, to: reading,
                                             carry: cpuCarry[key] ?? ProcessCPUCarry())
            let disk = ProcessTree.diskWrite(from: previous, to: reading)
            carried[key] = cpu.carry
            if readPorts {
                ports[key] = ProcessTree.held(tree.listening ?? [:],
                                              startedAt: began)
            }
            let holding = ports[key] ?? [:]
            // THE COUNT IS OF WHAT THE SESSION STARTED AND THE REST OF THE READINGS ARE OF THE
            // WHOLE TREE, which is one decision rather than an inconsistency: the count answers
            // "how much has this session put on my machine" and the CPU and the memory answer "what
            // is it costing me", and its own Claude Code is not the first and is very much the
            // second. What keeps the pair readable is the NAME beside the memory figure - the one
            // thing on the card that can say those gigabytes are the body rather than the work
            // (`ProcessTree.memoryLeader`).
            let started = ProcessTree.dispatched(measured, child: child)
            let footprint = ProcessFootprint(
                processes: started.count,
                // How many of those the walk could not have reached: the adopted jobs and everything
                // they have since started. Counted on the MEASURED set, so a job of ours (a hook
                // that outlived its parent) is no more countable here than anywhere else on the
                // card, and taken as a subtraction from the whole rather than from `orphans`, whose
                // own children are as background as it is.
                backgroundProcesses: orphans.isEmpty
                    ? 0 : measured.subtracting(reached[root] ?? []).count,
                // The subagents are the one reading here that is not taken from the machine: they
                // are conversations inside a process, so Claude Code's own hooks say how many
                // (`SessionAgentsRecord`), and a count that cannot be believed is not drawn. Held
                // rather than re-read behind a closed panel, on the ports' terms: it is a file per
                // session per tick for a figure no card is drawing, and the tick that reopens the
                // board reads it before anything is laid out (`beginViewing`).
                agents: tree.agents ?? (footprints[key]?.agents ?? 0),
                cpuPercent: cpu.percent,
                cpuLeader: name(of: cpu.leader),
                memoryBytes: reading.memoryBytes,
                memoryLeader: name(of: ProcessTree.memoryLeader(reading)),
                diskWriteBytesPerSecond: disk.bytesPerSecond,
                diskLeader: name(of: disk.leader),
                listeningPorts: holding.keys.sorted(),
                portNames: ProcessTree.portNames(holding, startedAt: began,
                                                 executable: { paths[$0] }))
            // WHETHER THERE IS A RATE TO RECORD AT ALL is a question about the PAIR of readings,
            // which no fixture can answer, so it is settled here on the machine's own numbers: the
            // first pair has no interval yet, and a zero written where "not measured yet" belongs
            // would draw a dip the machine never had.
            //
            // AND THE INTERVAL GOES WITH THE RATE, because the two rates meet INSIDE a bucket every
            // time somebody opens the board: the reading taken at that instant covers the ten
            // seconds the slow timer had been running, and the fast ones after it cover two each.
            // Folded flat they made a peak out of the opening (`FootprintTrendSample.folded`).
            let interval = cpu.percent != nil ? previous.map { now.timeIntervalSince($0.at) } : nil
            measurements.append(FootprintMeasurement(key: key, footprint: footprint,
                                                     interval: interval, idle: idle))
        }
        // WHAT EACH CARD ACTUALLY SAYS, once every card has been read: the warnings, the capture's
        // fixtures and the trend point, which are one step rather than three because they have to
        // agree with each other (`painted`, next door, carries the whole of why).
        let painted = painted(measurements, pressure: pressure, trends: &trends, at: now)
        let next = painted.drawn
        // WHETHER THE CARDS ADD UP, taken from the footprints the cards will actually DRAW rather
        // than from the readings above: on a capture those are fixtures, and a rollup summing the
        // machine's real numbers under a board of invented ones would contradict every card on the
        // page (the same reason the ring is offered the drawn footprint one loop up).
        // …with a session that runs INSIDE another one counted once (`MachineLoadRollup.nested`).
        let byProject = MachineLoadRollup.readings(of: next, roots: rootOfSession,
                                                   members: membership)
        // And the strays as they stand once the cards are settled: minus whatever a card turned out
        // to be counting, which is the adopted jobs' own children (`MachineLoadRollup.leftovers`).
        let unattributed = MachineLoadRollup.leftovers(strays: strayRoot, counted: counted)
        // The strays' own counters, read off the main thread like every other reading of the pass;
        // what they are paired against stays with the rollup (`ProjectLoadAccounting.readStrays`).
        let pools = rollup.accounted.isEmpty || DemoUsage.isActive ? [:] : rollup.strayPools(unattributed)
        let strayReads = await Task.detached(priority: .utility) {
            ProjectLoadAccounting.readStrays(pools, at: now)
        }.value
        let load = rollup.accounted.isEmpty
            ? MachineLoad()
            : rollup.load(sessions: byProject, strays: unattributed, at: now, reads: strayReads)
        // AND WHETHER ANY OF IT SHOULD STILL BE RUNNING (`OrphanReclaimStore`, which paces itself).
        // THE SESSIONS GO WITH THE STRAYS: a checkout somebody is working in is one whose leftovers
        // this app reports rather than ends (`OrphanReclaim.Veto.sessionPresent`).
        //
        // TAKEN FROM THE ROSTER RATHER THAN FROM THE CARDS, which is the one place in this pass
        // where the two must not be the same set. A card is dropped whenever its tree is
        // momentarily empty - a supervisor between children, a session whose Claude Code has gone
        // home - by the two guards in the loop above, and `readings` carries that hole through
        // (`MachineLoadRollup.readings`). The roster still holds that session and its directory,
        // and the difference between the two sets is a live session's dev server being signalled
        // in the checkout its own session is sitting in.
        //
        // AND WIDE IS THE SAFE DIRECTION HERE, which is why the wider set is the right one rather
        // than merely the larger. A root too many costs a message where a kill would have been; a
        // root too few costs somebody's server, ended under them, under a message saying nobody
        // was working there. The board's own rows are drawn from the cards as before: what is being
        // decided here is not what the page says but what may be killed.
        //
        // AND THE SET GOES OVER WITH ITS OWN COMPLETENESS BESIDE IT, which is the half a set cannot
        // carry: a roster row that published no directory at all is dropped by the map above
        // (`ProjectLoadAccounting.boardUnreadable`), and a dropped row is indistinguishable from a
        // machine with one session fewer. Named, the round fails closed instead of inferring.
        OrphanReclaimStore.shared.observe(
            strays: unattributed, processes: processes,
            sessions: OrphanReclaim.Sessions(checkouts: Set(rootOfSession.values),
                                             unreadable: rollup.boardUnreadable),
            at: now, leases: machine.leases)
        previousSample = readings
        cpuCarry = carried
        alertState = painted.alerts
        // THE LEDGER IS TOUCHED ONLY WHEN IT HAS SOMETHING TO SAY, which is what makes it
        // affordable on a two-second timer: a session running the jobs it was already running adds
        // no claims, and a board whose sessions are all still live has nothing to sweep, so the
        // steady state is one comparison and no file at all. Skipped outright on an empty roster,
        // where the sweep would read "nothing is running" off a question nobody asked
        // (`SessionProcessGroups.swept`).
        if !sessions.isEmpty {
            let stale = ledger.entries.contains { sessions[$0.session] != $0.sessionStartedAt }
            // ...and a third thing to say: a group whose last member has now been gone long enough
            // to retire its claims. Without it the retirement would wait for whichever session next
            // happened to start a command.
            if claims.isEmpty && !stale && !absences.expired {
                groupLedger = ledger
            } else {
                // WRITTEN OFF THE MAIN THREAD: a lock, a read and an atomic rewrite held the menu bar
                // on a loaded machine (Sentry TALLY-S, 2026-09-26). Still one writer at a time: this
                // pass awaits the write, and passes run one at a time (`sampleGate`).
                let absent = absences.ticks
                let written = await Task.detached(priority: .utility) {
                    SessionProcessGroups.record(claims, sessions: sessions, liveGroups: liveGroups,
                                                absentFor: { absent[$0] ?? 0 })
                }.value
                groupLedger = SessionProcessGroups.Index(written)
            }
        }
        // A pid is handed out again once its session has gone, so a series left behind would be
        // adopted by an unrelated tree and drawn as its own history.
        //
        // SWEPT AGAINST THE BOARD RATHER THAN AGAINST THIS TICK'S READINGS, and the difference is a
        // tree that could not be read for one pass: it has no entry above, and sweeping on that
        // would throw a quarter hour of history away over a single unreadable tick. The roster is
        // the thing that says a session has ENDED.
        trends.retain(Set(roots.map { String($0.0) }))
        // A session that has ended must not leave its ports behind for a pid the machine will hand
        // out again: the cache is only ever a stand-in for the tick that did not read them.
        ports = ports.filter { next[$0.key] != nil }
        ticks += 1
        publish(load: load, projects: rootOfSession, trends: trends, drawn: next)
    }
}
