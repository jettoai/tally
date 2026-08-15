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
/// TWO CADENCES, because the readings do not cost the same. The tree and its CPU come from one pass
/// over the process table plus a small call per process in the tree; the ports are a descriptor
/// table per process and a call per socket on top of that, so they are read every third tick and
/// held in between. A port is not a fast-moving number anyway: a dev server that came up six
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
    /// The previous CPU reading per session, which is the whole of what makes a percentage possible
    /// (`ProcessTree.cpuPercent`). Dropped when the last viewer goes, so a panel opened again an
    /// hour later reads the tree from now rather than averaging it over the hour nobody watched.
    @ObservationIgnored private var previousCPU: [String: ProcessCPUSample] = [:]
    /// The last ports reading per session, held between the ticks that do not take one.
    @ObservationIgnored private var ports: [String: [UInt16]] = [:]

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
        previousCPU = [:]
        ports = [:]
        footprints = [:]
    }

    /// One pass: the process table once, then each session's own tree out of it.
    ///
    /// THE ROSTER SAYS WHICH TREES THERE ARE, so this never has to decide what a session is - it
    /// reads the board's own rows and asks the machine about their pids. A board with nothing on it
    /// costs a dictionary assignment.
    private func sample() {
        let roots = SessionRosterStore.shared.rows.compactMap { pid_t($0.id) }
        // A board with nothing on it is not a special case, only an empty one: no table is walked,
        // the loop below does not run, and everything held falls out through the same three lines
        // that retire a single session that ended.
        let parents = roots.isEmpty ? [:] : ProcessTree.liveParents()
        let readPorts = ticks % Self.portsEveryNTicks == 0
        let now = Date()
        var next: [String: ProcessFootprint] = [:]
        var readings: [String: ProcessCPUSample] = [:]
        for root in roots {
            let members = ProcessTree.members(root: root, parents: parents)
            guard !members.isEmpty else { continue }
            let key = String(root)
            let reading = ProcessTree.cpuSample(of: members, at: now)
            readings[key] = reading
            if readPorts { ports[key] = ProcessTree.listeningPorts(of: members) }
            next[key] = ProcessFootprint(
                processes: members.count,
                cpuPercent: ProcessTree.cpuPercent(from: previousCPU[key], to: reading),
                listeningPorts: ports[key] ?? [])
        }
        previousCPU = readings
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
