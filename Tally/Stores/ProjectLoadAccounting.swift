import Darwin
import Foundation

/// WHETHER THE CARDS ADD UP, which is the one question the session board could not ask itself.
///
/// Everything on that page is per session, and the machine is free to be doing much more in the same
/// directories than the sessions on it account for: a dev server whose session was closed hours ago,
/// a build somebody started in a terminal, a fan-out that outlived the turn. Read card by card, a
/// board of quiet sessions on a machine at full load is not WRONG about any card and is wrong about
/// the machine - which is exactly the reading that stood for a week (`MachineLoadRollup` carries the
/// incident).
///
/// A HELPER RATHER THAN A SECOND STORE, and owned by the sampler that already walks the table
/// (`ProcessFootprintStore`): everything here is a second reading of a pass that has already been
/// made, and a store of its own would mean a second timer and a second walk to answer a question
/// about the first one's leftovers. What it holds is only what a RATE needs - the previous reading
/// of each pool and the credit that pair could not settle - plus the resolved directories, which are
/// held because they never change, and how long each project has been reading idle.
///
/// THE RULES ARE NEXT DOOR AND PURE (`MachineLoadRollup`); what is here is the state and the
/// syscalls, which is the same seam `ProcessTree` is split along.
@MainActor
final class ProjectLoadAccounting {
    /// The previous reading of each project's strays, which is the whole of what makes their rate
    /// possible on exactly the terms a session's own is (`ProcessTree.cpuPercent`).
    ///
    /// PER PROJECT RATHER THAN ONE POOL, so that one project's row is a rate over that project's
    /// processes and nothing else: a reading holding two projects' pids would state one figure for
    /// both, and each row would move when the other project's work did.
    ///
    /// AND WHAT THE PAIR IS TAKEN OVER IS DECIDED RATHER THAN ASSUMED, which is where a stray pool
    /// differs from a tree: a pid can leave this pool without dying, and only the ones that have
    /// really died AND been collected settle a credit
    /// (`ProcessResourceSample.pairing(with:departure:)`, which carries the measurements and what
    /// the rule still costs). So this holds one more thing than the last reading: a member that has
    /// died and not yet been collected, at the counters it was last read with, until the machine
    /// says its seconds have landed somewhere.
    ///
    /// AND IT IS KEPT WHILE THE PROJECT IS WATCHED RATHER THAN WHILE THE POOL HAS MEMBERS. This was
    /// rebuilt whole from each tick's live strays, which reads as "a project whose strays have all
    /// ended keeps nothing" and is a different sentence from the one it was written for: a member
    /// that has DIED is not a stray - it is in no process table and answers no working directory -
    /// so a pool that momentarily holds nothing but a zombie dropped the very credit it was waiting
    /// to spend, and the collector's arrival then landed with nothing to cancel it (30050%, asserted
    /// in `projectloadchecks.swift`). One idle tick was enough to do it, which is exactly the tick a
    /// session ends on. Bound to `watching` instead, which is the span this class already says the
    /// waiting lasts (`ProcessResourceSample.pairing(with:departure:)` points at it by name).
    private var previous: [String: ProcessResourceSample] = [:]
    /// What each project's last pair could not settle, on the same terms a session's card keeps one
    /// (`ProcessTree.cpuPercent`), and kept for the same span as the reading above.
    ///
    /// A POOL NEEDS ONE FOR A REASON A TREE DOES NOT HAVE. Waiting at the death rather than at the
    /// exit means a credit normally meets its arrival inside one reading, and the pairing used to
    /// say no carry was needed because of it. The exception is that the pool is READ and then each
    /// departure is ASKED about, microseconds apart: a member collected in between is settled
    /// against counters taken before its seconds landed, and its credit would be produced and thrown
    /// away with the tick. Rare and unbounded, so it is handed on instead - which turns 30050% into
    /// 100% on the pairing's own fixture, and costs nothing when the window is not hit.
    private var carry: [String: ProcessCPUCarry] = [:]
    /// When each stray began, out of the table walk this tick already made
    /// (`ProcessIdentity.startedAt`). Handed to each pool reading so the pairing can tell a member
    /// still with us from a number the machine has handed on; nothing here costs a syscall.
    private var strayStamps: [pid_t: Int64] = [:]
    /// Each session directory as the machine spells it. Held because a checkout does not move: this
    /// would be a `realpath` per session per tick otherwise, for an answer that never changes.
    private var resolved: [String: String] = [:]
    /// Every project this accounting is still watching: the ones its sessions are in, and the ones
    /// whose sessions have ENDED and whose work has not.
    ///
    /// THE ONE STATE THE ROLLUP EXISTS FOR CANNOT BE READ OFF THE BOARD, which is why this is kept
    /// at all. A project is found by matching working directories against roots, and taking those
    /// roots from the live rows alone means a directory stops being accounted for in the same tick
    /// its last session closes - so the dev server that outlived the session, the whole case the
    /// section was written for (`MachineLoadRollup`, motivation 3), disappeared from the page at
    /// the exact moment it became worth showing. The pure rules could always state it
    /// (`MachineLoadRollup.rows` with no sessions at all) and nothing assembled could produce it.
    ///
    /// KEPT WHILE THERE IS WORK IN IT, rather than for a span and rather than merely while it has a
    /// row: the rule and the floor are next door (`MachineLoadRollup.watched`), and what they are
    /// for is that a row is not evidence of work. The interactive shell a session was started from
    /// is a stray of its checkout for as long as that terminal tab is open, so "kept while it has a
    /// row" kept every checkout ever opened, forever, each with a Projects line reading nothing.
    private var watching: Set<String> = []
    /// How many consecutive ticks each watched project has read idle, which is the memory the grace
    /// period next door needs (`MachineLoadRollup.idleTicksBeforeDropping` carries the whole of why
    /// one reading is not evidence). A project that reads busy is simply absent from here.
    private var idleTicks: [String: Int] = [:]

    /// How a pool of pids is read: which of them the machine holds counters for, at an instant.
    typealias PoolReader = (Set<pid_t>, Date) -> ProcessResourceSample

    /// How a pid the pool no longer holds is asked what became of it.
    typealias PoolDeparture = (pid_t) -> ProcessDeparture

    /// A PARAMETER SO AN ASSERTION CAN STATE A RATE - two readings, real numbers, the figure a row
    /// would draw. That is the half of this file no fixture could reach before: the rule that pairs
    /// two readings is pure and asserted next door, and what nothing asserted is that this class
    /// hands it the right pair. A rewrite of exactly that turned a 50% row into a 30050% one with
    /// every suite in the repo still green (`projectloadchecks.swift`).
    private let sample: PoolReader
    /// AND A PARAMETER FOR THE SAME REASON, since half of what an assertion has to state about a
    /// rate is what the machine said between the two readings: a member that has died and not been
    /// collected reads differently from one that has, one tick apart, and no fixture can make a real
    /// process linger on cue.
    private let departure: PoolDeparture

    init(sample: @escaping PoolReader = { ProcessTree.resourceSample(of: $0, at: $1) },
         departure: @escaping PoolDeparture = { ProcessTree.departure(of: $0) }) {
        self.sample = sample
        self.departure = departure
    }

    /// The project roots this tick has to account against: the live sessions' and the retained.
    var accounted: Set<String> { watching }

    /// 🔴 WHETHER THE LAST READING OF THE BOARD COULD PLACE EVERY ROW ON IT, which the map below
    /// cannot say for itself: a row nothing could place is simply absent from it, and an absence
    /// reads the same way as a machine with one session fewer.
    ///
    /// FOR ONE CONSUMER AND NAMED FOR WHAT IT COSTS THERE. The rollup itself is unharmed by a
    /// missing row - a project short one session's card is a wrong figure for a tick, and the next
    /// tick corrects it. The reclaim is not: "no session is working in this checkout" is the
    /// reading that lets it end a process, and it is drawn from exactly this map
    /// (`ProcessFootprintStore.sample` hands it over, `OrphanReclaim.Sessions` carries this field
    /// alongside it, and `OrphanReclaim.Veto.sessionUnknown` is what the round does about it).
    private(set) var boardUnreadable = false

    /// Which project each session on the board is working in, keyed the way the board keys its rows.
    /// A session whose directory nothing published is simply absent, which is the same answer every
    /// other reading gives it - and is recorded as such above.
    ///
    /// And every root it finds is one this accounting watches until nothing is left running in it
    /// (`watching`).
    func roots(of board: [SessionRosterStore.SessionRow]) -> [String: String] {
        var found: [String: String] = [:]
        var missed = false
        for row in board {
            guard let directory = row.directory else {
                missed = true
                continue
            }
            let real = resolved[directory] ?? MachineLoadRollup.resolvedPath(directory)
            resolved[directory] = real
            found[row.id] = real
        }
        boardUnreadable = missed
        watching.formUnion(found.values)
        return found
    }

    /// Which session each live conversation belongs to, for the scratchpad signal
    /// (`MachineLoadRollup.scratchpadConversation`).
    ///
    /// A CONVERSATION TWO LIVE SESSIONS BOTH CLAIM BELONGS TO NEITHER. It happens: a conversation
    /// resumed under a new supervisor leaves the old one's report on disk until that supervisor
    /// ends, and both files then lead with the same id. Adopting for one of them would be a coin
    /// toss with somebody's cores on it, so the ambiguous id is dropped and the process stays a
    /// stray - which is the reading that says "this is work nobody here is answering for", and is
    /// true.
    func conversationOwners(of board: [SessionRosterStore.SessionRow]) -> [String: String] {
        var owners: [String: String] = [:]
        var contested: Set<String> = []
        for row in board {
            guard let conversation = SessionSidecar.readConversation(pid: row.id) else { continue }
            if owners[conversation] != nil { contested.insert(conversation) }
            owners[conversation] = row.id
        }
        for one in contested { owners[one] = nil }
        return owners
    }

    /// WHAT IS RUNNING IN THESE PROJECTS THAT NO CARD ACCOUNTS FOR, and the second way a job gets
    /// back onto a card.
    ///
    /// - Parameters:
    ///   - processes: the whole machine, out of the walk the tick has already made.
    ///   - claimed: every pid a session's tree walk reached on its own.
    ///   - adopted: every pid the group ledger has already matched back to a session
    ///     (`SessionProcessGroups`), which this may add to.
    ///   - roots: the project directories to account against.
    /// - Returns: the strays by project, and the adoptions with the scratchpad signal folded in.
    ///
    /// WHERE EVERY PROCESS NO SESSION HOLDS IS WORKING, which is the reading that lets the page
    /// admit what it cannot see. One `proc_pidvnodepathinfo` per unclaimed process: measured on
    /// this machine (2026-09-01, 1,162 processes in the table) at a median of 1.40 ms and a maximum
    /// of 2.24 ms over twenty passes of the WHOLE table, against the 0.5 to 0.6 ms the rest of the
    /// pass takes. At the background rate that is about 0.014% of one core, which is why it is
    /// taken on every tick rather than on a beat of its own: the strays' CPU is a difference of two
    /// readings like any other, and a reading taken on an irregular beat is one whose pair is
    /// harder to reason about than the syscalls are to make.
    ///
    /// THE SCRATCHPAD SIGNAL REACHES THE JOB THE LEDGER NEVER SAW: a command whose own shell exited
    /// between two ticks was never once inside a tree, so no group of it was ever claimed. Claude
    /// Code hands each session a scratchpad named after its conversation, and a command working with
    /// one carries that path in its arguments (`MachineLoadRollup.scratchpadConversation`, which is
    /// where the rule about never keeping argv is).
    ///
    /// ASKED ONLY OF THE STRAYS, which is what makes it affordable and what keeps it narrow: the
    /// reading costs 0.27 ms per forty processes (measured beside the pass above), and the
    /// candidates are the handful already known to be working inside one of these projects rather
    /// than every daemon on the machine.
    func strays(among processes: [ProcessIdentity], claimed: Set<pid_t>,
                adopted: [String: Set<pid_t>], board: [SessionRosterStore.SessionRow],
                roots: Set<String>) -> (strays: [pid_t: String], adoptions: [String: Set<pid_t>]) {
        guard !roots.isEmpty else { return ([:], adopted) }
        var strayRoot: [pid_t: String] = [:]
        // The stamps come from THIS walk rather than from a later question about a pid, which is the
        // point of taking them here: by the time the pool notices a member is gone, the machine can
        // no longer say when it began (`strayStamps`).
        strayStamps = processes.reduce(into: [:]) { $0[$1.pid] = $1.startedAt }
        let taken = claimed.union(adopted.values.joined())
        for one in processes where !taken.contains(one.pid) {
            guard let directory = MachineLoadRollup.workingDirectory(of: one.pid),
                  let root = MachineLoadRollup.project(of: directory, roots: roots) else { continue }
            strayRoot[one.pid] = root
        }
        // AND NOT THE METER ITSELF, which is the rule every card on the board already keeps: a
        // reading must not answer "what is this costing you" with the process taking the reading
        // (`ProcessTree.ownFamily` carries the whole of why). An ORPHANED one of ours is what
        // reaches here: a hook whose shell has gone, still in the checkout it ran in and in nobody's
        // tree, which every other test in this function calls a stray of that project. The cards say
        // such a process is not theirs; the Projects row said it was the project's, counted it in the
        // amber stray figure, and put its memory in the row. Same machine, same process, two
        // answers.
        //
        // ASKED OF THE HANDFUL RATHER THAN OF THE TABLE: one `proc_pidpath` per stray, and the
        // strays are the few already known to be working inside one of these directories. Compared
        // against THIS process rather than a session's root, because a stray pool has no root: the
        // app is the meter here, and the bundle around it is ours by the same reasoning `ownFamily`
        // gives. A pid whose program cannot be read stays a stray, which is the same direction that
        // rule already fails in.
        for pid in ProcessTree.ownFamily(strayRoot.keys, root: getpid(),
                                         executable: { ProcessTree.executablePath(of: $0) }) {
            strayRoot[pid] = nil
        }
        var adoptions = adopted
        let conversations = strayRoot.isEmpty ? [:] : conversationOwners(of: board)
        if !conversations.isEmpty {
            let uid = getuid()
            for pid in strayRoot.keys {
                guard let arguments = MachineLoadRollup.commandLine(of: pid),
                      let conversation = MachineLoadRollup.scratchpadConversation(in: arguments,
                                                                                  uid: uid),
                      let session = conversations[conversation] else { continue }
                adoptions[session, default: []].insert(pid)
                strayRoot[pid] = nil
            }
        }
        return (strayRoot, adoptions)
    }

    /// The rollup this tick: every project a session is working in, with what its sessions read and
    /// what is left over inside it.
    ///
    /// THE STRAYS ARE SAMPLED HERE AND NOWHERE ELSE, one `proc_pid_rusage` per stray, which is the
    /// same call the trees are read with and is only made for processes already known to be working
    /// inside one of these directories.
    ///
    /// A CAPTURE NEVER READS THE REAL MACHINE'S LEFTOVERS. The demo board's own rows are fixtures
    /// (`DemoUsage`, DemoSessions.swift), so the roots this accounts against are fabricated paths
    /// that no real process is working under and the strays would be empty on every launch - which
    /// would take the
    /// one row this section exists for out of every screenshot. So the fixtures answer instead, on
    /// the same terms every other fixture on that page is under: what is shown is the SHAPE, and no
    /// field of it came off this machine.
    ///
    func load(sessions: [MachineLoadRollup.SessionReading], strays: [pid_t: String],
              at now: Date) -> MachineLoad {
        let rollup = MachineLoadRollup.rows(
            sessions: sessions,
            strays: DemoUsage.isActive ? DemoUsage.strayReadings(for: sessions.map(\.root))
                                       : measure(strays, at: now))
        // WHICH PROJECTS THE NEXT TICK LOOKS FOR, decided on what this one turned out to hold rather
        // than on whether it produced a row at all, and over several ticks rather than one
        // (`MachineLoadRollup.idleTicksBeforeDropping`).
        let next = MachineLoadRollup.watched(rollup, idle: idleTicks)
        watching = next.roots
        idleTicks = next.idle
        // AND EVERYTHING A RATE NEEDS LASTS EXACTLY AS LONG AS THAT. A project still on the books is
        // one this pool may still be waiting on a member of, so its reading and its credit are kept
        // whether or not this tick found a live stray in it; one that has left the books will be a
        // first sighting when it comes back, which is the honest answer for a pool nothing has
        // watched in between.
        previous = previous.filter { watching.contains($0.key) }
        carry = carry.filter { watching.contains($0.key) }
        return rollup
    }

    /// The strays of each project, read and turned into a rate.
    private func measure(_ strays: [pid_t: String],
                         at now: Date) -> [MachineLoadRollup.StrayReading] {
        var pidsByRoot: [String: Set<pid_t>] = [:]
        for (pid, root) in strays { pidsByRoot[root, default: []].insert(pid) }
        var readings: [MachineLoadRollup.StrayReading] = []
        for (root, pids) in pidsByRoot {
            var reading = sample(pids, now)
            // Identities for whatever the reader did not supply them for, which in production is all
            // of them: `ProcessTree.resourceSample` asks `proc_pid_rusage` and that record carries no
            // birth time. A fixture that states its own stamps keeps them.
            for pid in reading.times.keys where reading.startedAt[pid] == nil {
                reading.startedAt[pid] = strayStamps[pid]
            }
            // PAIRED AGAINST WHAT THIS POOL ACTUALLY DID. Four things look identical from inside a
            // pool - a member has died and has not been collected, a member was collected, a member
            // was adopted back onto a card, a member joined - and reading them as one produced a
            // blank row followed by a spike, another spike, another blank row and a third spike
            // (`ProcessResourceSample.pairing(with:departure:)`, which is where all four are
            // measured). Asking the machine what became of each departure, at this instant rather
            // than off a table walked earlier in the pass, is what tells them apart.
            let pair = previous[root]?.pairing(with: reading, departure: departure)
            // A member whose NUMBER a live process has taken over cannot be settled through the
            // basis - it is present in both readings, so the rate reads it as a survivor - so its
            // seconds arrive here as a credit to spend, alongside whatever last tick could not.
            let held = carry[root] ?? ProcessCPUCarry()
            let cpu = ProcessTree.cpuPercent(
                from: pair?.basis, to: reading,
                carry: ProcessCPUCarry(theirs: held.theirs + (pair?.settled ?? 0), ours: held.ours))
            previous[root] = pair?.keep ?? reading
            carry[root] = cpu.carry
            readings.append(MachineLoadRollup.StrayReading(root: root, cpuPercent: cpu.percent,
                                                           memoryBytes: reading.memoryBytes,
                                                           processes: pids.count))
        }
        return readings
    }
}
