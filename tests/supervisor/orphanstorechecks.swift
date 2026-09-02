import Darwin
import Foundation

// THE RECLAIM DRIVEN END TO END, one round at a time
// (Tally/Stores/OrphanReclaimStore.swift).
//
// SPLIT FROM orphanchecks.swift when that file reached the repo's 1,000-line cap for a test file
// (2026-09-02), along the seam the suite already had inside it: over there are the pure rules,
// stated with no state and no machine at all, and here is what happens BETWEEN two rounds - which
// is where every defect this feature has had actually lived. All four Criticals the reviews found
// were in this half.
//
// NOTHING HERE TOUCHES A REAL PROCESS. Every reading is a fixture and every signal is recorded
// rather than sent (`FakeMachine`), which is the whole reason the store takes its machine as a
// struct of closures.

// MARK: - the round, end to end

/// A machine with nothing real behind it: every reading is a fixture and every signal is recorded.
@MainActor
private final class FakeMachine {
    var table: [ProcessIdentity] = []
    var programs: [pid_t: String] = [:]
    var directories: [pid_t: String] = [:]
    var sockets: [OrphanReclaim.Connection] = []
    /// Pids whose descriptor table this machine refuses to enumerate, which is a DIFFERENT fixture
    /// from a pid with no sockets (`OrphanReclaim.Sockets`).
    var unreadableSockets: Set<pid_t> = []
    var times: [pid_t: Double] = [:]
    var memory: [pid_t: UInt64] = [:]
    var leases: [OrphanLease] = []
    var cleared: [String] = []
    var terminals: Set<pid_t> = []
    var listening: Set<UInt16> = []
    /// What the kernel says about one pid when asked directly, for the pids it is asked about. A
    /// pid absent from here answers `.gone`, which is what makes an ordinary fixture's dead
    /// supervisor still read as dead.
    var presence: [pid_t: ProcessPresence] = [:]
    /// The table as the ESCALATION sees it, which is a whole grace period after the round's own
    /// walk: nil means "the same table", and setting it is how a fixture states what the machine
    /// did in between (a member exited, a stranger took its group).
    var laterTable: [ProcessIdentity]?
    /// Every signal that was "sent", as `(signal, pid)` and `(signal, -group)`.
    var sent: [(Int32, pid_t)] = []
    /// Which pids the table still holds for the SWEEP, which is a different question from the
    /// round's own walk: a kill takes effect between them.
    var surviving: [pid_t: Int64] = [:]
    var delivered: [(text: String, inbox: URL, name: String)] = []
    var gitRoot = "/Users/x/workspace/bigdata"

    func store(home: URL = URL(fileURLWithPath: "/Users/x")) -> OrphanReclaimStore {
        OrphanReclaimStore(machine: OrphanReclaimStore.Machine(
            program: { [self] pid in MainActor.assumeIsolated { programs[pid] } },
            directory: { [self] pid in MainActor.assumeIsolated { directories[pid] } },
            connections: { [self] pids in
                MainActor.assumeIsolated {
                    OrphanReclaim.Sockets(connections: sockets.filter { pids.contains($0.pid) },
                                          unreadable: unreadableSockets.intersection(pids))
                }
            },
            sample: { [self] pids, at in
                MainActor.assumeIsolated {
                    ProcessResourceSample(times: times.filter { pids.contains($0.key) },
                                          childTimes: [:],
                                          memory: memory.filter { pids.contains($0.key) },
                                          diskWritten: [:], at: at)
                }
            },
            hasTerminal: { [self] pid in MainActor.assumeIsolated { terminals.contains(pid) } },
            leases: { [self] in MainActor.assumeIsolated { leases } },
            clearLease: { [self] lease in
                MainActor.assumeIsolated { cleared.append(lease.pidFile) }
            },
            signals: OrphanKill.Signals(
                send: { [self] signal, pid in
                    MainActor.assumeIsolated { sent.append((signal, pid)) }
                },
                sendGroup: { [self] signal, group in
                    MainActor.assumeIsolated { sent.append((signal, -group)) }
                },
                alive: { [self] pids in
                    MainActor.assumeIsolated { surviving.filter { pids.contains($0.key) } }
                },
                listening: { [self] in MainActor.assumeIsolated { listening } },
                presence: { [self] pid in
                    MainActor.assumeIsolated { presence[pid] ?? .gone }
                },
                table: { [self] in MainActor.assumeIsolated { laterTable ?? table } }),
            gitEntry: { [self] path in
                MainActor.assumeIsolated { path == gitRoot + "/.git" ? .directory : nil }
            },
            deliver: { [self] text, inbox, name in
                MainActor.assumeIsolated {
                    delivered.append((text, inbox, name))
                    return inbox.appendingPathComponent(name)
                }
            },
            home: home))
    }
}

@MainActor
func runOrphanStoreChecks() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let repo = "/Users/x/workspace/bigdata"
    let web = repo + "/web"
    // Old enough for tier B: the age is taken from the root's own start time.
    let born = Int64(t0.addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000)
    // Far from this process's own job, which the plan refuses to signal as a group.
    let group = pid_t(getpgrp()) + 5_000
    let root = group, worker = group + 1

    func busyServer(_ fake: FakeMachine) {
        fake.table = [ProcessIdentity(pid: root, parent: 1, group: group, startedAt: born),
                      ProcessIdentity(pid: worker, parent: root, group: group, startedAt: born)]
        fake.programs = [root: "/opt/homebrew/bin/node", worker: "/opt/homebrew/bin/node"]
        fake.directories = [root: web, worker: web]
        fake.sockets = [OrphanReclaim.Connection(pid: root, localPort: 3000, remotePort: 0,
                                                 remoteIsLoopback: true, listening: true)]
        fake.memory = [root: 400_000_000, worker: 100_000_000]
        fake.surviving = [root: born, worker: born]
    }

    // MARK: two rounds and a reclaim

    let fake = FakeMachine()
    busyServer(fake)
    fake.times = [root: 100, worker: 0]
    let store = fake.store()
    store.observe(strays: [root: web, worker: web], processes: fake.table, at: t0)
    check("the first round of a busy leftover sends nothing at all", fake.sent.isEmpty)
    // AND SAYS NOTHING EITHER, because there is nothing to say yet: a rate needs two readings, so
    // on a first round this app does not know whether the thing is busy at all.
    check("…and puts nothing on the panel, since nothing has been read twice",
          store.watching.isEmpty && fake.delivered.isEmpty)
    // One whole core burned over the five minutes between rounds.
    fake.times = [root: 400, worker: 0]
    let round2 = t0.addingTimeInterval(OrphanReclaim.roundInterval)
    store.observe(strays: [root: web, worker: web], processes: fake.table, at: round2)
    check("the second round asks the whole job to end, once",
          fake.sent.map(\.0) == [SIGTERM] && fake.sent.map(\.1) == [-group])
    check("…and says nothing until it knows whether that worked", store.records.isEmpty)
    // The tree goes, and the port with it.
    fake.surviving = [:]
    store.advance(at: round2.addingTimeInterval(1))
    check("a tree that ended on the first signal is recorded as reclaimed",
          store.records.first?.outcome == .reclaimedBySustained
              && store.records.first?.program == "node" && store.records.count == 1)
    check("…and the project is told, in its own inbox, by the key the workspace path gives",
          fake.delivered.count == 1
              && fake.delivered.first?.inbox.path == "/Users/x/.claude/inboxes/bigdata"
              && fake.delivered.first?.text.contains("**reply**: none") == true)

    // MARK: a child that ignores SIGTERM, and a root that dies before its grandchildren

    let stubborn = FakeMachine()
    busyServer(stubborn)
    stubborn.times = [root: 100, worker: 0]
    let second = stubborn.store()
    second.observe(strays: [root: web, worker: web], processes: stubborn.table, at: t0)
    stubborn.times = [root: 400, worker: 0]
    second.observe(strays: [root: web, worker: web], processes: stubborn.table, at: round2)
    // The root goes at once and the worker does not, which is the ordinary shape of this: a group
    // kill is what reaches the survivor at all. The table the ESCALATION reads is the machine ten
    // seconds later, so the root is out of it.
    stubborn.surviving = [worker: born]
    stubborn.laterTable = [ProcessIdentity(pid: worker, parent: 1, group: group, startedAt: born)]
    second.advance(at: round2.addingTimeInterval(4))
    check("a survivor is waited on rather than shot immediately",
          stubborn.sent.map(\.0) == [SIGTERM])
    second.advance(at: round2.addingTimeInterval(OrphanKill.grace))
    // 🔴 AND ONE PROCESS AT A TIME, EVEN THOUGH THE GROUP IS PROVABLY CLEAN HERE (codex review of
    // 8bfb19c). "Provably" is the word that stopped being true: the proof is a table walk, one
    // `proc_pidinfo` per pid, and a single failure on an unrelated process sharing the group makes
    // a dirty group read as clean. `SIGTERM` may lean on that reading because it is a request;
    // `SIGKILL` may not (`OrphanKill.escalation`).
    check("…and signalled outright once the grace period is up",
          stubborn.sent.map(\.0) == [SIGTERM, SIGKILL] && stubborn.sent.last?.1 == worker)
    check("…with nothing recorded while it is still going on", second.records.isEmpty)
    second.advance(at: round2.addingTimeInterval(OrphanKill.grace + OrphanKill.finalGrace))
    check("a process that survives SIGKILL is reported as a failure, not as a reclaim",
          second.records.first?.outcome == .failed(
              reason: "1 of 2 processes survived SIGKILL"))

    // MARK: 🔴 what the machine did DURING the grace period (codex review, 2026-09-02)

    // THE SECOND SIGNAL USED TO RE-SEND THE FIRST ONE'S PLAN, which is a set of pids and process
    // GROUPS decided ten seconds earlier. Both go stale in that window, and the stale reading ends
    // with a SIGKILL at somebody who was never a candidate.
    //
    // THE FIXTURE HAS TO CONTAIN A REUSED NUMBER OR IT PROVES NOTHING, which is worth writing down
    // because the first version of it did not and passed anyway: with the exited member simply
    // ABSENT from the fresh table, a plan built from the stale target list drops it on the way past
    // `OrphanKill.plan` (which signals nothing the table does not hold), so the assertion was green
    // against the defect (measured, 2026-09-02 - the mutant survived). The hazard is the member
    // that exited AND had its number handed to something else inside the ten seconds: then the
    // stale list names a pid that is very much there, and only the start-time confirmation stops
    // the signal. So here the root goes, a new process takes its number, and that new process
    // carries the same group - which makes the group dirty at the same time.
    let racing = FakeMachine()
    busyServer(racing)
    racing.times = [root: 100, worker: 0]
    let sixthRace = racing.store()
    sixthRace.observe(strays: [root: web, worker: web], processes: racing.table, at: t0)
    racing.times = [root: 400, worker: 0]
    sixthRace.observe(strays: [root: web, worker: web], processes: racing.table, at: round2)
    check("the first signal reaches the whole job in one call, the group being clean",
          racing.sent.map(\.1) == [-group])
    let reused = born + 999_999
    racing.surviving = [worker: born, root: reused]
    racing.laterTable = [ProcessIdentity(pid: worker, parent: 1, group: group, startedAt: born),
                         ProcessIdentity(pid: root, parent: 1, group: group, startedAt: reused)]
    sixthRace.advance(at: round2.addingTimeInterval(OrphanKill.grace))
    // THE STRANGER WEARING THE OLD NUMBER IS THE ONE THIS EXISTS FOR.
    check("a member that exited and had its number handed on is never signalled again",
          !racing.sent.contains { $0.0 == SIGKILL && $0.1 == root })
    check("a group that has picked up somebody else is no longer signalled as a group",
          !racing.sent.contains { $0.0 == SIGKILL && $0.1 == -group })
    check("…the survivor is signalled one process at a time instead",
          racing.sent.filter { $0.0 == SIGKILL }.map(\.1) == [worker])

    // AND THE SAME HAZARD WHERE THE STALE LIST WOULD REACH THE STRANGER BY PID RATHER THAN BY
    // GROUP, which is the cell that pins the target list itself rather than the group rule. The
    // reused number lands in a job that holds an outsider, so a plan naming it cannot group-kill
    // and has to signal it directly: with the survivors confirmed there is nothing to signal, and
    // with the original target list there is a stranger's pid in the delivery.
    let direct = FakeMachine()
    busyServer(direct)
    direct.times = [root: 100, worker: 0]
    let seventhRace = direct.store()
    seventhRace.observe(strays: [root: web, worker: web], processes: direct.table, at: t0)
    direct.times = [root: 400, worker: 0]
    seventhRace.observe(strays: [root: web, worker: web], processes: direct.table, at: round2)
    let elsewhere = group + 700, outsider = group + 701
    direct.surviving = [worker: born, root: reused]
    direct.laterTable = [ProcessIdentity(pid: worker, parent: 1, group: group, startedAt: born),
                         ProcessIdentity(pid: root, parent: 1, group: elsewhere, startedAt: reused),
                         ProcessIdentity(pid: outsider, parent: 1, group: elsewhere,
                                         startedAt: born)]
    seventhRace.advance(at: round2.addingTimeInterval(OrphanKill.grace))
    check("a pid that is no longer the process it was is not in the SIGKILL delivery at all",
          !direct.sent.contains { $0.0 == SIGKILL && $0.1 == root })
    check("…and what IS delivered is the one surviving process, nothing wider",
          direct.sent.filter { $0.0 == SIGKILL }.map(\.1) == [worker])

    // MARK: 🔴 the escalation signals no group, ever (codex review of 8bfb19c)

    // THE NEGATIVE PID IS THE WHOLE ASSERTION. `kill` reads a pid below zero as a process GROUP, so
    // a single negative number in the delivery set is the difference between ending a tree and
    // ending whatever else happened to share its group. Taken over every sweep this file has
    // driven, so a group arm added back anywhere on the escalation path is caught here rather than
    // in whichever scenario happened to exercise it.
    for (name, fake) in [("a job every member of which is being reclaimed", stubborn),
                         ("a group that picked up a reused number", racing),
                         ("a survivor whose job holds an outsider", direct)] {
        check("no SIGKILL is ever addressed to a process group (\(name))",
              !fake.sent.contains { $0.0 == SIGKILL && $0.1 < 0 })
    }
    // …AND THE FIRST SIGNAL STILL DOES GROUP, which is the other half of the same decision: it is a
    // request rather than an execution, and the reach is what catches the workers a dev server
    // keeps spawning.
    check("…while SIGTERM still reaches the whole job in one call",
          stubborn.sent.contains { $0.0 == SIGTERM && $0.1 == -group })

    // MARK: 🔴 a number that changed hands between the sweep's two readings (codex review, same)

    // THE SWEEP READS THE MACHINE TWICE: once to ask who is still alive, and again - a moment later
    // - to rebuild the plan against a fresh table. A survivor that exited in between and had its
    // number handed on is alive in BOTH readings and is a different process in the second, and the
    // plan only asks whether a pid is in the table. So the recorded start time is intersected
    // against the fresh walk as well, and a pid survives only where all three readings agree.
    let handedOn = FakeMachine()
    busyServer(handedOn)
    handedOn.times = [root: 100, worker: 0]
    let eighthRace = handedOn.store()
    eighthRace.observe(strays: [root: web, worker: web], processes: handedOn.table, at: t0)
    handedOn.times = [root: 400, worker: 0]
    eighthRace.observe(strays: [root: web, worker: web], processes: handedOn.table, at: round2)
    // `alive()` still names the worker at the start time the round recorded, so it is a survivor;
    // the fresh table a moment later says that number belongs to something younger.
    handedOn.surviving = [worker: born]
    handedOn.laterTable = [ProcessIdentity(pid: worker, parent: 1, group: group, startedAt: reused)]
    eighthRace.advance(at: round2.addingTimeInterval(OrphanKill.grace))
    check("a survivor whose number changed hands between the two readings is not signalled",
          !handedOn.sent.contains { $0.0 == SIGKILL })

    // MARK: the tree is gone and the port is not

    let stuck = FakeMachine()
    busyServer(stuck)
    stuck.times = [root: 100, worker: 0]
    let third = stuck.store()
    third.observe(strays: [root: web, worker: web], processes: stuck.table, at: t0)
    stuck.times = [root: 400, worker: 0]
    third.observe(strays: [root: web, worker: web], processes: stuck.table, at: round2)
    stuck.surviving = [:]
    stuck.listening = [3000]
    third.advance(at: round2.addingTimeInterval(1))
    check("a reclaim whose port is still held afterwards does not report success",
          {
              if case .failed = third.records.first?.outcome { return true }
              return false
          }())

    // MARK: a browser on it, which must end the whole thing before it starts

    let watched = FakeMachine()
    busyServer(watched)
    watched.sockets.append(OrphanReclaim.Connection(pid: root, localPort: 3000, remotePort: 54_321,
                                                    remoteIsLoopback: true, listening: false))
    watched.times = [root: 100, worker: 0]
    let fourth = watched.store()
    fourth.observe(strays: [root: web, worker: web], processes: watched.table, at: t0)
    watched.times = [root: 400, worker: 0]
    fourth.observe(strays: [root: web, worker: web], processes: watched.table, at: round2)
    check("a server with a browser attached is never signalled, however busy or old",
          watched.sent.isEmpty && fourth.records.isEmpty)

    // MARK: tier C, which is the whole of what a doubt buys

    let doubted = FakeMachine()
    busyServer(doubted)
    // Not a program this app is willing to end - a soft veto, so the answer is a message rather
    // than either a signal or silence.
    doubted.programs = [root: "/usr/local/bin/mystery", worker: "/usr/local/bin/mystery"]
    doubted.times = [root: 100, worker: 0]
    let eighth = doubted.store()
    eighth.observe(strays: [root: web, worker: web], processes: doubted.table, at: t0)
    doubted.times = [root: 400, worker: 0]
    eighth.observe(strays: [root: web, worker: web], processes: doubted.table, at: round2)
    check("something heavy this app cannot vouch for is reported and never signalled",
          doubted.sent.isEmpty && eighth.records.first?.outcome
              == .reported(doubts: [.unknownProgram]))
    check("…on the panel as well as in the project's inbox",
          eighth.watching.map(\.pid) == [root] && doubted.delivered.count == 1
              && doubted.delivered.first?.text.contains("Left it alone.") == true)
    // AND NOT AGAIN AN HOUR LATER, which is what turns a channel into noise.
    doubted.times = [root: 700, worker: 0]
    eighth.observe(strays: [root: web, worker: web], processes: doubted.table,
                   at: round2.addingTimeInterval(OrphanReclaim.roundInterval))
    check("…and not said a second time the same day",
          doubted.delivered.count == 1 && eighth.records.count == 1)

    // MARK: 🔴 a descriptor table the machine would not read (codex review, 2026-09-02)

    // "NOBODY IS CONNECTED TO IT" AND "I COULD NOT FIND OUT" WERE THE SAME EMPTY LIST, and the
    // first of those is a reading that lets a tree be ended. One transient PROC_PIDLISTFDS failure
    // therefore turned the in-use veto off with nothing saying so - the browser holding an HMR
    // socket would simply not have been seen. Named, it is a doubt, and a doubt is tier C.
    let blind = FakeMachine()
    busyServer(blind)
    blind.unreadableSockets = [worker]
    blind.times = [root: 100, worker: 0]
    let ninth = blind.store()
    ninth.observe(strays: [root: web, worker: web], processes: blind.table, at: t0)
    blind.times = [root: 400, worker: 0]
    ninth.observe(strays: [root: web, worker: web], processes: blind.table, at: round2)
    check("a tree whose sockets could not be enumerated is reported rather than ended",
          blind.sent.isEmpty
              && ninth.records.first?.outcome == .reported(doubts: [.unreadable]))

    // MARK: a round is not a tick

    let paced = FakeMachine()
    busyServer(paced)
    paced.times = [root: 100, worker: 0]
    let fifth = paced.store()
    fifth.observe(strays: [root: web, worker: web], processes: paced.table, at: t0)
    paced.times = [root: 400, worker: 0]
    // Two seconds later, which is the sampler's own beat: a pair this close is one moment read
    // twice, and taking it as a round would confirm a link step as a runaway.
    fifth.observe(strays: [root: web, worker: web], processes: paced.table,
                  at: t0.addingTimeInterval(2))
    check("the sampler's own tick does not take a round", paced.sent.isEmpty)

    // MARK: the lease, driven through the store

    let leased = FakeMachine()
    busyServer(leased)
    let leaseBorn = Date(timeIntervalSince1970: Double(born) / 1_000_000).addingTimeInterval(-1)
    leased.leases = [OrphanLease(project: "bigdata-web", pidFile: "/tmp/bigdata-web.devwatch.pid",
                                 supervisor: 999_999, bornAt: leaseBorn, child: root,
                                 childBornAt: leaseBorn.addingTimeInterval(2))]
    let sixth = leased.store()
    // ONE ROUND, NOT TWO: the lease is a statement by the machine's own harness, not an inference.
    sixth.observe(strays: [:], processes: leased.table, at: t0)
    check("an abandoned lease is acted on in the very first round it is seen",
          leased.sent.map(\.0) == [SIGTERM])
    leased.surviving = [:]
    sixth.advance(at: t0.addingTimeInterval(1))
    check("…recorded as a reclaim the lease itself justified",
          sixth.records.first?.outcome == .reclaimedByLease)
    check("…and the lease's four files go with the tree, so no green light is left pointing at it",
          leased.cleared == ["/tmp/bigdata-web.devwatch.pid"])

    // AND A LEASE WHOSE SUPERVISOR IS ALIVE IS THE ROW THAT MUST END IN SILENCE.
    let tended = FakeMachine()
    busyServer(tended)
    tended.table.append(ProcessIdentity(pid: 999_999, parent: 1, group: 999_999,
                                        startedAt: Int64(leaseBorn.timeIntervalSince1970 * 1_000_000)))
    tended.leases = [OrphanLease(project: "bigdata-web", pidFile: "/tmp/bigdata-web.devwatch.pid",
                                 supervisor: 999_999, bornAt: leaseBorn, child: root,
                                 childBornAt: leaseBorn.addingTimeInterval(2))]
    let seventh = tended.store()
    seventh.observe(strays: [:], processes: tended.table, at: t0)
    check("a dev-watch supervisor that is alive and well has its server left entirely alone",
          tended.sent.isEmpty && tended.cleared.isEmpty)

    // MARK: 🔴 the table missing the supervisor, driven through the store (codex review, 2026-09-02)

    // THE WALK IS ONE `proc_pidinfo` PER PID AND ANY OF THEM CAN FAIL FOR A PASS. Read as death,
    // that lands in tier A, which sends a SIGTERM in the same round with no two-round confirmation
    // and no veto sweep anywhere near it - so a single missed reading ended a dev server whose
    // supervisor was sitting right there. Both fixtures below leave the supervisor OUT of the
    // table, which is exactly what such a failure looks like from in here.
    for (verdict, answer) in [("alive when the kernel is asked", ProcessPresence.running),
                              ("something the kernel will not answer for", .unknown)] {
        let missed = FakeMachine()
        busyServer(missed)
        missed.presence = [999_999: answer]
        missed.leases = [OrphanLease(project: "bigdata-web",
                                     pidFile: "/tmp/bigdata-web.devwatch.pid",
                                     supervisor: 999_999, bornAt: leaseBorn, child: root,
                                     childBornAt: leaseBorn.addingTimeInterval(2))]
        let store = missed.store()
        store.observe(strays: [:], processes: missed.table, at: t0)
        check("a supervisor absent from the table but \(verdict) has its server left alone",
              missed.sent.isEmpty && missed.cleared.isEmpty && store.records.isEmpty)
    }

    // MARK: a capture never reaches any of this

    // The demo flag fabricates every figure on this board, and a screenshot run that ended a real
    // process because a fixture said it was busy would be the worst version of this feature. The
    // flag cannot be turned on here (it is process-wide and the suites after this one would run in
    // demo mode, which is why demoboardchecks.swift is last), so the guard is pinned in the source.
    let source = (try? String(contentsOfFile: "Tally/Stores/OrphanReclaimStore.swift",
                              encoding: .utf8)) ?? ""
    check("a capture takes no round at all",
          source.contains("guard !DemoUsage.isActive else { return }"))
    check("…and the guard sits before the round rather than after the sweep",
          (source.range(of: "guard !DemoUsage.isActive")?.lowerBound).map { flag in
              (source.range(of: "lastRound = now")?.lowerBound).map { flag < $0 } ?? false
          } == true)
}

