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
    check("the line names the processes and what they are burning",
          ProcessTree.line(full, unit: "procs") == "3 procs · 12% CPU")
    // A difference of two samples two seconds apart is not accurate to a decimal place, and a card
    // that printed one would be spelling out noise.
    check("…rounding the CPU to a whole point",
          ProcessTree.line(ProcessFootprint(processes: 1, cpuPercent: 0.4, listeningPorts: []),
                           unit: "proc") == "1 proc · 0% CPU")
    // EVERY SEGMENT IS OPTIONAL AND ITS SEPARATOR GOES WITH IT, the rule the identity line one file
    // over already follows: an empty field is worse than a shorter line.
    check("a tree that has only been read once carries no CPU segment",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: nil, listeningPorts: [3000]),
                           unit: "procs") == "2 procs")
    // THE PORTS ARE NOT A FIELD OF THIS SENTENCE ANY MORE: they are their own element on the
    // identity line, where they are not the first thing a narrow card truncates away
    // (`ProcessTree.portsText`, asserted below).
    check("…and a session holding ports says nothing about them here",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: 5, listeningPorts: [3000]),
                           unit: "procs") == "2 procs · 5% CPU")
    // ZERO IS A READING NOW, which is what the count MEANING changed to: it counts what the session
    // started, so nought is the ordinary state of an ordinary card and taking the line away on it
    // would take the CPU, the memory and the whole trend row off most of the board.
    check("a session that has started nothing still states its count and its readings",
          ProcessTree.line(ProcessFootprint(processes: 0, cpuPercent: 9, memoryBytes: 96_000_000,
                                            listeningPorts: [3000]),
                           unit: "procs") == "0 procs · 9% CPU · 96 MB")

    // MARK: the memory and disk segments, and the name that goes with one of them

    let loaded = ProcessFootprint(processes: 9, cpuPercent: 34, cpuLeader: "node",
                                  memoryBytes: 820_000_000,
                                  diskWriteBytesPerSecond: 12_000_000, diskLeader: "esbuild",
                                  listeningPorts: [3789])
    check("a working tree says what it is burning, holding and writing",
          ProcessTree.line(loaded, unit: "procs")
              == "9 procs · 34% CPU · 820 MB · 12 MB/s (esbuild)")
    // THE TWO RATES SHARE ONE NAME AND DISK TAKES IT: both of them have a culprit here, and two
    // parentheticals on the rates is what turns a card's one line into a paragraph.
    check("…naming only the disk writer, though both rates know who to blame",
          ProcessTree.line(loaded, unit: "procs").contains("(node)") == false)
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
    // A NAME IS ONLY WORTH ITS ROOM WHEN IT IS A SURPRISE. Every card on this board is a Claude
    // Code session, so Claude Code is what is burning the CPU on almost all of them, and "(claude)"
    // on every card all day is the answer to a question nobody asked (Albert, 2026-08-15).
    check("the expected leader of a session tree is not named",
          ProcessTree.line(ProcessFootprint(processes: 4, cpuPercent: 34, cpuLeader: "claude",
                                            listeningPorts: []),
                           unit: "procs") == "4 procs · 34% CPU")
    check("…however the machine happened to spell it",
          ProcessTree.worthNaming("Claude") == nil && ProcessTree.worthNaming("claude") == nil)
    check("…and the surprise still is",
          ProcessTree.line(ProcessFootprint(processes: 4, cpuPercent: 42,
                                            cpuLeader: "Google Chrome Helper",
                                            listeningPorts: []),
                           unit: "procs") == "4 procs · 42% CPU (Google Chrome Helper)")
    // The disk writer is not put through the same rule: that segment only exists past a megabyte a
    // second, so it is the rare sighting where the question really is who.
    check("the disk writer is named whoever it is",
          ProcessTree.line(ProcessFootprint(processes: 4, cpuPercent: nil,
                                            diskWriteBytesPerSecond: 12_000_000,
                                            diskLeader: "claude", listeningPorts: []),
                           unit: "procs") == "4 procs · 12 MB/s (claude)")
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

    // MARK: what is holding the memory

    // THE MEMORY CARRIES ITS HOLDER'S NAME, which is the field's answer to the count no longer
    // including the session's own Claude Code: "1 proc · 3.4 GB" cannot say whether the gigabytes
    // are the body or the one thing it started, and this is the only place on the card that can.
    check("the memory segment names what is holding it",
          ProcessTree.line(ProcessFootprint(processes: 1, cpuPercent: nil,
                                            memoryBytes: 3_400_000_000, memoryLeader: "bun",
                                            listeningPorts: []),
                           unit: "proc") == "1 proc · 3.4 GB (bun)")
    // AND IT IS NOT PUT THROUGH `worthNaming`, which the CPU is: `(claude)` beside a percentage on
    // every card is the answer to a question nobody asked, and `(claude)` beside the memory is the
    // answer to the one the count now raises.
    check("…even when it is the program every card on this board is led by",
          ProcessTree.line(ProcessFootprint(processes: 0, cpuPercent: nil,
                                            memoryBytes: 3_400_000_000, memoryLeader: "claude",
                                            listeningPorts: []),
                           unit: "procs") == "0 procs · 3.4 GB (claude)")
    check("…and a tree with no single holder says the figure alone",
          ProcessTree.line(ProcessFootprint(processes: 4, cpuPercent: nil,
                                            memoryBytes: 3_400_000_000, listeningPorts: []),
                           unit: "procs") == "4 procs · 3.4 GB")
    // The name reaches the row that draws figures as its own quiet half, and the row that draws a
    // sentence as one of the words: the same rule the CPU is already under, so a listener hears it
    // either way (`SessionCardView.spoken`).
    check("…and the name is carried apart as well as inside the words",
          ProcessTree.segments(ProcessFootprint(processes: 1, cpuPercent: nil,
                                                memoryBytes: 3_400_000_000, memoryLeader: "bun",
                                                listeningPorts: []),
                               unit: "procs").last
              == ProcessFootprintSegment(kind: .memory, text: "3.4 GB (bun)", aside: "bun"))

    // MARK: where the disk rate changes unit

    // An NVMe drive does several gigabytes a second, and this printed `6174 MB/s` for one: four
    // digits where every other figure on the card is three.
    check("a rate past a thousand megabytes is stated in gigabytes",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: nil,
                                            diskWriteBytesPerSecond: 6_174_000_000,
                                            listeningPorts: []),
                           unit: "procs") == "2 procs · 6.2 GB/s")
    // Decided on the ROUNDED megabyte, exactly as the memory's threshold is, so the two units
    // change over at the same place rather than one of them printing "1000 MB/s".
    check("…switching on the rounded megabyte, as the memory figure does",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: nil,
                                            diskWriteBytesPerSecond: 999_700_000,
                                            listeningPorts: []),
                           unit: "procs") == "2 procs · 1.0 GB/s")
    check("…and just under it is still megabytes",
          ProcessTree.line(ProcessFootprint(processes: 2, cpuPercent: nil,
                                            diskWriteBytesPerSecond: 999_400_000,
                                            listeningPorts: []),
                           unit: "procs") == "2 procs · 999 MB/s")

    // MARK: the ports, which are a line of their own now

    let holding = ProcessFootprint(processes: 2, cpuPercent: nil,
                                   listeningPorts: [3000, 5173, 8080],
                                   portNames: [3000: "next-server", 5173: "node"])
    check("the ports say what is holding them",
          ProcessTree.portsText(holding) == ":3000 (next-server) :5173 (node) +1")
    check("…and give up the names before the numbers, which is what a narrow card takes",
          ProcessTree.portsText(holding, named: false) == ":3000 :5173 +1")
    check("…a port nobody could be named for showing the number alone",
          ProcessTree.portsText(ProcessFootprint(processes: 1, cpuPercent: nil,
                                                 listeningPorts: [3000, 5173]))
              == ":3000 :5173")
    check("the cap is the caller's to set, and what is past it is a count",
          ProcessTree.portsText(holding, maxPorts: 1) == ":3000 (next-server) +2")
    check("…with nothing added when everything fits",
          ProcessTree.portsText(holding, maxPorts: 3)
              == ":3000 (next-server) :5173 (node) :8080")
    check("a session listening on nothing has no ports line at all",
          ProcessTree.portsText(ProcessFootprint(processes: 4, cpuPercent: 9,
                                                 listeningPorts: [])) == nil)

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

    // MARK: the quieter half of a field

    // AN ASIDE IS READ BY EXACTLY ONE SURFACE: the row that draws a metric as a figure and prints
    // the word beside it a shade down (`SessionCardView.sessionFootprintTrends`), which is built
    // only for the three trended metrics. The fields with no shape are drawn as one sentence at one
    // weight, so an aside on them is data nobody reads - the agents' and the disk writer's were
    // exactly that (codex review of 4868f2f, 2026-08-16).
    check("only the fields drawn as figures carry an aside, and now all three of them do",
          ProcessTree.segments(ProcessFootprint(processes: 6, agents: 2, cpuPercent: 40,
                                                cpuLeader: "node", memoryBytes: 5_000_000_000,
                                                memoryLeader: "bun", listeningPorts: [3000]),
                               unit: "procs", agentUnit: "agents")
              .filter { $0.aside != nil }.map(\.kind) == [.processes, .cpu, .memory])
    // Including the one field that HAS a name to say and no row to say it on: the disk writer is
    // named inside the sentence itself, which is where a first-row field carries its words.
    check("…and the named disk writer is one of the words rather than an aside",
          ProcessTree.segments(ProcessFootprint(processes: 6, cpuPercent: 40,
                                                diskWriteBytesPerSecond: 12_000_000,
                                                diskLeader: "esbuild", listeningPorts: []),
                               unit: "procs").last
              == ProcessFootprintSegment(kind: .disk, text: "12 MB/s (esbuild)"))

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
    // THE FAST BEAT IS PAID FOR BY THE PAGE THAT SHOWS IT, and the page is still what asks for it.
    // What changed is what happens when it stops asking: the pass now goes on at a tenth of the
    // rate, because the cards draw a trend and a history that began when the panel opened would be
    // blank at the moment somebody opened it (`FootprintTrend.swift`, footprinttrendchecks.swift).
    check("the fast readings are taken only while the sessions page is on screen",
          boardSource.contains(".onAppear { ProcessFootprintStore.shared.beginViewing() }")
              && boardSource.contains(".onDisappear { ProcessFootprintStore.shared.endViewing() }")
              && storeSource.contains("guard viewers == 0 else { return }")
              && storeSource.contains("let wanted = viewers > 0 ? Self.visibleInterval : Self.backgroundInterval"))
    // THE CARRY IS A DEBT ONE TICK WIDE, and it used to be dropped when the panel closed because
    // the readings stopped there: a credit from an hour ago would have been subtracted from the
    // first tick of the next viewing. The readings no longer stop, so it is never more than one
    // background interval old, and the rule that bounds it to a single tick was always in the pure
    // function rather than in the store (`ProcessTree.cpuPercent`).
    check("the departed-process credit is handed to the rule that bounds it, tick after tick",
          storeSource.contains("carry: cpuCarry[key] ?? 0")
              && storeSource.contains("carried[key] = cpu.carry")
              && storeSource.contains("cpuCarry = carried"))
    check("…and is no longer thrown away with a panel that closed",
          !storeSource.contains("cpuCarry = [:]"))
    // The ports cost a descriptor table per process on top of the walk, so they are read on their
    // own slower beat, held in between, and never taken at all with nothing on screen.
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
    // A WARNING IS NOT A COLOUR, WHEREVER THERE IS ROOM TO SAY SO IN SOMETHING ELSE: the mark
    // carries the meaning for a reader who cannot separate the amber from the grey beside it, and
    // the colour only makes it faster to find. This is the row with the room - it is a sentence, and
    // nine points of triangle in a sentence is a sentence with a triangle in it. The row of eleven
    // point shapes below is where that stops being true, and states the second channel differently
    // (footprinttrendsurfacechecks.swift).
    check("a warned field is marked as well as coloured, in this app's own warning colour",
          cardSource.contains("Text(Image(systemName: \"exclamationmark.triangle.fill\"))")
              && cardSource.contains(".foregroundStyle(TallyColor.warning)"))
    // And VoiceOver gets neither of those, so it is handed the condition in words.
    check("…and the reader who hears the line is told what the warning is about",
          cardSource.contains(".accessibilityLabel(Self.spoken(rest))")
              && cardSource.contains("L(\"high CPU while nothing is running\")")
              && cardSource.contains("L(\"writing to disk while nothing is running\")")
              && cardSource.contains("L(\"holding a lot of memory while nothing is running\")"))
    // THE WARNING WENT WITH THE NUMBER when the numbers moved down a row: two of the three
    // conditions are about figures that are now drawn in the trend groups (the CPU and the memory),
    // and a mark left behind on the row they used to be on would be a warning about nothing.
    // The mark itself does not follow them down: a triangle in a row of pinned columns moves every
    // figure after it the moment a warning arrives, and on the eleven-point shape beside the figure
    // it covers the readings instead (asserted where the rest of that row is,
    // footprinttrendsurfacechecks.swift). What goes down with the numbers is the colour, on the
    // figure and on the shape alike, and the condition is still SAID in full.
    check("a warned reading is coloured where the reading now is, figure and shape together",
          cardSource.contains("Self.figure(trend.figure, alert: trend.segment.alert)")
              && cardSource.contains("FootprintSparklineView(values: trend.values,"
                                     + " alert: trend.segment.alert)"))
    check("…and the reader who hears the groups is told the same condition",
          cardSource.contains(".accessibilityLabel(Self.spokenTrends(trends))")
              && cardSource.contains("let reading = spoken([trend.segment])"))
    // THE STATE IS THE SUPERVISOR'S OWN WORD, not a second idleness detector living in the app:
    // only the supervisor can see the transcript, the open tool call and the subagents. `unknown`
    // is deliberately not idle - it is "has not said yet", and warning on it would be a guess.
    //
    // The counting the rule does is per session and survives the tick that took it, which is what
    // "a warning is about a condition that HOLDS" needs; a panel that closes no longer resets it,
    // because the ticks continue behind it and a warning re-earned from nothing on reopening would
    // be ten seconds late saying what was already true.
    check("idleness is read from the state the session publishes, and unknown is not idle",
          storeSource.contains("row.state == .idle || row.state == .blocked")
              && storeSource.contains("FootprintAlarm.advance(alertState[key] ?? FootprintAlertState(),")
              && storeSource.contains("alertState = alerting"))
    // WHAT THE AI IS DOING, NOT WHAT THE METER IS DOING. The exclusion is applied to the members
    // before anything is sampled, so the count, the CPU, the memory, the disk and the ports are all
    // of the same set; a tree with nothing left of the session gets no entry, which is what makes
    // the line disappear rather than report Tally to itself.
    check("the app's own processes are named before any of the tree is measured",
          storeSource.contains("let ours = ProcessTree.ownFamily(members, root: root) { paths[$0] }")
              && storeSource.contains("let measured = members.subtracting(ours)")
              && storeSource.contains("guard !measured.isEmpty else { continue }")
              && storeSource.contains("ProcessTree.listeningPorts(of: measured)"))
    // AND THE SESSION'S OWN CLI COMES OUT OF THE COUNT ONLY, by the pid its supervisor published
    // rather than by any name (`ProcessTree.dispatched`). The store is where the two meet, so this
    // is where "the count is of what was started, the readings are of the whole tree" is pinned:
    // the same expression used to be written twice here, and one of the two is the trend's.
    check("the count is of what the session started, in the figure and in the trend alike",
          storeSource.contains("row.childPid.flatMap { pid_t(exactly: $0) }")
              && storeSource.contains("let started = ProcessTree.dispatched(measured, child: child)")
              && storeSource.contains("processes: started.count,")
              && !storeSource.contains("processes: measured.count"))
    check("…while the memory and the CPU stay the whole tree's, with a name to read them by",
          storeSource.contains("memoryBytes: reading.memoryBytes,")
              && storeSource.contains("memoryLeader: name(of: ProcessTree.memoryLeader(reading)),"))
    // A port with nobody's name against it is a port whose holder could not be read, which is why
    // the name is resolved from THIS tick's table rather than cached with the port number.
    check("…and each port is named from the same table of programs the culprits are",
          storeSource.contains("portNames: holding.compactMapValues { name(of: $0) })")
              && storeSource.contains("listeningPorts: holding.keys.sorted(),"))
    // AND THE WHOLE TREE IS SAMPLED, ours included, which is the one thing here that looks like the
    // opposite of the line above and is what makes it true. A pid filtered off the list before the
    // sample can never be seen to DEPART, and departing is what cancels the seconds one of ours
    // hands to whoever collects it - which is Claude Code (`ProcessResourceSample.ours`).
    check("…and then read WITH the tree, so that one of them ending can still be seen to end",
          storeSource.contains("ProcessTree.resourceSample(of: members, ours: ours, at: now)"))
    // One reading of the programs per tree per tick, used for both questions it answers.
    check("…off the one table of programs that also names the culprit",
          storeSource.contains("let paths = ProcessTree.executablePaths(of: members)")
              && storeSource.contains("paths[$0].flatMap(ProcessTree.displayName)"))
    // The agents are the one number here the machine cannot be asked for, so it is read from what
    // Claude Code's own hooks published - and only when that record says it can be believed.
    check("the agent count is read from the session's own roster, and only when it is trusted",
          storeSource.contains("readSessionAgents(pid: key)?.reportable ?? 0"))
    // THE PORTS ARE THEIR OWN ELEMENT ON THE IDENTITY LINE, never a segment of the string that line
    // is otherwise drawn from: that string being nil is how the card knows it has nothing at all to
    // say yet and turns a spinner instead (`sessionIsLoading`), so a session that had published
    // only a port would have kept spinning forever.
    check("the ports are drawn beside the identity rather than written into it",
          boardCardSource.contains("return joined([account, row.model, row.effort])")
              && boardCardSource.contains("sessionCardLine { sessionIdentityRow }")
              && boardCardSource.contains("!row.isReporting && sessionIdentityLine == nil"))
    // Two spellings offered widest first, so a card that cannot hold the names keeps the numbers.
    check("…the names being what a narrow card gives up, and the identity what truncates",
          boardCardSource.contains("identityRow(ports: named)")
              && boardCardSource.contains("identityRow(ports: bare)")
              && boardCardSource.contains("Text(verbatim: ports)")
              && boardCardSource.contains(".lineLimit(1).fixedSize()"))
    check("…asked of the same pure rule the assertions above state",
          cardSource.contains("ProcessTree.portsText(footprint, named: named)"))

    // MARK: which processes the count is counting

    // THE SESSION'S OWN CLI IS NOT SOMETHING THE SESSION STARTED, and every card has one by
    // construction: counting it made "2 procs" the reading of a session running a single MCP
    // server (Albert, 2026-08-16).
    check("the process at the head of the tree is not one of the ones it started",
          ProcessTree.dispatched([100, 200, 300], child: 200) == [100, 300])
    // BY THE PUBLISHED PID, NEVER BY THE PROGRAM'S NAME, which is what makes these three true at
    // once: a nested Claude Code the session itself started is still counted…
    check("…and a Claude Code the session started itself is still counted",
          ProcessTree.dispatched([100, 200, 300, 400], child: 200).contains(400))
    // …a Codex session drops its own body under the very same rule, with nothing here knowing what
    // a provider is…
    check("…the rule knowing nothing about which provider the body belongs to",
          ProcessTree.dispatched([7, 8], child: 8) == [7])
    // …and a supervisor too old to publish the field keeps its old reading rather than a guess.
    check("…and a session that published no child keeps every process it holds",
          ProcessTree.dispatched([100, 200, 300], child: nil).count == 3)
    check("…as does one whose published child is not in the tree at all",
          ProcessTree.dispatched([100, 300], child: 200) == [100, 300])

    // MARK: what is holding the memory, and what is holding a port

    let held = ProcessResourceSample(times: [:], childTimes: [:],
                                     memory: [10: 3_000_000_000, 20: 400_000_000],
                                     at: Date(), ours: [])
    check("a process holding more than half the tree's memory is the one named",
          ProcessTree.memoryLeader(held) == 10)
    // HALF IS NOT ENOUGH, the same rule every other blame in this app is made under: a name beside
    // a figure claims one thing is doing this, and two halves make that claim false about both.
    check("…and two holding half each are neither of them named",
          ProcessTree.memoryLeader(ProcessResourceSample(times: [:], childTimes: [:],
                                                         memory: [10: 500, 20: 500],
                                                         at: Date())) == nil)
    // The meter is not the thing metered here either: a card must not answer "what is holding your
    // memory" with the app doing the reading.
    check("…and Tally's own are not eligible to be the answer",
          ProcessTree.memoryLeader(ProcessResourceSample(times: [:], childTimes: [:],
                                                         memory: [10: 3_000_000_000, 20: 400_000],
                                                         at: Date(), ours: [10])) == 20)
    check("…and a tree holding nothing names nobody",
          ProcessTree.memoryLeader(ProcessResourceSample(times: [:], childTimes: [:], memory: [:],
                                                         at: Date())) == nil)
    // A PORT TWO PROCESSES SHARE GOES TO THE LOWEST PID, and the point is that it is DECIDABLE: the
    // walk visits pids in whatever order a Set hands them over, so "the first one seen" would give
    // the card a name that changed every third tick (`SO_REUSEPORT`, a node cluster).
    check("a port several processes are listening on is credited to one of them, always the same one",
          ProcessTree.holders(of: [(port: 3000, pid: 900), (port: 3000, pid: 400),
                                   (port: 5173, pid: 700)]) == [3000: 400, 5173: 700]
              && ProcessTree.holders(of: [(port: 3000, pid: 400), (port: 3000, pid: 900),
                                          (port: 5173, pid: 700)]) == [3000: 400, 5173: 700])
    // Port zero is what an unbound or unreadable socket reports, and a card saying ":0" would be
    // reporting the read rather than the machine.
    check("…and a socket with no port is not a port",
          ProcessTree.holders(of: [(port: 0, pid: 400)]).isEmpty)
}
