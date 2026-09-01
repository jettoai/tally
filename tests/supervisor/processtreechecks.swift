import Foundation

// WHAT A SESSION'S PROCESS TREE COSTS, as the card's fourth line states it (Tally/Core/
// ProcessTreeStats.swift). Four rules, all pure, all stated here without a process in sight:
//
//   1. WHICH PIDS ARE IN THE SESSION: everything under the supervisor by parentage, AND everything
//      left in its job. Parentage alone loses the process the whole feature is for - a background
//      server outlives the shell that started it and macOS re-parents it to launchd.
//   2. WHAT TWO CUMULATIVE CPU READINGS MEAN, which is why they are held per pid AND why the
//      children a process has already buried are read too: an agent's work is mostly commands that
//      are born and finished between two ticks, and no sample ever sees those alive. A death and
//      the collection that accounts for it land on different ticks, so what one pair cannot settle
//      is carried to the next one - for exactly one tick, because a credit nothing will ever settle
//      would otherwise eat real work in silence.
//   3. WHICH OF THOSE PIDS ARE TALLY'S OWN, and so are the meter rather than the thing metered: the
//      supervisor is in every tree by construction, and the test is the program on disk rather than
//      the name, because a `tally` built in this repository is work somebody is watching.
//   4. WHICH PROCESS TO BLAME for a number, when a single one accounts for more than half of it.
//
// HOW THE LINE READS is one file over (processtreelinechecks.swift), along the seam the source is
// split on; WHICH of these readings is worth a warning is in a third (footprintalertchecks.swift).
//
// The libproc side of that file is thin wrappers with no decisions in them, with one exception that
// is asserted here against an independent oracle: what UNIT its counters are in.

func runProcessTreeChecks() {
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)

    // A start time derived from the pid, so every invented process has one of its own and none of
    // them collides - the same fixture shape the supervisor's own identity checks use
    // (transcriptidentitychecks.swift).
    func proc(_ pid: pid_t, ppid: pid_t, group: pid_t) -> ProcessIdentity {
        ProcessIdentity(pid: pid, parent: ppid, group: group,
                        startedAt: 1_786_000_000_000_000 + Int64(pid) * 1_000)
    }
    // A machine, in the shape a real one has (measured 2026-08-15): launchd (1), the tab's login
    // shell (90) leading its own job, and a supervisor (100) started as a job of its own - so it
    // LEADS the group its Claude Code (200), that session's shell (300) and its dev server (400)
    // all carry. 500 is another session's supervisor, 600 somebody's editor.
    let machine = [proc(1, ppid: 0, group: 1), proc(90, ppid: 1, group: 90),
                   proc(100, ppid: 90, group: 100), proc(200, ppid: 100, group: 100),
                   proc(300, ppid: 200, group: 100), proc(400, ppid: 300, group: 100),
                   proc(500, ppid: 1, group: 500), proc(600, ppid: 1, group: 600)]

    // MARK: which pids belong to the session

    check("the tree is the supervisor and everything under it, however deep",
          ProcessTree.members(root: 100, processes: machine) == [100, 200, 300, 400])
    check("…and neither a neighbouring session nor the tab's own shell is in it",
          !ProcessTree.members(root: 100, processes: machine).contains(500)
              && !ProcessTree.members(root: 100, processes: machine).contains(90))
    check("a leaf session is just itself",
          ProcessTree.members(root: 600, processes: machine) == [600])
    // The board draws a card for a session the last scan found, and a supervisor can be gone by the
    // time this runs. Nothing to measure is nothing to say, not a zero.
    check("a root the machine no longer has is no tree at all",
          ProcessTree.members(root: 999, processes: machine).isEmpty)
    // Pid numbers are reused, so a parent chain CAN come back on itself. Without the visited set
    // this spins forever, taking the panel with it.
    check("a parent chain that loops does not hang the walk",
          ProcessTree.members(root: 10, processes: [proc(10, ppid: 11, group: 10),
                                                    proc(11, ppid: 10, group: 10)]) == [10, 11])

    // MARK: the background server that outlived its shell

    // THE CASE THE PPID WALK LOSES, and the one the line exists for. `sh -c 'npm run dev &'` leaves
    // within the millisecond and macOS re-parents the server to launchd; verified live on this
    // machine (2026-08-15): a shell-backgrounded process reads `ppid 1 pgid <unchanged>`, the walk
    // by parentage found 2 processes and missed it, and this rule found 3 and did not.
    let reparented = [proc(1, ppid: 0, group: 1), proc(90, ppid: 1, group: 90),
                      proc(100, ppid: 90, group: 100), proc(200, ppid: 100, group: 100),
                      proc(400, ppid: 1, group: 100)]   // the shell that started it is gone
    check("a server re-parented to launchd is still the session's, by its job",
          ProcessTree.members(root: 100, processes: reparented) == [100, 200, 400])
    // The orphan goes on working: a dev server forks its own watchers after it is orphaned, and
    // those are as much the session's as it is.
    check("…and so is what that orphan starts afterwards, in the job or out of it",
          ProcessTree.members(root: 100, processes: reparented
                                  + [proc(450, ppid: 400, group: 100),
                                     proc(460, ppid: 400, group: 460)]) == [100, 200, 400, 450, 460])
    // A GROUP IS ONLY THE SESSION'S WHEN THE SESSION IS IN IT, and the case that matters is a group
    // that outlived its leader: 700 and 701 are what is left of a job whose leader 100 exited, and
    // pid 100 has since been handed to this supervisor - which joined its shell's job instead of
    // leading one. Trusting the number alone would put a dead stranger's processes on the card.
    let stale = [proc(90, ppid: 1, group: 90), proc(91, ppid: 90, group: 90),
                 proc(100, ppid: 90, group: 90), proc(200, ppid: 100, group: 90),
                 proc(700, ppid: 1, group: 100), proc(701, ppid: 700, group: 100)]
    check("a supervisor that leads no job of its own falls back to parentage alone",
          ProcessTree.members(root: 100, processes: stale) == [100, 200])

    // MARK: the counters are in the units this file thinks they are

    // THE ORACLE IS `getrusage`, because the trap here is silent and hardware-specific: the
    // `rusage_info` counters are mach absolute time, which IS nanoseconds on Intel and is 41.67ns
    // per unit on Apple Silicon. Read as nanoseconds, every reading on this machine was a
    // twenty-fourth of the truth, and nothing about the number looks wrong. Asserted rather than
    // commented, because a future simplification "removing a pointless multiply" is exactly how it
    // comes back.
    func selfCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
    // Two readings of the SAME total, taken at the same instant, rather than two deltas over a
    // stretch of spinning: both counters are this process's whole CPU life, so the comparison is
    // arithmetic rather than timing, and a machine under load cannot make it wobble.
    //
    // AND THE PROCESS BURNS ITS OWN FLOOR FIRST, rather than relying on the suite ahead of it
    // having spent one. The 24x error this exists to catch is only visible above the noise of two
    // counters sampled a few microseconds apart, so the guard needs a tenth of a second of CPU
    // behind it - and it used to get that from whatever ran before it, which made the assertion
    // true of the SUITE rather than of this file. Run on its own it then failed for having nothing
    // to measure, in a way indistinguishable from the unit bug. So the floor is earned here, and
    // the one condition that is not about units says so in its own words.
    func burn(_ seconds: Double) {
        let until = selfCPUSeconds() + seconds
        var spin = 0
        while selfCPUSeconds() < until { spin &+= 1 }
        precondition(spin > 0)
    }
    let me = getpid()
    burn(0.1)
    let selfSample = ProcessTree.resourceSample(of: [me])
    let measured = selfSample.times[me] ?? 0
    let oracle = selfCPUSeconds()
    // Separated from the check below on purpose: "there was nothing to compare" and "the comparison
    // came out wrong" are two different failures, and one line reading false for either is how a
    // machine that could not spin gets read as a machine whose timebase is wrong.
    check("the oracle has enough CPU behind it for the unit check to mean anything", oracle > 0.05)
    check("the CPU counters are read in the units the machine keeps them in",
          measured > oracle * 0.85 && measured < oracle * 1.15)
    // The other two counters come out of the same record and are plain bytes. This process is a
    // running Swift binary, so both are facts about it: it holds memory, and it has printed.
    check("the memory and disk counters come out of the same reading, in bytes",
          (selfSample.memory[me] ?? 0) > 1_000_000
              && selfSample.memoryBytes == selfSample.memory.values.reduce(0, +)
              && selfSample.diskWritten[me] != nil)
    // The reading both the name and the family test are made of: the path of the program a pid is
    // running, whole rather than truncated, and the same answer whether one pid is asked or many.
    check("a live pid's program is read as a whole path",
          ProcessTree.executablePath(of: me).map {
              ($0 as NSString).lastPathComponent
                  == (CommandLine.arguments[0] as NSString).lastPathComponent && $0.hasPrefix("/")
          } == true)
    check("…and the whole-tree reading is the same answer, per pid",
          ProcessTree.executablePaths(of: [me, -1]) == [me: ProcessTree.executablePath(of: me)!])
    check("…while a pid the machine does not have says nothing at all",
          ProcessTree.executablePath(of: -1) == nil)

    // MARK: which of a tree's processes are Tally's own

    // A session's tree as it really is: the supervisor at its root, a second `tally` of ours under
    // it (the status line, run on every prompt), the app itself, the Claude Code that IS the work,
    // and a `tally` built in this repository, which is work somebody is watching and not ours.
    let supervisorPath = "/Applications/Tally.app/Contents/Resources/tally"
    let programs: [pid_t: String] = [
        100: supervisorPath,
        101: supervisorPath,
        102: "/Applications/Tally.app/Contents/MacOS/Tally",
        200: "/Users/a/.local/share/claude/versions/2.1.233",
        300: "/Users/a/workspace/tally/.build/release/tally",
        400: "/usr/bin/caffeinate",
    ]
    let tree: Set<pid_t> = [100, 101, 102, 200, 300, 400]
    let family = ProcessTree.ownFamily(tree, root: 100) { programs[$0] }
    check("the supervisor and everything running the same program are the app's own",
          family == [100, 101, 102])
    check("…so what is measured is the work, a repo build of the same program included",
          tree.subtracting(family) == [200, 300, 400])
    // The bundle is a prefix that ends in its own SEPARATOR, so a neighbouring bundle whose path
    // merely begins with ours is not swallowed. The case is not hypothetical: a Sparkle update
    // leaves `Tally.app.old` beside the new one while it swaps them over.
    check("a bundle whose path merely begins with ours is not ours",
          ProcessTree.ownFamily([100, 500], root: 100) {
              $0 == 100 ? supervisorPath : "/Applications/Tally.app.old/Contents/MacOS/Tally"
          } == [100])
    check("the bundle is read off the path, and only when there is one",
          ProcessTree.appBundle(ofExecutablePath: supervisorPath) == "/Applications/Tally.app/"
              && ProcessTree.appBundle(ofExecutablePath: "/usr/local/bin/tally") == nil)
    // A supervisor with no bundle around it (a build run from a checkout) still knows its own
    // program, so a second copy of it is still ours.
    check("a supervisor outside a bundle claims its own program and nothing else",
          ProcessTree.ownFamily([1, 2, 3], root: 1) {
              [1: "/tmp/build/tally", 2: "/tmp/build/tally", 3: "/tmp/build/other"][$0]
          } == [1, 2])
    // The one thing that is true whatever the machine says: the root is the supervisor.
    check("a root whose program cannot be read gives up itself and nothing else",
          ProcessTree.ownFamily(tree, root: 100) { _ in nil } == [100])
    // A VERSION IS NOT A NAME, and this is the case that matters rather than a curiosity: Claude
    // Code installs itself as a file NAMED for its version, so the process this line will most
    // often have to blame would otherwise be printed as "(2.1.233)". All four paths below were
    // read off this machine on 2026-08-15 (`proc_pidpath`).
    check("a program installed under its version number is named for the program",
          ProcessTree.displayName(forPath: "/Users/a/.local/share/claude/versions/2.1.233")
              == "claude")
    // The same shape with the conventional `v` on the number, which is how most managers spell it.
    check("…and a version with the conventional v on it reads the same way",
          ProcessTree.displayName(forPath: "/Users/a/.local/share/bun/versions/v1.2.3") == "bun")
    // The walk STARTS on a version, so a name is never walked past: `bin` is stepped over on the
    // way up and is not a reason to reject the name a program actually has.
    check("an ordinary name is taken as it stands, container words and all",
          ProcessTree.displayName(forPath: "/opt/homebrew/Cellar/uv/0.9.2/bin/uv") == "uv"
              && ProcessTree.displayName(forPath: "/Applications/Tally.app/Contents/Helpers/tally")
                  == "tally"
              && ProcessTree.displayName(forPath: "/bin/zsh") == "zsh")
    // Letters make it a name that carries a number, which is most of the interpreters on a machine.
    check("…including the ones whose names end in digits",
          ProcessTree.displayName(forPath: "/Users/a/.local/share/uv/python/cpython-3.12.9/bin/python3.12")
              == "python3.12")
    check("a path with nothing nameable in it names nothing",
          ProcessTree.displayName(forPath: "") == nil
              && ProcessTree.displayName(forPath: "/versions/2.1.233") == nil)

    // MARK: what two readings say about CPU

    func sample(_ times: [pid_t: Double], child: [pid_t: Double] = [:],
                memory: [pid_t: UInt64] = [:], written: [pid_t: UInt64] = [:],
                ours: Set<pid_t> = [], at offset: TimeInterval) -> ProcessResourceSample {
        ProcessResourceSample(times: times, childTimes: child, memory: memory, diskWritten: written,
                              at: t0.addingTimeInterval(offset), ours: ours)
    }
    func percent(from previous: ProcessResourceSample?, to current: ProcessResourceSample,
                 carry: ProcessCPUCarry = ProcessCPUCarry()) -> Double? {
        ProcessTree.cpuPercent(from: previous, to: current, carry: carry).percent
    }
    let first = sample([100: 1, 200: 4], at: 0)
    // Two seconds later: the supervisor spent nothing, Claude Code spent one second, and a shell
    // that did not exist before spent half of one.
    let second = sample([100: 1, 200: 5, 300: 0.5], at: 2)
    check("a first reading says nothing, because a cumulative counter needs two",
          percent(from: nil, to: second) == nil)
    check("two readings are the work between them over the time between them",
          percent(from: first, to: second) == 75)
    // A pid born inside the interval spent everything it has inside it, by definition.
    check("…counting a process that appeared during the interval in full",
          percent(from: sample([:], at: 0), to: sample([300: 1], at: 2)) == 50)
    check("two readings taken at the same instant say nothing rather than dividing by nothing",
          percent(from: first, to: sample([100: 2], at: 0)) == nil)
    // The only way a pid's own counter goes backwards is the number naming a different process now.
    check("a counter that went backwards does not count as work",
          percent(from: sample([100: 9], at: 0), to: sample([100: 1], at: 2)) == 0)

    // MARK: the work of processes no sample ever saw alive

    // THE READING THAT WAS 0.007% FOR HALF A CORE. A command that starts and finishes between two
    // ticks is in neither sample, and its whole cost is in its parent's child counter - which is
    // where most of a session's CPU is, since an agent's work is short commands.
    check("a child born and buried between two ticks is counted, through its parent's counter",
          percent(from: sample([100: 1], child: [100: 0], at: 0),
                  to: sample([100: 1], child: [100: 1], at: 2)) == 50)
    // A long-lived child was already counted while it was alive, and its whole life lands in the
    // parent's counter the moment it is collected. Without taking its last own reading back off,
    // every long command would be counted twice at the tick it finished.
    check("…while a long-lived child that dies is not counted twice for the life it already spent",
          percent(from: sample([100: 1, 300: 3], child: [100: 0], at: 0),
                  to: sample([100: 1], child: [100: 4], at: 2)) == 50)
    // And the same for what IT had already buried: a shell that ran commands carries their CPU in
    // its own child counter, which was counted at the tick each of them finished, and which is
    // folded into the parent's counter when the shell itself is collected.
    check("…nor for the grandchildren it had already buried and been counted for",
          percent(from: sample([100: 1, 300: 3], child: [100: 0, 300: 6], at: 0),
                  to: sample([100: 1], child: [100: 10], at: 2)) == 50)
    // A process that has died and not yet been collected has had its readings taken off with
    // nothing yet added back. Half a tick under is the price of never double counting.
    check("…and a death nobody has collected yet reads as nothing rather than as negative work",
          percent(from: sample([100: 1, 300: 3], child: [100: 0], at: 0),
                  to: sample([100: 1], child: [100: 0], at: 2)) == 0)

    // MARK: the death and the collection that land on different ticks

    // THE SPIKE THIS CARRY EXISTS FOR. Three ticks, one child: alive at the first, dead at the
    // second with its parent not yet having collected it, collected at the third. The credit taken
    // off at tick two has nothing to take it off (the tick reads zero), and at tick three the
    // child's WHOLE life arrives in the parent's child counter. Without the carry that is a single
    // tick reporting 150% for three seconds that were already reported while the child was alive.
    let alive = sample([100: 1, 300: 3], child: [100: 0], at: 0)
    let died = sample([100: 1], child: [100: 0], at: 2)              // dead, not yet collected
    let collected = sample([100: 1], child: [100: 3], at: 4)         // the whole life arrives
    let atDeath = ProcessTree.cpuPercent(from: alive, to: died)
    check("a death the parent has not collected hands its credit to the next reading",
          atDeath.percent == 0 && atDeath.carry == ProcessCPUCarry(theirs: 3))
    let atCollection = ProcessTree.cpuPercent(from: died, to: collected, carry: atDeath.carry)
    check("…so the tick that collects it is not a spike for a life already counted",
          atCollection.percent == 0 && atCollection.carry == ProcessCPUCarry())
    // The credit is spent on the arrival and no further: real work in the same interval is still
    // reported, less what was owed.
    let busyCollection = ProcessTree.cpuPercent(from: died,
                                                to: sample([100: 1, 400: 1], child: [100: 3], at: 4),
                                                carry: atDeath.carry)
    check("…while work done in that same interval is still counted",
          busyCollection.percent == 50)
    // AND THE CREDIT IS WRITTEN OFF AFTER ONE TICK, because a credit nothing will ever settle is
    // entirely possible: an orphan is collected by launchd, so its seconds never arrive in any
    // counter this tree can read. Carried forever, they would silently eat that much real work.
    let orphanDied = ProcessTree.cpuPercent(from: sample([100: 1, 400: 9], child: [100: 0], at: 0),
                                            to: sample([100: 1], child: [100: 0], at: 2))
    check("an orphan whose collector is outside the tree still hands its credit on once",
          orphanDied.carry == ProcessCPUCarry(theirs: 9))
    let neverSettled = ProcessTree.cpuPercent(from: sample([100: 1], child: [100: 0], at: 0),
                                              to: sample([100: 3], child: [100: 0], at: 2),
                                              carry: orphanDied.carry)
    check("…and what that tick cannot spend is written off rather than suppressing the next one",
          neverSettled.percent == 0 && neverSettled.carry == ProcessCPUCarry())
    check("…which is what keeps the tick after it honest",
          percent(from: sample([100: 3], child: [100: 0], at: 0),
                  to: sample([100: 4], child: [100: 0], at: 2), carry: neverSettled.carry) == 50)

    // MARK: the pool whose departures settle nowhere

    // A CREDIT IS ONLY EVER WORTH TAKING WHERE AN ARRIVAL IS COMING. Everything above is about a
    // TREE, where the collector is the parent standing right there; a project's strays are the
    // processes no tree holds, so launchd buries them and nothing arrives anywhere this app reads
    // (`ProjectLoadAccounting`). 900 is a dev server steadily burning half a core, 901 a helper that
    // has been running for ten minutes and leaves: its whole lifetime of CPU came off the pool it
    // could never be settled against, and the row read 0% for two ticks - once for the credit and
    // once for the carry - while 900 went on burning.
    let pool = sample([900: 10, 901: 600], child: [:], at: 0)
    let departed = sample([900: 11], child: [:], at: 2)
    check("a whole pool differenced against a departure it cannot settle reads nothing at all",
          ProcessTree.cpuPercent(from: pool, to: departed).percent == 0)
    check("…and the pair taken over the survivors reads what the survivors are actually doing",
          ProcessTree.cpuPercent(from: pool.narrowed(to: [900]), to: departed).percent == 50)
    check("…leaving no carry to blank the tick after it either",
          ProcessTree.cpuPercent(from: pool.narrowed(to: [900]), to: departed).carry
              == ProcessCPUCarry())
    // Narrowing is by pid and touches nothing else: the instant and the readings of whoever is left
    // are the same numbers, or the pair would be measuring a different interval than it says.
    check("what is kept is kept exactly as it was read",
          pool.narrowed(to: [900]).times == [900: 10] && pool.narrowed(to: [900]).at == pool.at)

    // MARK: which process is doing it

    // MORE THAN HALF, NOT HALF: a name beside a number claims one thing is doing this, and two
    // processes at exactly half each make that claim false about both of them.
    check("nobody is named when the work is split evenly",
          ProcessTree.leader(of: [100: 50, 200: 50]) == nil)
    check("…and the one past half is",
          ProcessTree.leader(of: [100: 51, 200: 49]) == 100)
    check("a leader is nobody when there is no work at all",
          ProcessTree.leader(of: [:]) == nil && ProcessTree.leader(of: [100: 0]) == nil)
    // The reading names the pid, and the store turns it into a word: what a card shows has to come
    // from the same arithmetic the percentage does, or the name would be blaming another interval.
    check("the CPU reading names the pid that burned most of the interval",
          ProcessTree.cpuPercent(from: sample([100: 1, 200: 1], at: 0),
                                 to: sample([100: 1.4, 200: 4], at: 2)).leader == 200)
    // The kernel credits a reaped child to whoever collected it, so a shell that ran the build is
    // named for the build. That is where the seconds are, and repeating it is the honest reading.
    check("…counting what a process buried as its own, the way the kernel books it",
          ProcessTree.cpuPercent(from: sample([100: 1, 200: 1], child: [100: 0], at: 0),
                                 to: sample([100: 1, 200: 1.2], child: [100: 3], at: 2)).leader == 100)
    check("a tick that reports nothing blames nobody",
          ProcessTree.cpuPercent(from: sample([100: 1, 300: 3], child: [100: 0], at: 0),
                                 to: sample([100: 1], child: [100: 0], at: 2)).leader == nil)
    // THE COLLECTOR IS NOT THE CULPRIT, and this is the case that separates the two: pid 200 leaves
    // having spent a hundred seconds, those hundred seconds land in pid 100's child counter on this
    // very tick, and the one process actually working is pid 300 with its one second. The
    // percentage already knew that (100 arriving, 100 cancelled, 1 left over the two seconds = 50%)
    // while the blame was read off the total before the cancellation, and named pid 100 for a
    // hundred seconds it did not spend (measured 2026-08-15, codex review of 57c9795).
    let reaper = ProcessTree.cpuPercent(
        from: sample([100: 1, 200: 100, 300: 1], child: [100: 0, 200: 0, 300: 0], at: 0),
        to: sample([100: 1, 300: 2], child: [100: 100, 300: 0], at: 2))
    check("a parent that only collected a departed child is not the culprit for its life",
          reaper.leader == 300 && reaper.percent == 50)
    // The cancellation lands on the arrivals it is cancelling, so a collector that ALSO did real
    // work keeps that work to its name: 100 arriving and cancelled, 4 seconds of its own left.
    check("…while the work that collector did itself is still its own",
          ProcessTree.cpuPercent(
              from: sample([100: 1, 200: 100, 300: 1], child: [100: 0, 200: 0, 300: 0], at: 0),
              to: sample([100: 5, 300: 2], child: [100: 100, 300: 0], at: 2)).leader == 100)
    // Nothing to cancel is nothing taken off: a tick with arrivals and no departure blames the
    // collector exactly as before, which is where the kernel really does put those seconds.
    check("…and an arrival nobody is cancelling still names the process it landed on",
          ProcessTree.cpuPercent(from: sample([100: 1, 200: 1], child: [100: 0], at: 0),
                                 to: sample([100: 1, 200: 1.2], child: [100: 3], at: 2))
              .leader == 100)
    // Shared out in proportion, because the kernel does not say which collector got which child:
    // two collectors take 3 and 1 of a 4-second arrival, 2 seconds of it are cancelled, and what is
    // left of each (1.5 and 0.5) is still enough for the larger one to be past half.
    let split = ProcessTree.cpuPercent(
        from: sample([100: 1, 200: 1, 900: 2], child: [100: 0, 200: 0, 900: 0], at: 0),
        to: sample([100: 1, 200: 1], child: [100: 3, 200: 1], at: 2))
    check("a cancellation is shared across the arrivals in proportion",
          split.leader == 100 && split.percent == 100)

    // MARK: what the tree is writing to disk

    // A CUMULATIVE COUNTER LIKE THE CPU ONE, differenced the same way - but with no child
    // counterpart in the kernel, so a departed pid is dropped rather than credited: there is
    // nowhere for its bytes to arrive later, and nothing to double count.
    let quiet = sample([100: 1], written: [100: 1_000, 400: 2_000_000], at: 0)
    let writing = sample([100: 1], written: [100: 1_000, 400: 26_000_000], at: 2)
    check("a first reading says nothing about a rate",
          ProcessTree.diskWrite(from: nil, to: writing).bytesPerSecond == nil)
    check("two readings are the bytes between them over the time between them",
          ProcessTree.diskWrite(from: quiet, to: writing).bytesPerSecond == 12_000_000)
    check("…and they name the process writing most of it",
          ProcessTree.diskWrite(from: quiet, to: writing).leader == 400)
    check("a pid the earlier reading never saw counts everything it has written",
          ProcessTree.diskWrite(from: sample([100: 1], written: [100: 0], at: 0),
                                to: sample([100: 1], written: [100: 0, 500: 4_000_000], at: 2))
              .bytesPerSecond == 2_000_000)
    // Unsigned counters and reused pid numbers: the subtraction has to be able to go backwards
    // without trapping, and a negative is not a measurement.
    check("a writer that left takes its bytes with it rather than reading as negative traffic",
          ProcessTree.diskWrite(from: sample([100: 1], written: [100: 5_000, 400: 90_000_000], at: 0),
                                to: sample([100: 1], written: [100: 5_000], at: 2))
              .bytesPerSecond == 0)

    // MARK: the meter is read and then left out of every number

    // WHY OURS ARE SAMPLED AT ALL, which is the whole of this section. Leaving them off the pid list
    // is what a reader expects to be enough; it is not, because the kernel folds a process's whole
    // life into whoever COLLECTED it, and one of ours is collected by Claude Code. Measured on this
    // machine (2026-08-15): a child burning a known 0.300s put 0.3308s into its parent's
    // `ri_child_user_time` at the instant it was reaped, through the same `proc_pid_rusage` call
    // this sampler makes. So they are read, and each number takes them out for itself.
    //
    // 200 is the session's Claude Code, 999 one of ours running inside it (a status line, a hook).
    let hookAlive = sample([200: 10, 999: 0.3], child: [200: 0, 999: 0], ours: [999], at: 0)
    // The hook has ended and Claude Code has collected it: its 0.3s is now in 200's child counter,
    // and 999 is gone from the tree.
    let hookReaped = sample([200: 10], child: [200: 0.3], ours: [], at: 2)
    check("what one of ours left in the counters of whoever collected it is taken back off",
          percent(from: hookAlive, to: hookReaped) == 0)
    // THE CASE THIS REPLACED, stated as the thing that must not come back: filtered off the pid list
    // instead of sampled, that same interval is the hook's whole life reported as session work.
    check("…which is the reading a pid filter alone could not reach",
          percent(from: sample([200: 10], child: [200: 0], at: 0),
                  to: sample([200: 10], child: [200: 0.3], at: 2)) == 15)
    // And while it is alive it is simply not work: its own seconds never enter the sum.
    check("one of ours burning a core is not the session burning a core",
          percent(from: sample([200: 10, 999: 0], ours: [999], at: 0),
                  to: sample([200: 10, 999: 2], ours: [999], at: 2)) == 0)
    // Nor may it be named: a card that blamed the meter would be pointing at the wrong process by
    // construction, whatever the numbers said.
    check("…and it is never the culprit, however much of the tick it holds",
          ProcessTree.cpuPercent(from: sample([200: 10, 999: 0], ours: [999], at: 0),
                                 to: sample([200: 11, 999: 9], ours: [999], at: 2)).leader == 200)
    // What one of ours COLLECTED is not the session's either: the supervisor reaps the Claude Code
    // it started, and that whole life arriving on it must not read as a tick of work.
    check("what one of ours collected is not the session's work either",
          percent(from: sample([200: 10, 999: 0], child: [999: 0], ours: [999], at: 0),
                  to: sample([200: 10, 999: 0], child: [999: 40], ours: [999], at: 2)) == 0)
    // Memory is an instant rather than an interval, so nothing has to survive a process ending and
    // the pid test is the whole of it there.
    check("the tree holds what the session holds, not what the meter holds",
          sample([200: 1, 999: 1], memory: [200: 300_000_000, 999: 2_000_000_000], ours: [999],
                 at: 0).memoryBytes == 300_000_000)
    // Disk needs no departure to cancel anything, and that is a FACT ABOUT THE KERNEL rather than a
    // simplification: `rusage_info_v6` has six `ri_child_*` counters and no disk one among them
    // (read off the SDK header, 2026-08-15), so nothing one of ours wrote can arrive anywhere else.
    let bothWriting = ProcessTree.diskWrite(
        from: sample([200: 1, 999: 1], written: [200: 0, 999: 0], ours: [999], at: 0),
        to: sample([200: 1, 999: 1], written: [200: 2_000_000, 999: 80_000_000], ours: [999], at: 2))
    check("what the meter writes is not what the session writes",
          bothWriting.bytesPerSecond == 1_000_000)
    check("…and it is not the writer to blame either", bothWriting.leader == 200)
    // The one thing sampling still cannot see, asserted so it stays a known bound rather than a
    // surprise: one of ours born AND ended inside a single interval is in neither reading, so there
    // is nothing to depart and its seconds stay where the kernel put them.
    check("one of ours that lived entirely inside one tick is still on the collector",
          percent(from: sample([200: 10], child: [200: 0], at: 0),
                  to: sample([200: 10], child: [200: 0.2], at: 2)) == 10)

    // MARK: the identity the machine hands over with a pid

    // A PID IS NOT AN IDENTITY AND THIS IS THE FIELD THAT MAKES ONE, read out of the very record
    // the parent and the group come from (`ProcessIdentity.startedAt`). Asserted against the live
    // machine rather than a fixture, because the way it fails is silent: a field that came back
    // zero for everybody would still compare equal to itself, so the port cache's guard would pass
    // for exactly the recycled pids it exists to refuse (`ProcessTree.portNames`).
    let walked = ProcessTree.liveProcesses()
    let mine = walked.first { $0.pid == getpid() }
    check("the walk says when each process began", (mine?.startedAt ?? 0) > 0)
    // AND SAYS IT AS MICROSECONDS SINCE THE EPOCH, which is the half a stability test cannot see:
    // a field carrying only the sub-second part of the reading is just as stable and just as
    // different between two live processes, and it REPEATS EVERY SECOND - so the one property this
    // number exists for, that the next holder of a pid gets a different value, would hold only by
    // luck, and the claim that it is the unit the supervisor stamps by (`ProcessStamp`) would be
    // quietly false. Bounded against the wall clock rather than against a constant, so what is
    // pinned is the unit and not merely a magnitude.
    let clock = Int64(Date().timeIntervalSince1970 * 1_000_000)
    check("…on the same clock and in the same unit the supervisor stamps a process by",
          (mine?.startedAt ?? 0) > clock - 3_600_000_000 && (mine?.startedAt ?? 0) <= clock)
    check("…the same number on a second walk of the same live process",
          mine?.startedAt == ProcessTree.liveProcesses().first { $0.pid == getpid() }?.startedAt)
    let parent = walked.first { $0.pid == getppid() }
    check("…and a different one for the process that started this one",
          parent != nil && mine?.startedAt != parent?.startedAt)
}
