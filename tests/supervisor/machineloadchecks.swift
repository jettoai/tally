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
              && sampler.contains("strays: unattributed, at: now)")
              && !sampler.contains("strays: strayRoot, at: now)"))
    // And the walk that produced that set is skipped only where it could not answer differently: with
    // jobs to adopt it must still be made, or the re-parented work this whole repair exists for falls
    // back off the card it was just matched to.
    check("a card with jobs to adopt is walked again, and only such a card is",
          sampler.contains("orphans.isEmpty") && sampler.contains("adopting: orphans)"))

    // THE STATE THE ROLLUP EXISTS FOR: a checkout with load and no session at all.
    let abandoned = MachineLoadRollup.rows(sessions: [], strays: strays)
    check("a checkout whose session has ended still has a row while its jobs run",
          abandoned.projects.first?.sessions == 0
              && abandoned.projects.first?.strayProcesses == 6)

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
