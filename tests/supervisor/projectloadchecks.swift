import Foundation

// WHAT A PROJECT'S LEFTOVERS READ, AND WHICH PROJECTS A TICK LOOKS FOR AT ALL
// (Tally/Stores/ProjectLoadAccounting.swift).
//
// The rules are pure and asserted next door (machineloadchecks.swift, processtreechecks.swift).
// What is asserted HERE is what happens BETWEEN two ticks, which is the half those rules cannot
// reach, and both defects this suite exists for lived in exactly that gap:
//
//   - The pure rollup will happily state a row for a project with no session and every stray still
//     running, and for three months nothing could hand it one: the roots came off the live rows, so
//     a checkout stopped being accounted for in the same tick its last session closed. The assertion
//     of the rule was green throughout.
//   - The rate a stray pool reads had no behavioural assertion of any kind. It had a source-string
//     lock, which went red for the right line and the wrong reason: it could say the pair was
//     narrowed and could not say what the narrowing computed. A rewrite of that pairing turned a
//     50% row into a 30050% one and every suite in the repo stayed green (codex review of 904e540).
//
// So the readings here are INJECTED rather than taken from the machine: two ticks, real numbers, and
// the figure a row would draw. That is the only way an assertion can state a rate at all - the pids
// a real pass would sample are gone by the time anything could assert about them.
@MainActor
func runProjectLoadChecks() {
    // A directory that really exists, because the root is resolved through `realpath` and a made-up
    // path would be compared against its own unresolved spelling.
    let directory = NSTemporaryDirectory()
    let root = MachineLoadRollup.resolvedPath(directory)
    let board = [SessionRosterStore.SessionRow(id: "100", record: nil, cwd: directory)]
    let t0 = Date(timeIntervalSince1970: 1_786_600_000)

    // MARK: which projects the next tick looks for

    let accounting = ProjectLoadAccounting()
    check("a project one of the board's sessions is working in is accounted against",
          accounting.roots(of: board) == ["100": root] && accounting.accounted == [root])
    // THE SESSION CLOSES AND ITS DEV SERVER DOES NOT. The board no longer names this directory at
    // all, and everything the page is about to say about it depends on it still being a root: the
    // strays are found by matching working directories against these, so a project dropped here has
    // no processes, no row, and no way back onto the page.
    check("…and stays accounted for on the tick its last session leaves the board",
          accounting.roots(of: []).isEmpty && accounting.accounted == [root])
    let busy = accounting.load(sessions: [], strays: [.max: root], alive: [.max], at: t0)
    check("…which is what lets a checkout with no session left still state what it is running",
          busy.projects.map(\.root) == [root] && busy.projects.first?.sessions == 0
              && busy.projects.first?.strayProcesses == 1)
    check("…and the section is drawn for it, that being the state it exists for",
          MachineLoadRollup.isWorthDrawing(busy))
    check("…while it is still watched, so the next tick looks again",
          accounting.accounted == [root])
    check("a project with no session and nothing left in it is dropped, not kept on a clock",
          accounting.load(sessions: [], strays: [:], alive: [], at: t0).projects.isEmpty
              && accounting.accounted.isEmpty)

    // MARK: the readings, over two ticks

    // What the pool would report, handed to the accounting instead of read off the machine.
    var handed = ProcessResourceSample(times: [:], childTimes: [:], at: t0)
    func hand(_ times: [pid_t: Double], child: [pid_t: Double] = [:],
              memory: [pid_t: UInt64] = [:], at moment: Date) {
        handed = ProcessResourceSample(times: times, childTimes: child, memory: memory, at: moment)
    }
    func pool() -> ProjectLoadAccounting {
        ProjectLoadAccounting { pids, _ in handed.narrowed(to: pids) }
    }
    // 900 is a dev server burning half a core throughout, so the truth in every case below is 50%;
    // 901 is a helper that has been running for ten minutes.
    let later = t0.addingTimeInterval(2)

    // A MEMBER OF THE POOL REAPS ANOTHER, which is the ordinary shape of a stray pool rather than an
    // edge of it: what is in there is a shell and its job, or a server and its workers. The dead
    // one's whole life arrives in the survivor's child counter, and read as fresh work it is that
    // life divided by one tick - 30050% here, and unbounded in general.
    let reaping = pool()
    hand([900: 10, 901: 600], at: t0)
    _ = reaping.load(sessions: [], strays: [900: root, 901: root], alive: [900, 901], at: t0)
    hand([900: 11], child: [900: 600], at: later)
    let reaped = reaping.load(sessions: [], strays: [900: root], alive: [900], at: later)
    check("a pool member reaping another reads what the pool is doing, not what the dead one did",
          reaped.projects.first?.cpuPercent == 50)

    // A MEMBER IS TAKEN BACK ONTO A CARD, which is this app's own feature succeeding: it is alive
    // and counted elsewhere, so there is nothing to settle. Credited anyway, every successful
    // adoption blanked its project's row for two ticks.
    let adopting = pool()
    hand([900: 10, 901: 600], at: t0)
    _ = adopting.load(sessions: [], strays: [900: root, 901: root], alive: [900, 901], at: t0)
    hand([900: 11], at: later)
    let adopted = adopting.load(sessions: [], strays: [900: root], alive: [900, 901], at: later)
    check("a pool member taken back onto a card leaves the rest of the pool reading true",
          adopted.projects.first?.cpuPercent == 50)

    // A LONG-LIVED PROCESS JOINS, which is what the tick after a session ends looks like: its whole
    // tree is reclassified into the pool, carrying counters cumulative since birth.
    let joining = pool()
    hand([900: 10], at: t0)
    _ = joining.load(sessions: [], strays: [900: root], alive: [900], at: t0)
    hand([900: 11, 903: 3600], at: later)
    let joined = joining.load(sessions: [], strays: [900: root, 903: root], alive: [900, 903],
                              at: later)
    check("a process joining the pool does not state its whole life as this tick's work",
          joined.projects.first?.cpuPercent == 50)
    hand([900: 12, 903: 3601], at: t0.addingTimeInterval(4))
    let settled = joining.load(sessions: [], strays: [900: root, 903: root], alive: [900, 903],
                               at: t0.addingTimeInterval(4))
    check("…and is a rate of its own on the tick after that",
          settled.projects.first?.cpuPercent == 100)

    // MARK: what keeps a project on the books

    // THE SHELL A SESSION WAS STARTED FROM IS A STRAY OF ITS CHECKOUT FOREVER: it is the
    // supervisor's parent, so no tree reaches it, and its working directory is the repository. Kept
    // for having a ROW, it pins the Projects section to the page under an empty board, once per
    // checkout with a terminal tab still open in it (pid 3498 on this machine, 2026-09-01).
    let quiet = pool()
    hand([3498: 5], memory: [3498: 3_000_000], at: t0)
    _ = quiet.load(sessions: [], strays: [3498: root], alive: [3498], at: t0)
    check("a pool with no rate yet is kept, since nothing has been read twice",
          quiet.accounted == [root])
    hand([3498: 5], memory: [3498: 3_000_000], at: later)
    let idle = quiet.load(sessions: [], strays: [3498: root], alive: [3498], at: later)
    check("an idle shell is still a stray of that checkout",
          idle.projects.first?.strayProcesses == 1 && idle.projects.first?.cpuPercent == 0)
    check("…and is not work, so the project stops being watched for it",
          quiet.accounted.isEmpty)
    // And the reading that has to survive that: a dev server holding half a gigabyte while it waits
    // for a request is exactly what somebody closed their session and went looking for.
    let holding = pool()
    hand([7000: 5], memory: [7000: 500_000_000], at: t0)
    _ = holding.load(sessions: [], strays: [7000: root], alive: [7000], at: t0)
    hand([7000: 5], memory: [7000: 500_000_000], at: later)
    _ = holding.load(sessions: [], strays: [7000: root], alive: [7000], at: later)
    check("a project whose leftovers hold real memory stays watched at zero CPU",
          holding.accounted == [root])
}
