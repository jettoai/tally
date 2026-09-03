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
    // A RULER OF THE HARNESS'S OWN, because the real one is a font and there is no target with
    // AppKit in it here (`SessionCardView.portsWidth` is the production one). Two of them, and the
    // pair is the point: measured with the app's own font at 10pt (2026-08-17),
    // `:3000 (MMMMMMMMMMMMMMM) :5173` is 204.1pt over 29 characters, while the same shape whose
    // name is fifteen full-width characters is 220.4pt over the same 29 - so a rule counting
    // characters cannot tell the fitting spelling from the one that runs off the card.
    func narrow(_ text: String) -> Double { Double(text.count) * 5.1 }
    func wide(_ text: String) -> Double { Double(text.count) * 7.6 }
    // AND A THIRD RULER THAT IS NOT THE CHARACTER COUNT TIMES ANYTHING, which is the only kind that
    // can state what changed here: against a linear ruler `w(s) = k · s.count` a budget in points
    // and a budget in characters are the SAME RULE with k divided out, so the two above - useful as
    // they are for the ends of the budget - would pass just as well on the implementation this
    // replaced. This one charges per glyph, the way a font does.
    func perGlyph(_ text: String) -> Double {
        text.reduce(0) { $0 + ($1.isASCII ? 5.1 : 10.0) }
    }
    // THE BUDGET IS WHAT DECIDES HOW MANY NAMES ARE PRINTED, and it is decided here rather than by
    // the layout: the card used to hand two spellings to `ViewThatFits`, which chooses on its
    // candidates' IDEAL width and so measured the whole untruncated identity string against the
    // named ports - a test no ordinary card passes, which left the names silently off.
    check("a card with room says what is holding every port it lists",
          ProcessTree.portsText(holding, budget: 220, width: narrow)
              == ":3000 (next-server) :5173 (node) +1")
    // NAMES GO FROM THE RIGHT AND THE NUMBERS NEVER GO. 155pt is the measured budget of the
    // narrowest card: the one-named spelling is 142.6pt of it and naming both is 177.5pt, so the
    // narrow card still names the first port.
    check("…and a narrow one names as many as fit, from the left",
          ProcessTree.portsText(holding, width: narrow) == ":3000 (next-server) :5173 +1"
              && ProcessTree.portsBudget == 155)
    check("…dropping every name rather than any number when even one will not fit",
          ProcessTree.portsText(holding, budget: 100, width: narrow) == ":3000 :5173 +1")
    check("…and a spelling that cannot fit at all is still the numbers",
          ProcessTree.portsText(holding, budget: 1, width: narrow) == ":3000 :5173 +1")
    // THE SAME STRING, THE SAME CHARACTER COUNT, THE OTHER ANSWER - which is the whole of what
    // changed unit here (codex review of 0cd4a09). A capital-heavy ASCII name does it as readily as
    // a CJK one: the calibration that produced "thirty characters" was taken over lower-case
    // program names, and this app ships in five languages.
    check("a spelling is measured in the points it takes rather than in characters",
          ProcessTree.portsText(holding, width: wide) == ":3000 :5173 +1"
              && ProcessTree.portsText(holding, width: narrow) == ":3000 (next-server) :5173 +1")
    // AND THE PAIR THAT SAYS IT WITHOUT THE RULER'S HELP: two cards whose named spellings are the
    // same LENGTH and different WIDTHS, answered differently. Nothing about a budget in characters
    // can produce these two answers, whatever constant it is calibrated with - which is what the
    // pair of rulers above, both of them the character count times something, cannot state.
    let capitals = ProcessFootprint(processes: 1, cpuPercent: nil, listeningPorts: [3000, 5173],
                                    portNames: [3000: "MMMMMMMMMMMMMMM"])
    // Spelled as escapes rather than as the glyphs themselves, so this file stays ASCII: fifteen
    // full-width characters, exactly as many as the capitals above.
    let fullWidth = ProcessFootprint(processes: 1, cpuPercent: nil, listeningPorts: [3000, 5173],
                                     portNames: [3000: String(repeating: "\u{4E00}", count: 15)])
    check("…the precondition being that the two named spellings are the same length",
          ProcessTree.portsText(capitals, budget: .infinity, width: perGlyph)?.count
              == ProcessTree.portsText(fullWidth, budget: .infinity, width: perGlyph)?.count)
    check("…and the wide one loses its name where the narrow one keeps it, at equal length",
          ProcessTree.portsText(capitals, width: perGlyph) == ":3000 (MMMMMMMMMMMMMMM) :5173"
              && ProcessTree.portsText(fullWidth, width: perGlyph) == ":3000 :5173")
    // And the budget stays clear of the width that would CLIP rather than merely crowd: a 264pt
    // card gives 236pt of content, of which the provider mark (11), three gaps of four and the
    // minimum gutter (6) leave 207 for a ports string that is laid out at its own width and refuses
    // to shrink (`SessionCardView.sessionIdentityRow`).
    check("…and what may be spent is under what would run off the card",
          ProcessTree.portsBudget <= 207)
    // A name nobody could read is simply absent, which is the same shape as a culprit nobody could
    // name on the line above.
    check("a port nobody could be named for shows the number alone",
          ProcessTree.portsText(ProcessFootprint(processes: 1, cpuPercent: nil,
                                                 listeningPorts: [3000, 5173]),
                                width: narrow) == ":3000 :5173")
    check("the cap is the caller's to set, and what is past it is a count",
          ProcessTree.portsText(holding, maxPorts: 1, width: narrow) == ":3000 (next-server) +2")
    // A card holding ONE port has room for a long name that two ports could not both carry: 28
    // characters of `:3000 (Google Chrome Helper)` is 149.5pt measured, inside the budget.
    check("…and a single port is named even by a program with a long name",
          ProcessTree.portsText(ProcessFootprint(processes: 1, cpuPercent: nil,
                                                 listeningPorts: [3000],
                                                 portNames: [3000: "Google Chrome Helper"]),
                                width: narrow) == ":3000 (Google Chrome Helper)")
    check("…with nothing added when everything fits",
          ProcessTree.portsText(holding, maxPorts: 3, budget: 330, width: narrow)
              == ":3000 (next-server) :5173 (node) :8080")
    check("a session listening on nothing has no ports line at all",
          ProcessTree.portsText(ProcessFootprint(processes: 4, cpuPercent: 9,
                                                 listeningPorts: []), width: narrow) == nil)

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
                                                alerts: FootprintAlerts(cpu: .residue)),
                               unit: "procs", agentUnit: "agents").map(\.kind)
              == [.processes, .cpu, .agents, .memory])

    // MARK: the background field

    // THE ONE FIELD ON THIS CARD THAT EXPLAINS AN IDLE SESSION COSTING TWELVE CORES: the jobs whose
    // own shell exited, re-parented to launchd, matched back here by the group they still carry
    // (`SessionProcessGroups`). It was the reading the card could not produce at all before the
    // ledger existed, and it had no assertion of any kind: deleting the whole segment left every
    // suite in this repo green (mutation, 2026-09-01).
    check("a session that has left jobs running behind it says how many, right after the count",
          ProcessTree.line(ProcessFootprint(processes: 6, backgroundProcesses: 2, cpuPercent: 40,
                                            listeningPorts: []),
                           unit: "procs", backgroundUnit: "background")
              == "6 procs · 2 background · 40% CPU")
    // Zero is the ordinary session, which has left nothing behind: a segment reading "0 background"
    // would spend the card's narrowest line saying that nothing happened, on almost every card.
    check("…and a session that has left nothing says nothing about background at all",
          ProcessTree.segments(ProcessFootprint(processes: 6, backgroundProcesses: 0, cpuPercent: 40,
                                                listeningPorts: []),
                               unit: "procs").map(\.kind) == [.processes, .cpu])
    // The word is the caller's, exactly as "procs" and "agents" are: only the surface has the
    // bundle, and only it knows which language the card is being drawn in.
    check("the word for the background jobs is the caller's to choose",
          ProcessTree.line(ProcessFootprint(processes: 3, backgroundProcesses: 1,
                                            cpuPercent: nil, listeningPorts: []),
                           unit: "procs", backgroundUnit: "im Hintergrund")
              == "3 procs · 1 im Hintergrund")

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

    // Both halves of the card's footprint, which was split at the repo's line cap along the seam
    // its own header names: the value line stayed and the trend row became a file of its own
    // (SessionCardTrendRow.swift). Read as one string, so a line moving between them does not
    // silently stop being asserted.
    let cardSource = ["Tally/Views/SessionCardFootprint.swift",
                      "Tally/Views/SessionCardTrendRow.swift"]
        .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.joined()
    let boardCardSource = (try? String(contentsOfFile: "Tally/Views/SessionCardView.swift",
                                       encoding: .utf8)) ?? ""
    let boardSource = (try? String(contentsOfFile: "Tally/Views/SessionBoardView.swift",
                                   encoding: .utf8)) ?? ""
    // Both halves of the store, which was split at the repo's line cap: the sampling pass and the
    // timer that drives it (footprinttrendsurfacechecks.swift says the same).
    let storeSource = ["Tally/Stores/ProcessFootprintStore.swift",
                       "Tally/Stores/ProcessFootprintTiming.swift"]
        .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.joined()
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
          storeSource.contains("carry: cpuCarry[key] ?? ProcessCPUCarry()")
              && storeSource.contains("carried[key] = cpu.carry")
              && storeSource.contains("cpuCarry = carried"))
    check("…and is no longer thrown away with a panel that closed",
          !storeSource.contains("cpuCarry = [:]"))
    // AND THE FIELD ABOVE HAS TO BE FED BY THE MACHINE, which is the half no pure assertion can
    // reach: the count is a subtraction taken in the sampler (what the card ends up counting, less
    // what the tree walk could reach on its own), and a segment rule that draws it perfectly out of
    // a constant zero draws nothing on every card there is.
    check("the tick counts the jobs the walk could not have reached on its own",
          storeSource.contains("backgroundProcesses: orphans.isEmpty")
              && storeSource.contains("? 0 : measured.subtracting(reached[root] ?? []).count"))
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
    check("a warned field is marked as well as coloured, in its own tier's colour",
          cardSource.contains("Text(Image(systemName: \"exclamationmark.triangle.fill\"))")
              && cardSource.contains("guard let tint = level.tint else"
                                     + " { return Text(verbatim: text) }")
              && cardSource.contains(".foregroundStyle(tint)"))
    // AND THE AMBER IS STILL THE AMBER, which is what that indirection has to keep true: this row
    // holds the fields with no machine-level tier to be in (a fan-out, a write rate), so what it
    // draws is the residue colour it always drew (`FootprintAlertLevel.tint`).
    check("…the tier this row can be in still being the app's own warning colour",
          ((try? String(contentsOfFile: "Tally/Views/FootprintSparklineView.swift",
                        encoding: .utf8)) ?? "").contains("case .residue: TallyColor.warning"))
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
          cardSource.contains("Self.figure(trend.figure, level: trend.segment.level)")
              && cardSource.contains("FootprintSparklineView(values: trend.values,"
                                     + " level: trend.segment.level,"))
    check("…and the reader who hears the groups is told the same condition",
          cardSource.contains(".accessibilityLabel([Self.spokenTrends(trends), leftoversSpoken]")
              && cardSource.contains("let reading = spoken([trend.segment])"))
    // THE STATE IS THE SUPERVISOR'S OWN WORD, not a second idleness detector living in the app:
    // only the supervisor can see the transcript, the open tool call and the subagents. `unknown`
    // is deliberately not idle - it is "has not said yet", and warning on it would be a guess.
    //
    // The counting the rule does is per session and survives the tick that took it, which is what
    // "a warning is about a condition that HOLDS" needs; a panel that closes no longer resets it,
    // because the ticks continue behind it and a warning re-earned from nothing on reopening would
    // be ten seconds late saying what was already true.
    // The last of the three is spelled `alertState = painted.alerts` since the painting step moved
    // into ProcessFootprintTiming.swift (2026-09-02, the store passed the cap again). What it
    // still pins is the same sentence: the counting is carried BACK onto the store, so it survives
    // the tick that took it. Both files are read as one string above, so the move itself changed
    // nothing here.
    check("idleness is read from the state the session publishes, and unknown is not idle",
          storeSource.contains("row.state == .idle || row.state == .blocked")
              && storeSource.contains("FootprintAlarm.advance(alertState[one.key] ?? FootprintAlertState(),")
              && storeSource.contains("alertState = painted.alerts"))
    // ONE PRESSURE READING PER TICK, TAKEN OUTSIDE THE LOOP. The memory tier's second witness is a
    // fact about the MACHINE rather than about a card (`MachineMemoryPressure`), so a board of ten
    // cards must not carry ten readings from ten instants. Asserted by WHERE it is read as well as
    // that it is: moved inside the loop this would still compile and still be right most of the
    // time, which is the shape of defect a source check is worth having for.
    //
    // AND THE ALARM ITSELF MOVED OUT OF THE MEASURING LOOP, which is what the second half of this
    // now reads: one of the memory tier's witnesses is about the whole BOARD - whether any other
    // session holds more - and no card can be asked that until every card has been read
    // (`FootprintAlarm.saturatedMemoryShare`).
    check("the machine's memory pressure is read once a tick and handed to the rule",
          storeSource.contains("let pressure = MachineMemoryPressure.current")
              && storeSource.contains("pressure: pressure,\n                                               largestHolder: one.key == heaviest)")
              && (storeSource.range(of: "let pressure = MachineMemoryPressure.current")
                  .flatMap { read in
                      storeSource.range(of: "for one in measurements {")
                          .map { read.upperBound < $0.lowerBound }
                  }) == true)
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
    // the name is resolved from THIS tick's table rather than cached with the port number - and why
    // the pid it is resolved for has to be confirmed as the same process first
    // (`ProcessTree.portNames`, processtreecensuschecks.swift).
    check("…and each port is named from the same table of programs the culprits are",
          storeSource.contains("executable: { paths[$0] }))")
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
    // THE PORTS ARE LAID OUT AT THEIR OWN WIDTH AND THE IDENTITY ASKS LAST, which is a layout
    // priority rather than a list of candidates: `ViewThatFits` chooses on IDEAL width, and a
    // truncating Text's ideal is its whole untruncated string, so a candidate list measured the
    // full identity against the named ports and fell to the bare spelling on every ordinary card.
    check("…the identity giving way for them rather than the two being candidates",
          boardCardSource.contains(".lineLimit(1).truncationMode(.tail).layoutPriority(-1)")
              && boardCardSource.contains("Text(verbatim: ports)")
              && boardCardSource.contains(".lineLimit(1).fixedSize()"))
    check("…and no candidate list is left on this row to choose between them",
          !boardCardSource.contains("identityRow(ports:"))
    // THE READER-END COPY OF A RULE SAYS THE SAME THING THE RULE DOES. The budget changed unit and
    // the paragraph on this card that cites it went on saying "character budget" for a commit,
    // which is the drift a grep closes and a memory does not (codex review of 707a1a7).
    check("…described on the card in the unit the rule actually spends",
          boardCardSource.contains("on a measured POINT budget (`ProcessTree.portsText`)")
              && !boardCardSource.contains("character budget"))
    // AND THE PRIORITY ON THIS ROW IS NOT THE ONE THAT WAS DELETED NEXT DOOR. It reads the same and
    // is not the same: here the row is a plain `HStack` and something really is compressed, while
    // the trend row's was inside a `ViewThatFits`, which never asks a candidate to give room up. A
    // note filing the two under one rule invites the next reader to remove this one too, and this
    // one is what keeps a port number whole.
    check("…and the live priority here not filed under the dead one's rule",
          boardCardSource.contains("THAT PRIORITY IS LOAD-BEARING HERE AND WAS NOT ON THE TREND ROW")
              && !boardCardSource.contains("which is the same rule the trend row's culprit names"))
    // WHAT THE BUDGET DROPPED IS STILL SPOKEN IN FULL, which is the rule the trend row keeps for
    // its own dropped words: both of the limits on this spelling are about room, so both are lifted
    // for a listener who has none.
    check("…and a listener told every name and every port the row had no room for",
          boardCardSource.contains(".accessibilityLabel(sessionPortsSpoken ?? ports)")
              && cardSource.contains("ProcessTree.portsText(footprint, maxPorts: .max,"
                                     + " budget: .infinity,"))
    check("…asked of the same pure rule the assertions above state",
          cardSource.contains("ProcessTree.portsText(footprint, width: Self.portsWidth)"))
    // THE RULE IS PURE AND THE RULER IS NOT: the budget is in points, so the one thing the rule
    // cannot do for itself is turn a spelling into points, and the card hands it a measurement in
    // the font it is about to draw the string in - digits included, since these strings are mostly
    // digits and the row asks for monospaced ones.
    check("…and measured in the very font that row draws, rather than against a guess",
          cardSource.contains("NSAttributedString(string: text, attributes: [.font: portsFont])")
              && cardSource.contains("NSFont.monospacedDigitSystemFont(")
              && cardSource.contains("ofSize: NSFont.preferredFont(forTextStyle: .caption2)"
                                     + ".pointSize, weight: .regular)")
              && boardCardSource.contains(".font(.caption2.monospacedDigit()).foregroundStyle"
                                          + "(.tertiary)"))
}
