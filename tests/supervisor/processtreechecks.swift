import Foundation

// WHAT A SESSION'S PROCESS TREE COSTS, as the card's fourth line states it (Tally/Core/
// ProcessTreeStats.swift). Three rules, all pure, all stated here without a process in sight:
//
//   1. WHICH PIDS ARE IN THE SESSION: everything under the supervisor by parentage, AND everything
//      left in its job. Parentage alone loses the process the whole feature is for - a background
//      server outlives the shell that started it and macOS re-parents it to launchd.
//   2. WHAT TWO CUMULATIVE CPU READINGS MEAN, which is why they are held per pid AND why the
//      children a process has already buried are read too: an agent's work is mostly commands that
//      are born and finished between two ticks, and no sample ever sees those alive.
//   3. HOW THE LINE READS when a segment has nothing to say, and how many ports fit on a card.
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
    let measured = ProcessTree.cpuSample(of: [me]).times[me] ?? 0
    let oracle = selfCPUSeconds()
    check("the CPU counters are read in the units the machine keeps them in",
          oracle > 0.05 && measured > oracle * 0.85 && measured < oracle * 1.15)

    // MARK: what two readings say about CPU

    func sample(_ times: [pid_t: Double], child: [pid_t: Double] = [:],
                at offset: TimeInterval) -> ProcessCPUSample {
        ProcessCPUSample(times: times, childTimes: child, at: t0.addingTimeInterval(offset))
    }
    let first = sample([100: 1, 200: 4], at: 0)
    // Two seconds later: the supervisor spent nothing, Claude Code spent one second, and a shell
    // that did not exist before spent half of one.
    let second = sample([100: 1, 200: 5, 300: 0.5], at: 2)
    check("a first reading says nothing, because a cumulative counter needs two",
          ProcessTree.cpuPercent(from: nil, to: second) == nil)
    check("two readings are the work between them over the time between them",
          ProcessTree.cpuPercent(from: first, to: second) == 75)
    // A pid born inside the interval spent everything it has inside it, by definition.
    check("…counting a process that appeared during the interval in full",
          ProcessTree.cpuPercent(from: sample([:], at: 0), to: sample([300: 1], at: 2)) == 50)
    check("two readings taken at the same instant say nothing rather than dividing by nothing",
          ProcessTree.cpuPercent(from: first, to: sample([100: 2], at: 0)) == nil)
    // The only way a pid's own counter goes backwards is the number naming a different process now.
    check("a counter that went backwards does not count as work",
          ProcessTree.cpuPercent(from: sample([100: 9], at: 0),
                                 to: sample([100: 1], at: 2)) == 0)

    // MARK: the work of processes no sample ever saw alive

    // THE READING THAT WAS 0.007% FOR HALF A CORE. A command that starts and finishes between two
    // ticks is in neither sample, and its whole cost is in its parent's child counter - which is
    // where most of a session's CPU is, since an agent's work is short commands.
    check("a child born and buried between two ticks is counted, through its parent's counter",
          ProcessTree.cpuPercent(from: sample([100: 1], child: [100: 0], at: 0),
                                 to: sample([100: 1], child: [100: 1], at: 2)) == 50)
    // A long-lived child was already counted while it was alive, and its whole life lands in the
    // parent's counter the moment it is collected. Without taking its last own reading back off,
    // every long command would be counted twice at the tick it finished.
    check("…while a long-lived child that dies is not counted twice for the life it already spent",
          ProcessTree.cpuPercent(from: sample([100: 1, 300: 3], child: [100: 0], at: 0),
                                 to: sample([100: 1], child: [100: 4], at: 2)) == 50)
    // And the same for what IT had already buried: a shell that ran commands carries their CPU in
    // its own child counter, which was counted at the tick each of them finished, and which is
    // folded into the parent's counter when the shell itself is collected.
    check("…nor for the grandchildren it had already buried and been counted for",
          ProcessTree.cpuPercent(from: sample([100: 1, 300: 3], child: [100: 0, 300: 6], at: 0),
                                 to: sample([100: 1], child: [100: 10], at: 2)) == 50)
    // A process that has died and not yet been collected has had its readings taken off with
    // nothing yet added back. Half a tick under is the price of never double counting.
    check("…and a death nobody has collected yet reads as nothing rather than as negative work",
          ProcessTree.cpuPercent(from: sample([100: 1, 300: 3], child: [100: 0], at: 0),
                                 to: sample([100: 1], child: [100: 0], at: 2)) == 0)

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
    // The ports cost a descriptor table per process on top of the walk, so they are read on their
    // own slower beat and held in between.
    check("the ports are read on a slower beat than the tree and its CPU",
          storeSource.contains("ticks % Self.portsEveryNTicks == 0")
              && storeSource.contains("private static let portsEveryNTicks = 3"))
    // A card in its own slot, drawn on every card whether or not it has numbers: a card that
    // dropped the row would stand shorter than the ones beside it (`sessionCardLine`).
    check("the card gives the footprint a line of its own, on every card",
          cardSource.contains("sessionCardLine { statsText(sessionFootprintLine) }"))
    // The plural is decided where the bundle is; the shape of the line is decided in the pure
    // function above, which is why this suite can state it at all.
    check("the card asks for the word and the pure rule builds the line",
          cardSource.contains("ProcessTree.line(footprint,")
              && cardSource.contains("unit: L(footprint.processes == 1 ? \"proc\" : \"procs\")"))
}
