import Darwin
import Foundation

// WHAT A STANDING TREE IS TOLD ACROSS PROCESSES (OrphanReclaim.NoticeMemory).
//
// Replayed from the 2026-10-05 jetto-web inbox: 29 messages in 5.5 hours about one `pnpm dev`
// (pid 21369, :3005, a session working in the checkout), each written by a DIFFERENT Tally
// process (the writer pid is in every filename; the system log shows the three in the densest
// minute were `Tally Dev` launched seconds earlier) and none a repeat within its own process. Each launch below is a fresh store, which is what a new process
// is: nothing in memory, a round due at once. They share one home, which is what the machine had.
@MainActor
func runOrphanMemoryChecks() {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("orphan-memory-\(getpid())-\(UInt32.random(in: 0 ..< 1_000_000))")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    // The local clock times in the 29 filenames (HHMMSS, 2026-10-05, +08:00).
    let stamps = [095716, 105618, 111524, 111543, 111600, 111633, 111814, 111830, 113254, 114226,
                  115626, 120618, 123022, 132442, 140700, 142620, 143144, 144740, 144833, 145207,
                  145231, 153658, 153941, 154134, 155047, 155356, 162052, 162252, 162315]
    let midnight = Date(timeIntervalSince1970: 1_791_129_600) // 2026-10-05T00:00:00+08:00
    let moments = stamps.map {
        midnight.addingTimeInterval(Double($0 / 10_000 * 3600 + $0 / 100 % 100 * 60 + $0 % 100))
    }
    let web = "/Users/x/workspace/web"
    let root: pid_t = 21369, worker: pid_t = 21370
    let born = Int64(moments[0].addingTimeInterval(-12 * 3600).timeIntervalSince1970 * 1_000_000)
    let fake = FakeMachine()
    fake.gitRoot = web
    fake.table = [ProcessIdentity(pid: root, parent: 1, group: root, startedAt: born),
                  ProcessIdentity(pid: worker, parent: root, group: root, startedAt: born)]
    fake.programs = [root: "/opt/homebrew/bin/node", worker: "/opt/homebrew/bin/node"]
    fake.directories = [root: web, worker: web]
    fake.sockets = [OrphanReclaim.Connection(pid: root, localPort: 3005, remotePort: 0,
                                             remoteIsLoopback: true, listening: true)]
    fake.memory = [root: 2_300_000_000, worker: 100_000_000]

    for moment in moments {
        fake.store(home: home).observe(strays: [root: web, worker: web], processes: fake.table,
                                       sessions: OrphanReclaim.Sessions(checkouts: [web]),
                                       at: moment)
    }
    check("one standing tree is written about once however many processes take a round on it"
              + " (29 launches replayed, got \(fake.delivered.count))",
          fake.delivered.count == 1)

    // AND A TREE NOBODY HAS TOLD THE INBOX ABOUT IS STILL SAID by a new process: the same number
    // at a later birth is a different tree, on a port the first never held.
    let reborn = born + 3_600_000_000
    fake.table = fake.table.map {
        ProcessIdentity(pid: $0.pid, parent: $0.parent, group: $0.group, startedAt: reborn)
    }
    fake.sockets = [OrphanReclaim.Connection(pid: root, localPort: 3006, remotePort: 0,
                                             remoteIsLoopback: true, listening: true)]
    fake.store(home: home).observe(strays: [root: web, worker: web], processes: fake.table,
                                   sessions: OrphanReclaim.Sessions(checkouts: [web]),
                                   at: moments[moments.count - 1].addingTimeInterval(600))
    check("…while a different tree is still announced by the next process that sees it",
          fake.delivered.count == 2)

    // WITHIN ONE PROCESS, A SESSION COMING AND GOING IS NOT NEWS EITHER: the round without a
    // session changes the doubts, and the situation key (no doubts in it) holds that quiet.
    // Pinned because it was the other suspected cause of the same report; it was never one.
    let flap = FakeMachine()
    flap.gitRoot = web
    flap.table = fake.table
    flap.programs = fake.programs
    flap.directories = fake.directories
    flap.sockets = fake.sockets
    flap.memory = fake.memory
    let one = flap.store()
    for index in 0 ..< 8 {
        flap.times = [root: Double(100 + index), worker: 0]
        one.observe(strays: [root: web, worker: web], processes: flap.table,
                    sessions: OrphanReclaim.Sessions(checkouts: index % 2 == 0 ? [web] : []),
                    at: moments[0].addingTimeInterval(Double(index) * OrphanReclaim.roundInterval))
    }
    check("a session arriving and leaving round after round does not repeat the message",
          flap.delivered.count == 1)
}
