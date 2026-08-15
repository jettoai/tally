import Foundation
import Observation

/// WHAT EACH SESSION'S PROCESS TREE IS COSTING, sampled while somebody is looking at the board and
/// not one moment otherwise.
///
/// A STORE OF ITS OWN rather than another reading on the roster: the roster is a reader of files the
/// supervisors wrote (`SessionRosterStore`), which is cheap enough to run on a knock with no window
/// open at all, and this walks the process table. The two cost different things and are wanted at
/// different times, so they are switched on and off separately - the roster keeps the menu bar's
/// blocked dot honest with everything closed, and this one does nothing whatsoever until the
/// Sessions page is on screen (`sessionsPage`).
///
/// TWO CADENCES, because the readings do not cost the same. The tree, its CPU, its memory and its
/// disk writing all come from one pass over the process table plus a single call per process in the
/// tree, which hands over all four counters at once; the ports are a descriptor table per process
/// and a call per socket on top of that, so they are read every third tick and held in between. A port is not a fast-moving number anyway: a dev server that came up six
/// seconds ago is news soon enough.
@MainActor
@Observable
final class ProcessFootprintStore {
    static let shared = ProcessFootprintStore()

    /// One entry per session that has a live tree, keyed by supervisor pid as the board spells it
    /// (`SessionRosterStore.SessionRow.id`). A session whose supervisor is already gone has no
    /// entry rather than an empty one: its card then draws no footprint line, which is the honest
    /// reading of "there is nothing to measure".
    private(set) var footprints: [String: ProcessFootprint] = [:]

    /// How long between samples of the tree and its CPU. The board's own scan interval, so a card
    /// gains its processes and its state in the same beat.
    private static let interval: TimeInterval = 2
    /// How many of those ticks pass between two readings of the ports (see the note above).
    private static let portsEveryNTicks = 3

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var ticks = 0
    /// The previous reading per session, which is the whole of what makes a rate possible
    /// (`ProcessTree.cpuPercent`, `ProcessTree.diskWrite`). Dropped when the last viewer goes, so a
    /// panel opened again an hour later reads the tree from now rather than averaging it over the
    /// hour nobody watched.
    @ObservationIgnored private var previousSample: [String: ProcessResourceSample] = [:]
    /// Per session, the departed-process CPU credit the last pair of readings could not settle. It
    /// exists because a child dies on one tick and is collected on the next, and without carrying
    /// the credit across that gap the collection reads as a burst of work that was already counted
    /// (`ProcessTree.cpuPercent`). One tick of memory, deliberately: the rule that bounds it lives
    /// in the pure function, and this only has to hand the number back.
    @ObservationIgnored private var cpuCarry: [String: Double] = [:]
    /// The last ports reading per session, held between the ticks that do not take one.
    @ObservationIgnored private var ports: [String: [UInt16]] = [:]
    /// Per session, how long each warning condition has been met or missed. A warning is about a
    /// condition that HOLDS rather than about one tick's reading, so something has to count the
    /// ticks, and this is the only thing here that knows what a tick is (`FootprintAlerts.swift`).
    @ObservationIgnored private var alertState: [String: FootprintAlertState] = [:]

    private init() {}

    /// A surface showing the board has appeared. Samples at once, because what somebody just opened
    /// has to say something before the first tick rather than after it.
    func beginViewing() {
        viewers += 1
        sample()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in ProcessFootprintStore.shared.sample() }
        }
        // `.common`, so the readings keep coming while a menu or a scroll is tracking - the same
        // reason the roster's own timer is registered that way.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The last surface showing the board has gone. Everything measured is dropped with it: these
    /// are readings of a moment, and a card that came back carrying numbers from the last time the
    /// panel was open would be stating a measurement nobody is taking.
    func endViewing() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        ticks = 0
        previousSample = [:]
        cpuCarry = [:]
        ports = [:]
        alertState = [:]
        footprints = [:]
    }

    /// One pass: the process table once, then each session's own tree out of it.
    ///
    /// THE ROSTER SAYS WHICH TREES THERE ARE, so this never has to decide what a session is - it
    /// reads the board's own rows and asks the machine about their pids. A board with nothing on it
    /// costs a dictionary assignment.
    private func sample() {
        // Each root with what its session is DOING, because a warning is about the mismatch between
        // the two (`FootprintAlarm`). The state is the supervisor's own published word rather than
        // anything guessed here, and `unknown` is not idle: a session that has not said yet is not
        // a session that said "nothing is running".
        let roots = SessionRosterStore.shared.rows.compactMap { row in
            pid_t(row.id).map { ($0, row.state == .idle || row.state == .blocked) }
        }
        // A board with nothing on it is not a special case, only an empty one: no table is walked,
        // the loop below does not run, and everything held falls out through the same three lines
        // that retire a single session that ended.
        let processes = roots.isEmpty ? [] : ProcessTree.liveProcesses()
        let readPorts = ticks % Self.portsEveryNTicks == 0
        let now = Date()
        var next: [String: ProcessFootprint] = [:]
        var readings: [String: ProcessResourceSample] = [:]
        var carried: [String: Double] = [:]
        var alerting: [String: FootprintAlertState] = [:]
        for (root, idle) in roots {
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
            let reading = ProcessTree.resourceSample(of: measured, at: now)
            readings[key] = reading
            let cpu = ProcessTree.cpuPercent(from: previousSample[key], to: reading,
                                             carry: cpuCarry[key] ?? 0)
            let disk = ProcessTree.diskWrite(from: previousSample[key], to: reading)
            carried[key] = cpu.carry
            if readPorts { ports[key] = ProcessTree.listeningPorts(of: measured) }
            var footprint = ProcessFootprint(
                processes: measured.count,
                // The subagents are the one reading here that is not taken from the machine: they
                // are conversations inside a process, so Claude Code's own hooks say how many
                // (`SessionAgentsRecord`), and a count that cannot be believed is not drawn.
                agents: readSessionAgents(pid: key)?.reportable ?? 0,
                cpuPercent: cpu.percent,
                cpuLeader: name(of: cpu.leader),
                memoryBytes: reading.memoryBytes,
                diskWriteBytesPerSecond: disk.bytesPerSecond,
                diskLeader: name(of: disk.leader),
                listeningPorts: ports[key] ?? [])
            // The warnings are decided from THIS tick's reading and the ticks before it, then put
            // back on the same reading: what the card draws and what the card warns about are one
            // value, so they cannot be a tick apart.
            let state = FootprintAlarm.advance(alertState[key] ?? FootprintAlertState(),
                                               reading: footprint, idle: idle)
            alerting[key] = state
            footprint.alerts = state.alerts
            next[key] = footprint
        }
        previousSample = readings
        cpuCarry = carried
        alertState = alerting
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
