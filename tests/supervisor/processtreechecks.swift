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
//   3. WHICH PROCESS TO BLAME for a number, when a single one accounts for more than half of it.
//   4. HOW THE LINE READS when a segment has nothing to say, and how many ports fit on a card.
//
// WHICH of those readings is worth a warning is one file over (footprintalertchecks.swift), and so
// is the mismatch rule it turns on; what the CARD does with a warned field is here, with the rest
// of the checks that read that source.
//
// The libproc side of that file is thin wrappers with no decisions in them, with one exception that
// is asserted here against an independent oracle: what UNIT its counters are in.

func runProcessTreeChecks() {
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)

    func proc(_ pid: pid_t, ppid: pid_t, group: pid_t) -> ProcessIdentity {
        ProcessIdentity(pid: pid, parent: ppid, group: group)
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
    // arithmetic rather than timing, and a machine under load cannot make it wobble. By the time
    // this suite reaches here it has burned seconds, which is what makes the totals meaningful.
    let me = getpid()
    let selfSample = ProcessTree.resourceSample(of: [me])
    let measured = selfSample.times[me] ?? 0
    let oracle = selfCPUSeconds()
    check("the CPU counters are read in the units the machine keeps them in",
          oracle > 0.05 && measured > oracle * 0.85 && measured < oracle * 1.15)
    // The other two counters come out of the same record and are plain bytes. This process is a
    // running Swift binary, so both are facts about it: it holds memory, and it has printed.
    check("the memory and disk counters come out of the same reading, in bytes",
          (selfSample.memory[me] ?? 0) > 1_000_000
              && selfSample.memoryBytes == selfSample.memory.values.reduce(0, +)
              && selfSample.diskWritten[me] != nil)
    // The name on the card is the executable's, not a truncation of it: this harness is compiled to
    // a binary called `run`, and the check is that the path was read and reduced to its last part.
    check("a live pid can be named, by the last component of its executable path",
          ProcessTree.name(of: me) == (CommandLine.arguments[0] as NSString).lastPathComponent)
    check("…and a pid the machine does not have is not named at all",
          ProcessTree.name(of: -1) == nil)
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
                at offset: TimeInterval) -> ProcessResourceSample {
        ProcessResourceSample(times: times, childTimes: child, memory: memory, diskWritten: written,
                              at: t0.addingTimeInterval(offset))
    }
    func percent(from previous: ProcessResourceSample?, to current: ProcessResourceSample,
                 carry: Double = 0) -> Double? {
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
          atDeath.percent == 0 && atDeath.carry == 3)
    let atCollection = ProcessTree.cpuPercent(from: died, to: collected, carry: atDeath.carry)
    check("…so the tick that collects it is not a spike for a life already counted",
          atCollection.percent == 0 && atCollection.carry == 0)
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
          orphanDied.carry == 9)
    let neverSettled = ProcessTree.cpuPercent(from: sample([100: 1], child: [100: 0], at: 0),
                                              to: sample([100: 3], child: [100: 0], at: 2),
                                              carry: orphanDied.carry)
    check("…and what that tick cannot spend is written off rather than suppressing the next one",
          neverSettled.percent == 0 && neverSettled.carry == 0)
    check("…which is what keeps the tick after it honest",
          percent(from: sample([100: 3], child: [100: 0], at: 0),
                  to: sample([100: 4], child: [100: 0], at: 2), carry: neverSettled.carry) == 50)

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

    // MARK: how the line reads

    let full = ProcessFootprint(processes: 3, cpuPercent: 12.4, listeningPorts: [3789, 5173])
    check("the line names the processes, the CPU and the ports it is holding",
          ProcessTree.line(full, unit: "procs") == "3 procs · 12% CPU · :3789 :5173")
    // A difference of two samples two seconds apart is not accurate to a decimal place, and a card
    // that printed one would be spelling out noise.
    check("…rounding the CPU to a whole point",
          ProcessTree.line(ProcessFootprint(processes: 1, cpuPercent: 0.4, listeningPorts: []),
                           unit: "proc") == "1 proc · 0% CPU")
    // EVERY SEGMENT IS OPTIONAL AND ITS SEPARATOR GOES WITH IT, the rule the identity line one file
    // over already follows: an empty field is worse than a shorter line.
    check("a tree that has only been read once carries no CPU segment",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: nil, listeningPorts: [3000]),
                           unit: "procs") == "2 procs · :3000")
    check("…and a session listening on nothing says nothing about ports",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: 5, listeningPorts: []),
                           unit: "procs") == "2 procs · 5% CPU")
    check("a tree with no processes has no line at all",
          ProcessTree.line(ProcessFootprint(processes: 0, cpuPercent: 9, listeningPorts: [3000]),
                           unit: "procs") == nil)
    // A card is one line wide and a dev box can hold a dozen ports: past three they become a count,
    // which still says "there are more" without pushing the other two segments off the card.
    check("past three ports the rest become a count",
          ProcessTree.line(ProcessFootprint(processes: 5, cpuPercent: nil,
                                            listeningPorts: [3000, 3789, 5173, 8080, 9229]),
                           unit: "procs") == "5 procs · :3000 :3789 :5173 +2")
    check("…and exactly three are all named, with nothing added",
          ProcessTree.line(ProcessFootprint(processes: 5, cpuPercent: nil,
                                            listeningPorts: [3000, 3789, 5173]),
                           unit: "procs") == "5 procs · :3000 :3789 :5173")
    check("the cap is the caller's to set",
          ProcessTree.line(ProcessFootprint(processes: 5, cpuPercent: nil,
                                            listeningPorts: [3000, 3789, 5173]),
                           unit: "procs", maxPorts: 1) == "5 procs · :3000 +2")

    // MARK: the memory and disk segments, and the name that goes with one of them

    let loaded = ProcessFootprint(processes: 9, cpuPercent: 34, cpuLeader: "node",
                                  memoryBytes: 820_000_000,
                                  diskWriteBytesPerSecond: 12_000_000, diskLeader: "esbuild",
                                  listeningPorts: [3789])
    check("a working tree says what it is burning, holding, writing and listening on",
          ProcessTree.line(loaded, unit: "procs")
              == "9 procs · 34% CPU · 820 MB · 12 MB/s (esbuild) · :3789")
    // ONE NAME PER LINE AND DISK TAKES IT: both segments have a culprit here, and two
    // parentheticals is what turns a card's one line into a paragraph.
    check("…naming only the disk writer, though both segments know who to blame",
          ProcessTree.line(loaded, unit: "procs")?.contains("(node)") == false)
    check("the CPU segment carries the name when there is no disk segment to take it",
          ProcessTree.line(ProcessFootprint(processes: 4, cpuPercent: 34, cpuLeader: "node",
                                            memoryBytes: 1_200_000_000, listeningPorts: []),
                           unit: "procs") == "4 procs · 34% CPU (node) · 1.2 GB")
    // Below the threshold the disk segment is not there at all, so the name goes back to the CPU.
    check("…and takes it back when the writing drops below the threshold",
          ProcessTree.line(ProcessFootprint(processes: 4, cpuPercent: 34, cpuLeader: "node",
                                            memoryBytes: 500_000_000,
                                            diskWriteBytesPerSecond: 999_999, diskLeader: "esbuild",
                                            listeningPorts: []),
                           unit: "procs") == "4 procs · 34% CPU (node) · 500 MB")
    check("a megabyte a second is where the disk segment starts",
          ProcessTree.line(ProcessFootprint(processes: 4, cpuPercent: nil,
                                            diskWriteBytesPerSecond: 1_000_000,
                                            listeningPorts: []),
                           unit: "procs") == "4 procs · 1 MB/s")
    // A pid that has ended between being picked and being named has no name, and the segment says
    // the number alone rather than an empty pair of brackets.
    check("a culprit nobody could name leaves the number to speak for itself",
          ProcessTree.line(ProcessFootprint(processes: 4, cpuPercent: 34,
                                            diskWriteBytesPerSecond: 12_000_000,
                                            listeningPorts: []),
                           unit: "procs") == "4 procs · 34% CPU · 12 MB/s")
    // MEMORY IS AN INSTANT, not an interval: it needs no earlier reading and is there on the first
    // tick, which is the tick the CPU segment cannot say anything on.
    check("memory is on the line before there is any interval to measure a rate over",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: nil,
                                            memoryBytes: 96_000_000, listeningPorts: []),
                           unit: "procs") == "2 procs · 96 MB")
    check("a tree holding under a megabyte says nothing rather than 0 MB",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: 5, memoryBytes: 400_000,
                                            listeningPorts: []),
                           unit: "procs") == "2 procs · 5% CPU")
    // Rounded first, so the segment is never four digits of megabytes.
    check("just under a gigabyte is a gigabyte rather than 1000 MB",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: nil, memoryBytes: 999_700_000,
                                            listeningPorts: []),
                           unit: "procs") == "2 procs · 1.0 GB")

    // MARK: the parts that only exist inside a view

    let cardSource = (try? String(contentsOfFile: "Tally/Views/SessionCardView.swift",
                                  encoding: .utf8)) ?? ""
    let boardSource = (try? String(contentsOfFile: "Tally/Views/SessionBoardView.swift",
                                   encoding: .utf8)) ?? ""
    let storeSource = (try? String(contentsOfFile: "Tally/Stores/ProcessFootprintStore.swift",
                                   encoding: .utf8)) ?? ""
    check("the three sources this suite reads are readable",
          !cardSource.isEmpty && !boardSource.isEmpty && !storeSource.isEmpty)
    // WALKING THE PROCESS TABLE IS PAID FOR BY THE PAGE THAT SHOWS IT. On the page rather than on
    // the root the roster is switched from: a surface sitting on the Usage tab must pay nothing.
    check("the readings are taken only while the sessions page is on screen",
          boardSource.contains(".onAppear { ProcessFootprintStore.shared.beginViewing() }")
              && boardSource.contains(".onDisappear { ProcessFootprintStore.shared.endViewing() }")
              && storeSource.contains("guard viewers == 0 else { return }")
              && storeSource.contains("timer?.invalidate()"))
    // THE CARRY IS A READING OF A MOMENT LIKE EVERY OTHER NUMBER HERE. Held past the panel that
    // took it, a debt from an hour ago would be subtracted from the first tick of the next viewing.
    check("the departed-process credit is dropped with everything else when the panel closes",
          storeSource.contains("cpuCarry = [:]")
              && storeSource.contains("carry: cpuCarry[key] ?? 0"))
    // The ports cost a descriptor table per process on top of the walk, so they are read on their
    // own slower beat and held in between.
    check("the ports are read on a slower beat than the tree and its CPU",
          storeSource.contains("ticks % Self.portsEveryNTicks == 0")
              && storeSource.contains("private static let portsEveryNTicks = 3"))
    // A card in its own slot, drawn on every card whether or not it has numbers: a card that
    // dropped the row would stand shorter than the ones beside it (`sessionCardLine`).
    check("the card gives the footprint a line of its own, on every card",
          cardSource.contains("sessionCardLine { sessionFootprint }"))
    // The plural is decided where the bundle is; the shape of the line is decided in the pure
    // function above, which is why this suite can state it at all.
    check("the card asks for the word and the pure rule builds the line",
          cardSource.contains("ProcessTree.segments(footprint,")
              && cardSource.contains("unit: L(footprint.processes == 1 ? \"proc\" : \"procs\")"))
    // THE CARD JOINS THE PIECES ITSELF, because a run that carries its own colour cannot be handed
    // over as one string - so the separator is spelled in two places and this is what keeps them the
    // same one. `ProcessTree.line` above states the whole sentence and is what the assertions read;
    // this states that what is DRAWN is that sentence rather than a second spelling of it.
    check("the drawn line separates its fields the way the stated line does",
          cardSource.contains("Text(verbatim: pickEffortSeparator)"))
    // A WARNING IS NOT A COLOUR: the mark carries the meaning for a reader who cannot separate the
    // amber from the grey beside it, and the colour only makes it faster to find.
    check("a warned field is marked as well as coloured, in this app's own warning colour",
          cardSource.contains("Text(Image(systemName: \"exclamationmark.triangle.fill\"))")
              && cardSource.contains(".foregroundStyle(TallyColor.warning)"))
    // And VoiceOver gets neither of those, so it is handed the condition in words.
    check("…and the reader who hears the line is told what the warning is about",
          cardSource.contains(".accessibilityLabel(Self.spoken(segments))")
              && cardSource.contains("L(\"high CPU while nothing is running\")")
              && cardSource.contains("L(\"writing to disk while nothing is running\")")
              && cardSource.contains("L(\"high memory\")"))
    // THE STATE IS THE SUPERVISOR'S OWN WORD, not a second idleness detector living in the app:
    // only the supervisor can see the transcript, the open tool call and the subagents. `unknown`
    // is deliberately not idle - it is "has not said yet", and warning on it would be a guess.
    check("idleness is read from the state the session publishes, and unknown is not idle",
          storeSource.contains("row.state == .idle || row.state == .blocked")
              && storeSource.contains("FootprintAlarm.advance(alertState[key] ?? FootprintAlertState(),")
              && storeSource.contains("alertState = [:]"))
}
