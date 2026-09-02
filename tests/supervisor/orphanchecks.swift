import Darwin
import Foundation

// ENDING SOMEBODY ELSE'S PROCESS, WHICH IS THE THING THIS FEATURE CANNOT TAKE BACK
// (Tally/Core/Orphan*.swift, Tally/Stores/OrphanReclaimStore*.swift).
//
// Every other reading on the session board can be wrong for a tick and right on the next one. This
// one sends a signal. So the whole feature is written to be assertable with no processes around it -
// the tiers, the vetoes, the identity tests, the kill plan and the sweep are pure, and the store
// takes its machine as a struct of closures - and this file is the reason that shape was chosen:
// what follows is the acceptance matrix from the plan, one cell at a time, with nothing on this
// machine at risk.
//
// THE MATRIX (docs/plans, "the acceptance"): a clean teardown, a Ctrl-C, a wrapper killed outright,
// a child that ignores SIGTERM, a root that dies before its grandchildren, a portless CPU loop, a
// recycled pid, a stranger's server on the same port, a browser holding an HMR socket, a tunnel, and
// a dev-watch supervisor that is alive and well. Ten of those eleven must end with nothing happening.
@MainActor
func runOrphanChecks() {
    runOrphanTreeChecks()
    runOrphanLeaseChecks()
    runOrphanVerdictChecks()
    runOrphanKillChecks()
    runOrphanNoticeChecks()
    runOrphanStoreChecks()
}

// MARK: - which strays belong together

private func runOrphanTreeChecks() {
    let repo = "/Users/x/workspace/tally"
    let other = "/Users/x/workspace/bigdata"
    // A server, its worker, and an unrelated shell in the same checkout.
    let table = [identity(900, parent: 1, group: 900), identity(901, parent: 900, group: 900),
                 identity(902, parent: 1, group: 902),
                 // …and a worker whose parent is in ANOTHER project's pool.
                 identity(903, parent: 900, group: 900)]
    let trees = OrphanReclaim.trees(of: [900: repo, 901: repo, 902: repo, 903: other],
                                    among: table)
    check("a stray whose parent is also a stray of the same project is in that parent's tree",
          trees.first { $0.root == 900 }?.members == [900, 901])
    check("…and one with no stray above it is a tree of its own",
          trees.contains { $0.root == 902 && $0.members == [902] })
    // FUSING TWO CHECKOUTS' WORK INTO ONE TREE IS THE ERROR THAT KILLS THE INNOCENT HALF: the
    // verdict would then be taken on the pair and the signal sent to both.
    check("…and a child working in another project is never folded into this one's tree",
          trees.contains { $0.root == 903 && $0.members == [903] })
    // A STRANGER'S SERVER ON THE SAME PORT: something outside every checkout this app accounts for
    // is not in the stray map at all, so no tree can reach it and no plan can name it. This is the
    // matrix row that would be worst to get wrong - the port collision is exactly the symptom a
    // person is chasing when they come looking.
    let foreign = table + [identity(500, parent: 1, group: 500)]
    check("a process outside these checkouts is in no tree, whatever port it is holding",
          OrphanReclaim.trees(of: [900: repo, 901: repo], among: foreign)
              .flatMap { $0.members }.sorted() == [900, 901])
    check("the root's start time is carried, since the pid alone is not the tree's identity",
          trees.first { $0.root == 900 }?.rootStartedAt == identity(900, parent: 1,
                                                                    group: 900).startedAt)
    // A parent map assembled from a moving table can hold a cycle; the walk must still end, and
    // every stray must land in exactly one tree whichever way it broke the loop.
    let looped = [identity(10, parent: 11, group: 10), identity(11, parent: 10, group: 10)]
    let broken = OrphanReclaim.trees(of: [10: repo, 11: repo], among: looped)
    check("a parent map that loops does not hang the walk, and loses nobody",
          broken.flatMap { $0.members }.sorted() == [10, 11])

    // The ancestry walk, which is how a tmux or an editor above a tree is found at all.
    check("the ancestry stops at launchd rather than walking into it",
          OrphanReclaim.ancestry(of: 5, parents: [5: 4, 4: 3, 3: 1]) == [4, 3])
    check("…and a loop in it terminates too",
          OrphanReclaim.ancestry(of: 5, parents: [5: 6, 6: 5]) == [6])
}

// MARK: - the lease: tier A

private func runOrphanLeaseChecks() {
    let born = Date(timeIntervalSince1970: 1_800_000_000)
    let lease = OrphanLease(project: "bigdata-web", pidFile: "/tmp/bigdata-web.devwatch.pid",
                            supervisor: 500, bornAt: born, child: 600,
                            childBornAt: born.addingTimeInterval(300))
    // Microseconds since the epoch, the unit every pid stamp in this repository uses.
    func began(_ instant: Date) -> Int64 { Int64(instant.timeIntervalSince1970 * 1_000_000) }
    /// How many times the direct probe was asked, so "it was not consulted" can be asserted as well
    /// as what it answered: the probe is a syscall the common case must not pay for, and a rule
    /// that asked it about a RECYCLED number would be asking whether a stranger is running.
    var asked = 0
    func state(_ lease: OrphanLease, supervisor: Int64?, presence: ProcessPresence = .gone,
               child: Int64?) -> OrphanReclaim.LeaseState {
        OrphanReclaim.state(of: lease, supervisorStartedAt: supervisor,
                            presence: { asked += 1; return presence }, childStartedAt: child)
    }

    // A LIVE `/dev-watch` SUPERVISOR IS THE FIRST ROW OF THE MATRIX THAT MUST END IN SILENCE.
    check("a lease whose supervisor is still the process that wrote it is left entirely alone",
          state(lease, supervisor: began(born.addingTimeInterval(-1)),
                child: began(born.addingTimeInterval(300))) == .tended)
    check("…without a syscall, since the table already answered", asked == 0)
    // THE WRAPPER KILLED OUTRIGHT: the supervisor's EXIT trap never ran, so all four files are
    // still there and the tree it named is still running. This is the whole of tier A.
    check("a lease whose supervisor is gone and whose tree is alive is reclaimable outright",
          state(lease, supervisor: nil, presence: .gone,
                child: began(born.addingTimeInterval(300))) == .abandoned(root: 600))
    // 🔴 A TABLE MISSING A PROCESS IS NOT THE PROCESS BEING GONE (codex review, 2026-09-02). The
    // walk that produces the table is one `proc_pidinfo` per pid and any of them can fail for a
    // pass; read as death, one such failure ends a healthy dev server in the same round, with no
    // second round and no veto sweep anywhere near it. So the kernel is asked about that one pid.
    check("a supervisor merely absent from the table, but alive when asked, is left alone",
          state(lease, supervisor: nil, presence: .running,
                child: began(born.addingTimeInterval(300))) == .tended)
    check("…and one the kernel will not answer for is left alone too, for tier B to look at",
          state(lease, supervisor: nil, presence: .unknown,
                child: began(born.addingTimeInterval(300))) == .unsure)
    // A CLEAN TEARDOWN AND A CTRL-C both run the trap, which deletes the files: there is no lease
    // to read at all, which the reader below asserts. What reaches here is the other clean ending -
    // the supervisor gone AND its tree gone - and it must not send a signal to anything.
    check("a lease whose tree has ended too is spent, not reclaimable",
          state(lease, supervisor: nil, child: nil) == .spent)
    // THE RECYCLED PID, ARRIVING AT THE SUPERVISOR: some new process holds 500 now. It started
    // AFTER the lease was written, so it did not write it, and the real writer is gone.
    asked = 0
    check("a supervisor pid the machine handed out again does not keep the lease alive",
          state(lease, supervisor: began(born.addingTimeInterval(600)),
                child: began(born.addingTimeInterval(300))) == .abandoned(root: 600))
    // …AND THE PROBE IS NOT ASKED ABOUT IT, which would be asking whether a stranger is running and
    // getting a yes: the writer being gone here is arithmetic, not an observation.
    check("…and the kernel is not asked whether that stranger is running", asked == 0)
    // …AND THE RECYCLING ARRIVING AT THE CHILD, which is the direction that ends a stranger: 600 is
    // somebody else's process now, and the lease says nothing about it.
    check("a child pid the machine handed out again is never signalled on the lease's word",
          state(lease, supervisor: nil, child: began(born.addingTimeInterval(600))) == .spent)
    // The child is compared against ITS OWN file, which is rewritten on every restart: comparing it
    // against the supervisor's stamp would call every restarted server a recycled number.
    check("a server restarted long after the lease was written is still the lease's own",
          state(lease, supervisor: nil, child: began(born.addingTimeInterval(299)))
              == .abandoned(root: 600))
    check("a lease with no child file has no way down to a tree and is left alone",
          state(OrphanLease(project: "x", pidFile: "/tmp/x.devwatch.pid", supervisor: 500,
                            bornAt: born, child: nil, childBornAt: nil),
                supervisor: nil, child: nil) == .spent)
    // The statusline draws a green `dev:<port>` from the mere existence of `.port`, so a tree ended
    // without all four files going leaves a light pointing at nothing.
    check("the four files of a lease are named, the port and the timeout flag included",
          lease.files == ["/tmp/bigdata-web.devwatch.pid", "/tmp/bigdata-web.devwatch.pid.child",
                          "/tmp/bigdata-web.devwatch.pid.port",
                          "/tmp/bigdata-web.devwatch.starttimeout"])

    // MARK: reading them off a disk

    let directory = NSTemporaryDirectory() + "orphan-lease-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    func write(_ text: String, _ name: String) {
        try? text.write(toFile: directory + "/" + name, atomically: true, encoding: .utf8)
    }
    // A CLEAN TEARDOWN LEAVES NOTHING, which is the first row of the matrix as the reader sees it.
    check("a directory with no lease files in it produces no leases",
          OrphanLeases.all(in: directory).isEmpty)
    write("4242\n", "demo.devwatch.pid")
    write("4343\n", "demo.devwatch.pid.child")
    write("not a pid", "broken.devwatch.pid")
    write("3000", "demo.devwatch.pid.port")
    let read = OrphanLeases.all(in: directory)
    check("a lease is read as its two pids and the two stamps its files carry",
          read.count == 1 && read.first?.supervisor == 4242 && read.first?.child == 4343
              && read.first?.project == "demo" && read.first?.childBornAt != nil)
    check("…and a pid file holding something that is not a pid is simply not a lease",
          !read.contains { $0.project == "broken" })
    OrphanLeases.clear(read[0])
    check("clearing a lease takes all four files with it",
          (try? FileManager.default.contentsOfDirectory(atPath: directory)) == ["broken.devwatch.pid"])
}

// MARK: - the verdict: tiers B and C

private func runOrphanVerdictChecks() {
    let repo = "/Users/x/workspace/bigdata"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let tree = OrphanReclaim.Tree(root: 900, rootStartedAt: 1, members: [900, 901], project: repo)
    func reading(at moment: Date = t0, age: TimeInterval = 40 * 60, cpu: Double? = 60,
                 memory: UInt64 = 100_000_000, ports: [UInt16] = [3000],
                 vetoes: Set<OrphanReclaim.Veto> = [],
                 root: Int64 = 1) -> OrphanReclaim.Reading {
        OrphanReclaim.Reading(
            tree: OrphanReclaim.Tree(root: 900, rootStartedAt: root, members: [900, 901],
                                     project: repo),
            takenAt: moment, age: age, cpuPercent: cpu, memoryBytes: memory,
            listeningPorts: ports, name: "node", vetoes: vetoes)
    }
    let round2 = t0.addingTimeInterval(OrphanReclaim.roundInterval)

    // ONE ROUND IS NEVER ENOUGH, whatever it says.
    check("a first sighting of a busy old server waits rather than acting",
          OrphanReclaim.verdict(for: reading(), previous: nil).verdict == .wait)
    let first = OrphanReclaim.verdict(for: reading(), previous: nil).keep
    // 🔴 AND WHAT THE SECOND ROUND DOES IS WRITE ABOUT IT (2026-09-02, the hold on v0.65.0). It
    // ended the tree until the root-cause review found that the three repairs before it had one
    // shape in common - a kill authorised by the ABSENCE of a veto, over readings whose failure is
    // spelled the same way as their safe answer - and that the design goes on producing that class
    // of defect. Every bar above still has to be cleared; the last step is a message
    // (`OrphanReclaim.verdict` carries what reopens it).
    check("…and the second round five minutes later reports it rather than ending it",
          OrphanReclaim.verdict(for: reading(at: round2), previous: first).verdict == .notify)
    // TWO READINGS OF ONE MOMENT SAY ONLY THAT IT WAS BUSY JUST NOW, which is what a link step is.
    let soon = OrphanReclaim.verdict(for: reading(at: t0.addingTimeInterval(120)), previous: first)
    check("two rounds two minutes apart are one moment read twice", soon.verdict == .wait)
    check("…and the pair stays open, so the confirmation is not pushed another interval out",
          soon.keep == first)
    check("…which the round at five minutes from the FIRST sighting then confirms",
          OrphanReclaim.verdict(for: reading(at: round2), previous: soon.keep).verdict == .notify)
    // A MACHINE THAT SLEPT WATCHED NOTHING.
    check("a pair straddling a sleep is thrown away rather than believed",
          OrphanReclaim.verdict(for: reading(at: t0.addingTimeInterval(3600)),
                                previous: first).verdict == .wait)
    // THE RECYCLED PID, ARRIVING BETWEEN TWO ROUNDS: same number, different process, and by number
    // alone the second round confirms the first.
    check("a root pid handed out again starts from nothing rather than inheriting the case",
          OrphanReclaim.verdict(for: reading(at: round2, root: 2), previous: first).verdict
              == .wait)
    check("…which the continuity rule states directly",
          OrphanReclaim.continuity(
              from: OrphanReclaim.Sighting(rootStartedAt: 1, at: t0, cpuPercent: 60),
              to: OrphanReclaim.Sighting(rootStartedAt: 2, at: round2, cpuPercent: 60))
              == .restart)

    // MARK: the bars

    check("a tree younger than twenty minutes is not looked at, however busy",
          OrphanReclaim.verdict(for: reading(at: round2, age: 60, cpu: 400),
                                previous: first).verdict == .wait)
    check("a rate that has not been established yet clears nothing",
          !OrphanReclaim.heavy(reading(cpu: nil)))
    check("a quiet server holding two gigabytes clears the bar on memory alone",
          OrphanReclaim.heavy(reading(cpu: 0, memory: 2 * 1024 * 1024 * 1024)))
    check("…and one holding a little at zero per cent does not",
          !OrphanReclaim.heavy(reading(cpu: 0, memory: 100_000_000)))
    // THE PORTLESS RUNAWAY, WHICH IS THE 2026-09-01 INCIDENT ITSELF: no listener, so there is
    // nothing about it that says what it is, and the bar it has to clear is higher.
    check("a portless tree at sixty per cent is not heavy, where a server on a port would be",
          !OrphanReclaim.heavy(reading(cpu: 60, ports: [])) && OrphanReclaim.heavy(reading(cpu: 60)))
    check("…and one at eighty-five is",
          OrphanReclaim.heavy(reading(cpu: 85, ports: [])))
    let spike = OrphanReclaim.verdict(for: reading(cpu: 10, ports: []), previous: nil).keep
    check("…but a portless tree that was quiet on the first round is not ended on the second",
          OrphanReclaim.verdict(for: reading(at: round2, cpu: 85, ports: []),
                                previous: spike).verdict == .wait)
    let sustainedSpike = OrphanReclaim.verdict(for: reading(cpu: 85, ports: []), previous: nil).keep
    check("…and one burning through both rounds clears the bar, which is the 2026-09-01 incident",
          OrphanReclaim.verdict(for: reading(at: round2, cpu: 85, ports: []),
                                previous: sustainedSpike).verdict == .notify)
    // AND NOTHING ANYWHERE REACHES THE OTHER ANSWER, which is the whole of the hold stated as a
    // property rather than as three cells: the inference tier is the only producer of
    // `Reason.sustained`, and while it is report-only no reading of any shape can reach it. Taken
    // over the matrix above rather than at one point in it, so a `return` left behind anywhere in
    // the rule is caught here (`Reason.leaseOwnerGone` is untouched: a lease is a statement).
    let everyShape = [reading(), reading(at: round2), reading(at: round2, cpu: 400),
                      reading(at: round2, memory: 4 * 1024 * 1024 * 1024),
                      reading(at: round2, cpu: 85, ports: []),
                      reading(at: round2, age: 10 * 3600, cpu: 300, ports: [])]
    check("no reading of any shape ends a tree on evidence while the tier is report-only",
          everyShape.allSatisfy { shape in
              [nil, first, sustainedSpike, spike].allSatisfy {
                  OrphanReclaim.verdict(for: shape, previous: $0).verdict != .reclaim(.sustained)
              }
          })

    // MARK: what speaks against it

    for veto in [OrphanReclaim.Veto.terminal, .ancestor, .inUse] {
        check("a tree vetoed by \(veto.rawValue) is left alone and NOT reported",
              OrphanReclaim.verdict(for: reading(at: round2, vetoes: [veto]),
                                    previous: first).verdict == .leave)
    }
    for veto in [OrphanReclaim.Veto.unreadable, .crossRepo, .unknownProgram, .sessionPresent,
                 .sessionUnknown] {
        check("a tree in doubt over \(veto.rawValue) is reported and not ended",
              OrphanReclaim.verdict(for: reading(at: round2, vetoes: [veto]),
                                    previous: first).verdict == .notify)
    }
    // 🔴 EVERY VETO IS ONE OR THE OTHER, and the reason this is asserted over `allCases` rather
    // than case by case is that a new one added without a `hard` answer is the failure that ends a
    // process: the switch is exhaustive, so the compiler catches a missing case, and what it cannot
    // catch is a case added to the wrong side of it.
    check("a soft veto is a doubt and a hard one is silence, over every veto there is",
          OrphanReclaim.Veto.allCases.filter(\.hard).sorted()
              == [.ancestor, .inUse, .leased, .terminal])
    // 🔴 AND A LEASED TREE IS SILENCE RATHER THAN A REPORT, which is the whole of the 2026-09-02
    // dev-watch defect: the harness registered that server itself, so "run it under `/dev-watch`,
    // whose lease says whose it is" is advice it has already taken.
    check("a tree its own dev-watch lease still answers for is left without a word",
          OrphanReclaim.verdict(for: reading(at: round2, vetoes: [.leased]),
                                previous: first).verdict == .leave)

    // MARK: 🔴 which checkout a directory is in (2026-09-02, the session-present veto)

    // A WORKTREE IS ITS REPOSITORY, which is what makes a session in the trunk speak for a leftover
    // in a parallel line of it. Same rule the messages are addressed by, asked here for a different
    // purpose: whether two directories are the same body of work.
    let line = "/Users/x/workspace/bigdata/.worktrees/wt1"
    func entry(_ path: String) -> OrphanNotice.GitEntry? {
        switch path {
        case repo + "/.git": return .directory
        case line + "/.git": return .file("gitdir: " + repo + "/.git/worktrees/wt1")
        default: return nil
        }
    }
    check("a directory inside a checkout is that checkout",
          OrphanReclaim.checkout(of: repo + "/web", entry: entry) == repo)
    check("…and a parallel line of it is the repository, not a checkout of its own",
          OrphanReclaim.checkout(of: line, entry: entry) == repo)
    check("…while a directory with no repository above it is only itself",
          OrphanReclaim.checkout(of: "/tmp/somewhere", entry: entry) == "/tmp/somewhere")

    // 🔴 AND THE SAME QUESTION PUT TO A REAL DIRECTORY, because what makes the two sides of this
    // comparison disagree is produced by the disk rather than by any fixture (codex review of
    // d155fdc). The fold goes through `standardizedFileURL` (`OrphanNotice.absolute`), which takes
    // a leading `/private` off and hands back DECOMPOSED Unicode; a session's directory reaches the
    // store through `realpath`, which keeps `/private` and answers with the name the volume holds.
    // So one checkout arrives under two spellings, compares unequal, and the veto is missed in the
    // one direction that ends a process. The store closes it by putting both sides through
    // `OrphanReclaimStore.checkout(of:)`, and what is asserted here is that exact composition:
    // resolve after fold. The store's own suite states it with a map of fake resolutions
    // (orphanstorechecks.swift), which can only be as good as the spellings somebody thought to put
    // in the map.
    var template = Array("/private/tmp/tally-orphan-fold-XXXXXX".utf8CString)
    if let base = mkdtemp(&template).map({ String(cString: $0) }) {
        let disk = FileManager.default
        // A COMPOSED "é" (U+00E9) IN THE REPOSITORY'S NAME, written composed on purpose: it is half
        // of what the fold changes, and a name of plain ASCII would leave only the `/private` half.
        let foldRepo = base + "/r\u{00E9}po"
        let foldLine = base + "/wt"
        do {
            try disk.createDirectory(atPath: foldRepo + "/.git", withIntermediateDirectories: true)
            try disk.createDirectory(atPath: foldLine, withIntermediateDirectories: true)
            // RELATIVE ON PURPOSE: this is the line `git worktree add --relative-paths` writes, and
            // the whole reason there is anything to fold.
            try "gitdir: ../r\u{00E9}po/.git/worktrees/wt\n"
                .write(toFile: foldLine + "/.git", atomically: true, encoding: .utf8)
            let folded = OrphanReclaim.checkout(of: foldLine, entry: OrphanNotice.gitEntry)
            check("a parallel line's repository, resolved, is the checkout the session is in",
                  MachineLoadRollup.resolvedPath(folded)
                      == MachineLoadRollup.resolvedPath(foldRepo))
            // AND WHY THE RESOLVING IS NOT DECORATION. Without it the comparison is made against a
            // spelling no process on this machine ever reports, and the answer is "nobody is
            // working here" about a checkout somebody is working in.
            check("…while the fold on its own answers a spelling the machine never reports",
                  folded != foldRepo)
        } catch {
            // 🔴 A FIXTURE THAT WOULD NOT BE WRITTEN IS A FAILURE, not a cell to wave through
            // (codex review of 15c5552). This pair used to assert `true` and print PASS, so a run
            // in which the one assertion that touches a real disk never happened was
            // indistinguishable from a run in which it passed - on the two cells that exist
            // BECAUSE no fixture can produce what the disk produces.
            check("a real checkout fold could not be set up: \(error)", false)
        }
        try? disk.removeItem(atPath: base)
    } else {
        check("a real checkout fold could not be set up: /private/tmp would take no directory",
              false)
    }

    // MARK: the vetoes themselves, taken off real readings

    func member(_ pid: pid_t, parent: pid_t = 1, program: String? = "/opt/homebrew/bin/node",
                directory: String? = "/Users/x/workspace/bigdata/web",
                terminal: Bool = false) -> OrphanReclaim.Member {
        OrphanReclaim.Member(identity: ProcessIdentity(pid: pid, parent: parent, group: 900,
                                                       startedAt: 1, hasTerminal: terminal),
                             program: program, directory: directory)
    }
    let clean = [member(900), member(901)]
    check("a dev server nobody is at draws no veto at all",
          OrphanReclaim.vetoes(of: tree, members: clean, sockets: OrphanReclaim.Sockets(), ancestors: []).isEmpty)
    // A PERSON IS AT IT. The field is on the process table record, so it costs nothing to ask.
    check("a member with a terminal attached vetoes the whole tree",
          OrphanReclaim.vetoes(of: tree, members: [member(900), member(901, terminal: true)],
                               sockets: OrphanReclaim.Sockets(), ancestors: []).contains(.terminal))
    check("a tree under a multiplexer is somebody's workspace",
          OrphanReclaim.vetoes(of: tree, members: clean, sockets: OrphanReclaim.Sockets(),
                               ancestors: ["zsh", "tmux-server"]).contains(.ancestor))
    check("a member whose program the machine will not name makes the tree unsafe to end",
          OrphanReclaim.vetoes(of: tree, members: [member(900), member(901, program: nil)],
                               sockets: OrphanReclaim.Sockets(), ancestors: []).contains(.unreadable))
    check("…and so does a member the reader could not describe at all",
          OrphanReclaim.vetoes(of: tree, members: [member(900)], sockets: OrphanReclaim.Sockets(),
                               ancestors: []).contains(.unreadable))
    check("a member working in another checkout is a doubt about the whole tree",
          OrphanReclaim.vetoes(of: tree,
                               members: [member(900), member(901, directory: "/Users/x/workspace/geo")],
                               sockets: OrphanReclaim.Sockets(), ancestors: []).contains(.crossRepo))
    check("a program this app does not recognise as development work is never ended",
          OrphanReclaim.vetoes(of: tree,
                               members: [member(900, program: "/Applications/Mail.app/Contents/MacOS/Mail"),
                                         member(901, program: "/bin/zsh")],
                               sockets: OrphanReclaim.Sockets(), ancestors: []).contains(.unknownProgram))
    // A dev server started through a shell has `sh` at its root and the work one level down.
    check("…while a shell at the root of a node tree is recognised through its members",
          !OrphanReclaim.vetoes(of: tree, members: [member(900, program: "/bin/sh"), member(901)],
                                sockets: OrphanReclaim.Sockets(), ancestors: []).contains(.unknownProgram))

    // MARK: who is connected to it

    func socket(_ pid: pid_t, local: UInt16, remote: UInt16 = 0, loopback: Bool = true,
                listening: Bool = false) -> OrphanReclaim.Connection {
        OrphanReclaim.Connection(pid: pid, localPort: local, remotePort: remote,
                                 remoteIsLoopback: loopback, listening: listening)
    }
    check("a server waiting with nobody on it is not in use",
          !OrphanReclaim.inUse([socket(900, local: 3000, listening: true)], within: tree.members))
    // A BROWSER HOLDING AN HMR SOCKET is loopback and inbound, and is the clearest possible
    // statement that somebody still wants this server.
    check("a browser connected over loopback means somebody is using it",
          OrphanReclaim.inUse([socket(900, local: 3000, listening: true),
                               socket(900, local: 3000, remote: 54_321)], within: tree.members))
    // A TUNNEL IN FRONT OF IT is the same shape from the socket's point of view.
    check("…and so does a tunnel in front of it",
          OrphanReclaim.inUse([socket(900, local: 3000, remote: 61_000)], within: tree.members))
    check("a connection to somewhere off this machine counts too",
          OrphanReclaim.inUse([socket(900, local: 55_000, remote: 443, loopback: false)],
                              within: tree.members))
    // AND THE TRAFFIC A DEV SERVER HAS WITH ITSELF IS MOST OF ITS SOCKET TABLE: counting it would
    // veto every candidate this feature has.
    check("a tree's own workers talking to each other are not somebody using it",
          !OrphanReclaim.inUse([socket(900, local: 3000, listening: true),
                                socket(901, local: 41_000, listening: true),
                                socket(900, local: 3000, remote: 41_000),
                                socket(901, local: 41_000, remote: 3000)], within: tree.members))
    check("…and a connection held by a process outside the tree says nothing about the tree",
          !OrphanReclaim.inUse([socket(777, local: 3000, remote: 54_321)], within: tree.members))
    // AND THE READER ITSELF, ASKED OF THE REAL MACHINE, because the rule above can only be as good
    // as what is handed to it and the two answers it has to tell apart are produced by libproc
    // rather than by any fixture. `proc_pidinfo` reports failure as ZERO rather than as -1
    // (measured 2026-09-02), so a reader written the obvious way returns "no sockets" for a pid it
    // could not read - which is the reading that lets a tree be ended.
    check("a pid the machine will not describe comes back named, not as an absence of sockets",
          ProcessTree.connections(of: [pid_t(999_999)]).unreadable == [999_999])
    check("…while this very process, which certainly has descriptors, does not",
          ProcessTree.connections(of: [getpid()]).unreadable.isEmpty)
    check("the ports a tree is waiting on are stated once each, ascending",
          OrphanReclaim.listening([socket(900, local: 3000, listening: true),
                                   socket(901, local: 3000, listening: true),
                                   socket(900, local: 24_678, listening: true),
                                   socket(900, local: 3000, remote: 9)]) == [3000, 24_678])

    // MARK: the rate

    func sample(_ times: [pid_t: Double], born: [pid_t: Int64], at moment: Date)
        -> ProcessResourceSample {
        ProcessResourceSample(times: times, childTimes: [:], at: moment, startedAt: born)
    }
    let before = sample([900: 100, 901: 50], born: [900: 1, 901: 2], at: t0)
    check("no rate at all until something has been read twice",
          OrphanReclaim.rate(from: nil, to: before) == nil)
    check("a tree that burned one whole core between two rounds reads a hundred per cent",
          OrphanReclaim.rate(from: before,
                             to: sample([900: 400, 901: 50], born: [900: 1, 901: 2],
                                        at: t0.addingTimeInterval(300))) == 100)
    // A WORKER THAT JOINED brings a counter cumulative since ITS birth, and differencing it against
    // nothing states its whole life as this interval's work - which here would be a kill.
    check("a worker that joined between the rounds does not state its whole life as this interval",
          OrphanReclaim.rate(from: before,
                             to: sample([900: 400, 901: 50, 902: 9_000], born: [900: 1, 901: 2, 902: 3],
                                        at: t0.addingTimeInterval(300))) == 100)
    // AND THE SAME NUMBER TWICE IS NOT THE SAME PROCESS TWICE.
    check("a member whose number was handed on contributes nothing to the rate",
          OrphanReclaim.rate(from: before,
                             to: sample([900: 400, 901: 9_000], born: [900: 1, 901: 77],
                                        at: t0.addingTimeInterval(300))) == 100)
    check("…and a pair with no stamps at either end is skipped rather than believed",
          OrphanReclaim.rate(from: sample([900: 100], born: [:], at: t0),
                             to: sample([900: 400], born: [:], at: t0.addingTimeInterval(300)))
              == 0)

    // MARK: not saying the same thing twice a day

    check("what a message is about does not carry the pid, which changes on every restart",
          !OrphanReclaim.fingerprint(reading()).contains("900")
              && OrphanReclaim.fingerprint(reading()) == OrphanReclaim.fingerprint(reading(cpu: 3)))
    check("…and a different port is a different situation",
          OrphanReclaim.fingerprint(reading()) != OrphanReclaim.fingerprint(reading(ports: [3001])))
    let said = [OrphanReclaim.fingerprint(reading()): t0]
    check("something said an hour ago is not said again",
          OrphanReclaim.silenced(OrphanReclaim.fingerprint(reading()), said: said,
                                 at: t0.addingTimeInterval(3600)))
    check("…and is said again the next day",
          !OrphanReclaim.silenced(OrphanReclaim.fingerprint(reading()), said: said,
                                  at: t0.addingTimeInterval(25 * 3600)))
    check("a clock that went backwards leaves the channel quiet rather than repeating",
          OrphanReclaim.silenced(OrphanReclaim.fingerprint(reading()), said: said,
                                 at: t0.addingTimeInterval(-3600)))

    // MARK: 🔴 nor twice about one tree (2026-09-02, three messages in thirty minutes)

    // THE SITUATION KEY ABOVE CANNOT HOLD A STANDING TREE QUIET, and the machine showed how: a
    // `next dev` under a dev-watch supervisor holds :3000 AND an ephemeral port that its own
    // restarts hand back and take out again, so `project|program|ports` was a different string
    // every time it was read (`:3000, :55955`, then `:54887`, then `:58902` - the three messages
    // the incident is named for). What has not changed between those three is the TREE and the
    // answer reached about it, which is what this key is.
    let told = OrphanReclaim.Told(rootStartedAt: 1_000, doubts: [.sessionPresent])
    check("a tree nothing has been said about yet is worth saying",
          OrphanReclaim.worthSaying(nil, rootStartedAt: 1_000, doubts: [.sessionPresent]))
    check("…and the same tree with the same answer is not worth saying again",
          !OrphanReclaim.worthSaying(told, rootStartedAt: 1_000, doubts: [.sessionPresent]))
    // A CHANGED ANSWER IS NEWS IN BOTH DIRECTIONS. The session that was working here has gone home,
    // or has arrived: either way the reader is being told something they were not told before.
    check("…while a different set of doubts about it is",
          OrphanReclaim.worthSaying(told, rootStartedAt: 1_000, doubts: [.unknownProgram])
              && OrphanReclaim.worthSaying(told, rootStartedAt: 1_000,
                                           doubts: [.sessionPresent, .unknownProgram]))
    // AND THE PID IS NOT THE TREE. The number is handed out again; what says it is the same tree is
    // the number AND the instant it began, which is the identity rule the sighting already uses.
    check("…and a number handed on to something else is a new tree, not a repeat",
          OrphanReclaim.worthSaying(told, rootStartedAt: 2_000, doubts: [.sessionPresent]))
}

// MARK: - how it is ended

private func runOrphanKillChecks() {
    // 900, 901 and 902 are one server's tree; 800 is a leftover elsewhere; 999 is a number the
    // table no longer holds; 1 is launchd, which is live and must never be signalled.
    let live: Set<pid_t> = [900, 901, 902, 800, 1]
    // 🔴 ONE CALL PER PROCESS, FOR BOTH SIGNALS AND WHATEVER THE JOB LOOKS LIKE (root-cause review,
    // 2026-09-02). The first signal used to reach a whole process group wherever every live member
    // of that group was being reclaimed, on the argument that a `SIGTERM` is a request rather than
    // an execution. The argument held and its EVIDENCE did not: "every live member" is a
    // completeness claim about the machine read out of a table walk that is one `proc_pidinfo` per
    // pid, any of which can fail for a pass, and a single failure on an unrelated process sharing
    // the group makes a dirty group read as clean. There is no entry point left that can ask for
    // one, which is the same shape the escalation's own rule had before it folded into this.
    let clean = OrphanKill.plan(members: [900, 901, 902], live: live, ours: [])
    check("a job every member of which is being reclaimed is still signalled one at a time",
          clean.pids == [900, 901, 902])
    check("…and a job holding somebody else the same way",
          OrphanKill.plan(members: [800], live: live, ours: []).pids == [800])
    // `kill(-1)` REACHES EVERY PROCESS THIS USER OWNS, `kill(-0)` the caller's own job, and pid 1
    // is launchd. None can be a member of a stray tree, and the guard costs a comparison.
    check("nothing at or below pid 1 is ever in a plan, whatever is in the reclaim set",
          OrphanKill.plan(members: [1, 900], live: live, ours: []).pids == [900])
    // The meter is never the thing metered, here as everywhere else on this page.
    let withOurs = OrphanKill.plan(members: [900, 901, 902], live: live, ours: [902])
    check("a process of Tally's own inside the set is spared and says so",
          withOurs.spared == [902] && withOurs.pids == [900, 901])
    check("a member the table no longer holds needs no signal",
          OrphanKill.plan(members: [999], live: live, ours: []).pids.isEmpty)
    check("nothing left to signal is an empty plan",
          OrphanKill.plan(members: [999], live: live, ours: []).isEmpty)
    // AND THE ORDER IS STATED RATHER THAN A SET'S OWN, so a record of what was sent reads the same
    // way twice.
    check("the plan is ascending, so two runs of one reclaim deliver in the same order",
          OrphanKill.plan(members: [902, 900, 901], live: live, ours: []).pids == [900, 901, 902])
    // 🔴 AND THE DELIVERY ITSELF NEVER ADDRESSES A GROUP, which is the half a plan cannot state:
    // the planner refuses to put such a number in, and the sending refuses to send one, so neither
    // is the single point the guarantee rests on (`OrphanKill.Signals.real`).
    var addressed: [pid_t] = []
    OrphanKill.deliver(SIGTERM, following: clean,
                       through: OrphanKill.Signals(
                           send: { addressed.append($1) }, alive: { _ in [:] },
                           listening: { [] }, presence: { _ in .running }, table: { [] }))
    check("every delivery is one call to one positive pid",
          addressed == [900, 901, 902] && !addressed.contains { $0 <= 1 })

    // THE LAST THING BEFORE THE SIGNAL: five minutes passed between the verdict and here.
    check("a pid whose start time has changed since the reading is not signalled",
          OrphanKill.confirmed([900, 901], expected: [900: 1, 901: 2], now: [900: 1, 901: 99])
              == [900])
    check("…and one the machine will not state is not signalled either",
          OrphanKill.confirmed([900], expected: [900: 1], now: [:]).isEmpty)

    // MARK: the sweep

    check("nothing left is a settled sweep",
          OrphanKill.step(survivors: 0, elapsed: 0, escalated: false) == .settled)
    check("a tree shutting down is given its ten seconds",
          OrphanKill.step(survivors: 2, elapsed: 4, escalated: false) == .wait)
    // A CHILD THAT IGNORES SIGTERM, which is its own row of the matrix.
    check("…and is signalled outright once they are up",
          OrphanKill.step(survivors: 1, elapsed: 10, escalated: false) == .escalate)
    check("a survivor of SIGKILL is waited on briefly",
          OrphanKill.step(survivors: 1, elapsed: 11, escalated: true) == .wait)
    check("…and then reported as a failure rather than waited on forever",
          OrphanKill.step(survivors: 1, elapsed: 13, escalated: true) == .failed)

    // A TREE CAN DIE AND LEAVE ITS PORT TAKEN, which is the state this feature exists to remove.
    check("a reclaim whose port is still held by something is not a reclaim that worked",
          !OrphanKill.released([3000], held: [3000, 5432]))
    check("…and one whose ports are answering to nobody is",
          OrphanKill.released([3000], held: [5432]) && OrphanKill.released([], held: [3000]))
}

// MARK: - saying so

private func runOrphanNoticeChecks() {
    let workspace = "/Users/x/workspace"
    // AN ORDINARY CHECKOUT: `.git` is a directory and its parent is the repository.
    let plain: (String) -> OrphanNotice.GitEntry? = { path in
        path == "/Users/x/workspace/bigdata/.git" ? .directory : nil
    }
    check("the repository above a working directory is the nearest checkout",
          OrphanNotice.repository(of: "/Users/x/workspace/bigdata/web/app", entry: plain)
              == OrphanNotice.Repository(root: "/Users/x/workspace/bigdata", worktree: nil))
    check("…and a directory in no repository at all is nobody's",
          OrphanNotice.repository(of: "/Applications", entry: { _ in nil }) == nil)
    // A PARALLEL LINE: its `.git` is a file pointing back at the repository it was cut from, and
    // its own inbox is read only while somebody is working in it - which is not now.
    let worktree: (String) -> OrphanNotice.GitEntry? = { path in
        path == "/Users/x/workspace/bigdata/.worktrees/feat/.git"
            ? .file("gitdir: /Users/x/workspace/bigdata/.git/worktrees/feat\n") : nil
    }
    check("a worktree's message is addressed to the repository it was cut from",
          OrphanNotice.repository(of: "/Users/x/workspace/bigdata/.worktrees/feat/web",
                                  entry: worktree)
              == OrphanNotice.Repository(root: "/Users/x/workspace/bigdata",
                                         worktree: "/Users/x/workspace/bigdata/.worktrees/feat"))
    // A submodule or a `--separate-git-dir` repo points somewhere that is not a worktrees path.
    check("a git file this rule cannot read falls back to the checkout holding it",
          OrphanNotice.repository(of: "/Users/x/workspace/bigdata/vendor/lib",
                                  entry: { $0 == "/Users/x/workspace/bigdata/vendor/lib/.git"
                                      ? .file("gitdir: /Users/x/workspace/bigdata/.git/modules/lib")
                                      : nil })
              == OrphanNotice.Repository(root: "/Users/x/workspace/bigdata/vendor/lib",
                                         worktree: nil))

    // A PARALLEL LINE THAT POINTS BACK RELATIVELY, which is what git writes under
    // `worktree.useRelativePaths` and `git worktree add --relative-paths` (git 2.48 and after) so a
    // repository and its lines can be moved or copied as one directory. Taken as written, the root
    // is a path relative to the worktree, and everything this app does with a root compares it
    // against an absolute one: the session veto asks whether a stray's checkout is a checkout
    // somebody is working in, and `../bigdata` is equal to nothing (`OrphanReclaim.checkout`).
    let sibling: (String) -> OrphanNotice.GitEntry? = { path in
        path == "/Users/x/workspace/bigdata-wt1/.git"
            ? .file("gitdir: ../bigdata/.git/worktrees/wt1\n") : nil
    }
    check("a worktree pointing back relatively is folded into the repository it names",
          OrphanNotice.repository(of: "/Users/x/workspace/bigdata-wt1/web", entry: sibling)
              == OrphanNotice.Repository(root: "/Users/x/workspace/bigdata",
                                         worktree: "/Users/x/workspace/bigdata-wt1"))
    // The nested layout is the same rule two directories deeper, and it is the one this machine's
    // own worktrees are cut in.
    let nested: (String) -> OrphanNotice.GitEntry? = { path in
        path == "/Users/x/workspace/bigdata/.worktrees/feat/.git"
            ? .file("gitdir: ../../.git/worktrees/feat\n") : nil
    }
    check("…and one that climbs two levels back arrives at the same place",
          OrphanNotice.repository(of: "/Users/x/workspace/bigdata/.worktrees/feat",
                                  entry: nested)?.root == "/Users/x/workspace/bigdata")
    check("…and a `.` segment on the way out is removed rather than compared",
          OrphanNotice.repository(of: "/Users/x/workspace/bigdata-wt1",
                                  entry: { $0 == "/Users/x/workspace/bigdata-wt1/.git"
                                      ? .file("gitdir: ../bigdata/./.git/worktrees/wt1") : nil })?
              .root == "/Users/x/workspace/bigdata")
    // 🔴 AND THE READING THE VETO ACTUALLY TAKES, which is the whole point of the fold: a trunk
    // session's root is an absolute path, so a relative answer here would say "a different
    // checkout" about the one directory that session is sitting in.
    check("…and the checkout a relative worktree is in equals the trunk session's own root",
          OrphanReclaim.checkout(of: "/Users/x/workspace/bigdata/.worktrees/feat/web",
                                 entry: nested) == "/Users/x/workspace/bigdata")

    // THE FOLD ITSELF, which is lexical on purpose: no filesystem is touched on a path that runs
    // while a machine is already in trouble, and what is being asked is which checkout two strings
    // name rather than what the disk holds this second.
    check("an absolute path is already the answer",
          OrphanNotice.absolute("/Users/x/workspace/bigdata", from: "/anywhere")
              == "/Users/x/workspace/bigdata")
    check("…a relative one is resolved against the directory that stated it",
          OrphanNotice.absolute("../bigdata", from: "/Users/x/workspace/bigdata-wt1")
              == "/Users/x/workspace/bigdata")
    check("…climbing past the top stops at the root rather than running off it",
          OrphanNotice.absolute("../../../..", from: "/Users/x") == "/")
    check("…and a directory that is itself relative has nothing to resolve against",
          OrphanNotice.absolute("../bigdata", from: "workspace/wt") == "../bigdata")

    // A KEY NOTHING READS IS A DEAD LETTER, so this is the rule the other writers of these inboxes
    // already use: the path under the workspace, flattened.
    check("a nested checkout's inbox key is its path under the workspace with the slashes flattened",
          OrphanNotice.key(for: "/Users/x/workspace/taiwanbigdata/bigdata", workspace: workspace)
              == "taiwanbigdata-bigdata")
    check("…and a checkout at the top of it is its own name",
          OrphanNotice.key(for: "/Users/x/workspace/tally", workspace: workspace) == "tally")
    check("…and one outside the workspace falls back to its last component",
          OrphanNotice.key(for: "/opt/src/thing", workspace: workspace) == "thing")
    check("a sibling whose name merely starts the same way is not inside the workspace",
          OrphanNotice.key(for: "/Users/x/workspace-old/tally", workspace: workspace) == "tally")
    // AND THE INBOX FOLLOWS THE SAME ROOT, which is the second thing a relative one breaks: a key
    // taken off `../bigdata` addresses a directory called `..`, and the message lands where nobody
    // is reading.
    let feat = "/Users/x/workspace/bigdata/.worktrees/feat"
    check("a relatively linked worktree's message is addressed to its repository's own box",
          OrphanNotice.key(for: OrphanNotice.repository(of: feat, entry: nested)?.root ?? "",
                           workspace: workspace) == "bigdata")
    check("the inbox is the one the harness's own notify skill writes into",
          OrphanNotice.inbox("tally", home: URL(fileURLWithPath: "/Users/x")).path
              == "/Users/x/.claude/inboxes/tally")

    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let name = OrphanNotice.filename(at: at, pid: 4242, random: 77)
    check("a message's name carries the second, the writer and a random number, so two cannot collide",
          name.hasSuffix("-4242-77-from-tally-app-orphan-reclaim.md")
              && name.first?.isNumber == true)

    let report = OrphanNotice.Report(
        project: "/Users/x/workspace/bigdata/web", program: "node", pid: 900, processes: 4,
        cpuPercent: 187, memoryBytes: 3_400_000_000, listeningPorts: [3000, 24_678],
        ageSeconds: 7200, signalled: [900, 901, 902, 904], outcome: .reclaimedByLease)
    let text = OrphanNotice.message(report, to: "bigdata", worktree: nil, at: at)
    // THE STOP GATE ON THE RECEIVING SIDE CHASES ANYTHING THAT ASKS FOR A REPLY, and the writer
    // here is a menu bar app that cannot receive one.
    check("every message asks for no reply, since nothing here could read one",
          text.contains("**reply**: none"))
    check("…and carries the fields the inbox contract names",
          text.contains("**from**: tally-app") && text.contains("**to**: bigdata")
              && text.contains("**type**: notify") && text.contains("**thread**: orphan-reclaim")
              && text.contains("**hop**: 0"))
    check("a message says what was running and what was done about it",
          text.contains("node") && text.contains(":3000, :24678") && text.contains("187%")
              && text.contains("2h 0m") && text.contains("Ended it."))
    // 🔴 AND WHICH PROCESSES, not merely how many (root-cause review, 2026-09-02). A machine that
    // comes back wrong is read by comparing what this app says it ended against what the person
    // finds missing, and a count compares with nothing.
    check("…and writes down every pid the signal actually went to",
          text.contains("- Signalled: 900, 901, 902, 904"))
    var unsent = report
    unsent.signalled = []
    unsent.outcome = .reported(doubts: [.unknownProgram])
    check("…while a report, which sends nothing, has no such line to write",
          !OrphanNotice.message(unsent, to: "bigdata", worktree: nil, at: at)
              .contains("Signalled:"))
    check("…and a parallel line's message says which line, since the repository's box is not it",
          OrphanNotice.message(report, to: "bigdata",
                               worktree: "/Users/x/workspace/bigdata/.worktrees/feat", at: at)
              .contains("/Users/x/workspace/bigdata/.worktrees/feat"))
    var doubted = report
    doubted.outcome = .reported(doubts: [.inUse, .unknownProgram])
    check("a tier-C message says what was NOT done and why, in words rather than in enum names",
          OrphanNotice.message(doubted, to: "bigdata", worktree: nil, at: at)
              .contains("something is connected to it; its program is not one this app recognises"))
    // 🔴 AND THE ONE THE INCIDENT WAS MISSING: what a reader is to do when the doubt is that they
    // themselves are working here. "Have a look and end it yourself" is the wrong sentence for a
    // tree that may be their own session's.
    var mine = report
    mine.outcome = .reported(doubts: [.sessionPresent])
    let told = OrphanNotice.message(mine, to: "bigdata", worktree: nil, at: at)
    check("a tree in an occupied checkout is reported as possibly the reader's own work",
          told.contains("a session is working in this checkout, so this may be its work"))
    check("…and is told how to keep it rather than only how to end it",
          told.contains("If it is yours, there is nothing to do.")
              && told.contains("`/dev-watch`") && !told.contains("Have a look and end it yourself"))
    // 🔴 AND THE ONE A CANDIDATE WITH NOTHING AGAINST IT GETS, which is the shape the hold on the
    // inference tier created: it cleared every bar and every veto, so a sentence ending in a list
    // of doubts would have nothing to put in the list. Saying "it could not be sure" about it
    // would be untrue, and saying nothing would hide the one reading the observation period exists
    // to collect (`OrphanReclaim.verdict`).
    var clear = report
    clear.signalled = []
    clear.outcome = .reported(doubts: [])
    let held = OrphanNotice.message(clear, to: "bigdata", worktree: nil, at: at)
    check("a candidate with no doubt at all is reported as one this app would end and did not",
          held.contains("no session is working in its checkout")
              && held.contains("switched off while this feature is being observed"))
    check("…and names no doubt, there being none to name",
          !held.contains("it could not be:") && !held.contains("Ended it."))
    // AND THE OTHER READING THE ROUND CAN FAIL CLOSED ON: a board that would not place one of its
    // own live sessions (`OrphanReclaim.Veto.sessionUnknown`), which has to read as a doubt about
    // that rather than as a fact about the checkout.
    var unplaced = report
    unplaced.signalled = []
    unplaced.outcome = .reported(doubts: [.sessionUnknown])
    let vague = OrphanNotice.message(unplaced, to: "bigdata", worktree: nil, at: at)
    check("a round whose board could not place a session says so, and offers the careful advice",
          vague.contains("a live session would not say which checkout it is working in")
              && vague.contains("If it is yours, there is nothing to do."))
    // AND THE SENTENCE THE INCIDENT'S OWN MESSAGES CARRIED, which is now a claim something checks
    // (`OrphanReclaim.Veto.sessionPresent`). It was in this file before the veto existed. The
    // outcome it belongs to has no producer while the inference tier is held, and the wording is
    // kept for the same reason the reason itself is (`OrphanReclaim.Reason.sustained`).
    var sustained = report
    sustained.outcome = .reclaimedBySustained
    check("a reclaim still says no session was working here, which is now a tested claim",
          OrphanNotice.message(sustained, to: "bigdata", worktree: nil, at: at)
              .contains("No live session was working in this checkout"))
    var failed = report
    failed.outcome = .failed(reason: "it would not go")
    check("…and a failure says the thing is still running",
          OrphanNotice.message(failed, to: "bigdata", worktree: nil, at: at)
              .contains("It is still running."))

    // MARK: delivering it

    let inbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("orphan-inbox-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: inbox) }
    let landed = OrphanNotice.deliver(text, to: inbox, named: name)
    check("a message is delivered into the inbox under its own name",
          landed?.lastPathComponent == name
              && (try? String(contentsOf: landed!, encoding: .utf8)) == text)
    // WRITTEN INTO `.tmp` AND RENAMED, so a reader opening the directory never sees half a message.
    check("…and nothing is left behind in the staging directory",
          (try? FileManager.default.contentsOfDirectory(atPath:
              inbox.appendingPathComponent(".tmp").path)) == [])
}

/// A process table entry with a start time derived from its pid, so two fixtures of the same pid
/// are the same process and two of different pids are not.
private func identity(_ pid: pid_t, parent: pid_t, group: pid_t) -> ProcessIdentity {
    ProcessIdentity(pid: pid, parent: parent, group: group, startedAt: Int64(pid) * 1_000)
}
