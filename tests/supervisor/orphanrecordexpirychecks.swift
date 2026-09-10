import Darwin
import Foundation

// Panel history expires independently of reclaim rounds. The shared FakeMachine records signals
// and inbox deliveries without touching processes or files.
@MainActor
func runOrphanRecordExpiryChecks() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let ttl = OrphanReclaimStore.successfulRecordLifetime
    let repo = "/Users/x/workspace/bigdata"
    func report(_ outcome: OrphanNotice.Outcome, pid: pid_t = 10,
                project: String = "/Users/x/workspace/bigdata") -> OrphanNotice.Report {
        OrphanNotice.Report(project: project, program: "node", pid: pid, processes: 2,
                            cpuPercent: nil, memoryBytes: 0, listeningPorts: [],
                            ageSeconds: 3600, outcome: outcome)
    }
    check("successful panel history has a ten-minute lifetime", ttl == 600)

    let fake = FakeMachine()
    let store = fake.store()
    store.announce(report(.reclaimedByLease), at: t0)
    store.announce(report(.reclaimedBySustained, pid: 11), at: t0)
    store.expireSuccessfulRecords(at: t0)
    check("fresh lease and sustained successes remain visible", store.records.count == 2)
    let emptyLoad = MachineLoad(projects: [])
    func ghosts(in load: MachineLoad) -> [ProjectLoad] {
        let remembered = Set(store.records.map(\.project)).union(store.watching.map(\.project))
        return SessionBoardGhosts.unclaimed(in: load, remembering: remembered)
    }
    check("successful history alone supplies a ghost before expiry",
          store.watching.isEmpty && ghosts(in: emptyLoad).map(\.root) == [repo])
    store.expireSuccessfulRecords(at: t0.addingTimeInterval(ttl - 0.001))
    check("both successful outcomes remain immediately before expiry", store.records.count == 2)
    let deliveries = fake.delivered.count
    store.expireSuccessfulRecords(at: t0.addingTimeInterval(ttl))
    check("both successful outcomes expire exactly at their lifetime", store.records.isEmpty)
    check("expiry sends no signals and does not redeliver the original inbox notices",
          deliveries == 2 && fake.delivered.count == deliveries && fake.sent.isEmpty)
    check("a pure-history ghost disappears after its successful record expires",
          ghosts(in: emptyLoad).isEmpty)
    let liveLoad = MachineLoad(projects: [
        ProjectLoad(root: repo, name: "bigdata", cpuPercent: nil, memoryBytes: 0,
                    sessions: 0, strayProcesses: 1)
    ])
    check("a project with actual strays keeps its ghost after history expires",
          ghosts(in: liveLoad).map(\.root) == [repo])

    store.announce(report(.reported(doubts: [])), at: t0)
    store.announce(report(.failed(reason: "still alive"), pid: 11), at: t0)
    let attention = store.records
    store.expireSuccessfulRecords(at: t0.addingTimeInterval(30 * 24 * 3600))
    check("old reports and failures remain available for attention", store.records == attention)

    // Seed a real first round just one second before expiry, including evidence and a watch.
    // The next tick must expire the record despite the five-minute round throttle.
    let throttledMachine = FakeMachine()
    let throttled = throttledMachine.store()
    let root = pid_t(getpgrp()) + 8_000
    let born = Int64(t0.addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000)
    throttledMachine.table = [ProcessIdentity(pid: root, parent: 1, group: root, startedAt: born)]
    throttledMachine.programs = [root: "/opt/homebrew/bin/node"]
    throttledMachine.directories = [root: repo]
    throttledMachine.memory = [root: OrphanReclaim.heldBytes]
    throttled.announce(report(.reclaimedByLease), at: t0)
    throttled.observe(strays: [root: repo], processes: throttledMachine.table,
                      sessions: OrphanReclaim.Sessions(), at: t0.addingTimeInterval(ttl - 1))
    let watches = throttled.watching
    let sightings = throttled.sightings
    check("the pre-expiry round retains history and builds watch evidence",
          throttled.records.count == 1 && !watches.isEmpty && !sightings.isEmpty)
    throttled.observe(strays: [:], processes: [], sessions: OrphanReclaim.Sessions(),
                      at: t0.addingTimeInterval(ttl))
    check("the next tick expires history without waiting for another round",
          throttled.records.isEmpty && throttled.watching == watches
              && throttled.sightings == sightings)
    check("throttled expiry neither signals nor repeats an inbox delivery",
          throttledMachine.sent.isEmpty && throttledMachine.delivered.count == 1
              && throttledMachine.cleared.isEmpty && throttled.sweeps.isEmpty)
    check("an active watch still supplies a ghost after successful history expires",
          SessionBoardGhosts.unclaimed(
              in: emptyLoad,
              remembering: Set(throttled.records.map(\.project))
                  .union(throttled.watching.map(\.project))).map(\.root) == [repo])

    let updating = FakeMachine().store()
    updating.announce(report(.reclaimedByLease), at: t0)
    updating.announce(report(.reclaimedBySustained, pid: 11),
                      at: t0.addingTimeInterval(ttl - 1))
    updating.expireSuccessfulRecords(at: t0.addingTimeInterval(ttl))
    check("expiring an old success does not remove a recent success in the same project",
          updating.records.map(\.pid) == [11])
    let announcing = FakeMachine().store()
    announcing.announce(report(.reclaimedByLease), at: t0)
    announcing.announce(report(.reported(doubts: []), pid: 11),
                        at: t0.addingTimeInterval(ttl))
    check("announcing a new event removes expired successes without an observe tick",
          announcing.records.map(\.pid) == [11])
    for pid in 20...32 {
        announcing.announce(report(.failed(reason: "still alive"), pid: pid_t(pid)),
                            at: t0.addingTimeInterval(ttl))
    }
    check("new events retain the existing twelve-record cap and newest-first order",
          announcing.records.map(\.pid) == Array((21...32).reversed()).map { pid_t($0) })

    // Empty projects avoid inbox date formatting: these fixtures exercise only history retention.
    let unusual = FakeMachine().store()
    for (index, value) in [Double.nan, .infinity, -.infinity].enumerated() {
        unusual.announce(report(.reclaimedByLease, pid: pid_t(index), project: ""),
                         at: Date(timeIntervalSinceReferenceDate: value))
    }
    unusual.expireSuccessfulRecords(at: t0.addingTimeInterval(ttl))
    check("successful records with non-finite timestamps are conservatively retained",
          unusual.records.count == 3)
    let clock = FakeMachine().store()
    clock.announce(report(.reclaimedByLease), at: t0)
    for value in [Double.nan, .infinity, -.infinity] {
        clock.expireSuccessfulRecords(at: Date(timeIntervalSinceReferenceDate: value))
    }
    check("a non-finite observation clock does not expire a successful record",
          clock.records.count == 1)
    clock.expireSuccessfulRecords(at: t0.addingTimeInterval(-ttl))
    check("a future-dated success survives a clock rollback", clock.records.count == 1)
    clock.expireSuccessfulRecords(at: t0.addingTimeInterval(ttl))
    check("a future-dated success expires when its actual lifetime elapses", clock.records.isEmpty)
}
