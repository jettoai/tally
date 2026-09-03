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
// So the readings here are INJECTED rather than taken from the machine, and so is what the machine
// says became of a member that has left the pool: two ticks, real numbers, and the figure a row
// would draw. That is the only way an assertion can state a rate at all - the pids a real pass would
// sample are gone by the time anything could assert about them, and a real process cannot be asked
// to die on one tick and be collected on the next.
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
    let busy = accounting.load(sessions: [], strays: [.max: root], at: t0)
    check("…which is what lets a checkout with no session left still state what it is running",
          busy.projects.map(\.root) == [root] && busy.projects.first?.sessions == 0
              && busy.projects.first?.strayProcesses == 1)
    check("…and the section is drawn for it, that being the state it exists for",
          MachineLoadRollup.isWorthDrawing(busy))
    check("…while it is still watched, so the next tick looks again",
          accounting.accounted == [root])
    check("a project with no session and nothing left in it is dropped, not kept on a clock",
          accounting.load(sessions: [], strays: [:], at: t0).projects.isEmpty
              && accounting.accounted.isEmpty)

    // MARK: what never enters the pool at all

    // TALLY'S OWN PROCESSES ARE THE METER, NOT THE WORK, and this is the one reading that had not
    // been told: every card takes its own family out (`ProcessTree.ownFamily`), while the Projects
    // row counted an orphaned hook of ours as a stray of whatever checkout it had been working in.
    // Driven with THIS process as the candidate, which is the one pid an assertion can be sure is
    // ours and is really on the machine: its working directory is the checkout the suite runs in,
    // so it is a stray of that project by every other test in `strays`.
    let here = MachineLoadRollup.resolvedPath(FileManager.default.currentDirectoryPath)
    let me = ProcessIdentity(pid: getpid(), parent: 1, group: getpid(), startedAt: 0)
    check("a process of Tally's own working in a checkout is not that project's stray",
          accounting.strays(among: [me], claimed: [], adopted: [:], board: [],
                            roots: [here]).strays.isEmpty)
    // WHAT THIS ASSERTION DOES AND DOES NOT REACH, said rather than implied: the pid it offers is
    // the harness itself, so what it pins is that the pool asks the ownership question at all
    // (remove the test and this pid becomes that project's stray). The BUNDLE half of the same rule
    // - a hook running out of Tally.app beside the app's own binary - is a pure rule with its own
    // assertions next door (processtreechecks.swift, `ownFamily`), because no assertion here can
    // put a second process of ours on the machine to be found.
    // AND THE SHELL THE SESSION IS BEING READ IN IS NOT ITS CHECKOUT'S LEFTOVER, which is the
    // defect this pair pins: an interactive `-/bin/zsh` sitting in the project, in nobody's tree
    // because the supervisor is its CHILD rather than its parent, was a stray of that project for
    // as long as the terminal tab stayed open. Measured on this machine (2026-09-03): every project
    // on the board read exactly one stray and in every case it was that shell, so the amber count
    // the unclaimed card exists for was permanently one and permanently wrong.
    //
    // DRIVEN WITH A REAL PROCESS AND TWO PARENT MAPS, because only a real pid has a working
    // directory to be read: this harness's own PARENT is the shell the suite was started from, its
    // directory is the checkout, and it is nobody's family (`ownFamily` answers about Tally's
    // bundle, not about bash). The board names THIS process as the session, and the only thing that
    // changes between the two readings is whether the shell is above it.
    let shell = getppid()
    let session = SessionRosterStore.SessionRow(id: "\(getpid())", record: nil,
                                                cwd: FileManager.default.currentDirectoryPath)
    func table(shellIsHost: Bool) -> [ProcessIdentity] {
        [ProcessIdentity(pid: shell, parent: 1, group: shell, startedAt: 0),
         ProcessIdentity(pid: getpid(), parent: shellIsHost ? shell : 1, group: getpid(),
                         startedAt: 0)]
    }
    // The fixture's own precondition, asserted rather than assumed: both readings below are about a
    // real process, and a run whose parent had gone would make the pair green by having nothing to
    // find (`workingDirectory` answers nothing for a pid the machine no longer holds).
    check("the harness really was started from a shell sitting in this checkout",
          shell > 1
              && MachineLoadRollup.workingDirectory(of: shell)
                  .flatMap { MachineLoadRollup.project(of: $0, roots: [here]) } == here)
    check("the shell a supervisor was started from is the session's host, not the project's stray",
          accounting.strays(among: table(shellIsHost: true), claimed: [getpid()], adopted: [:],
                            board: [session], roots: [here]).strays.isEmpty)
    // THE CONTROL, and it is the same process read the same way: with the session started somewhere
    // else, that very shell is work in this checkout that no card accounts for - which is the whole
    // reading the unclaimed card is drawn for, and what a rule that simply dropped every shell
    // would have thrown away with the false positive.
    check("…while the same shell, with no session under it, is still that project's leftover",
          accounting.strays(among: table(shellIsHost: false), claimed: [getpid()], adopted: [:],
                            board: [session], roots: [here]).strays == [shell: here])
    check("…and the pool asks that of the program on disk, which is the rule the cards use",
          ProcessTree.ownFamily([200, 300], root: 100, executable: {
              [100: "/Applications/Tally.app/Contents/MacOS/Tally",
               200: "/Applications/Tally.app/Contents/Resources/tally",
               300: "/opt/homebrew/bin/node"][$0]
          }) == [100, 200])

    // MARK: the readings, over two ticks

    // What the pool would report, handed to the accounting instead of read off the machine.
    var handed = ProcessResourceSample(times: [:], childTimes: [:], at: t0)
    func hand(_ times: [pid_t: Double], child: [pid_t: Double] = [:],
              memory: [pid_t: UInt64] = [:], born: [pid_t: Int64] = [:], at moment: Date) {
        handed = ProcessResourceSample(times: times, childTimes: child, memory: memory, at: moment,
                                       startedAt: born)
    }
    // What the machine says became of a departed member, which is the other half of what decides a
    // rate and the half no fixture of readings alone can state: a member that has died and not been
    // collected reads differently from one that has, one tick apart.
    var became: [pid_t: ProcessDeparture] = [:]
    func pool() -> ProjectLoadAccounting {
        ProjectLoadAccounting(sample: { pids, _ in handed.narrowed(to: pids) },
                              departure: { became[$0] ?? .collected })
    }
    // 900 is a dev server burning half a core throughout, so the truth in every case below is 50%;
    // 901 is a helper that has been running for ten minutes.
    let later = t0.addingTimeInterval(2)
    let last = t0.addingTimeInterval(4)

    // A MEMBER OF THE POOL REAPS ANOTHER, which is the ordinary shape of a stray pool rather than an
    // edge of it: what is in there is a shell and its job, or a server and its workers. The dead
    // one's whole life arrives in the survivor's child counter, and read as fresh work it is that
    // life divided by one tick - 30050% here, and unbounded in general.
    let reaping = pool()
    became = [:]
    hand([900: 10, 901: 600], at: t0)
    _ = reaping.load(sessions: [], strays: [900: root, 901: root], at: t0)
    hand([900: 11], child: [900: 600], at: later)
    let reaped = reaping.load(sessions: [], strays: [900: root], at: later)
    check("a pool member reaping another reads what the pool is doing, not what the dead one did",
          reaped.projects.first?.cpuPercent == 50)

    // AND DEATH AND COLLECTION ARE TWO EVENTS THAT NOTHING MAKES LAND IN ONE INTERVAL. The table
    // drops a process at its exit and its seconds arrive at its collection, so a pool that settles
    // on the table settles a tick before the arrival it is cancelling: the credit comes off a tick
    // with nothing to take it off (0%) and the arrival lands on the next one with nothing left to
    // cancel it (30050%, the very figure this section was written to remove). Waited for instead,
    // both ticks read what 900 is actually doing.
    let lingering = pool()
    became = [901: .ended]
    hand([900: 10, 901: 600], at: t0)
    _ = lingering.load(sessions: [], strays: [900: root, 901: root], at: t0)
    hand([900: 11], at: later)
    let unreaped = lingering.load(sessions: [], strays: [900: root], at: later)
    check("a member that has died and not been collected takes nothing off the tick that finds it",
          unreaped.projects.first?.cpuPercent == 50)
    became = [901: .collected]
    hand([900: 12], child: [900: 600], at: last)
    let arrived = lingering.load(sessions: [], strays: [900: root], at: last)
    check("…and settles on the tick its seconds actually arrive, a whole tick after it died",
          arrived.projects.first?.cpuPercent == 50)

    // A MEMBER IS TAKEN BACK ONTO A CARD, which is this app's own feature succeeding: it is alive
    // and counted elsewhere, so there is nothing to settle. Credited anyway, every successful
    // adoption blanked its project's row for two ticks.
    let adopting = pool()
    became = [901: .living(startedAt: nil)]
    hand([900: 10, 901: 600], at: t0)
    _ = adopting.load(sessions: [], strays: [900: root, 901: root], at: t0)
    hand([900: 11], at: later)
    let adopted = adopting.load(sessions: [], strays: [900: root], at: later)
    check("a pool member taken back onto a card leaves the rest of the pool reading true",
          adopted.projects.first?.cpuPercent == 50)
    // AND IS NOT WAITED FOR AFTERWARDS, which is what separates it from the one above: it is on a
    // card now, so its death is that card's arrival to cancel and not this pool's. Waited for here
    // too, it would blank this row on whatever tick it eventually dies on.
    became = [901: .collected]
    hand([900: 12], at: last)
    let after = adopting.load(sessions: [], strays: [900: root], at: last)
    check("…and nothing of it is settled on the tick it eventually dies on",
          after.projects.first?.cpuPercent == 50)

    // WHAT THAT ASSUMES, ASSERTED RATHER THAN ASSUMED AWAY: that whoever collects it later is not in
    // this pool. It usually is not (a job on a card is collected by the card, or by launchd), and
    // there are ways out of a pool where it is - the scratchpad signal adopts a process whose parent
    // is still a stray, a member's directory moves under another root while its parent's does not.
    // Then the arrival lands with no credit to meet it and the clamp at zero does nothing, because
    // this error is POSITIVE. Not repaired: settling across pools means one ledger for the machine
    // rather than one per project (`ProcessResourceSample.pairing(with:departure:)` names the cost).
    let strandedCredit = pool()
    became = [901: .living(startedAt: nil)]
    hand([900: 10, 901: 600], at: t0)
    _ = strandedCredit.load(sessions: [], strays: [900: root, 901: root], at: t0)
    hand([900: 11], at: later)
    _ = strandedCredit.load(sessions: [], strays: [900: root], at: later)
    became = [:]
    hand([900: 12], child: [900: 600], at: last)
    let stranded = strandedCredit.load(sessions: [], strays: [900: root], at: last)
    check("a member that left alive and is reaped by a survivor still spikes the row it left",
          stranded.projects.first?.cpuPercent == 30050)

    // COLLECTED BETWEEN THE READING AND THE QUESTION, which is the one window waiting at the death
    // cannot close: the pool is sampled, and each departure is asked about microseconds afterwards.
    // A member collected in between is judged `.collected` against counters taken before its seconds
    // landed, so the credit is produced a tick before the arrival - 0% and then 30050% if the tick
    // throws it away. Handed to the next pair instead, the spike is bounded by the interval.
    let racing = pool()
    became = [901: .collected]
    hand([900: 10, 901: 600], at: t0)
    _ = racing.load(sessions: [], strays: [900: root, 901: root], at: t0)
    hand([900: 11], at: later)
    let earlyVerdict = racing.load(sessions: [], strays: [900: root], at: later)
    check("a verdict reached after the counters were read costs one tick, not an unbounded one",
          earlyVerdict.projects.first?.cpuPercent == 0)
    hand([900: 12], child: [900: 600], at: last)
    let lateArrival = racing.load(sessions: [], strays: [900: root], at: last)
    check("…because the credit that tick could not spend meets the arrival on the next one",
          lateArrival.projects.first?.cpuPercent == 100)

    // A NUMBER THE MACHINE HANDS ON WHILE THE POOL IS WAITING ON IT. 901 dies, is waited for, is
    // collected, and its pid is given to a new process in the same pool. By number alone that is a
    // survivor whose counters went backwards, and the 600 seconds arriving in 900 have no credit to
    // meet them. The stamps come off the table walk the tick already made, so this costs no syscall.
    let recycled = pool()
    became = [901: .ended]
    hand([900: 10, 901: 600], born: [900: 1, 901: 2], at: t0)
    _ = recycled.load(sessions: [], strays: [900: root, 901: root], at: t0)
    hand([900: 11], born: [900: 1], at: later)
    _ = recycled.load(sessions: [], strays: [900: root], at: later)
    hand([900: 12, 901: 1], child: [900: 600], born: [900: 1, 901: 9], at: last)
    let reissued = recycled.load(sessions: [], strays: [900: root, 901: root], at: last)
    check("a waited-for member whose number a new process took over is settled, not read as alive",
          reissued.projects.first?.cpuPercent == 50)

    // A LONG-LIVED PROCESS JOINS, which is what the tick after a session ends looks like: its whole
    // tree is reclassified into the pool, carrying counters cumulative since birth.
    let joining = pool()
    became = [:]
    hand([900: 10], at: t0)
    _ = joining.load(sessions: [], strays: [900: root], at: t0)
    hand([900: 11, 903: 3600], at: later)
    let joined = joining.load(sessions: [], strays: [900: root, 903: root], at: later)
    check("a process joining the pool does not state its whole life as this tick's work",
          joined.projects.first?.cpuPercent == 50)
    hand([900: 12, 903: 3601], at: last)
    let settled = joining.load(sessions: [], strays: [900: root, 903: root], at: last)
    check("…and is a rate of its own on the tick after that",
          settled.projects.first?.cpuPercent == 100)

    // MARK: what keeps a project on the books

    // THE SHELL A SESSION WAS STARTED FROM IS A STRAY OF ITS CHECKOUT FOREVER: it is the
    // supervisor's parent, so no tree reaches it, and its working directory is the repository. Kept
    // for having a ROW, it pins the Projects section to the page under an empty board, once per
    // checkout with a terminal tab still open in it (pid 3498 on this machine, 2026-09-01).
    let quiet = pool()
    became = [:]
    hand([3498: 5], memory: [3498: 3_000_000], at: t0)
    _ = quiet.load(sessions: [], strays: [3498: root], at: t0)
    check("a pool with no rate yet is kept, since nothing has been read twice",
          quiet.accounted == [root])
    hand([3498: 5], memory: [3498: 3_000_000], at: later)
    let idle = quiet.load(sessions: [], strays: [3498: root], at: later)
    check("an idle shell is still a stray of that checkout",
          idle.projects.first?.strayProcesses == 1 && idle.projects.first?.cpuPercent == 0)
    // AND ONE READING OF IT IS NOT EVIDENCE, which is what the grace period next door is for
    // (`MachineLoadRollup.idleTicksBeforeDropping`): the tick a session ends on reads 0% for
    // everything it leaves behind, by construction rather than by chance.
    check("…and one idle reading does not take the checkout off the books",
          quiet.accounted == [root])
    hand([3498: 5], memory: [3498: 3_000_000], at: last)
    _ = quiet.load(sessions: [], strays: [3498: root], at: last)
    hand([3498: 5], memory: [3498: 3_000_000], at: last.addingTimeInterval(2))
    _ = quiet.load(sessions: [], strays: [3498: root], at: last.addingTimeInterval(2))
    check("…and reading idle throughout the grace period does",
          quiet.accounted.isEmpty)

    // AND THE WAIT ITSELF LIVES EXACTLY THAT LONG, which is the other half of the same rule. A
    // member that has DIED is not a stray - no table holds it and it answers no directory - so a
    // project whose remaining strays all read idle for one tick used to be dropped, and the pool's
    // reading went with it, credit and waiting member and all. The collector's arrival then landed
    // on a first sighting or, one tick later, on nothing at all to cancel it.
    let waitingOut = pool()
    became = [901: .ended]
    hand([900: 10, 901: 600], at: t0)
    _ = waitingOut.load(sessions: [], strays: [900: root, 901: root], at: t0)
    hand([900: 10], at: later)
    let stalled = waitingOut.load(sessions: [], strays: [900: root], at: later)
    check("a project reading nothing while a dead member is waited for stays on the books",
          stalled.projects.first?.cpuPercent == 0 && waitingOut.accounted == [root])
    became = [901: .collected]
    hand([900: 11], child: [900: 600], at: last)
    let met = waitingOut.load(sessions: [], strays: [900: root], at: last)
    check("…so the credit is still there to meet the arrival, rather than the row spiking",
          met.projects.first?.cpuPercent == 50)
    // And the reading that has to survive that: a dev server holding half a gigabyte while it waits
    // for a request is exactly what somebody closed their session and went looking for.
    let holding = pool()
    hand([7000: 5], memory: [7000: 500_000_000], at: t0)
    _ = holding.load(sessions: [], strays: [7000: root], at: t0)
    hand([7000: 5], memory: [7000: 500_000_000], at: later)
    _ = holding.load(sessions: [], strays: [7000: root], at: later)
    check("a project whose leftovers hold real memory stays watched at zero CPU",
          holding.accounted == [root])
}
