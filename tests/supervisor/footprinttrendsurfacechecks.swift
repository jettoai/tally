import Foundation

// THE SURFACES THE TREND REACHES (footprinttrendchecks.swift states the series itself), read from
// their SOURCE because none of them can be constructed here: the store that fills the ring is an
// observable @MainActor store, and the card and the sparkline are SwiftUI. Each of them carries a
// property the arithmetic next door cannot state - what is sampled behind a closed panel, which
// order a row is laid out in, where a warning is drawn.
//
// Split from that file when the two together passed this repository's file length limit, along the
// seam they were already written on: everything here reads a string off disk, and nothing there
// does.

func runFootprintTrendSurfaceChecks() {
    let store = (try? String(contentsOfFile: "Tally/Stores/ProcessFootprintStore.swift",
                             encoding: .utf8)) ?? ""
    let card = (try? String(contentsOfFile: "Tally/Views/SessionCardFootprint.swift",
                            encoding: .utf8)) ?? ""
    let spark = (try? String(contentsOfFile: "Tally/Views/FootprintSparklineView.swift",
                             encoding: .utf8)) ?? ""
    check("the three sources this suite reads are readable from it",
          !store.isEmpty && !card.isEmpty && !spark.isEmpty)
    // THE HISTORY IS THE REASON THE STORE SAMPLES WITH NOTHING OPEN. A trend that only existed
    // while somebody was looking would be empty at the moment it is wanted, since a person opens
    // this board BECAUSE something already felt wrong.
    check("the store samples for the life of the process, not only while the page is up",
          store.contains("func install() { retime() }")
              && store.contains("private static let backgroundInterval: TimeInterval = 10"))
    check("…at the trend's own cadence, so a closed panel adds no point the ring would refuse",
          FootprintTrendSeries.cadence == 10)
    check("…and the app starts it",
          ((try? String(contentsOfFile: "Tally/App/AppDelegate.swift", encoding: .utf8)) ?? "")
              .contains("ProcessFootprintStore.shared.install()"))
    // The one reading that stays behind the panel: ports are a descriptor table per process and a
    // call per socket, and nothing draws them with the board closed.
    check("the ports are never scanned in the background",
          store.contains("let readPorts = viewers > 0 && ticks % Self.portsEveryNTicks == 0"))
    check("…and the agent count is held rather than re-read there",
          store.contains("agents: viewers > 0 ? (readSessionAgents(pid: key)?.reportable ?? 0)"))
    // The measurement is the card's, exactly: Tally's own processes come out of the tree before
    // anything reaches the ring, so the line and the figure above it are about the same thing.
    //
    // WHICH IS NOW PINNED BY CONSTRUCTION rather than by two expressions that happen to agree: the
    // ring is offered the FOOTPRINT the card draws, so a value the card shows and a point the line
    // is drawn from cannot be two different numbers. It could, and did, during a capture: the
    // fixtures were painted after the ring was fed, so every fixture card drew a line of real
    // readings with a fabricated point on the end - and the sparkline measures from zero to its own
    // maximum, which flattened the whole window against the floor and stood the last step upright.
    check("the trend is recorded from the same footprint the card draws",
          store.contains("processes: footprint.processes),")
              && store.contains("memoryBytes: footprint.memoryBytes,")
              && store.contains("trends.record(FootprintTrendSample(cpuPercent: percent,"))
    check("…the fixtures being painted before the ring is offered anything",
          (store.range(of: "DemoUsage.footprint(footprint, at: index)").map { paint in
              store.range(of: "trends.record(").map { paint.lowerBound < $0.lowerBound }
          } ?? nil) == true)
    // The pair of readings still decides whether there IS a rate, which is a question about the
    // machine that no fixture can answer.
    check("…and a fixture cannot invent an interval the machine never measured",
          store.contains("let interval = cpu.percent != nil"
                         + " ? previous.map { now.timeIntervalSince($0.at) } : nil"))
    // The rate and the span it covers are handed over together: the two sampling rates meet inside
    // one bucket every time the board is opened, and a fold that weighted every reading alike made
    // a peak out of the opening (`FootprintTrendSample.folded`).
    check("…and only once there is an interval to state a rate over, which goes with it",
          store.contains("if let interval = one.interval, let percent = footprint.cpuPercent {")
              && store.contains("seconds: interval,"))
    // EVERY FIXTURE IS ON THE BOARD, which is a property of WHICH KEYS the indices are handed out
    // over: the two guards above can drop a root whose session has just ended or whose tree is all
    // Tally's own, and an index decided before them left a hole in the run - the first fixture is
    // the WARNED card, the one state a capture cannot sit and wait for, and three normal-looking
    // cards say nothing about a fourth that never appeared (codex review of 0cd4a09).
    check("the fixtures are handed out over the cards that will be drawn, not over the roster",
          store.contains("DemoUsage.fixtureOrder(of: measurements.map(\\.key))")
              && !store.contains("fixtureOrder(of: roots.map"))
    let guarded = store.range(of: "guard !measured.isEmpty else { continue }")
    let keyed = store.range(of: "DemoUsage.fixtureOrder(of:")
    check("…decided after every guard that can drop one of them",
          (guarded.map { edge in keyed.map { edge.upperBound < $0.lowerBound } } ?? nil) == true)
    // Swept against the BOARD rather than against this tick's readings: a tree that could not be
    // read for one pass has no entry, and sweeping on that would throw a quarter hour of history
    // away over a single unreadable tick.
    check("a session that left the board takes its series with it",
          store.contains("trends.retain(Set(roots.map { String($0.0) }))"))
    // The regression the background rate introduces if it is written carelessly: the old store
    // dropped every reading when the last viewer went, which would now throw the history away
    // every time the panel closed.
    let ending = (store.components(separatedBy: "func endViewing()").last ?? "")
        .components(separatedBy: "private func retime()").first ?? ""
    check("closing the panel drops the ports and nothing else",
          ending.contains("ports = [:]") && !ending.contains("footprints = [:]")
              && !ending.contains("previousSample = [:]"))

    // THE THREE PIECES OF A GROUP ARE ABOUT ONE NUMBER, which is the whole correction: the figure
    // sits between the shape it arrived by and the ceiling it came off, and the row above it holds
    // only the fields that have no shape.
    check("the figure is drawn inside its own metric's group",
          card.contains("FootprintSparklineView(values: trend.values, level: trend.segment.level)")
              && card.contains("Self.figure(trend.figure, level: trend.segment.level)"))
    check("…and it is the loudest small text on the card",
          card.contains(".foregroundStyle(.primary)")
              && card.contains(".font(.caption2.monospacedDigit())"))
    check("…with the peak beside it the quietest",
          card.contains("Text(verbatim: trend.peak.map { Self.peakMark + $0 } ?? \"\")\n")
              && card.contains(".foregroundStyle(.tertiary)"))
    check("the row above the readings is quieter than they are",
          card.contains(".font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)"))
    // A metric sampled once has a number and no line: the group falls back to the figure alone
    // rather than waiting half a minute to say anything at all.
    check("a metric with too few readings draws its figure without a line",
          card.contains("let drawn = readings.count >= FootprintSparkline.minimumReadings"))
    // BUILT FROM THE READINGS AND NEVER FROM THE HISTORY, which is what keeps an idle session's
    // figures on its card: a group whose existence depended on having a peak worth printing would
    // take the whole CPU group off every session sitting at nought per cent, which is most of the
    // board most of the time.
    check("a group exists because there is a figure, not because there is a peak",
          card.contains("return FootprintTrendMetric.allCases.compactMap { metric in")
              && card.contains("guard let segment = fields[metric] else { return nil }"))
    // ONE ORDER ON EVERY CARD, WHICHEVER FIELDS ARE WARNED. The value line these groups take their
    // words from is reordered by a warning, which is right for a sentence truncated at its tail and
    // wrong for a row of figures read DOWN a board: an alarmed session printed
    // `procs · 4.1 GB · 1%` beside a calm neighbour printing `procs · 1% · 3.4 GB`, so the same
    // column carried a percentage on one card and a memory figure on the next (Albert, 2026-08-16).
    let calm = ProcessFootprint(processes: 4, cpuPercent: 1, memoryBytes: 3_400_000_000,
                                listeningPorts: [])
    var alarmed = calm
    alarmed.memoryBytes = 4_100_000_000
    alarmed.alerts = FootprintAlerts(memory: .residue)
    func trended(_ footprint: ProcessFootprint) -> [FootprintTrendMetric] {
        ProcessTree.segments(footprint, unit: "procs").compactMap { FootprintTrendMetric($0.kind) }
    }
    check("a warning does reorder the value line these groups are read off",
          trended(alarmed) == [.processes, .memory, .cpu] && trended(calm) == [.processes, .cpu,
                                                                              .memory])
    check("…and the row is built in the metric's own order instead, so two cards line up",
          card.contains("return FootprintTrendMetric.allCases.compactMap { metric in")
              && !card.contains("sessionFootprintSegments.compactMap"))
    // The warning is not lost by staying put: it is on the group whose number it is about, and this
    // row says it in COLOUR ALONE - the figure, the line and both of its dots turn amber together.
    //
    // WHICH IS THE ONE PLACE IN THIS APP THAT DROPS THE MARK, and it took both alternatives being
    // built to settle: a triangle is about nine points of text, so in the row it pushed every figure
    // to its right along, on the one row this card had just pinned into fixed columns to stop
    // exactly that; moved onto the shape it stopped moving anything and covered nearly half of a
    // twenty-four point line, peak dot included. A mark that destroys what it marks is not a second
    // channel, so at this size the second channel is the amber's own luminance step and the spoken
    // sentence below (Albert, 2026-08-16, having seen both). The row of WORDS above keeps its
    // triangle, and so does every account card.
    check("…the warned group carrying its colour where it stands",
          card.contains("guard let tint = level.tint else"
                            + " { return Text(verbatim: text).foregroundStyle(.primary) }")
              && card.contains("return Text(verbatim: text).foregroundStyle(tint)"))
    // Asked once per piece and answered in one place, so the three cannot drift into a figure that
    // is warned in parts: the line, the peak dot and the current dot each state the grey they wear
    // on a calm card AND the rank they keep on a warned one, and take both from the same rule.
    check("…the line and both of its dots turning amber with the figure",
          spark.contains("guard let tint = level.tint else { return AnyShapeStyle(calm) }")
              && spark.contains("return AnyShapeStyle(tint.opacity(step))")
              && spark.contains(".stroke(tone(calm: .tertiary, step: Self.alertLine),")
              && spark.contains("tone(calm: .secondary, step: Self.alertPeak)")
              && spark.contains("tone(calm: .primary, step: Self.alertCurrent)"))
    // THREE STEPS OF ONE COLOUR, IN THE ORDER THE CALM CARD'S GREYS ARE: quietest at the line and
    // loudest at the current reading, mirroring tertiary, secondary, primary. It was not a mirror
    // before - the line and the current dot were both full amber, so the shape was as loud as the
    // reading it is about and the ceiling was the only quiet thing on a warned figure.
    //
    // READ AS NUMBERS RATHER THAN AS THREE STRINGS, which is the whole repair to this assertion:
    // what stood here matched a fragment that broke across a line ending, so setting the two ends
    // to the SAME value left it green (ledger P4). Parsed, an edit that flattens any two of the
    // three turns it red.
    func alertStep(_ name: String) -> Double? {
        guard let mark = spark.range(of: "private static let \(name): Double = ") else { return nil }
        return Double(spark[mark.upperBound...].prefix { $0.isNumber || $0 == "." })
    }
    let quiet = alertStep("alertLine"), middle = alertStep("alertPeak")
    let loud = alertStep("alertCurrent")
    check("the warned figure's three pieces each state their own step of the colour",
          [quiet, middle, loud].allSatisfy { step in (step ?? 0) > 0 && (step ?? 0) <= 1 })
    check("…in the order the calm card reads in, quietest line to loudest reading",
          (quiet ?? 0) < (middle ?? 0) && (middle ?? 0) < (loud ?? 0))
    // AND THE SAME THREE STEPS IN EITHER TIER'S COLOUR, which is what keeps the second one from
    // arriving with a loudness order of its own: the tier decides the hue and nothing else, so the
    // step constants above are asked once and answered for whichever colour is in them.
    check("which colour a tier wears is stated once, for every surface that draws one",
          spark.contains("case .calm: nil")
              && spark.contains("case .residue: TallyColor.warning")
              && spark.contains("case .saturation: TallyColor.critical"))
    check("…and every surface that draws one asks that rather than naming a colour itself",
          card.components(separatedBy: "TallyColor.warning").count - 1 == 0
              && card.components(separatedBy: "TallyColor.critical").count - 1 == 0)
    // THE MACHINE-LEVEL TIER BORROWS THE RED THIS APP ALREADY MEANS "NOW" WITH, rather than adding
    // a third vocabulary: the blocked session's dot, its state word and the account meter's last
    // stop are the same literal, and a tree taking the machine belongs in that sentence.
    check("…the red being the state axis's own red and not a second one",
          ((try? String(contentsOfFile: "Tally/Views/TallyVisualStyle.swift", encoding: .utf8))
              ?? "").contains("static let critical = Color("))
    // A TIER IS A DIFFERENT SENTENCE, not a louder one, for the reader who gets no colour at all:
    // the amber ones name the IDLENESS, because that is the whole of why they are warnings, and the
    // red ones name the MACHINE, because that is why they are said while a turn is running. One
    // sentence for both would tell a listener a working session is idle.
    check("the spoken row says which tier it is rather than saying warned twice",
          card.contains("L(\"using most of this machine's CPU\")")
              && card.contains("L(\"holding most of this machine's memory\")")
              && card.contains("L(\"high CPU while nothing is running\")")
              && card.contains("L(\"holding a lot of memory while nothing is running\")"))
    check("…and asks the level first, so a tier added here cannot inherit a sentence by omission",
          card.contains("static func warning(about kind: ProcessFootprintSegment.Kind,")
              && card.contains("level: FootprintAlertLevel) -> String?")
              && card.contains("case .calm: nil"))
    // The disk has no machine-level tier to name (a write rate has no ceiling to be a share of), so
    // that pair says nothing rather than borrowing the idle sentence for a state it cannot be in.
    let saturationArm = (card.components(separatedBy: "case .saturation:").last ?? "")
        .components(separatedBy: "case .residue:").first ?? ""
    check("…the machine-level arm naming the two readings that have a share and no others",
          saturationArm.contains("case .cpu:") && saturationArm.contains("case .memory:")
              && !saturationArm.contains("case .disk:"))
    for key in ["using most of this machine's CPU", "holding most of this machine's memory"] {
        let entry = (((try? Data(contentsOf: URL(fileURLWithPath:
            "Tally/Resources/Localizable.xcstrings")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["strings"]
            as? [String: Any])?[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any] ?? [:]
        check("\"\(key)\" is translated into every language Tally ships",
              AppLocaleSupported.allSatisfy { localizations[$0] != nil })
    }
    // THE NEGATIVE HALF OF THE SAME CONTRACT, because a mark is the obvious thing to add back to a
    // warning: nothing on this row draws one, at any width, whether or not the group has a line yet.
    check("…and no triangle rides on this row at all",
          !spark.contains("exclamationmark.triangle")
              && !card.contains("Self.drawn(trend.figure")
              && !card.contains("marked:"))
    // A session in its first half-minute has a figure and no shape, and it is warned the same way:
    // putting the mark back for those thirty seconds would buy a channel this row cannot read
    // anyway, at the price of the reflow the columns exist to prevent.
    check("…a group with no line yet being warned in the same colour and nothing else",
          card.contains("static func figure(_ text: String, level: FootprintAlertLevel) -> Text")
              && card.contains("Self.figure(trend.figure, level: trend.segment.level)"))
    // The row above is unchanged: it has no columns to hold still, and its fields are one sentence.
    check("the fields with no shape are still marked in the sentence itself",
          card.contains("Self.drawn(part.element.text, level: part.element.level)")
              && card.contains("Text(Image(systemName: \"exclamationmark.triangle.fill\"))"))
    // A peak equal to the reading printed beside it is the same number twice with an arrow between
    // them, which is what makes the row fit a narrow card in the ordinary case.
    check("a peak that equals the reading is not printed",
          card.contains("peak: peak == figure ? nil : peak)"))
    // A CEILING UNDER THE NUMBER IT IS THE CEILING OF, which is what the ring alone produces: its
    // newest point is up to a bucket behind the live figure, so a session that has just jumped to
    // 16% has a fifteen-minute maximum of 1%. Taken together they agree by construction.
    check("the ceiling is taken over the live reading as well as the kept ones",
          card.contains("let peak = [series?.peak(of: metric), now].compactMap { $0 }.max()"))
    // WHAT GIVES WAY WHEN THE CARD IS TOO NARROW, in a stated order: the figures and their lines
    // are never dropped, and the ceilings go one at a time.
    check("the row degrades by dropping ceilings rather than figures",
          card.contains("ViewThatFits(in: .horizontal)")
              && card.contains("trendRow(trends, peaks: 3, asides: .all)")
              && card.contains("trendRow(trends, peaks: 0, asides: .all)"))
    // AND THE CULPRITS OUTLIVE THE CEILINGS, which is the order that moved when the memory figure
    // gained a name. Attribution is what this row was asked for - a memory reading with no name
    // cannot say whether those gigabytes are the session's own Claude Code or the thing it started
    // - and a ceiling is a second reading of a number already printed. ONE LEDGER FOR THE WHOLE
    // LADDER, re-measured at 10pt (2026-08-17) and stated the same way where the row itself is
    // written (`SessionCardView.sessionFootprintTrends`): the three shapes, the three figures and
    // the unit word are 208pt, the unit word plus the memory's name takes it to 244, and the rung
    // that has dropped the unit word and kept BOTH names is 240 - all of them against the 236pt a
    // 264pt card gives its content, so a narrow card DOES reach these rungs rather than them being
    // decoration.
    let chain = card.components(separatedBy: "trendRow(trends, peaks:").dropFirst()
        .map { "peaks:" + ($0.components(separatedBy: ")").first ?? "") }
    check("every candidate keeps its culprits until all three ceilings are gone",
          chain.prefix(4).allSatisfy { $0.contains("asides: .all") }
              && chain.prefix(4).allSatisfy { !$0.contains("peaks: 0, asides: .culpritsOnly") })
    // Then the unit word goes before the names do: `procs` is what the figure counts and a reader
    // of a row whose other two figures carry their own units can infer it, while a culprit's name
    // is a fact only this card holds.
    //
    // AND THE TWO NAMES GO ONE AT A TIME, which they did not when this row was first laid out this
    // way: both are culprits, so one rung kept or dropped them together and a card that could hold
    // one name but not two went straight to holding neither (213pt with the memory's holder alone
    // against 240pt with the CPU's as well, on the 236pt a 264pt card gives its content). The
    // session that names a process for both readings is the busy one somebody has the board open
    // for, so it was the reported defect's own case (codex review of 0cd4a09).
    check("…and then the unit word goes, then one name, then the other",
          chain.suffix(4).map { $0 } == ["peaks: 0, asides: .all",
                                         "peaks: 0, asides: .culpritsOnly",
                                         "peaks: 0, asides: .memoryCulpritOnly",
                                         "peaks: 0, asides: .none"])
    // THE WHOLE TABLE RATHER THAN THE INTERESTING ROW OF IT: every metric on this row is asked both
    // questions, so a metric added here cannot inherit an answer by omission and a rung cannot
    // quietly change which words it keeps.
    check("…with the difference between a unit and a culprit stated once, by the metric",
          FootprintTrendMetric.allCases.map(\.asideNamesACulprit) == [false, true, true])
    check("…and which single name outlives the other stated the same way",
          FootprintTrendMetric.allCases.map(\.asideSurvivesAlone) == [false, false, true])
    // THE RUNGS ONLY EVER GIVE THINGS UP, which is what makes that list an order rather than four
    // arrangements: whatever a rung keeps, every rung above it keeps too.
    check("…each rung keeping a subset of the words the rung above it keeps",
          FootprintTrendMetric.allCases.allSatisfy {
              !$0.asideSurvivesAlone || $0.asideNamesACulprit
          })
    check("…and the row asking the metric rather than testing for one by name",
          card.contains("case .culpritsOnly: metric.asideNamesACulprit")
              && card.contains("case .memoryCulpritOnly: metric.asideSurvivesAlone")
              && !card.contains("metric != .processes") && !card.contains("metric == .memory"))
    // A NAME IS DROPPED BY THE CANDIDATE LIST OR NOT AT ALL. A `layoutPriority(-1)` stood on this
    // word claiming to catch "the name too long for even the narrowest candidate", which cannot
    // happen: `ViewThatFits` takes a candidate only when its ideal width already fits, and the one
    // it falls back on when none do has no names in it - so nothing was ever asked to give room up
    // (codex review of 0cd4a09, dead code with a note explaining a mechanism that could not run).
    check("…and no priority pretending to shrink a name the candidates already decided about",
          !card.contains("Text(verbatim: aside).foregroundStyle(.tertiary).layoutPriority"))
    // Read off the source like everything else here, because the order lives on a SwiftUI view this
    // harness cannot construct: every metric is in it (so no group is silently barred from ever
    // printing a peak) and the CPU is the last one dropped.
    check("…and every metric is somewhere in that order, the spikiest of them last to go",
          card.contains("static let peakOrder: [FootprintTrendMetric] = [.cpu, .memory, .processes]")
              && FootprintTrendMetric.allCases.count == 3)
    check("the card draws the trend row it builds",
          ((try? String(contentsOfFile: "Tally/Views/SessionCardView.swift", encoding: .utf8)) ?? "")
              .contains("sessionCardLine { sessionFootprintTrends }"))

    // A ROW OF LIVE NUMBERS LAID OUT TO ITS OWN CONTENT IS A ROW IN MOTION: every figure is re-read
    // every two seconds, so a CPU going from 9% to 10% pushed the memory figure along with it.
    check("every figure is held in a column as wide as its own widest reading",
          card.contains("Self.column(trend.metric.widestFigure)")
              && card.contains("Self.column(Self.peakMark + trend.metric.widestFigure)"))
    check("…sized by a hidden copy of that reading rather than by a number in points",
          card.contains("ZStack(alignment: .trailing)")
              && card.contains("Text(verbatim: widest).hidden()"))
    // A peak is hidden exactly when the reading has just become the highest of the window, so on a
    // climbing session the arrow leaves and comes back every few seconds; a column held only while
    // there is something to put in it would take the group beside it along both ways.
    check("…and a tracked metric keeps its ceiling's column whether or not it has one to print",
          card.contains("if named.contains(trend.metric), !trend.values.isEmpty {")
              && card.contains("Text(verbatim: trend.peak.map { Self.peakMark + $0 } ?? \"\")"))
    check("…and the widest cases are the ones a session actually reaches",
          FootprintTrendMetric.cpu.widestFigure == "100%"
              && FootprintTrendMetric.memory.widestFigure == "99.9 GB"
              && FootprintTrendMetric.processes.widestFigure == "99")

    // THE TWO DOTS ARE THE TWO FIGURES PRINTED BESIDE THE LINE, and the bright one is only honest
    // because the row hands over the live reading with the kept ones: from the ring alone it marked
    // 20% on a session whose card said 400%, the newest KEPT point being up to a bucket old.
    check("the line marks the peak and the newest reading, quiet and bright",
          spark.contains("if let index = FootprintSparkline.peakIndex(values)")
              && spark.contains("dot(at: points[index], diameter: Self.peakDot)")
              && spark.contains("dot(at: last, diameter: Self.currentDot)"))
    check("…and the newest one is this instant's reading, drawn and never stored",
          card.contains("? readings + [now].compactMap { $0 } : []"))

    // A CAPTURE MUST NOT SHIP THIS MACHINE'S OWN PORTS. These fixtures exist for the README and
    // marketing shots, and the branch that leaves a field alone keeps whatever the real reading
    // held - which for the ports is a dev server somebody has running right now. So the clearing
    // happens once, before the fixtures branch, where no new fixture can miss it.
    let demo = (try? String(contentsOfFile: "Tally/Core/DemoUsage.swift", encoding: .utf8)) ?? ""
    let fixture = (demo.components(separatedBy: "static func footprint(_ real: ProcessFootprint")
        .last ?? "").components(separatedBy: "switch index % 4").first ?? ""
    check("the fixture clears every field it could leak before it fills any of them in",
          fixture.contains("one.listeningPorts = []") && fixture.contains("one.portNames = [:]")
              && fixture.contains("one.diskWriteBytesPerSecond = nil"))
    // The ordering the fixtures are keyed by buys STABILITY and nothing else, which is what the
    // note beside it now says: sorted pid STRINGS are neither the board's seating nor numeric, so
    // which card is the warned one cannot be predicted - only that it stays put while a capture
    // runs and a shutter is pressed twice.
    check("…and the fixture each card gets is stable for the length of a capture",
          demo.contains("for (index, key) in Set(keys).sorted().enumerated()")
              && demo.contains("WHAT THE ORDER BUYS IS STABILITY, NOT AN ARRANGEMENT")
              && !demo.contains("keyed by the board's own order"))
    // COUNTED OVER THE DISTINCT KEYS, which closes the same hole by its other route: a key listed
    // twice takes two indices and answers to only the second, so `["100", "100", "200"]` numbered
    // straight through leaves index 0 - the warned card - belonging to nobody. Read off the source
    // because this suite has no target that compiles DemoUsage.swift (it reaches AccountUsage, the
    // token history and the advisor); what can be pinned is that the de-duplication is there and
    // that the shape it replaced is not.
    check("…every fixture having somebody to belong to even if a key arrives twice",
          demo.contains("Set(keys).sorted()") && !demo.contains("in keys.sorted().enumerated()")
              && demo.contains("COUNTED OVER THE DISTINCT KEYS"))
    // FOUR STATES, AND THE COUNT THE INDEX IS TAKEN MODULO IS THE SAME FOUR. A fixture added to the
    // switch without the divisor moving is a fixture no card can ever be handed, which is the same
    // silent hole as an index handed out over the wrong keys and is invisible in exactly the same
    // way: three normal-looking cards say nothing about a fourth that never appeared.
    let divisor = Int(String((demo.components(separatedBy: "switch index % ").last ?? "")
        .prefix { $0.isNumber })) ?? 0
    let arms = (demo.components(separatedBy: "switch index % 4").last ?? "")
        .components(separatedBy: "return one").first ?? ""
    let branches = (0 ..< 9).filter { arms.contains("case \($0):") }.count
        + (arms.contains("default:") ? 1 : 0)
    check("the number of fixtures and the number the index is taken modulo are one number",
          divisor == 4 && branches == divisor)
    // THE ONE A LIVE BOARD CANNOT POSE FOR, twice over: a machine-level reading takes minutes of a
    // tree holding most of the machine to earn (`FootprintAlarm.outlastsABuild`), and the row's
    // lower rungs are only reached by a card whose blamed process is named like a real one.
    let saturated = (arms.components(separatedBy: "case 2:").last ?? "")
        .components(separatedBy: "default:").first ?? ""
    check("the fourth fixture is the machine-level card, red on both readings",
          saturated.contains("FootprintAlerts(cpu: .saturation, memory: .saturation)"))
    check("…and it is the one that names a culprit at the length real program names run to",
          saturated.contains("one.cpuLeader = \"Google Chrome Helper\"")
              && saturated.contains("one.memoryLeader ="))
    check("…with readings a machine-level card would actually be showing",
          saturated.contains("one.cpuPercent = 1180")
              && saturated.contains("one.memoryBytes = 68_000_000_000"))
    // AND IT CLAIMS THE CARD RATHER THAN THE VERDICT. The tier flags are set, not earned: what the
    // rule wants is a share of THIS machine's own memory and cores (`MachineCapacity`), which no
    // number written into a fixture can promise on hardware it has never seen.
    check("…the fixture saying so rather than implying the rule would have agreed",
          saturated.contains("The tier flags are SET rather than"))

    // A PORT READING IS HELD BETWEEN THE TICKS THAT DO NOT TAKE ONE, and a pid is not an identity:
    // the machine hands numbers out again, so what is cached with the port is WHEN its holder
    // started, and the name is printed only while the pid still belongs to that same process. The
    // program's path was what this used to cache, which cannot see the recycling it matters most
    // for - a restarted node under a tree of them (codex review of 0cd4a09).
    check("the ports are cached with the identity of the process holding them",
          store.contains("ProcessTree.held(ProcessTree.listeningPorts(of: measured)) {")
              && store.contains("private var ports: [String: [UInt16: ProcessPortHolder]] = [:]")
              && store.contains("if viewers > 0 { for one in processes"
                                + " { startedAt[one.pid] = one.startedAt } }"))
    check("…and named only while the pid is still that process",
          store.contains("portNames: ProcessTree.portNames(holding, startedAt: { startedAt[$0] },"))

    // EVERY WORD THIS ROW ADDED IS IN THE CATALOGUE, in all four translations: the app ships five
    // languages, and a string that reaches a person in English on a Japanese machine is a missing
    // translation nobody notices until they see it.
    let catalogue = (try? Data(contentsOf: URL(fileURLWithPath:
        "Tally/Resources/Localizable.xcstrings")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let strings = catalogue?["strings"] as? [String: Any] ?? [:]
    check("the string catalogue is readable from this suite", !strings.isEmpty)
    for metric in FootprintTrendMetric.allCases {
        let entry = strings[metric.peakLabelKey] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any] ?? [:]
        check("\(metric.peakLabelKey) is translated into every language Tally ships",
              AppLocaleSupported.allSatisfy { localizations[$0] != nil })
        // The spoken sentence is one catalogue entry per metric rather than a name substituted into
        // a shared one, so a translator sees every phrase whole.
        check("…and carries the one placeholder the peak is put into",
              metric.peakLabelKey.components(separatedBy: "%@").count == 2)
    }
}
