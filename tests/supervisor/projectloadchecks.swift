import Foundation

// WHICH PROJECTS A TICK ACCOUNTS AGAINST (Tally/Stores/ProjectLoadAccounting.swift).
//
// The rules the rollup is built on are pure and asserted next door (machineloadchecks.swift). What
// is asserted HERE is the state between two ticks, which is the half those rules cannot reach: the
// pure function will happily state a row for a project with no sessions on it and every stray still
// running, and for three months nothing could hand it one - the roots were taken from the live rows
// alone, so a checkout stopped being accounted for in the same tick its last session closed.
//
// THAT IS THE ONE STATE THE SECTION EXISTS FOR ("a fan-out whose session has since been closed",
// MachineLoadRollup's own motivation), and the defect had a passing assertion sitting on top of it:
// `rows(sessions: [], strays: …)` is green and always was. An assertion of a rule is not an
// assertion of the thing that feeds it.
@MainActor
func runProjectLoadChecks() {
    let accounting = ProjectLoadAccounting()
    // A directory that really exists, because the root is resolved through `realpath` and a made-up
    // path would be compared against its own unresolved spelling.
    let directory = NSTemporaryDirectory()
    let root = MachineLoadRollup.resolvedPath(directory)
    let board = [SessionRosterStore.SessionRow(id: "100", record: nil, cwd: directory)]

    check("a project one of the board's sessions is working in is accounted against",
          accounting.roots(of: board) == ["100": root] && accounting.accounted == [root])
    // THE SESSION CLOSES AND ITS DEV SERVER DOES NOT. The board no longer names this directory at
    // all, and everything the page is about to say about it depends on it still being a root: the
    // strays are found by matching working directories against these, so a project dropped here has
    // no processes, no row, and no way back onto the page.
    check("…and stays accounted for on the tick its last session leaves the board",
          accounting.roots(of: []).isEmpty && accounting.accounted == [root])
    let busy = accounting.load(sessions: [], strays: [.max: root], at: Date())
    check("…which is what lets a checkout with no session left still state what it is running",
          busy.projects.map(\.root) == [root] && busy.projects.first?.sessions == 0
              && busy.projects.first?.strayProcesses == 1)
    check("…and the section is drawn for it, that being the state it exists for",
          MachineLoadRollup.isWorthDrawing(busy))
    check("…while it is still watched, so the next tick looks again",
          accounting.accounted == [root])
    // AND IT LEAVES ON THE TICK THAT FINDS NOTHING, which is what stops this growing without bound:
    // kept against a clock, every project this app had ever seen would be walked for forever.
    check("a project with no session and nothing running in it is dropped, not kept on a clock",
          accounting.load(sessions: [], strays: [:], at: Date()).projects.isEmpty
              && accounting.accounted.isEmpty)
}
