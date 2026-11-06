import Darwin
import Foundation

/// One tree's machine readings for a reclaim round, taken off the main thread (Sentry TALLY-B6,
/// 2026-11-06: the round's `proc_pid_rusage` held the menu bar for over two seconds at load 45).
struct OrphanTreeRead: Sendable {
    struct Member: Sendable {
        let program: String?
        let directory: String?
    }

    /// The members this was read for; a round whose tree has other members reads it again.
    let members: Set<pid_t>
    let each: [pid_t: Member]
    let sample: ProcessResourceSample
    let sockets: OrphanReclaim.Sockets
    let ancestorNames: [String]
    let terminalAbove: Bool
    /// The tree's checkout, resolved (`OrphanReclaimStore.checkout(of:machine:)`).
    let checkout: String
}

/// A due round's readings: every tree by root, and the sessions' checkouts resolved.
struct OrphanRoundReads: Sendable {
    let trees: [pid_t: OrphanTreeRead]
    let occupied: Set<String>
}

extension OrphanReclaimStore {
    /// Built on the main actor, run off it (the footprint pass's detached hop), as `leaseReaderIfDue`
    /// is. Nil when no round is due.
    func roundReaderIfDue(strays: [pid_t: String], processes: [ProcessIdentity],
                          sessions: OrphanReclaim.Sessions, at now: Date) -> (@Sendable () -> OrphanRoundReads)? {
        guard roundDue(at: now) else { return nil }
        let trees = OrphanReclaim.trees(of: strays, among: processes)
        let parents = Dictionary(processes.map { ($0.pid, $0.parent) }) { first, _ in first }
        let machine = machine, checkouts = sessions.checkouts
        return {
            OrphanRoundReads(
                trees: Dictionary(trees.map { ($0.root, Self.gather($0, parents: parents, machine: machine, at: now)) },
                                  uniquingKeysWith: { first, _ in first }),
                occupied: Set(checkouts.map { Self.checkout(of: $0, machine: machine) }))
        }
    }

    /// Everything one tree's verdict asks the machine, and nothing it decides.
    nonisolated static func gather(_ tree: OrphanReclaim.Tree, parents: [pid_t: pid_t],
                                   machine: Machine, at now: Date) -> OrphanTreeRead {
        var each: [pid_t: OrphanTreeRead.Member] = [:]
        for pid in tree.members {
            each[pid] = OrphanTreeRead.Member(program: machine.program(pid), directory: machine.directory(pid))
        }
        let ancestors = OrphanReclaim.ancestry(of: tree.root, parents: parents)
        return OrphanTreeRead(
            members: tree.members, each: each, sample: machine.sample(tree.members, now),
            sockets: machine.connections(tree.members),
            // The walk stops at launchd, so for an ordinary orphan this is empty and costs nothing.
            ancestorNames: ancestors.compactMap { machine.program($0).flatMap(ProcessTree.displayName) },
            terminalAbove: ancestors.contains(where: machine.hasTerminal),
            checkout: checkout(of: tree.project, machine: machine))
    }

    /// WHICH CHECKOUT A DIRECTORY IS IN, resolved: the one call both sides of the session veto go
    /// through (see `OrphanReclaimStore.checkout(of:)`).
    nonisolated static func checkout(of directory: String, machine: Machine) -> String {
        machine.resolve(OrphanReclaim.checkout(of: directory, entry: machine.gitEntry))
    }
}
