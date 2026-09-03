import Foundation
import Observation

/// WHAT EACH SESSION'S PROCESS TREE IS COSTING, now and over the last quarter of an hour.
///
/// A STORE OF ITS OWN rather than another reading on the roster: the roster is a reader of files the
/// supervisors wrote (`SessionRosterStore`), which is cheap enough to run on a knock with no window
/// open at all, and this walks the process table. The two are still switched separately, because
/// they answer to different surfaces - the roster keeps the menu bar's blocked dot honest, and this
/// one exists for the Sessions page (`sessionsPage`).
///
/// TWO RATES, ONE PASS. The board asks for the current figures every two seconds while it is on
/// screen, because a number somebody is watching must not visibly lag the machine; with nothing
/// open the same pass runs every ten. It used to run at neither rate with the page closed, and the
/// trend line is why that changed: a history that only exists while somebody is looking is empty at
/// the exact moment it is wanted, since a person opens this board BECAUSE something already felt
/// wrong. The kept series is even at ten seconds whichever rate produced it, and says the same
/// thing at either: the fast ticks are folded into the point being assembled rather than dropped,
/// so a spike between two kept points is in the line (`FootprintTrendSample.folded`).
///
/// WHAT THE BACKGROUND RATE COSTS, measured on this machine rather than assumed: one pass over the
/// process table plus one `proc_pid_rusage` and one `proc_pidpath` per process in the trees. See
/// the note on `backgroundInterval` for the reading.
///
/// THE PORTS NEVER GO BEHIND THE PANEL. They are a descriptor table per process and a call per
/// socket on top of the pass above, which is the one reading here expensive enough to be worth
/// switching off, and nothing needs them while there is no card to draw them on. On screen they are
/// read every third tick and held in between: a dev server that came up six seconds ago is news
/// soon enough.
@MainActor
@Observable
final class ProcessFootprintStore {
    static let shared = ProcessFootprintStore()

    /// One entry per session that has a live tree, keyed by supervisor pid as the board spells it
    /// (`SessionRosterStore.SessionRow.id`). A session whose supervisor is already gone has no
    /// entry rather than an empty one: its card then draws no footprint line, which is the honest
    /// reading of "there is nothing to measure".
    private(set) var footprints: [String: ProcessFootprint] = [:]

    /// The same readings kept over time, one series per session (`FootprintHistory`). Observed like
    /// the figures above, because the card draws both from the same tick.
    private(set) var history = FootprintHistory()

    /// WHAT THE WHOLE MACHINE IS DOING IN THESE PROJECTS, sessions and strays alike
    /// (`MachineLoadRollup`). The one reading on this page that is not about a card: it is what
    /// says whether the cards ADD UP, which nothing here could say before.
    private(set) var machineLoad = MachineLoad()

    /// WHICH PROJECT EACH CARD IS WORKING IN, keyed the way the board keys its rows.
    ///
    /// THE BOARD CANNOT WORK THIS OUT FOR ITSELF, which is why it is published rather than left
    /// inside the accounting: a row's directory is whatever its supervisor wrote, and a project is
    /// that path RESOLVED (`ProjectLoadAccounting.roots`), so a page comparing the two spellings
    /// would file a card under a project the rollup has never heard of wherever a symlink sits in
    /// the way. Two readers need the join - the unclaimed cards, which sit beside the sessions of
    /// their own checkout, and the flame, which is decided on a project and drawn on a card
    /// (`SessionBoardGhosts`).
    private(set) var sessionProjects: [String: String] = [:]

    /// How long between samples while the board is on screen. The board's own scan interval, so a
    /// card gains its processes and its state in the same beat.
    static let visibleInterval: TimeInterval = 2
    /// And with nothing open: the trend's own cadence, so a closed panel adds no points the ring
    /// would refuse anyway (`FootprintTrendSeries.cadence`).
    ///
    /// MEASURED RATHER THAN ASSUMED, because this is the one thing here that runs when nobody asked
    /// for it. On this machine (2026-08-15, Apple silicon, 754 processes in the table and six
    /// supervised trees holding 65 processes between them) one whole pass - the table walk, then
    /// every tree's members, their executable paths and their rusage counters - averages 0.5 to
    /// 0.6 ms over twenty runs, which at this rate is about 0.005% of one core. It scales with the
    /// machine's process count rather than with the number of sessions, since the walk dominates.
    ///
    /// THAT READING PREDATES THE ROSTER SCAN THIS PASS NOW MAKES WITH NOTHING OPEN (see `sample`),
    /// and has not been retaken: the scan is a few small file reads per session, which the roster's
    /// own note calls cheap enough to make on a knock with no window at all, but nobody has put a
    /// number on the pair together. Stated rather than folded into the figure above, because a
    /// measurement that quietly grows a term is worse than one that says what it left out.
    static let backgroundInterval: TimeInterval = 10
    /// How many visible ticks pass between two readings of the ports (see the note above).
    private static let portsEveryNTicks = 3

    // THE SIX BELOW ARE NOT `private` BECAUSE THE TIMER IS NEXT DOOR. When this file passed the
    // repo's 500-line cap the lifecycle went into ProcessFootprintTiming.swift, along the seam the
    // class already had: what it HOLDS and what one pass DOES stayed here, when the pass runs went
    // there. Swift's `private` is file-scoped, so the rate, the audience and the ports cache are
    // module-visible - the same trade `UsageStore` made for the same reason.
    //
    // THE SIXTH IS `alertState`, and it went the same way for the same reason: the file passed the
    // cap a second time, and the piece that moved was the step that turns every card's reading into
    // what the card SAYS (`painted`), which is what carries the warnings from tick to tick.
    @ObservationIgnored var timer: Timer?
    /// What the running timer's interval is, so a rate that has not changed is not restarted (which
    /// would push the next sample a whole interval away every time a surface appeared).
    @ObservationIgnored var timerInterval: TimeInterval?
    @ObservationIgnored var viewers = 0
    @ObservationIgnored var ticks = 0
    /// The previous reading per session, which is the whole of what makes a rate possible
    /// (`ProcessTree.cpuPercent`, `ProcessTree.diskWrite`). Kept across a closed panel now that the
    /// pass keeps running behind it: it is never more than one background interval old, so a card
    /// states a rate over the last ten seconds rather than over the hour nobody watched.
    @ObservationIgnored private var previousSample: [String: ProcessResourceSample] = [:]
    /// Per session, the departed-process CPU credit the last pair of readings could not settle. It
    /// exists because a child dies on one tick and is collected on the next, and without carrying
    /// the credit across that gap the collection reads as a burst of work that was already counted
    /// (`ProcessTree.cpuPercent`). One tick of memory, deliberately: the rule that bounds it lives
    /// in the pure function, and this only has to hand the number back.
    @ObservationIgnored private var cpuCarry: [String: ProcessCPUCarry] = [:]
    /// WHICH JOBS EACH SESSION HAS STARTED, so a job that is re-parented to launchd when its own
    /// shell exits can still be matched back to the session that started it
    /// (`SessionProcessGroups`, which is also where the incident this exists for is written down).
    ///
    /// HELD IN MEMORY AND WRITTEN THROUGH, rather than re-read every tick: this app is the only
    /// writer, so what is here IS the file, and reading it back twice a second would be a file read
    /// per tick for an answer this process just wrote. Nil until the first tick that needs it - a
    /// launch with no sessions running never touches the file at all. Indexed by group as it is
    /// taken in, which is the only question either reading of it asks (`SessionProcessGroups.
    /// Index`).
    @ObservationIgnored private var groupLedger: SessionProcessGroups.Index?
    /// Per group the ledger still claims, how many consecutive non-empty walks it has been missing
    /// from: the evidence a claim is retired on, held here because the rule that reads it is pure
    /// (`SessionProcessGroups.absences`). A group seen again resets, and a tick that walked nothing
    /// leaves it alone, since silence is not absence.
    @ObservationIgnored private var groupAbsentTicks: [pid_t: Int] = [:]
    /// EVERYTHING THE PROJECT ROLLUP NEEDS TO REMEMBER, which is its own object next door
    /// (`ProjectLoadAccounting`): the strays' previous readings, what their pairs could not settle,
    /// and each session directory as the machine spells it. Held apart from the readings above
    /// because it answers a different question - not "what is this card costing" but "do the cards
    /// add up" - and because this file had run out of room.
    @ObservationIgnored private let rollup = ProjectLoadAccounting()
    /// The last ports reading per session, each with the process that was holding it AND the
    /// instant that process started, held between the ticks that do not take one.
    ///
    /// TWO TICKS IS AS OLD AS THIS GETS, which is worth stating precisely because the cheap thing
    /// to assume is that it is much older: the reading is taken on one visible tick in three, and
    /// the whole cache is dropped when the last viewer goes (`endViewing`), which the next opening
    /// re-reads on its first tick (`beginViewing` puts the count back to zero). So a held pid is at
    /// most four seconds behind the machine.
    ///
    /// THE START TIME IS WHAT MAKES A HELD READING SAFE TO NAME, and it is not the width of that
    /// window that earns it: the machine hands pid numbers out again, so a name looked up for an
    /// old pid in the current table can belong to a process that has never held that port, and four
    /// seconds is enough for a restarted dev server to be a different process wearing the same
    /// number. Naming is therefore conditional on the holder being the same process it was
    /// (`ProcessTree.portNames`), and anything else prints the bare number.
    @ObservationIgnored var ports: [String: [UInt16: ProcessPortHolder]] = [:]
    /// Per session, how long each warning condition has been met or missed. A warning is about a
    /// condition that HOLDS rather than about one tick's reading, so something has to count the
    /// ticks, and this is the only thing here that knows what a tick is (`FootprintAlerts.swift`).
    @ObservationIgnored var alertState: [String: FootprintAlertState] = [:]

    private init() {}

    /// One pass: the process table once, then each session's own tree out of it.
    ///
    /// THE ROSTER SAYS WHICH TREES THERE ARE, so this never has to decide what a session is - it
    /// reads the board's own rows and asks the machine about their pids. A board with nothing on it
    /// costs a dictionary assignment.
    func sample() {
        // THE ROSTER IS NOT SCANNING BEHIND THE PANEL, and this pass consumes it. Its own timer
        // runs only while a surface is up; with nothing open it is refreshed by the supervisors'
        // knock, which is not a delivery anything can rely on (a session killed outright never
        // knocks). So a session that ended while nobody was looking would stay on this list, and
        // the walk below would go on reading a process GROUP the machine is free to hand out again
        // - appending an unrelated job's readings to a dead session's series. One synchronous scan,
        // at the rate this pass already runs at, rather than a second timer: the roster's own note
        // says a scan is cheap enough to make on a knock with no window open at all.
        if viewers == 0 { SessionRosterStore.shared.refresh() }
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
        let processes = roots.isEmpty && rollup.accounted.isEmpty
            ? [] : ProcessTree.liveProcesses()
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
            : (groupLedger ?? SessionProcessGroups.Index(SessionProcessGroups.load()))
        let adopted = ledger.entries.isEmpty ? [:] : SessionProcessGroups.adoptions(
            unclaimed: processes.lazy.filter { !claimed.contains($0.pid) },
            in: ledger, sessions: sessions, startedAt: began)
        // HOW LONG EACH CLAIMED GROUP HAS BEEN GONE, counted only on a walk that saw something: an
        // empty table is a question nobody asked, and retiring a job on it would be reading the
        // silence for an answer (`SessionProcessGroups.absences`).
        let absences = processes.isEmpty
            ? SessionProcessGroups.Absences(ticks: groupAbsentTicks, expired: false)
            : SessionProcessGroups.absences(in: ledger, seeing: liveGroups, after: groupAbsentTicks)
        groupAbsentTicks = absences.ticks
        // The claims this tick has to add to the ledger, gathered across every card and written
        // once: each write is a lock and a whole-file rewrite, and a board of ten sessions starting
        // commands would otherwise take ten of them in one tick.
        var claims: [SessionProcessGroup] = []
        // WHAT IS RUNNING IN THOSE DIRECTORIES THAT NO CARD ACCOUNTS FOR: the rollup's own work,
        // next door, being a second reading of the pass just made rather than another pass, and
        // this file had run out of room (`ProjectLoadAccounting.strays`, which is also where the
        // scratchpad signal is).
        let (strayRoot, adoptions) = rollup.strays(among: processes, claimed: claimed,
                                                   adopted: adopted, board: board,
                                                   roots: rollup.accounted)
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
        let now = Date()
        /// When this tick LOOKED, which is what a claim written below records - the same
        /// distinction the worktree ledger draws between observing and writing.
        let observedAt = SessionProcessGroups.timestamp(now)
        // WHAT THE MACHINE SAYS ABOUT ITS OWN MEMORY, once for the whole tick: it is a fact about
        // the machine rather than about any card, so ten cards must not produce ten readings at ten
        // instants - "the machine was short when this session was measured" has to mean the same
        // instant on every card of one board (`MachineMemoryPressure`). It is the second witness
        // the memory tier needs, because the per-process figures below count a shared page once per
        // mapper and the kernel counts it once (`FootprintAlarm.saturatedMemoryShare`).
        let pressure = MachineMemoryPressure.current
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
            guard !members.isEmpty else { continue }
            // Every program in the tree, once: the same table answers which of these processes are
            // Tally's own and what to call the one that earned a name.
            let paths = ProcessTree.executablePaths(of: members)
            // WHAT THE AI IS DOING, WHICH IS NOT WHAT THE METER IS DOING. The supervisor is in
            // every tree by construction, so Tally's own processes come out before anything is
            // counted (`ProcessTree.ownFamily` says why the test is the program rather than the
            // name). A tree with nothing left is a session whose Claude Code has gone home: no
            // entry, so the card draws no line at all, which is the honest reading of it.
            let ours = ProcessTree.ownFamily(members, root: root) { paths[$0] }
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
            let reading = ProcessTree.resourceSample(of: members, ours: ours, at: now)
            readings[key] = reading
            let cpu = ProcessTree.cpuPercent(from: previous, to: reading,
                                             carry: cpuCarry[key] ?? ProcessCPUCarry())
            let disk = ProcessTree.diskWrite(from: previous, to: reading)
            carried[key] = cpu.carry
            if readPorts {
                ports[key] = ProcessTree.held(ProcessTree.listeningPorts(of: measured),
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
                agents: viewers > 0 ? (readSessionAgents(pid: key)?.reportable ?? 0)
                                    : (footprints[key]?.agents ?? 0),
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
        let load = rollup.accounted.isEmpty
            ? MachineLoad() : rollup.load(sessions: byProject, strays: unattributed, at: now)
        if load != machineLoad { machineLoad = load }
        // Assigned only when it moved, for the reason every other observed field here is: this is
        // the same answer on every tick of a board nobody has changed, and re-publishing it would
        // re-render every card twice a second for a map that did not move.
        if rootOfSession != sessionProjects { sessionProjects = rootOfSession }
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
            at: now)
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
            groupLedger = claims.isEmpty && !stale && !absences.expired ? ledger
                : SessionProcessGroups.Index(
                    SessionProcessGroups.record(claims, sessions: sessions, liveGroups: liveGroups,
                                                absentFor: { absences.ticks[$0] ?? 0 }))
        }
        // A pid is handed out again once its session has gone, so a series left behind would be
        // adopted by an unrelated tree and drawn as its own history.
        //
        // SWEPT AGAINST THE BOARD RATHER THAN AGAINST THIS TICK'S READINGS, and the difference is a
        // tree that could not be read for one pass: it has no entry above, and sweeping on that
        // would throw a quarter hour of history away over a single unreadable tick. The roster is
        // the thing that says a session has ENDED.
        trends.retain(Set(roots.map { String($0.0) }))
        // Assigned only when it moved, for the reason the figures below are: `record` is a mutating
        // call whether or not the ring closed a point on it, and an observed property notices the
        // call rather than the change. The ring now carries the readings BETWEEN points as well as
        // the points, so a tick that only added to the bucket does move it - what the guard still
        // saves is the idle board where nothing was recorded at all (no session, or no rate yet).
        if trends != history { history = trends }
        // A session that has ended must not leave its ports behind for a pid the machine will hand
        // out again: the cache is only ever a stand-in for the tick that did not read them.
        ports = ports.filter { next[$0.key] != nil }
        ticks += 1
        // Nothing moved is an ordinary tick on an idle board, and assigning anyway would re-render
        // every card on it twice a second for numbers that did not change.
        guard next != footprints else { return }
        footprints = next
    }
}
