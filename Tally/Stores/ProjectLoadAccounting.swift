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
/// and the credit it could not settle - plus the resolved directories, which are held because they
/// never change.
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
    /// AND THE PAIR IS TAKEN OVER THE SURVIVORS ONLY, which is where a stray pool differs from a
    /// tree: there is no carry beside this, because a departure from this pool produces no credit
    /// to carry (`ProcessResourceSample.narrowed(to:)` says what that costs and why the reading it
    /// replaced was worse).
    private var previous: [String: ProcessResourceSample] = [:]
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
    /// KEPT UNTIL A TICK FINDS NOTHING UNDER IT, rather than for a span: a root leaves this set on
    /// the first pass that reads no session and no stray in it, which is also what stops it growing
    /// - every project this app has ever seen would otherwise be walked for forever.
    private var watching: Set<String> = []

    /// The project roots this tick has to account against: the live sessions' and the retained.
    var accounted: Set<String> { watching }

    /// Which project each session on the board is working in, keyed the way the board keys its rows.
    /// A session whose directory nothing published is simply absent, which is the same answer every
    /// other reading gives it.
    ///
    /// And every root it finds is one this accounting watches until nothing is left running in it
    /// (`watching`).
    func roots(of board: [SessionRosterStore.SessionRow]) -> [String: String] {
        var found: [String: String] = [:]
        for row in board {
            guard let directory = row.directory else { continue }
            let real = resolved[directory] ?? MachineLoadRollup.resolvedPath(directory)
            resolved[directory] = real
            found[row.id] = real
        }
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
        let taken = claimed.union(adopted.values.joined())
        for one in processes where !taken.contains(one.pid) {
            guard let directory = MachineLoadRollup.workingDirectory(of: one.pid),
                  let root = MachineLoadRollup.project(of: directory, roots: roots) else { continue }
            strayRoot[one.pid] = root
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
    func load(sessions: [MachineLoadRollup.SessionReading], strays: [pid_t: String],
              at now: Date) -> MachineLoad {
        let rollup = MachineLoadRollup.rows(
            sessions: sessions,
            strays: DemoUsage.isActive ? DemoUsage.strayReadings(for: sessions.map(\.root))
                                       : measure(strays, at: now))
        // A PROJECT LEAVES THE BOOKS WHEN THIS TICK FOUND NOTHING IN IT, which is what a row IS:
        // `rows` states one for every root that had a session or a stray in it, so what is left over
        // is the answer to "is there still anything here" without a second pass to ask it.
        watching = Set(rollup.projects.map(\.root))
        return rollup
    }

    /// The strays of each project, read and turned into a rate.
    private func measure(_ strays: [pid_t: String],
                         at now: Date) -> [MachineLoadRollup.StrayReading] {
        var pidsByRoot: [String: Set<pid_t>] = [:]
        for (pid, root) in strays { pidsByRoot[root, default: []].insert(pid) }
        var readings: [MachineLoadRollup.StrayReading] = []
        var nextPrevious: [String: ProcessResourceSample] = [:]
        for (root, pids) in pidsByRoot {
            let reading = ProcessTree.resourceSample(of: pids, at: now)
            // PAIRED AGAINST THE SURVIVORS ONLY. A departure's credit exists to cancel an arrival
            // and a stray's collector is launchd by construction, so there is no arrival to cancel
            // and the credit - a whole lifetime of CPU, not an interval of it - simply blanked the
            // pool for two ticks. Every job this app successfully adopts back onto a card LEAVES
            // this pool, so the reading went to zero precisely when the rest of the page was working
            // (`ProcessResourceSample.narrowed(to:)` carries the measurement and the cost).
            let cpu = ProcessTree.cpuPercent(from: previous[root]?.narrowed(to: pids), to: reading)
            nextPrevious[root] = reading
            readings.append(MachineLoadRollup.StrayReading(root: root, cpuPercent: cpu.percent,
                                                           memoryBytes: reading.memoryBytes,
                                                           processes: pids.count))
        }
        // A project whose strays have all ended keeps nothing: its next stray is a first sighting
        // rather than the continuation of a pool that no longer exists.
        previous = nextPrevious
        return readings
    }
}
