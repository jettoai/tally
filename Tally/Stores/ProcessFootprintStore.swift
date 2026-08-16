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

    /// How long between samples while the board is on screen. The board's own scan interval, so a
    /// card gains its processes and its state in the same beat.
    private static let visibleInterval: TimeInterval = 2
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
    private static let backgroundInterval: TimeInterval = 10
    /// How many visible ticks pass between two readings of the ports (see the note above).
    private static let portsEveryNTicks = 3

    @ObservationIgnored private var timer: Timer?
    /// What the running timer's interval is, so a rate that has not changed is not restarted (which
    /// would push the next sample a whole interval away every time a surface appeared).
    @ObservationIgnored private var timerInterval: TimeInterval?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var ticks = 0
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
    @ObservationIgnored private var cpuCarry: [String: Double] = [:]
    /// The last ports reading per session, each with the pid holding it, held between the ticks
    /// that do not take one. The NAME beside a port is resolved from the current tick's own table
    /// of programs rather than cached with it, so a port whose holder has since gone is printed as
    /// the bare number instead of by a name that is no longer true.
    @ObservationIgnored private var ports: [String: [UInt16: pid_t]] = [:]
    /// Per session, how long each warning condition has been met or missed. A warning is about a
    /// condition that HOLDS rather than about one tick's reading, so something has to count the
    /// ticks, and this is the only thing here that knows what a tick is (`FootprintAlerts.swift`).
    @ObservationIgnored private var alertState: [String: FootprintAlertState] = [:]

    private init() {}

    /// Start sampling for the life of the process, at the background rate. Called once at launch,
    /// exactly as the roster's own observer is (`SessionRosterStore.install`), and for the same
    /// reason: a registration that is missed is a feature that silently never runs.
    func install() { retime() }

    /// A surface showing the board has appeared. Samples at once, because what somebody just opened
    /// has to say something before the first tick rather than after it, and resets the tick count so
    /// that first sample is the one that reads the ports.
    func beginViewing() {
        if viewers == 0 { ticks = 0 }
        viewers += 1
        retime()
        sample()
    }

    /// The last surface showing the board has gone. The readings go on being taken, slower: what is
    /// dropped is only what is exclusively the panel's, which is the ports (nothing draws them, and
    /// a pid the machine hands out again must never inherit them).
    func endViewing() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        retime()
        ports = [:]
    }

    /// Put the timer on the rate the current audience deserves, and only when that rate changed.
    private func retime() {
        let wanted = viewers > 0 ? Self.visibleInterval : Self.backgroundInterval
        guard timerInterval != wanted else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: wanted, repeats: true) { _ in
            Task { @MainActor in ProcessFootprintStore.shared.sample() }
        }
        // `.common`, so the readings keep coming while a menu or a scroll is tracking - the same
        // reason the roster's own timer is registered that way.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = wanted
    }

    /// One pass: the process table once, then each session's own tree out of it.
    ///
    /// THE ROSTER SAYS WHICH TREES THERE ARE, so this never has to decide what a session is - it
    /// reads the board's own rows and asks the machine about their pids. A board with nothing on it
    /// costs a dictionary assignment.
    private func sample() {
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
        let roots = SessionRosterStore.shared.rows.compactMap { row in
            pid_t(row.id).map { ($0, row.state == .idle || row.state == .blocked,
                                 row.childPid.flatMap { pid_t(exactly: $0) }) }
        }
        // A board with nothing on it is not a special case, only an empty one: no table is walked,
        // the loop below does not run, and everything held falls out through the same three lines
        // that retire a single session that ended.
        let processes = roots.isEmpty ? [] : ProcessTree.liveProcesses()
        // On screen only, and see the file's note for why: this is the one reading here that costs
        // enough to be worth switching off, and nothing behind a closed panel draws it.
        let readPorts = viewers > 0 && ticks % Self.portsEveryNTicks == 0
        let now = Date()
        var next: [String: ProcessFootprint] = [:]
        var readings: [String: ProcessResourceSample] = [:]
        var carried: [String: Double] = [:]
        var alerting: [String: FootprintAlertState] = [:]
        var trends = history
        for (root, idle, child) in roots {
            let members = ProcessTree.members(root: root, processes: processes)
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
            let key = String(root)
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
                                             carry: cpuCarry[key] ?? 0)
            let disk = ProcessTree.diskWrite(from: previous, to: reading)
            carried[key] = cpu.carry
            if readPorts { ports[key] = ProcessTree.listeningPorts(of: measured) }
            let holding = ports[key] ?? [:]
            // THE COUNT IS OF WHAT THE SESSION STARTED AND THE REST OF THE READINGS ARE OF THE
            // WHOLE TREE, which is one decision rather than an inconsistency: the count answers
            // "how much has this session put on my machine" and the CPU and the memory answer "what
            // is it costing me", and its own Claude Code is not the first and is very much the
            // second. What keeps the pair readable is the NAME beside the memory figure - the one
            // thing on the card that can say those gigabytes are the body rather than the work
            // (`ProcessTree.memoryLeader`).
            let started = ProcessTree.dispatched(measured, child: child)
            var footprint = ProcessFootprint(
                processes: started.count,
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
                portNames: holding.compactMapValues { name(of: $0) })
            // The warnings are decided from THIS tick's reading and the ticks before it, then put
            // back on the same reading: what the card draws and what the card warns about are one
            // value, so they cannot be a tick apart.
            //
            // A TICK IS NOT ALWAYS TWO SECONDS, which is why the rule is handed the INSTANT rather
            // than counting ticks (`FootprintAlarm`): five of them used to mean ten seconds with
            // the board open and fifty behind it, and a warning could be earned by four fast
            // readings and one slow one - evidence over two different spans added together.
            let state = FootprintAlarm.advance(alertState[key] ?? FootprintAlertState(),
                                               reading: footprint, idle: idle, at: now)
            alerting[key] = state
            footprint.alerts = state.alerts
            next[key] = footprint
            // THE RING IS OFFERED EVERY TICK AND KEEPS ONE POINT IN FIVE OF THEM, folding the rest
            // into it, which is what holds the series to one cadence AND to one meaning across two
            // rates (`FootprintTrendSeries.record`). Only once there is a rate to keep: the first
            // pair of readings has no interval yet, and a zero written where "not measured yet"
            // belongs would draw a dip the machine never had.
            //
            // AND THE INTERVAL GOES WITH THE RATE, because the two rates meet INSIDE a bucket every
            // time somebody opens the board: the reading taken at that instant covers the ten
            // seconds the slow timer had been running, and the fast ones after it cover two each.
            // Folded flat they made a peak out of the opening (`FootprintTrendSample.folded`).
            if let percent = cpu.percent, let since = previous?.at {
                trends.record(FootprintTrendSample(cpuPercent: percent,
                                                   seconds: now.timeIntervalSince(since),
                                                   memoryBytes: reading.memoryBytes,
                                                   processes: started.count),
                              for: key, at: now)
            }
        }
        previousSample = readings
        cpuCarry = carried
        alertState = alerting
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
        // FIXTURE READINGS FOR A CAPTURE, and only for one: the flag lives in the volatile argument
        // domain, so an ordinary launch never takes this branch (`DemoUsage`). Painted over the
        // finished readings rather than substituted for them, so the shapes behind the figures are
        // still the machine's own and only what a card SAYS is fabricated.
        if DemoUsage.isActive { next = DemoUsage.footprints(over: next) }
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
