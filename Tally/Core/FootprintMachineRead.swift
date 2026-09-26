import Foundation

/// What one footprint pass reads off the machine before it decides anything, taken off the main
/// thread in one hop (`ProcessFootprintStore.sample`).
struct FootprintMachineRead: Sendable {
    let processes: [ProcessIdentity]
    let pressure: MachineMemoryPressure
    /// The reclaim's leases, read only when its round is due (`OrphanReclaimStore.leaseReaderIfDue`).
    let leases: [OrphanLease]?
}

/// One session tree's readings for one pass: everything the card loop used to ask the machine per
/// tree, taken together off the main thread (`FootprintTreeReads.take`).
struct FootprintTreeRead: Sendable {
    let paths: [pid_t: String]
    let ours: Set<pid_t>
    let reading: ProcessResourceSample
    /// The listening ports, on the ticks that read them; nil otherwise.
    let listening: [UInt16: pid_t]?
    /// The reportable subagent count while somebody is looking; nil behind a closed panel.
    let agents: Int?
}

enum FootprintTreeReads {
    /// Per root with members, its readings. A tree that is only Tally's own has no entry, which is
    /// the same answer the card loop gives it (no card).
    nonisolated static func take(_ targets: [(pid_t, Set<pid_t>)], readPorts: Bool,
                                 readAgents: Bool, at now: Date) -> [pid_t: FootprintTreeRead] {
        var out: [pid_t: FootprintTreeRead] = [:]
        for (root, members) in targets where !members.isEmpty {
            let paths = ProcessTree.executablePaths(of: members)
            let ours = ProcessTree.ownFamily(members, root: root) { paths[$0] }
            let measured = members.subtracting(ours)
            guard !measured.isEmpty else { continue }
            out[root] = FootprintTreeRead(
                paths: paths, ours: ours,
                reading: ProcessTree.resourceSample(of: members, ours: ours, at: now),
                listening: readPorts ? ProcessTree.listeningPorts(of: measured) : nil,
                agents: readAgents ? (readSessionAgents(pid: String(root))?.reportable ?? 0) : nil)
        }
        return out
    }
}
