import Foundation

// HOW THE FOOTPRINT READS, which is the other half of the file next door
// (processtreechecks.swift): that one states what the numbers MEAN, this one states what a person
// sees. Split along the same seam the source was (Tally/Core/ProcessTreeLine.swift), and it holds
// two kinds of assertion:
//
//   1. The pure line rules: which segments appear, in what order, with what separator, and where a
//      number stops being worth a segment at all.
//   2. The parts that only exist inside a view or a store, read off their source text - the plural
//      the bundle decides, the colour and the mark a warning is drawn in, and the sampling this
//      whole reading is paid for by.
//
// The second kind is a static read on purpose: a SwiftUI body cannot be rendered here, so what can
// be pinned is the one line of it that would silently stop being true.

func runProcessTreeLineChecks() {
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

    // MARK: the agents field

    // A COUNT ONLY WHEN THERE IS ONE. Zero is both "no fan-out" and "a Claude Code that cannot say",
    // and a segment reading "0 agents" would spend the card's narrowest line on either.
    check("a session running subagents says how many, right after the process count",
          ProcessTree.line(ProcessFootprint(processes: 6, agents: 2, cpuPercent: 40,
                                            listeningPorts: []),
                           unit: "procs", agentUnit: "agents") == "6 procs · 2 agents · 40% CPU")
    check("…and a session with none says nothing about agents at all",
          ProcessTree.line(ProcessFootprint(processes: 6, agents: 0, cpuPercent: 40,
                                            listeningPorts: []),
                           unit: "procs", agentUnit: "agents") == "6 procs · 40% CPU")
    // The word is the caller's, exactly as "procs" is: only the surface has the bundle, and only it
    // knows whether this is the plural.
    check("the word for one agent is the caller's to choose",
          ProcessTree.line(ProcessFootprint(processes: 3, agents: 1, cpuPercent: nil,
                                            listeningPorts: []),
                           unit: "procs", agentUnit: "agent") == "3 procs · 1 agent")
    // AN ORDINARY FIELD, so a warned reading still comes forward past it: a fan-out is something
    // somebody chose to start and is never itself the alarm.
    check("a warned field is drawn before the agents, and the count still leads",
          ProcessTree.segments(ProcessFootprint(processes: 6, agents: 2, cpuPercent: 80,
                                                memoryBytes: 5_000_000_000, listeningPorts: [],
                                                alerts: FootprintAlerts(cpu: true)),
                               unit: "procs", agentUnit: "agents").map(\.kind)
              == [.processes, .cpu, .agents, .memory])

    // MARK: the parts that only exist inside a view

    let cardSource = (try? String(contentsOfFile: "Tally/Views/SessionCardFootprint.swift",
                                  encoding: .utf8)) ?? ""
    let boardCardSource = (try? String(contentsOfFile: "Tally/Views/SessionCardView.swift",
                                       encoding: .utf8)) ?? ""
    let boardSource = (try? String(contentsOfFile: "Tally/Views/SessionBoardView.swift",
                                   encoding: .utf8)) ?? ""
    let storeSource = (try? String(contentsOfFile: "Tally/Stores/ProcessFootprintStore.swift",
                                   encoding: .utf8)) ?? ""
    check("the four sources this suite reads are readable",
          !cardSource.isEmpty && !boardCardSource.isEmpty && !boardSource.isEmpty
              && !storeSource.isEmpty)
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
          boardCardSource.contains("sessionCardLine { sessionFootprint }"))
    // The plurals are decided where the bundle is; the shape of the line is decided in the pure
    // function above, which is why this suite can state it at all.
    check("the card asks for the words and the pure rule builds the line",
          cardSource.contains("ProcessTree.segments(footprint,")
              && cardSource.contains("unit: L(footprint.processes == 1 ? \"proc\" : \"procs\")")
              && cardSource.contains("agentUnit: L(footprint.agents == 1 ? \"agent\" : \"agents\")"))
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
              && cardSource.contains("L(\"holding a lot of memory while nothing is running\")"))
    // THE STATE IS THE SUPERVISOR'S OWN WORD, not a second idleness detector living in the app:
    // only the supervisor can see the transcript, the open tool call and the subagents. `unknown`
    // is deliberately not idle - it is "has not said yet", and warning on it would be a guess.
    check("idleness is read from the state the session publishes, and unknown is not idle",
          storeSource.contains("row.state == .idle || row.state == .blocked")
              && storeSource.contains("FootprintAlarm.advance(alertState[key] ?? FootprintAlertState(),")
              && storeSource.contains("alertState = [:]"))
    // WHAT THE AI IS DOING, NOT WHAT THE METER IS DOING. The exclusion is applied to the members
    // before anything is sampled, so the count, the CPU, the memory, the disk and the ports are all
    // of the same set; a tree with nothing left of the session gets no entry, which is what makes
    // the line disappear rather than report Tally to itself.
    check("the app's own processes come out of the tree before any of it is measured",
          storeSource.contains("let ours = ProcessTree.ownFamily(members, root: root) { paths[$0] }")
              && storeSource.contains("let measured = members.subtracting(ours)")
              && storeSource.contains("guard !measured.isEmpty else { continue }")
              && storeSource.contains("ProcessTree.resourceSample(of: measured, at: now)")
              && storeSource.contains("ProcessTree.listeningPorts(of: measured)")
              && storeSource.contains("processes: measured.count"))
    // One reading of the programs per tree per tick, used for both questions it answers.
    check("…off the one table of programs that also names the culprit",
          storeSource.contains("let paths = ProcessTree.executablePaths(of: members)")
              && storeSource.contains("paths[$0].flatMap(ProcessTree.displayName)"))
    // The agents are the one number here the machine cannot be asked for, so it is read from what
    // Claude Code's own hooks published - and only when that record says it can be believed.
    check("the agent count is read from the session's own roster, and only when it is trusted",
          storeSource.contains("readSessionAgents(pid: key)?.reportable ?? 0"))
}
