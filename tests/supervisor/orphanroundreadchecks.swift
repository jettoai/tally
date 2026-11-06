import Darwin
import Foundation

// A RECLAIM ROUND'S MACHINE READINGS ARE TAKEN OFF THE MAIN THREAD (Sentry TALLY-B6, 2026-11-06:
// `proc_pid_rusage` inside the round held the menu bar for over two seconds at load 45).
// Tally/Stores/OrphanReclaimRoundReads.swift builds the readings in the footprint pass's detached
// hop and `OrphanReclaimStore.observe` consumes them; FakeMachine cannot drive this (its closures
// trap off the main thread), so `ThreadedMachine` records which thread asked what.

/// A machine that records which thread asked it what, and can be slow on cue.
final class ThreadedMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(api: String, onMain: Bool)] = []
    var delay: TimeInterval = 0
    var table: [ProcessIdentity] = []
    var directories: [pid_t: String] = [:]
    var sockets: [OrphanReclaim.Connection] = []
    var times: [pid_t: Double] = [:]
    var memory: [pid_t: UInt64] = [:]
    let home: URL

    init() {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orphan-round-reads-\(UUID().uuidString)")
    }

    var calls: [(api: String, onMain: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func reset() {
        lock.lock(); recorded = []; lock.unlock()
    }

    private func note(_ api: String) {
        lock.lock(); recorded.append((api, Thread.isMainThread)); lock.unlock()
    }

    var machine: OrphanReclaimStore.Machine {
        OrphanReclaimStore.Machine(
            program: { [self] _ in note("program"); return "/opt/homebrew/bin/node" },
            directory: { [self] in note("directory"); return directories[$0] },
            connections: { [self] pids in
                note("connections")
                return OrphanReclaim.Sockets(connections: sockets.filter { pids.contains($0.pid) })
            },
            sample: { [self] pids, at in
                note("sample")
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                return ProcessResourceSample(times: times.filter { pids.contains($0.key) },
                                             childTimes: [:],
                                             memory: memory.filter { pids.contains($0.key) },
                                             diskWritten: [:], at: at)
            },
            hasTerminal: { [self] _ in note("hasTerminal"); return false },
            leases: { [] },
            clearLease: { _ in },
            signals: OrphanKill.Signals(send: { _, _ in }, alive: { _ in [:] }, listening: { [] },
                                        presence: { _ in .gone }, table: { [] }),
            resolve: { [self] in note("resolve"); return $0 },
            gitEntry: { [self] _ in note("gitEntry"); return nil },
            deliver: { _, _, _ in },
            home: home)
    }
}

/// Runs `work` on a thread of its own and waits. Not `DispatchQueue.global().sync`: GCD may run a
/// sync block on the calling thread, which would measure the main thread.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: T?
    Thread { out = work(); done.signal() }.start()
    done.wait()
    return out!
}

@MainActor
func runOrphanRoundReadChecks() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let web = "/Users/x/workspace/bigdata/web"
    let born = Int64(t0.addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000)
    let group = pid_t(getpgrp()) + 5_000
    let round2 = t0.addingTimeInterval(OrphanReclaim.roundInterval)
    let none = OrphanReclaim.Sessions()

    /// `count` independent servers (each its own root) plus, for the first one, a worker.
    func scenario(_ m: ThreadedMachine, trees count: Int = 1, rootMemory: UInt64 = 400_000_000)
        -> (strays: [pid_t: String], roots: [pid_t]) {
        var strays: [pid_t: String] = [:]
        var roots: [pid_t] = []
        m.table = []
        for i in 0..<count {
            let root = group + pid_t(i * 10)
            roots.append(root)
            m.table.append(ProcessIdentity(pid: root, parent: 1, group: root, startedAt: born))
            m.directories[root] = web
            m.memory[root] = rootMemory
            m.times[root] = 100
            m.sockets.append(OrphanReclaim.Connection(pid: root, localPort: UInt16(3000 + i),
                                                      remotePort: 0, remoteIsLoopback: true,
                                                      listening: true))
            strays[root] = web
        }
        let worker = roots[0] + 1
        m.table.append(ProcessIdentity(pid: worker, parent: roots[0], group: roots[0], startedAt: born))
        m.directories[worker] = web
        m.memory[worker] = 100_000_000
        m.times[worker] = 0
        strays[worker] = web
        return (strays, roots)
    }

    // R1 + R2: the readings are all taken off the main thread, and the round asks the machine for
    // none of them.
    let fast = ThreadedMachine()
    let s1 = scenario(fast)
    let store1 = OrphanReclaimStore(machine: fast.machine)
    let reader = store1.roundReaderIfDue(strays: s1.strays, processes: fast.table, sessions: none, at: t0)
    check("R1 a due round hands back a reader", reader != nil)
    let reads = reader.map { r in offMain { r() } }
    let apis = Set(fast.calls.map(\.api))
    check("R1 the reader takes every reading off the main thread",
          !fast.calls.isEmpty && fast.calls.allSatisfy { !$0.onMain }
              && ["sample", "program", "directory", "connections"].allSatisfy(apis.contains))
    fast.reset()
    store1.observe(strays: s1.strays, processes: fast.table, sessions: none, at: t0, reads: reads)
    let heavyApis: Set<String> = ["program", "directory", "sample", "connections", "hasTerminal",
                                  "gitEntry", "resolve"]
    check("R2 the round reads nothing from the machine when it was handed the readings",
          fast.calls.filter { heavyApis.contains($0.api) }.isEmpty)

    // R3: moving the reads must not change a verdict. Two rounds each, the second one a report.
    func twoRounds(prefetch: Bool) -> (OrphanReclaimStore, ThreadedMachine) {
        let m = ThreadedMachine()
        let s = scenario(m)
        let store = OrphanReclaimStore(machine: m.machine)
        for (n, at) in [t0, round2].enumerated() {
            m.times[s.roots[0]] = n == 0 ? 100 : 400
            let reads = prefetch
                ? store.roundReaderIfDue(strays: s.strays, processes: m.table, sessions: none, at: at)
                    .map { r in offMain { r() } }
                : nil
            store.observe(strays: s.strays, processes: m.table, sessions: none, at: at, reads: reads)
        }
        return (store, m)
    }
    let (sync, syncMachine) = twoRounds(prefetch: false)
    let (ahead, aheadMachine) = twoRounds(prefetch: true)
    check("R3 the scenario reaches a report (the comparison is not vacuous)", sync.records.count == 1)
    check("R3 handed readings reach the same verdict as reading in place",
          sync.watching == ahead.watching && sync.sightings == ahead.sightings
              && sync.records.map(\.outcome) == ahead.records.map(\.outcome)
              && sync.records.map(\.pid) == ahead.records.map(\.pid))
    for m in [syncMachine, aheadMachine] { try? FileManager.default.removeItem(at: m.home) }

    // R4: a slow machine does not hold the thread that calls `observe`.
    let slowSync = ThreadedMachine(), slowAhead = ThreadedMachine()
    slowSync.delay = 0.3; slowAhead.delay = 0.3
    let a = scenario(slowSync, trees: 3), b = scenario(slowAhead, trees: 3)
    let slowControl = OrphanReclaimStore(machine: slowSync.machine)
    let slowStore = OrphanReclaimStore(machine: slowAhead.machine)
    let inPlace = ContinuousClock().measure {
        slowControl.observe(strays: a.strays, processes: slowSync.table, sessions: none, at: t0)
    }
    let slowReads = slowStore.roundReaderIfDue(strays: b.strays, processes: slowAhead.table,
                                               sessions: none, at: t0).map { r in offMain { r() } }
    let handed = ContinuousClock().measure {
        slowStore.observe(strays: b.strays, processes: slowAhead.table, sessions: none, at: t0,
                          reads: slowReads)
    }
    check("R4 the control really is slow (three trees x 0.3 s), or this proves nothing",
          inPlace >= .milliseconds(850))
    check("R4 handed the readings, the same slow machine costs the main thread under 50 ms",
          handed < .milliseconds(50))

    // R5: a tree that lost a member between the readings and the round is read again, in place.
    let shrunk = ThreadedMachine()
    let c = scenario(shrunk, rootMemory: 2_500_000_000)
    let store5 = OrphanReclaimStore(machine: shrunk.machine)
    let wide = store5.roundReaderIfDue(strays: c.strays, processes: shrunk.table, sessions: none, at: t0)
        .map { r in offMain { r() } }
    shrunk.reset()
    store5.observe(strays: [c.roots[0]: web], processes: shrunk.table, sessions: none, at: t0, reads: wide)
    let sampled = shrunk.calls.filter { $0.api == "sample" }
    check("R5 a tree whose members changed is sampled again on the main thread, once",
          sampled.count == 1 && sampled[0].onMain)
    check("R5 and the worker that left is not counted in its memory",
          store5.watching.first?.memoryBytes == 2_500_000_000)

    // R6: no reader when no round is due.
    check("R6 a round that was just taken has no reader",
          store1.roundReaderIfDue(strays: s1.strays, processes: fast.table, sessions: none,
                                  at: t0.addingTimeInterval(1)) == nil)
    check("R6 and the next one is due again after the interval",
          store1.roundReaderIfDue(strays: s1.strays, processes: fast.table, sessions: none,
                                  at: round2) != nil)
    for m in [fast, shrunk, slowSync, slowAhead] { try? FileManager.default.removeItem(at: m.home) }

    // R7: the pass builds the reader on the main actor, runs it inside the detached hop, and hands it on.
    let pass = (try? String(contentsOfFile: "Tally/Stores/ProcessFootprintPass.swift", encoding: .utf8)) ?? ""
    let built = pass.range(of: "roundReaderIfDue(")?.lowerBound
    let run = pass.range(of: "roundReader?()")
    let hop = run.flatMap { pass[..<$0.lowerBound].range(of: "await Task.detached(priority: .utility) {",
                                                          options: .backwards) }
    check("R7 the reader is built, then run inside the detached hop, then handed to observe",
          built != nil && hop != nil && run != nil && built! < hop!.lowerBound
              && !pass[hop!.upperBound..<run!.lowerBound].contains("}.value")
              && pass.contains("reads: roundReads") && pass.components(separatedBy: "roundReader?()").count == 2)
}
