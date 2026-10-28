import Foundation

// What the reclaim panel holds and who each entry is attributed to. Moved out of
// OrphanReclaimStore.swift, which would otherwise pass the repo's 500-line cap.
extension OrphanReclaimStore {
    /// One thing that happened.
    struct Record: Equatable, Identifiable {
        var at: Date
        var project: String
        var program: String
        var pid: pid_t
        var processes: Int
        var outcome: OrphanNotice.Outcome
        /// The supervisor pid of the live session this tree came from (the roster row's id), when
        /// the tree's inherited `TALLY_SUPERVISOR_PID` named one the board still holds. Optional and
        /// never persisted: nil is "cannot say", and the panel then draws nothing about it.
        var session: pid_t? = nil
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
        /// As on `Record`.
        var session: pid_t? = nil
        var id: pid_t { pid }
    }

    /// WHICH LIVE SESSION A TREE CAME FROM, remembered by its root pid so a kill that finishes a
    /// few ticks later (`announce`) still names it. The same three-witness walk the load alarm
    /// uses (`hostHealthSessionOwner`), with the process-group ledger left out: an unreadable
    /// marker is simply no answer here, and an answer from memory would be a guess about whose
    /// work this was. A session that has already left the board is not named either.
    func attribute(_ root: pid_t, parents: [pid_t: pid_t], supervisors: Set<pid_t>) -> pid_t? {
        let owner = supervisors.isEmpty ? nil : hostHealthSessionOwner(
            of: root, supervisors: supervisors, parent: { parents[$0] },
            marker: machine.marker, ledger: { _ in nil })
        owners[root] = owner
        return owner
    }

    /// Forget trees that are neither being looked at nor named by something still on the panel.
    func pruneOwners(seen: Set<pid_t>) {
        owners = owners.filter { root, _ in
            seen.contains(root) || records.contains { $0.pid == root }
                || sweeps.contains { $0.report.pid == root }
        }
    }

    /// A CAPTURE'S PANEL (`DemoUsage`): leftovers being watched and handled in one project,
    /// attributed to sessions on the demo board. The figures are the shape of the state and none
    /// of them came off this machine.
    static func demoEntries(project: String, sessions: [pid_t], at now: Date) -> ([Watch], [Record]) {
        func session(_ index: Int) -> pid_t? { sessions.isEmpty ? nil : sessions[index % sessions.count] }
        let watches = [
            Watch(project: project, program: "node", pid: 90_101, cpuPercent: 82, memoryBytes: 1_300_000_000,
                  doubts: [], session: session(0)),
            Watch(project: project, program: "next-server", pid: 90_102, cpuPercent: 41,
                  memoryBytes: 620_000_000, doubts: [], session: session(1)),
            // No session on the board answers for this one: the callout says so (B-3185).
            Watch(project: project, program: "webpack", pid: 90_105, cpuPercent: 17,
                  memoryBytes: 410_000_000, doubts: [], session: nil),
        ]
        let records = [
            Record(at: now, project: project, program: "vite", pid: 90_103, processes: 3,
                   outcome: .reclaimedBySustained, session: session(2)),
            Record(at: now.addingTimeInterval(-90), project: project, program: "storybook", pid: 90_104,
                   processes: 2, outcome: .reported(doubts: []), session: session(1)),
            Record(at: now.addingTimeInterval(-300), project: project, program: "esbuild", pid: 90_106,
                   processes: 1, outcome: .reclaimedByLease, session: nil),
        ]
        return (watches, records)
    }
}
