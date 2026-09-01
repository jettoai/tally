import Foundation

// WHETHER THE BOARD'S CARDS ADD UP (Tally/Core/MachineLoadRollup.swift).
//
// The rollup answers a question no card can: what is running in these checkouts that no live session
// accounts for. Everything asserted here is pure - which project a working directory belongs to, how
// the rows are built out of two kinds of reading, when the section is worth drawing at all, and the
// one signal that reads a command line.
//
// THE TWO ERRORS WORTH THE MOST HERE ARE BOTH SILENT: a prefix match that puts one checkout's dev
// server on its neighbour's row, and a scan that takes any argument it likes for a session name. The
// first prints a confident wrong number, the second attributes somebody's cores by coincidence.

func runMachineLoadChecks() {
    let tally = "/Users/x/workspace/tally"
    let sibling = "/Users/x/workspace/tally-wt1"
    let inner = "/Users/x/workspace/tally/.worktrees/feat"
    let roots = [tally, sibling, inner]

    // MARK: which project a directory belongs to

    check("a directory inside a checkout belongs to it",
          MachineLoadRollup.project(of: tally + "/Tally/Views", roots: roots) == tally)
    check("…and the checkout itself does too",
          MachineLoadRollup.project(of: tally, roots: roots) == tally)
    // THE ERROR THAT PRINTS A CONFIDENT WRONG NUMBER: `tally-wt1` starts with `tally`, so a
    // character prefix test files one parallel line's dev server under the other's name.
    check("a sibling whose name merely starts the same way is its own project",
          MachineLoadRollup.project(of: sibling + "/node_modules", roots: roots) == sibling)
    // …and the half of that which the sibling being a root of its own would hide: with only the
    // shorter checkout on the board, work in `tally-wt1` belongs to NOBODY. A character prefix test
    // answers `tally` here, which is the confident wrong number this rule exists to refuse.
    check("…and belongs to nobody at all when only the shorter one is on the board",
          MachineLoadRollup.project(of: sibling + "/node_modules", roots: [tally]) == nil)
    // A worktree lives inside its repository often enough to matter, and the nearer root is the one
    // somebody would name: the outer one would swallow every parallel line into the trunk.
    check("a worktree inside its repository is the worktree, not the repository",
          MachineLoadRollup.project(of: inner + "/app", roots: roots) == inner)
    check("a directory in none of them belongs to nobody",
          MachineLoadRollup.project(of: "/Applications/Safari.app", roots: roots) == nil)
    check("…and a board with no sessions on it claims nothing at all",
          MachineLoadRollup.project(of: tally, roots: []) == nil)

    // MARK: the rows

    let sessions = [MachineLoadRollup.SessionReading(root: tally, cpuPercent: 12,
                                                     memoryBytes: 400_000_000),
                    MachineLoadRollup.SessionReading(root: tally, cpuPercent: 8,
                                                     memoryBytes: 100_000_000),
                    MachineLoadRollup.SessionReading(root: sibling, cpuPercent: nil,
                                                     memoryBytes: 50_000_000)]
    let strays = [MachineLoadRollup.StrayReading(root: sibling, cpuPercent: 300,
                                                 memoryBytes: 2_000_000_000, processes: 6)]
    let load = MachineLoadRollup.rows(sessions: sessions, strays: strays)
    check("one row per project, in a stable order that is never the load's",
          load.projects.map(\.name) == ["tally", "tally-wt1"])
    check("two sessions in one checkout add up into its row",
          load.projects.first?.cpuPercent == 20 && load.projects.first?.sessions == 2)
    check("…and what nobody claims adds up beside them",
          load.projects.last?.cpuPercent == 300 && load.projects.last?.strayProcesses == 6)
    check("…memory included", load.projects.last?.memoryBytes == 2_050_000_000)
    // A percentage that has not been established yet is nil everywhere else in this app, and summing
    // it as a zero here would state a reading nobody took.
    check("a project where nothing has been read twice states no rate rather than zero",
          MachineLoadRollup.rows(
              sessions: [MachineLoadRollup.SessionReading(root: tally, cpuPercent: nil,
                                                          memoryBytes: 1)],
              strays: []).projects.first?.cpuPercent == nil)
    check("the heaviest is marked when it is worth pointing at", load.heaviest == sibling)
    // Below a whole core "the heaviest" is whichever project happens to have a language server
    // indexing, and a mark that is always on somebody says nothing.
    check("…and nobody is marked on a quiet machine",
          MachineLoadRollup.rows(sessions: sessions, strays: []).heaviest == nil)
    // TWO PROJECTS ON EXACTLY THE SAME FIGURE MUST NOT SWAP THE MARK BETWEEN THEM, which is the
    // flicker the stable row order exists to stop arriving one field over. The mark is settled on the
    // root, the field the rows are keyed by, rather than on whichever NAME happened to sort first:
    // the two orders disagree the moment a project's directory and its last component disagree.
    let deepApi = "/Users/x/workspace/zeta/api"
    let shallowZulu = "/Users/x/apps/zulu"
    let tied = MachineLoadRollup.rows(
        sessions: [MachineLoadRollup.SessionReading(root: deepApi, cpuPercent: 250,
                                                    memoryBytes: 1),
                   MachineLoadRollup.SessionReading(root: shallowZulu, cpuPercent: 250,
                                                    memoryBytes: 1)],
        strays: [])
    check("two projects burning the same amount settle the mark on the root, not on the row order",
          tied.projects.map(\.name) == ["api", "zulu"] && tied.heaviest == shallowZulu)

    // MARK: what is still unattributed once the cards are settled

    // The strays are picked out BEFORE the cards are walked, because that is what says which
    // processes no tree reached; the walk is then seeded with the adopted jobs and pulls their own
    // children back onto a card. A child that started a process group of its own was in neither set
    // that first pass had, so left in it is drawn twice on one page: inside a card's figures, and
    // again as work nobody is answering for.
    let grandchild: pid_t = 4002
    let nobodys: pid_t = 4003
    let leftBehind: [pid_t: String] = [grandchild: tally, nobodys: sibling]
    check("a process a card turned out to be counting is not left over as well",
          MachineLoadRollup.leftovers(strays: leftBehind,
                                      counted: [7001, 4001, grandchild]) == [nobodys: sibling])
    check("…and work no card reached is left exactly where it was",
          MachineLoadRollup.leftovers(strays: leftBehind, counted: [7001]) == leftBehind)
    check("…as it is on a board that counted nothing at all",
          MachineLoadRollup.leftovers(strays: leftBehind, counted: []) == leftBehind)
    // AND THE SAMPLER HAS TO ACTUALLY SPEND IT. A rule that subtracts correctly while the tick hands
    // the rollup the set it had BEFORE the cards were walked is the same double count with a passing
    // assertion beside it, which is how this was written the first time: the membership loop gathered
    // what the cards counted and nothing consumed it (`ProcessFootprintStore.sample`).
    let sampler = (try? String(contentsOfFile: "Tally/Stores/ProcessFootprintStore.swift",
                               encoding: .utf8)) ?? ""
    check("the sources this suite reads are readable from it", !sampler.isEmpty)
    check("the tick pays the strays out of what its cards turned out to be counting",
          sampler.contains("MachineLoadRollup.leftovers(strays: strayRoot, counted: counted)")
              && sampler.contains("rollup.load(sessions: byProject, strays: unattributed,")
              && !sampler.contains("rollup.load(sessions: byProject, strays: strayRoot"))
    // And the walk that produced that set is skipped only where it could not answer differently: with
    // jobs to adopt it must still be made, or the re-parented work this whole repair exists for falls
    // back off the card it was just matched to.
    check("a card with jobs to adopt is walked again, and only such a card is",
          sampler.contains("orphans.isEmpty") && sampler.contains("adopting: orphans)"))
    // THE ROOTS ARE NOT THE BOARD'S, and the difference is the whole state this section exists for.
    // Taken from the live rows, a checkout stops being accounted for in the same tick its last
    // session closes: its dev server has no project to be a stray of, and with the board empty the
    // pass does not even walk the table. Both short circuits are on the RETAINED roots now
    // (`ProjectLoadAccounting.accounted`, whose lifecycle projectloadchecks.swift drives).
    check("the tick accounts against the projects still being watched, not against the board",
          sampler.contains("roots: rollup.accounted")
              && sampler.contains("roots.isEmpty && rollup.accounted.isEmpty")
              && sampler.contains("rollup.accounted.isEmpty\n            ? MachineLoad()")
              && !sampler.contains("roots.isEmpty ? MachineLoad()")
              && !sampler.contains("roots: Set(rootOfSession.values)"))
    // And a project's total is asked for rather than assembled here, so the nesting rule cannot be
    // skipped by a caller that only wanted the figures.
    check("the sessions' side of the rollup comes through the rule that de-duplicates it",
          sampler.contains("MachineLoadRollup.readings(of: next, roots: rootOfSession,")
              && sampler.contains("members: membership)"))
    // The strays' own rate is the other half that only exists in the store: a pair taken over the
    // whole previous reading credits a departed stray its entire lifetime of CPU against a pool that
    // can never settle it, and reads 0% for two ticks every time a job is adopted back onto a card.
    let accounting = (try? String(contentsOfFile: "Tally/Stores/ProjectLoadAccounting.swift",
                                  encoding: .utf8)) ?? ""
    check("the accounting this suite reads is readable from it", !accounting.isEmpty)
    check("a stray pool's pair is decided on what became of each departure, not on the membership",
          accounting.contains("previous[root]?.pairing(with: reading, departure: departure)")
              && accounting.contains("previous[root] = pair?.keep ?? reading"))
    // AND NOT ON A TABLE WALKED EARLIER IN THE PASS, which is the half a source string can still
    // say: the counters and the verdict about them have to be the same instant, and this tick walks
    // its table some milliseconds of cwd reads before it samples the pool. The MICROSECONDS between
    // the pool being read and each departure being asked about are a second instant again, which no
    // source string reaches and which the pool's carry is what answers - that half is asserted
    // behaviourally next door (projectloadchecks.swift, "collected between the reading and the
    // question"); this line only rules out the milliseconds.
    check("…and the tick hands it no table of its own to decide with",
          sampler.contains("rollup.load(sessions: byProject, strays: unattributed, at: now)")
              && !sampler.contains("alive: Set(identities.keys)"))
    check("…and a project is watched from the tick a session names it until nothing works in it",
          accounting.contains("watching.formUnion(found.values)")
              && accounting.contains("MachineLoadRollup.watched(rollup, idle: idleTicks)"))
    // AND WHAT A RATE NEEDS LIVES EXACTLY THAT LONG. Rebuilt from each tick's live strays instead,
    // a pool holding nothing but a member it is waiting on lost the credit it was waiting to spend.
    check("…and a pool's reading and credit are kept for as long as the project is",
          accounting.contains("previous = previous.filter { watching.contains($0.key) }")
              && accounting.contains("carry = carry.filter { watching.contains($0.key) }"))

    // THE STATE THE ROLLUP EXISTS FOR: a checkout with load and no session at all. What hands this
    // rule such an input is state rather than a rule, and is asserted where it lives
    // (projectloadchecks.swift): for three months nothing could, and this assertion was green
    // throughout.
    let abandoned = MachineLoadRollup.rows(sessions: [], strays: strays)
    check("a checkout whose session has ended still has a row while its jobs run",
          abandoned.projects.first?.sessions == 0
              && abandoned.projects.first?.strayProcesses == 6)

    // MARK: a session running inside another one

    // `tally claude` from a supervised terminal puts the inner supervisor inside the outer one's
    // tree, so the outer card's members already hold every process the inner card counts. Two
    // cards, one honest answer each; one project total, and adding them states the checkout at
    // twice its size.
    let members = ["100": Set<pid_t>([100, 200, 500, 600]), "500": Set<pid_t>([500, 600])]
    check("the session whose whole tree is inside another one's on the same project is nested",
          MachineLoadRollup.nested(members, roots: ["100": tally, "500": tally]) == ["500"])
    // THE SHARED PIDS ARE NOT ALWAYS A CONTAINED TREE, and reading them as one is how this rule
    // came to do nothing in the case it was written for. The inner session adopts a job of its own
    // (the whole reason the group ledger exists) and the sets OVERLAP: the inner card holds the
    // orphan, the outer does not, neither contains the other. Tested for containment, the project
    // added both cards and counted the inner tree twice - and the contest rule hands the adoption
    // to the inner session every time, so this was the main path (codex review of 904e540).
    let overlapping = ["100": Set<pid_t>([100, 200, 500, 600]), "500": Set<pid_t>([500, 600, 900])]
    check("…and so is one that merely SHARES processes with it, which containment does not catch",
          MachineLoadRollup.nested(overlapping, roots: ["100": tally, "500": tally]) == ["500"])
    check("…the larger card being the one a project keeps",
          MachineLoadRollup.nested(["100": [100, 200], "500": [200, 500, 600]],
                                   roots: ["100": tally, "500": tally]) == ["100"])
    // A card is dropped only for a card the project is really counting. Decided against every other
    // card instead, a chain of overlaps takes work off the row that nothing was counting twice.
    check("…and a card dropped for another dropped card is not dropped at all",
          MachineLoadRollup.nested(["a": [1, 2, 3, 4], "b": [4, 5, 6], "c": [6, 7]],
                                   roots: ["a": tally, "b": tally, "c": tally]) == ["b"])
    check("…and two sessions of one checkout that share no process are not",
          MachineLoadRollup.nested(["100": [100, 200], "500": [500, 600]],
                                   roots: ["100": tally, "500": tally]).isEmpty)
    // The rule is about one project's total, so it has nothing to say across two of them: those are
    // two rows, and neither is adding the other's figures to itself.
    check("…nor is a tree inside another one when the two are filed under different checkouts",
          MachineLoadRollup.nested(members, roots: ["100": tally, "500": sibling]).isEmpty)
    let together = MachineLoadRollup.rows(
        sessions: [MachineLoadRollup.SessionReading(root: tally, cpuPercent: 300,
                                                    memoryBytes: 4_000_000_000),
                   MachineLoadRollup.SessionReading(root: tally, cpuPercent: 120,
                                                    memoryBytes: 1_000_000_000, nested: true)],
        strays: [])
    check("a checkout's total counts a nested session without adding its figures a second time",
          together.projects.first?.cpuPercent == 300
              && together.projects.first?.memoryBytes == 4_000_000_000)
    // AND IT IS STILL A SESSION WORKING HERE, which is not a detail: "more than one session in one
    // checkout" is half of why this section is on the page at all, so a rule that dropped the row
    // instead of its figures would take the section down with it.
    check("…and is still counted as a session, which is half of why the section is drawn",
          together.projects.first?.sessions == 2 && MachineLoadRollup.isWorthDrawing(together))
    // And the readings the tick hands to `rows` are marked by the same rule, over the memberships
    // the cards were drawn from.
    let outer = ProcessFootprint(processes: 4, cpuPercent: 300, memoryBytes: 4_000_000_000,
                                 listeningPorts: [])
    let within = ProcessFootprint(processes: 2, cpuPercent: 120, memoryBytes: 1_000_000_000,
                                  listeningPorts: [])
    let drawn = MachineLoadRollup.readings(of: ["100": outer, "500": within],
                                           roots: ["100": tally, "500": tally], members: members)
    check("the reading of the session inside the other one is the one marked",
          drawn.filter(\.nested).map(\.memoryBytes) == [1_000_000_000])
    check("…so the checkout states the outer figure rather than the two added together",
          MachineLoadRollup.rows(sessions: drawn, strays: []).projects.first?.cpuPercent == 300)
    // A CARD THAT WAS NOT DRAWN SWALLOWS NOTHING: a root whose tree was all Tally's own has no
    // footprint and adds nothing to the project, so letting its membership mark the session inside
    // it would take that session's figures off the row with nothing putting them back.
    check("…and a session whose card was skipped does not swallow the one inside it",
          MachineLoadRollup.readings(of: ["500": within], roots: ["100": tally, "500": tally],
                                     members: members).contains { $0.nested } == false)
    check("two sessions in one checkout that share no process are both read in full",
          MachineLoadRollup.rows(
              sessions: MachineLoadRollup.readings(of: ["100": outer, "500": within],
                                                   roots: ["100": tally, "500": tally],
                                                   members: ["100": [100, 200], "500": [500, 600]]),
              strays: []).projects.first?.cpuPercent == 420)

    // MARK: when the section is worth the room

    check("leftovers are always worth saying", MachineLoadRollup.isWorthDrawing(load))
    check("…and so is a checkout running several sessions at once",
          MachineLoadRollup.isWorthDrawing(MachineLoadRollup.rows(sessions: sessions, strays: [])))
    // On the ordinary board this section is a summary of the cards underneath it, and printing it
    // would spend the top of the page restating the page.
    check("but one session per checkout with nothing left over is the cards themselves",
          !MachineLoadRollup.isWorthDrawing(MachineLoadRollup.rows(
              sessions: [MachineLoadRollup.SessionReading(root: tally, cpuPercent: 3,
                                                          memoryBytes: 1)],
              strays: [])))

    // MARK: which projects are worth watching after their sessions have gone

    // A ROW IS NOT WORK. The interactive shell a session was launched from is a stray of that
    // checkout for as long as the terminal tab is open, so a rule that kept every root with a row
    // kept every checkout ever opened, each with a Projects line reading nothing.
    func watchedTick(_ cpu: Double?, _ memory: UInt64, sessions: Int = 0, idle: [String: Int] = [:])
        -> (roots: Set<String>, idle: [String: Int]) {
        MachineLoadRollup.watched(MachineLoadRollup.rows(
            sessions: (0..<sessions).map { _ in
                MachineLoadRollup.SessionReading(root: tally, cpuPercent: nil, memoryBytes: 0)
            },
            strays: [MachineLoadRollup.StrayReading(root: tally, cpuPercent: cpu,
                                                    memoryBytes: memory, processes: 1)]),
            idle: idle)
    }
    func watched(_ cpu: Double?, _ memory: UInt64, sessions: Int = 0) -> Set<String> {
        watchedTick(cpu, memory, sessions: sessions).roots
    }
    check("a project burning something is watched",
          watched(4, 3_000_000) == [tally])
    check("…and so is one nothing has been read twice in yet, which is not the same as idle",
          watched(nil, 3_000_000) == [tally])
    check("…and one whose leftovers are holding real memory at rest",
          watched(0, MachineLoadRollup.idleMemoryFloor) == [tally])
    check("…and one with a live session on it whatever its leftovers are doing",
          watched(0, 3_000_000, sessions: 1) == [tally])

    // AND ONE READING IS NOT EVIDENCE. An idle process reads 0% by construction, and the tick a
    // session ENDS on is guaranteed to read 0% for everything it leaves behind (a pid joining a pool
    // is given that reading as its baseline), so the very tick this section exists for was the tick
    // most likely to drop the project - and nothing puts a dropped one back until some session names
    // that directory again.
    let firstIdle = watchedTick(0, 3_000_000)
    let thirdIdle = watchedTick(0, 3_000_000, idle: [tally: 2])
    check("an idle shell is not work, but one reading of it does not drop the checkout either",
          firstIdle.roots == [tally] && firstIdle.idle == [tally: 1])
    check("…nor does the second, which is the first that could have read a rate at all",
          watchedTick(0, 3_000_000, idle: [tally: 1]).roots == [tally])
    check("…and the third takes it off the books, holding nothing over for it",
          thirdIdle.roots.isEmpty && thirdIdle.idle.isEmpty)
    // A project that reads busy at any point starts again from nothing, which is what makes the
    // count a grace period rather than a lifespan.
    let busyAgain = watchedTick(4, 3_000_000, idle: [tally: 2])
    check("a checkout that does something once is not two ticks from being dropped",
          busyAgain.roots == [tally] && busyAgain.idle.isEmpty)

    // MARK: the scratchpad signal

    let conversation = "ba7b61f3-5098-45bf-ae6f-34e881cf3bd7"
    let scratchpad = "/tmp/claude-501/-Users-x-workspace-tally/\(conversation)/scratchpad"
    check("a command working in a session's scratchpad names that conversation",
          MachineLoadRollup.scratchpadConversation(in: "python3\nrun.py\n--out\n\(scratchpad)/o.json",
                                                   uid: 501) == conversation)
    check("…wherever in the arguments the path sits",
          MachineLoadRollup.scratchpadConversation(in: "\(scratchpad)\n--quiet", uid: 501)
              == conversation)
    // The directory is named for the user, and another user's scratchpad is a path this app can say
    // nothing about.
    check("another user's scratchpad is not this user's session",
          MachineLoadRollup.scratchpadConversation(in: scratchpad, uid: 502) == nil)
    check("…read from the other side: a path under another uid's directory names nothing here",
          MachineLoadRollup.scratchpadConversation(
              in: "/tmp/claude-502/-Users-y-work/\(conversation)/scratchpad", uid: 501) == nil)
    // THE ERROR THAT WOULD ATTRIBUTE CORES BY COINCIDENCE: anything at all in the second component
    // being taken for a session name.
    check("a component that is not a conversation id names no session",
          MachineLoadRollup.scratchpadConversation(
              in: "/tmp/claude-501/-Users-x-workspace-tally/notes/thing", uid: 501) == nil)
    check("…and neither does a truncated one",
          MachineLoadRollup.scratchpadConversation(
              in: "/tmp/claude-501/proj/ba7b61f3-5098-45bf-ae6f-34e881cf3b/x", uid: 501) == nil)
    check("…nor one with a letter outside hexadecimal in it",
          MachineLoadRollup.scratchpadConversation(
              in: "/tmp/claude-501/proj/za7b61f3-5098-45bf-ae6f-34e881cf3bd7/x", uid: 501) == nil)
    check("an ordinary command line names nothing",
          MachineLoadRollup.scratchpadConversation(in: "node\n/Users/x/app/server.js", uid: 501)
              == nil)
    // The marker with nothing after it is the shape a truncated read produces, and a scan that ran
    // off the end of it would be reading whatever came next in the buffer.
    check("the marker alone is not a session either",
          MachineLoadRollup.scratchpadConversation(in: "/tmp/claude-501/", uid: 501) == nil)
    check("a conversation id is 8-4-4-4-12 hexadecimal and nothing else",
          MachineLoadRollup.isConversationID(conversation)
              && !MachineLoadRollup.isConversationID("ba7b61f3509845bf")
              && !MachineLoadRollup.isConversationID(""))
}
