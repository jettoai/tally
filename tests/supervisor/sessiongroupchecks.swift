import Foundation

// WHICH JOBS A SESSION HAS STARTED, AND WHICH ORPHAN COMES BACK TO WHICH CARD
// (Tally/Core/SessionProcessGroups.swift).
//
// THE DEFECT THIS CLOSES, replayed below as `theIncident`: a session dispatched a twelve-worker run
// through `uv`; the command's own shell exited, macOS re-parented the survivors to launchd, and the
// group they kept was the dead shell's pid rather than the supervisor's. The tree walk reaches a job
// through parentage or through the ROOT'S OWN group, and that job had neither, so twelve of sixteen
// cores were busy and the card read 2% (2026-08-25). The repair is to write the group down while it
// is still reachable and match the orphan back against it.
//
// EVERY RULE HERE IS ABOUT A NUMBER THAT CAN LIE, which is why the file is mostly refusals: a pid is
// reused, so both the supervisor's number and the GROUP's number can come to name something else,
// and an adoption that got either wrong would put a stranger's cores on somebody's card - a failure
// nothing downstream could notice. The tests that matter most are the ones that assert nothing is
// adopted.
//
// The other half of the file is the CPU credit that this session's own processes leave behind
// (`ProcessCPUCarry`, Tally/Core/ProcessTreeRates.swift): why it may only ever cancel an arrival,
// which is a correction to the repair asserted in footprintchecks.swift.

func runSessionGroupChecks() {
    // Instants as the process table states them: microseconds since the epoch, derived from the pid
    // so every invented process has one of its own (the shape processtreechecks.swift uses).
    func birth(_ pid: pid_t) -> Int64 { 1_786_000_000_000_000 + Int64(pid) * 1_000 }
    func proc(_ pid: pid_t, ppid: pid_t, group: pid_t) -> ProcessIdentity {
        ProcessIdentity(pid: pid, parent: ppid, group: group, startedAt: birth(pid))
    }

    // THE INCIDENT, as the machine held it. 100 is the supervisor, leading its own job; 200 its
    // Claude Code; 300 the shell one Bash tool call ran in, which made a job of its own (Claude Code
    // does this so it can signal the job rather than the process); 400 the `uv` that shell started,
    // and 401 one of its workers.
    let running = [proc(1, ppid: 0, group: 1), proc(100, ppid: 1, group: 100),
                   proc(200, ppid: 100, group: 100), proc(300, ppid: 200, group: 300),
                   proc(400, ppid: 300, group: 300), proc(401, ppid: 400, group: 300)]
    // …and a moment later, the shell gone and its survivors re-parented to launchd.
    let detached = [proc(1, ppid: 0, group: 1), proc(100, ppid: 1, group: 100),
                    proc(200, ppid: 100, group: 100),
                    proc(400, ppid: 1, group: 300), proc(401, ppid: 400, group: 300)]
    func table(_ processes: [ProcessIdentity]) -> (pid_t) -> Int64? {
        let byPid = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.startedAt) })
        return { byPid[$0] }
    }
    let sessions = ["100": birth(100)]

    // MARK: what a tick writes down

    let seen = SessionProcessGroups.observed(
        members: running.filter { [100, 200, 300, 400, 401].contains($0.pid) },
        startedAt: table(running), name: { $0 == 400 ? "uv" : "sh" })
    check("every job the tree carries is written down, not just the root's own",
          seen.map(\.group) == [100, 300])
    check("…identified by when the job's LEADER started, which is what survives its members",
          seen.first { $0.group == 300 }?.leaderStartedAt == birth(300))
    check("…and by the oldest member ever seen in it, which is what is left when the leader has gone",
          seen.first { $0.group == 300 }?.earliestMemberStart == birth(300))
    // Group 1 is launchd's, and half the machine's daemons are in it: claiming it would hand a
    // session every orphan on the machine the first time one turned up.
    check("launchd's own group is not a job anybody started",
          !SessionProcessGroups.observed(members: [proc(9, ppid: 1, group: 1)],
                                         startedAt: table(running), name: { _ in nil })
              .contains { $0.group == 1 })

    let ledger = SessionProcessGroups.claims(seen, session: "100", sessionStartedAt: birth(100),
                                             against: [], at: "2026-08-25T10:00:00.000Z")
    check("a first sighting is written as a claim per job", ledger.count == 2)
    check("…and a job already claimed by the same session writes nothing again",
          SessionProcessGroups.claims(seen, session: "100", sessionStartedAt: birth(100),
                                      against: ledger, at: "2026-08-25T10:00:02.000Z").isEmpty)
    // A group number reused INSIDE one session's life is a new job, and a ledger that called it
    // answered would go on vouching for the dead one's earliest member.
    let reborn = [SessionProcessGroups.Observation(group: 300, leaderStartedAt: birth(999),
                                                   earliestMemberStart: birth(999), name: "sh")]
    check("…but the same number belonging to a NEW job is news",
          SessionProcessGroups.claims(reborn, session: "100", sessionStartedAt: birth(100),
                                      against: ledger, at: "2026-08-25T10:00:04.000Z").count == 1)

    // MARK: what comes back

    let orphan = detached.first { $0.pid == 400 }!
    check("the incident: the orphaned job is matched back to the session that started it",
          SessionProcessGroups.claimant(of: orphan, ledger: ledger, sessions: sessions,
                                        startedAt: table(detached)) == "100")
    // The whole point of the ledger, stated against the walk it repairs.
    check("…which the tree walk alone cannot do",
          !ProcessTree.members(root: 100, processes: detached).contains(400))
    check("…and the walk does it once the adoption is fed back into it",
          ProcessTree.members(root: 100, processes: detached,
                              adopting: [400]) == [100, 200, 400, 401])
    check("…the orphan's own children coming with it, being as much the session's as it is",
          ProcessTree.members(root: 100, processes: detached, adopting: [400]).contains(401))
    check("an adoption of nothing leaves the walk exactly as it was",
          ProcessTree.members(root: 100, processes: detached, adopting: [])
              == ProcessTree.members(root: 100, processes: detached))

    // MARK: the four ways a number lies

    check("a supervisor given a dead session's pid inherits none of its claims",
          SessionProcessGroups.claimant(of: orphan, ledger: ledger,
                                        sessions: ["100": birth(100) + 5_000_000],
                                        startedAt: table(detached)) == nil)
    check("…and a session the board no longer holds claims nothing at all",
          SessionProcessGroups.claimant(of: orphan, ledger: ledger, sessions: [:],
                                        startedAt: table(detached)) == nil)
    // THE ONE THAT WOULD PUT A STRANGER'S CORES ON A CARD: the group's leader has exited, its
    // number has been handed to an unrelated process, and a job of that number turns up.
    let recycled = table(detached + [ProcessIdentity(pid: 300, parent: 1, group: 300,
                                                     startedAt: birth(300) + 9_000_000)])
    check("a group number handed out again is refused rather than adopted",
          SessionProcessGroups.claimant(of: proc(700, ppid: 1, group: 300), ledger: ledger,
                                        sessions: sessions, startedAt: recycled) == nil)
    // The weaker test, and the only one left once the leader is gone: a process older than the
    // oldest member the claim ever saw cannot be of the same generation of the group.
    check("…and so is a process that predates the oldest member the job ever had",
          SessionProcessGroups.claimant(of: ProcessIdentity(pid: 700, parent: 1, group: 300,
                                                            startedAt: birth(300) - 1),
                                        ledger: ledger, sessions: sessions,
                                        startedAt: table(detached)) == nil)
    check("a process in launchd's own group is never anybody's",
          SessionProcessGroups.claimant(of: proc(700, ppid: 1, group: 1), ledger: ledger,
                                        sessions: sessions, startedAt: table(detached)) == nil)

    // MARK: the refusal above, on the path this whole file exists for

    // THE LEADER OF A JOB IS THE SHELL WHOSE EXIT MAKES THE JOB AN ORPHAN, so the tick that matters
    // is always a tick where the process table can no longer say when the group's leader started.
    // Taking that silence for the answer wrote a second claim with no stamp on it, and `claimant`
    // skips the recycled-number test on a stamp-less claim: the strongest of the three refusals
    // switched itself off on the main path, leaving the weak test alone against a newborn stranger.
    let afterExit = SessionProcessGroups.observed(
        members: detached.filter { [100, 200, 400, 401].contains($0.pid) },
        startedAt: table(detached), name: { $0 == 400 ? "uv" : "sh" })
    check("the job's leader has gone by the time the orphan matters, so the table cannot stamp it",
          afterExit.first { $0.group == 300 }?.leaderStartedAt == nil)
    let carriedOn = SessionProcessGroups.claims(afterExit, session: "100",
                                                sessionStartedAt: birth(100), against: ledger,
                                                at: "2026-08-25T10:00:02.000Z")
    check("…and the tick after it exits writes nothing, the claim on file still answering for it",
          carriedOn.isEmpty)
    // A claim IS written again when a member older than any seen before turns up in the group, and
    // that one has to carry the stamp forward too: what is written down is the only thing left that
    // knows when the leader began.
    let older = [SessionProcessGroups.Observation(group: 300, leaderStartedAt: nil,
                                                  earliestMemberStart: birth(300) - 1_000,
                                                  name: "uv")]
    let restamped = SessionProcessGroups.claims(older, session: "100",
                                                sessionStartedAt: birth(100), against: ledger,
                                                at: "2026-08-25T10:00:04.000Z")
    check("…and a claim written once the leader has gone keeps the stamp the leader left",
          restamped.first?.leaderStartedAt == birth(300))
    // THE FAILURE THAT PUTS A STRANGER'S CORES ON A CARD, replayed through the ledger a live session
    // actually builds rather than through a hand-written one: the first claim, plus everything the
    // ticks after the leader's exit added to it, still refuses a recycled group number.
    check("…so the ledger that outlives the leader still refuses a recycled group number",
          SessionProcessGroups.claimant(of: proc(700, ppid: 1, group: 300),
                                        ledger: ledger + carriedOn + restamped,
                                        sessions: sessions, startedAt: recycled) == nil)

    // MARK: two sessions claiming one job

    // A `tally claude` started inside a supervised terminal is genuinely in its parent's tree, so
    // both can hold the group; the one that STARTED the job is the inner one.
    //
    // AND THE NESTED CASE IS A TIE ON "WHO SAW IT LAST", which is why the claims here carry the SAME
    // instant rather than two hand-written ones three seconds apart. The inner supervisor is already
    // inside the outer's tree, so one pass of one tick observes the job on both cards, and a tick
    // stamps every claim it writes with one instant (`ProcessFootprintStore.sample` takes it once).
    // A test that invented a gap was asserting a mechanism production cannot reach: the contest was
    // always being settled by the arbitrary tie-break underneath it.
    let sameTick = "2026-08-25T10:00:00.000Z"
    check("the two sessions of a nested pair see the job on the same tick, at the same instant",
          ledger.allSatisfy { $0.firstSeen == sameTick })
    let contested = ledger + [SessionProcessGroup(session: "500", sessionStartedAt: birth(500),
                                                  group: 300, leaderStartedAt: birth(300),
                                                  earliestMemberStart: birth(300),
                                                  firstSeen: sameTick, name: "sh")]
    let bothLive = ["100": birth(100), "500": birth(500)]
    check("a contested job goes to the inner session, which is the supervisor that started later",
          SessionProcessGroups.claimant(of: orphan, ledger: contested, sessions: bothLive,
                                        startedAt: table(detached)) == "500")
    // The outer supervisor is the one with the LOWER pid here as well as the earlier start, so the
    // answer above is the second key's rather than the pid tie-break's underneath it.
    check("…which is not what the pid tie-break under it would have answered",
          contested.filter { $0.group == 300 }.map(\.session).min() == "100")
    check("…and falls back to the live one when the other has gone",
          SessionProcessGroups.claimant(of: orphan, ledger: contested, sessions: sessions,
                                        startedAt: table(detached)) == "100")
    // Two supervisors that somehow started at the same instant still have to be told apart, and the
    // answer only has to be DECIDABLE: an adoption changing hands from tick to tick would move cores
    // between two cards every two seconds.
    let twins = contested.map { record -> SessionProcessGroup in
        var same = record
        same.sessionStartedAt = birth(100)
        return same
    }
    check("…and a tie on both keys falls to the lower pid, which is arbitrary and stable",
          SessionProcessGroups.claimant(of: orphan, ledger: twins,
                                        sessions: ["100": birth(100), "500": birth(100)],
                                        startedAt: table(detached)) == "100")

    // MARK: the index every reading is now taken through

    // THE SCAN THE INDEX REPLACED, kept as the oracle it has to agree with: the same three refusals
    // and the same tie-break, over the whole ledger in file order. An optimisation of a rule this
    // delicate is only worth having while something independent still states the rule, and the
    // whole claim of `SessionProcessGroups.Index` is that it changed the cost and nothing else
    // (measured 2026-09-03: 1370 unclaimed processes against 4000 claims was 350ms of the main
    // thread every two seconds with the board doing nothing at all).
    func linearClaimant(of process: ProcessIdentity, ledger: [SessionProcessGroup],
                        sessions: [String: Int64], startedAt: (pid_t) -> Int64?) -> String? {
        guard process.group > 1 else { return nil }
        var best: SessionProcessGroup?
        for record in ledger where record.group == process.group {
            guard sessions[record.session] == record.sessionStartedAt else { continue }
            if let leader = record.leaderStartedAt, let now = startedAt(record.group),
               now != leader { continue }
            guard process.startedAt >= record.earliestMemberStart else { continue }
            guard let held = best else { best = record; continue }
            if record.firstSeen > held.firstSeen
                || (record.firstSeen == held.firstSeen
                    && (record.sessionStartedAt > held.sessionStartedAt
                        || (record.sessionStartedAt == held.sessionStartedAt
                            && record.session < held.session))) {
                best = record
            }
        }
        return best?.session
    }
    // Every ledger this file has built, against every process it has asked about, under every
    // roster: the four shapes the refusals exist for (a contest, a tie on both keys, a session the
    // board has lost, a recycled group number) CROSSED with each other rather than one at a time.
    let ledgers: [(String, [SessionProcessGroup])] = [
        ("first sighting", ledger), ("contested", contested), ("twins", twins),
        ("outliving the leader", ledger + carriedOn + restamped)]
    let rosters: [(String, [String: Int64])] = [
        ("one session", sessions), ("both live", bothLive),
        ("twin supervisors", ["100": birth(100), "500": birth(100)]),
        ("the board lost it", ["100": birth(100) + 5_000_000]), ("empty board", [:])]
    let probes: [(String, ProcessIdentity, (pid_t) -> Int64?)] = [
        ("the orphan", orphan, table(detached)),
        ("a newborn on a recycled number", proc(700, ppid: 1, group: 300), recycled),
        ("one older than the job ever was",
         ProcessIdentity(pid: 700, parent: 1, group: 300, startedAt: birth(300) - 1),
         table(detached)),
        ("one in launchd's group", proc(700, ppid: 1, group: 1), table(detached))]
    var disagreements: [String] = []
    var answers: Set<String> = []
    for (ledgerName, one) in ledgers {
        let index = SessionProcessGroups.Index(one)
        for (rosterName, roster) in rosters {
            for (probeName, process, clock) in probes {
                let indexed = SessionProcessGroups.claimant(of: process, in: index,
                                                            sessions: roster, startedAt: clock)
                answers.insert(indexed ?? "nobody")
                if indexed != linearClaimant(of: process, ledger: one, sessions: roster,
                                             startedAt: clock) {
                    disagreements.append("\(ledgerName) / \(rosterName) / \(probeName)")
                }
            }
        }
    }
    check("the indexed claimant answers what the whole-ledger scan answered, on every fixture here",
          disagreements.isEmpty)
    // …and the matrix is not vacuous: eighty comparisons that all answered "nobody" would pass
    // whatever the index did with them.
    check("…over a matrix that reaches both cards and a refusal",
          ledgers.count * rosters.count * probes.count == 80
              && answers == ["100", "500", "nobody"])
    // WHICH OF A SESSION'S CLAIMS ON ONE GROUP IS THE ONE ON FILE: the LAST it wrote. The buckets
    // keep the ledger's order for this reason alone, and a bucket sorted on anything else would go
    // on comparing against the claim that was superseded while every other assertion here passed.
    check("a re-stamped claim is what the next tick is compared against, not the one it replaced",
          SessionProcessGroups.claims(older, session: "100", sessionStartedAt: birth(100),
                                      against: ledger + restamped,
                                      at: "2026-08-25T10:00:06.000Z").isEmpty)
    check("…which is not what the claim it replaced would have answered",
          SessionProcessGroups.claims(older, session: "100", sessionStartedAt: birth(100),
                                      against: ledger, at: "2026-08-25T10:00:06.000Z").count == 1)

    // MARK: the whole machine at once

    let adopted = SessionProcessGroups.adoptions(
        unclaimed: detached.filter { ![100, 200].contains($0.pid) },
        ledger: ledger, sessions: sessions, startedAt: table(detached))
    check("every orphan of a claimed job comes back in one pass", adopted["100"] == [400, 401])
    check("…and a process already inside somebody's tree is never offered for adoption",
          SessionProcessGroups.adoptions(unclaimed: [], ledger: ledger, sessions: sessions,
                                         startedAt: table(detached)).isEmpty)

    // MARK: what the ledger keeps

    let dead = ledger + [SessionProcessGroup(session: "900", sessionStartedAt: birth(900),
                                             group: 901, leaderStartedAt: nil,
                                             earliestMemberStart: birth(901),
                                             firstSeen: "2026-08-25T09:00:00.000Z", name: nil)]
    check("claims of a session the board no longer holds are swept",
          SessionProcessGroups.swept(dead, sessions: sessions).map(\.group) == [100, 300])
    // The sampler takes no reading at all on an empty roster, so an empty set here means "not
    // asked": acting on it would empty the file on the first tick after a relaunch.
    check("…but an empty board is not evidence that nothing is running",
          SessionProcessGroups.swept(dead, sessions: [:]).count == dead.count)

    // MARK: and what it stops keeping, once a job's group has no member left

    // A CLAIM ON A GROUP WITH NO MEMBER LEFT CAN ONLY EVER BE WRONG (`SessionProcessGroups.
    // groupGrace`): a group exists while something is in it and `setpgid` only joins one that
    // already exists, so a job that could still be adopted is a job that is still running, and a
    // running job keeps its group alive. Until this rule the file was bounded by nothing but the
    // cap and had reached it (measured 2026-09-03: 4000 claims, 1.0MB, 3003 groups, 19 of them
    // still alive), which cost a megabyte rewritten on every command any session started.
    let liveOnly: Set<pid_t> = [100]
    check("a claim whose group has been gone for the whole grace is dropped",
          SessionProcessGroups.swept(ledger, sessions: sessions, liveGroups: liveOnly,
                                     absentFor: { _ in SessionProcessGroups.groupGrace })
              .map(\.group) == [100])
    check("…and one walk short of it is kept, because a walk that missed is not a walk that saw",
          SessionProcessGroups.swept(ledger, sessions: sessions, liveGroups: liveOnly,
                                     absentFor: { _ in SessionProcessGroups.groupGrace - 1 })
              .map(\.group) == [100, 300])
    check("…and a group this walk DID see is kept however long it had been missing before",
          SessionProcessGroups.swept(ledger, sessions: sessions, liveGroups: [100, 300],
                                     absentFor: { _ in 99 }).map(\.group) == [100, 300])
    // An empty set of groups is a walk that was never made, exactly as an empty roster is a board
    // that was never asked: acting on it would empty the file on the first tick after a relaunch.
    check("…and an empty walk is not evidence that every group on the machine has gone",
          SessionProcessGroups.swept(ledger, sessions: sessions, liveGroups: [],
                                     absentFor: { _ in 99 }).map(\.group) == [100, 300])
    // THE CLAIM THE WEAK TEST STANDS ALONE ON: written after the leader had already gone, so
    // `claimant` skips the recycled-number refusal on it and a newborn stranger has only the
    // generation test left to get past. It is the claim most worth retiring, and it is retired on
    // exactly the same evidence as any other.
    let stampless = [SessionProcessGroup(session: "100", sessionStartedAt: birth(100), group: 300,
                                          leaderStartedAt: nil, earliestMemberStart: birth(300),
                                          firstSeen: "2026-08-25T10:00:02.000Z", name: "uv")]
    check("a stamp-less claim goes with its group, being the one a stranger could still pass",
          SessionProcessGroups.swept(stampless, sessions: sessions, liveGroups: liveOnly,
                                     absentFor: { _ in SessionProcessGroups.groupGrace }).isEmpty)

    // The count the rule above is decided on, which no pure function can hold for itself.
    var counts: [pid_t: Int] = [:]
    var retiredOn: Int?
    for walk in 1...(SessionProcessGroups.groupGrace + 1) {
        let round = SessionProcessGroups.absences(in: SessionProcessGroups.Index(ledger),
                                                  seeing: liveOnly, after: counts,
                                                  stillAlive: { _ in false })
        counts = round.ticks
        if round.expired, retiredOn == nil { retiredOn = walk }
    }
    check("the walks are counted per group, and the grace-th consecutive miss is what retires it",
          retiredOn == SessionProcessGroups.groupGrace
              && counts == [300: SessionProcessGroups.groupGrace + 1])
    check("…while a group the walk saw again is not counted at all, which is how a count resets",
          SessionProcessGroups.absences(in: SessionProcessGroups.Index(ledger),
                                        seeing: [100, 300], after: counts,
                                        stillAlive: { _ in false }).ticks.isEmpty)

    // MARK: and the walk's silence, which is not the same thing as an absence

    // THE DEFECT THIS CLOSES, stated as the job it lost: a session runs something under `sudo`, its
    // children belong to root, and `proc_pidinfo` will not answer for them - so the group is
    // missing from EVERY walk this app makes while sixteen cores are busy with it. On the walk
    // alone that is three misses and a retired claim, and the attribution of exactly the long job
    // the ledger exists for is gone for good. `killpg(group, 0)` answers what the walk cannot:
    // EPERM is "there are members and they are not yours".
    var deniedCounts: [pid_t: Int] = [:]
    var deniedExpired = false
    for _ in 1...SessionProcessGroups.groupGrace {
        let round = SessionProcessGroups.absences(in: SessionProcessGroups.Index(ledger),
                                                  seeing: liveOnly, after: deniedCounts,
                                                  stillAlive: { _ in true })
        deniedCounts = round.ticks
        deniedExpired = deniedExpired || round.expired
    }
    check("a group no walk can see but the kernel says is there is never counted absent",
          deniedCounts.isEmpty)
    check("…so the grace never runs out on it, and the sweep leaves its claim alone",
          !deniedExpired
              && SessionProcessGroups.swept(ledger, sessions: sessions, liveGroups: liveOnly,
                                            absentFor: { deniedCounts[$0] ?? 0 })
                  .map(\.group) == [100, 300])
    // AND THE PROBE ZEROES THE COUNT RATHER THAN PAUSING IT, which is the half that a mere "not
    // counted this round" would leave wrong: the kernel outranks the walk, so an answer of "still
    // there" makes the misses before it worthless rather than banked. Two misses, then two rounds
    // in which the kernel says the group is there, then it really goes. Counting from one again
    // puts the retirement three rounds after that, on the seventh; banking the first two would
    // have retired it on the fifth, and ignoring the probe entirely on the third.
    var mixedCounts: [pid_t: Int] = [:]
    var mixedRetiredOn: Int?
    for walk in 1...(SessionProcessGroups.groupGrace + 4) {
        let round = SessionProcessGroups.absences(in: SessionProcessGroups.Index(ledger),
                                                  seeing: liveOnly, after: mixedCounts,
                                                  stillAlive: { _ in walk == 3 || walk == 4 })
        mixedCounts = round.ticks
        if round.expired, mixedRetiredOn == nil { mixedRetiredOn = walk }
    }
    check("a group the kernel confirmed is counted from one again, not from where the walk was",
          mixedRetiredOn == SessionProcessGroups.groupGrace + 4
              && mixedCounts == [300: SessionProcessGroups.groupGrace])

    // AND THE PROBE ITSELF ERRS TOWARDS KEEPING THE CLAIM. `killpg(group, 0)` is asked of the
    // kernel, so no assertion can make it fail in a chosen way; the verdict it takes on the failure
    // is the half that can be. The two mistakes do not cost the same - a wrong "gone" loses an
    // attribution for good and a wrong "alive" costs one more tick of grace - so only the one errno
    // that MEANS "no such group" is read as gone (`SessionProcessGroups.stillAlive`).
    check("no such group is the only answer that retires a claim",
          !SessionProcessGroups.stillAliveAfter(ESRCH))
    check("…while members that are somebody else's are members all the same",
          SessionProcessGroups.stillAliveAfter(EPERM))
    check("…and an answer the probe cannot read is not evidence that the group has gone",
          SessionProcessGroups.stillAliveAfter(EINVAL)
              && SessionProcessGroups.stillAliveAfter(EFAULT))

    // MARK: the file

    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-groups-\(UUID().uuidString)")
    let file = SessionProcessGroups.fileURL(home: home)
    defer { try? FileManager.default.removeItem(at: home) }
    let written = SessionProcessGroups.record(ledger, sessions: sessions, in: file)
    check("what is written is what comes back", SessionProcessGroups.load(from: file) == ledger)
    check("…and the writer hands back the ledger it left on disk", written == ledger)
    check("…swept of the sessions that have gone, in the same pass",
          SessionProcessGroups.record([], sessions: ["100": birth(100) + 1], in: file).isEmpty)

    // MARK: the CPU credit one of ours leaves behind (ProcessCPUCarry)

    let t0 = Date(timeIntervalSince1970: 1_786_571_200)
    // Two processes: 10 is Tally's own (a hook), 20 is the session's Claude Code. The hook has
    // burned two seconds and is about to end.
    let before = ProcessResourceSample(times: [10: 2, 20: 1], childTimes: [10: 0, 20: 0],
                                       at: t0, ours: [10])
    // It has gone, and NOTHING collected it inside this tree: launchd buried it, because its parent
    // died first. Meanwhile 20 really did burn a second of work.
    let orphaned = ProcessResourceSample(times: [20: 2], childTimes: [20: 0],
                                         at: t0.addingTimeInterval(1), ours: [])
    let unsettled = ProcessTree.cpuPercent(from: before, to: orphaned)
    check("a departure of ours with nothing to cancel does not eat the session's real work",
          unsettled.percent == 100)
    check("…and its credit is held for exactly one tick rather than dropped on the spot",
          unsettled.carry.ours == 2 && unsettled.carry.theirs == 0)
    // The repair this must not break: the ordinary case, where the hook IS collected by the Claude
    // Code this card measures, and its two seconds arrive in that process's child counter.
    let collected = ProcessResourceSample(times: [20: 1], childTimes: [20: 2],
                                          at: t0.addingTimeInterval(1), ours: [])
    check("the ordinary case still cancels: a collected hook's seconds are not counted twice",
          ProcessTree.cpuPercent(from: before, to: collected).percent == 0)
    // …including across the tick boundary, which is the whole reason a carry exists: the hook died
    // just before one reading and was collected just after it.
    let late = ProcessResourceSample(times: [20: 1], childTimes: [20: 2],
                                     at: t0.addingTimeInterval(2), ours: [])
    check("…and across the tick that saw the death but not the collection",
          ProcessTree.cpuPercent(from: orphaned, to: late, carry: unsettled.carry).percent == 0)
    // The defect, stated as the reading it produced: carried into a tick with nothing of its own to
    // cancel, ours' credit used to come off somebody else's real seconds.
    let working = ProcessResourceSample(times: [20: 4], childTimes: [20: 0],
                                        at: t0.addingTimeInterval(2), ours: [])
    check("an unspendable credit is written off rather than suppressing the next tick",
          ProcessTree.cpuPercent(from: orphaned, to: working, carry: unsettled.carry).percent == 200)

    // MARK: the two credits, on the tick that holds both of them

    // ONE TICK'S ARRIVALS ARE ONE POOL, and each credit capped at the whole of them is each credit
    // settling the same seconds. 30 is a session process that ends having burned three seconds; 10
    // is a hook of ours that ends having burned two; 20 collects three seconds of children and
    // really burns five of its own. The tree's own credit takes the whole three arriving seconds,
    // so ours has nothing left to spend and is written off - the five seconds of real work stand.
    let bothKinds = ProcessResourceSample(times: [10: 2, 20: 1, 30: 3], childTimes: [:],
                                          at: t0, ours: [10])
    let settling = ProcessResourceSample(times: [20: 6], childTimes: [20: 3],
                                         at: t0.addingTimeInterval(1), ours: [])
    let paired = ProcessTree.cpuPercent(from: bothKinds, to: settling)
    check("two kinds of credit against one tick's arrivals do not each spend the whole of them",
          paired.percent == 500)
    check("…and what ours could not spend is handed on rather than taken out of the work",
          paired.carry.ours == 2 && paired.carry.theirs == 0)
    // The same, with ours' credit arriving from the tick before instead of departing on this one:
    // both halves of ours' spending are capped against what the tree's own credit left.
    let carriedIn = ProcessResourceSample(times: [20: 1, 30: 3], childTimes: [:], at: t0, ours: [])
    check("…and a credit carried in from the previous tick is capped the same way",
          ProcessTree.cpuPercent(from: carriedIn, to: settling,
                                 carry: ProcessCPUCarry(theirs: 0, ours: 2)).percent == 500)
}
