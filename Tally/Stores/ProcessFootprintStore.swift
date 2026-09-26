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
    static let portsEveryNTicks = 3

    // THE STORED STATE HERE IS NOT `private` BECAUSE THE TIMER AND THE PASS ARE NEXT DOOR. When this file passed the
    // repo's 500-line cap the lifecycle went into ProcessFootprintTiming.swift, along the seam the
    // class already had: what it HOLDS and what one pass DOES stayed here, when the pass runs went
    // there. Swift's `private` is file-scoped, so the rate, the audience and the ports cache are
    // module-visible - the same trade `UsageStore` made for the same reason.
    //
    // THE SIXTH IS `alertState`, and it went the same way for the same reason: the file passed the
    // cap a second time, and the piece that moved was the step that turns every card's reading into
    // what the card SAYS (`painted`), which is what carries the warnings from tick to tick. And the
    // pass itself went too (ProcessFootprintPass.swift), when its reading moved off the main thread
    // (2026-09-26), so the readings, the ledger and the rollup it keeps across ticks went with it.
    /// One pass at a time: a beat that lands while the last pass is still reading folds into one
    /// follow-up (`tick`, `CoalescingGate`).
    @ObservationIgnored var sampleGate = CoalescingGate()
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
    @ObservationIgnored var previousSample: [String: ProcessResourceSample] = [:]
    /// Per session, the departed-process CPU credit the last pair of readings could not settle. It
    /// exists because a child dies on one tick and is collected on the next, and without carrying
    /// the credit across that gap the collection reads as a burst of work that was already counted
    /// (`ProcessTree.cpuPercent`). One tick of memory, deliberately: the rule that bounds it lives
    /// in the pure function, and this only has to hand the number back.
    @ObservationIgnored var cpuCarry: [String: ProcessCPUCarry] = [:]
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
    @ObservationIgnored var groupLedger: SessionProcessGroups.Index?
    /// Per group the ledger still claims, how many consecutive non-empty walks it has been missing
    /// from: the evidence a claim is retired on, held here because the rule that reads it is pure
    /// (`SessionProcessGroups.absences`). A group seen again resets, and a tick that walked nothing
    /// leaves it alone, since silence is not absence.
    @ObservationIgnored var groupAbsentTicks: [pid_t: Int] = [:]
    /// EVERYTHING THE PROJECT ROLLUP NEEDS TO REMEMBER, which is its own object next door
    /// (`ProjectLoadAccounting`): the strays' previous readings, what their pairs could not settle,
    /// and each session directory as the machine spells it. Held apart from the readings above
    /// because it answers a different question - not "what is this card costing" but "do the cards
    /// add up" - and because this file had run out of room.
    @ObservationIgnored let rollup = ProjectLoadAccounting()
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

    /// The pass's four observed results, assigned here because their setters are this file's; the
    /// pass that computes them is next door (ProcessFootprintPass.swift).
    func publish(load: MachineLoad, projects: [String: String], trends: FootprintHistory,
                 drawn next: [String: ProcessFootprint]) {
        if load != machineLoad { machineLoad = load }
        // Assigned only when it moved, for the reason every other observed field here is: this is
        // the same answer on every tick of a board nobody has changed, and re-publishing it would
        // re-render every card twice a second for a map that did not move.
        if projects != sessionProjects { sessionProjects = projects }
        // Assigned only when it moved, for the reason the figures below are: `record` is a mutating
        // call whether or not the ring closed a point on it, and an observed property notices the
        // call rather than the change. The ring now carries the readings BETWEEN points as well as
        // the points, so a tick that only added to the bucket does move it - what the guard still
        // saves is the idle board where nothing was recorded at all (no session, or no rate yet).
        if trends != history { history = trends }
        // Nothing moved is an ordinary tick on an idle board, and assigning anyway would re-render
        // every card on it twice a second for numbers that did not change.
        guard next != footprints else { return }
        footprints = next
    }
}
