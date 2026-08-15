import Foundation

// WHAT A SESSION'S PROCESS TREE COSTS, as the card's fourth line states it (Tally/Core/
// ProcessTreeStats.swift). Three rules, all pure, all stated here without a process in sight:
//
//   1. WHICH PIDS ARE IN THE TREE, walked from one pass over the machine's parent map. A session is
//      never one process - supervisor, Claude Code, and every shell and dev server under them - so
//      a rule that stopped at the first generation would report a fraction of the cost.
//   2. WHAT TWO CUMULATIVE CPU READINGS MEAN, which is the only reason the readings are held per
//      pid: a tree total goes DOWN when a shell exits, and differencing that would print negative
//      work as often as a session finishes a command.
//   3. HOW THE LINE READS when a segment has nothing to say, and how many ports fit on a card.
//
// The libproc side of that file is three thin wrappers with no decisions in them; what it hands
// over is asserted where the decisions are, here.

func runProcessTreeChecks() {
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)

    // A machine, as the parent map spells it: launchd (1) holds a supervisor (100), which holds a
    // Claude Code (200), which holds a shell (300) with a dev server (400) under it. 500 is another
    // session's supervisor and 600 is somebody's editor - neither belongs to this tree.
    let parents: [pid_t: pid_t] = [1: 0, 100: 1, 200: 100, 300: 200, 400: 300, 500: 1, 600: 1]

    // MARK: which pids belong to the tree

    check("the tree is the supervisor and everything under it, however deep",
          ProcessTree.members(root: 100, parents: parents) == [100, 200, 300, 400])
    // THE WHOLE POINT OF WALKING IT. A dev server four generations down is exactly the process that
    // holds the port and burns the CPU, and it is under a shell nobody would think to look in.
    check("…so a grandchild's own child is in it, and a neighbouring session is not",
          ProcessTree.members(root: 100, parents: parents).contains(400)
              && !ProcessTree.members(root: 100, parents: parents).contains(500))
    check("a leaf session is just itself",
          ProcessTree.members(root: 600, parents: parents) == [600])
    // The board draws a card for a session the last scan found, and a supervisor can be gone by the
    // time this runs. Nothing to measure is nothing to say, not a zero.
    check("a root the machine no longer has is no tree at all",
          ProcessTree.members(root: 999, parents: parents).isEmpty)
    // Pid numbers are reused, so a parent chain CAN come back on itself. Without the visited set
    // this spins forever, taking the panel with it.
    check("a parent chain that loops does not hang the walk",
          ProcessTree.members(root: 10, parents: [10: 11, 11: 10]) == [10, 11])

    // MARK: what two readings say about CPU

    let first = ProcessCPUSample(times: [100: 1, 200: 4], at: t0)
    // Two seconds later: the supervisor spent nothing, Claude Code spent one second, and a shell
    // that did not exist before spent half of one.
    let second = ProcessCPUSample(times: [100: 1, 200: 5, 300: 0.5], at: t0.addingTimeInterval(2))
    check("a first reading says nothing, because a cumulative counter needs two",
          ProcessTree.cpuPercent(from: nil, to: second) == nil)
    check("two readings are the work between them over the time between them",
          ProcessTree.cpuPercent(from: first, to: second) == 75)
    // A pid born inside the interval spent everything it has inside it, by definition.
    check("…counting a process that appeared during the interval in full",
          ProcessTree.cpuPercent(from: ProcessCPUSample(times: [:], at: t0),
                                 to: ProcessCPUSample(times: [300: 1],
                                                      at: t0.addingTimeInterval(2))) == 50)
    // THE READING THAT USED TO GO NEGATIVE. Held as one tree total, a shell finishing subtracts its
    // whole lifetime from the next difference; held per pid it simply stops contributing.
    check("…and a process that ended takes nothing away with it",
          ProcessTree.cpuPercent(from: ProcessCPUSample(times: [100: 1, 300: 9], at: t0),
                                 to: ProcessCPUSample(times: [100: 2],
                                                      at: t0.addingTimeInterval(2))) == 50)
    // The only way a pid's own counter goes backwards is the number naming a different process now.
    check("…nor does a counter that went backwards count as work",
          ProcessTree.cpuPercent(from: ProcessCPUSample(times: [100: 9], at: t0),
                                 to: ProcessCPUSample(times: [100: 1],
                                                      at: t0.addingTimeInterval(2))) == 0)
    check("two readings taken at the same instant say nothing rather than dividing by nothing",
          ProcessTree.cpuPercent(from: first, to: ProcessCPUSample(times: [100: 2], at: t0)) == nil)

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
