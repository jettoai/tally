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
    // BOTH HALVES OF THE STORE, because it was split at the repo's line cap and the assertions
    // here are about the pass AND about when it runs (ProcessFootprintTiming.swift). Read as one
    // string so a line moving between the two files does not silently stop being asserted.
    let store = ["Tally/Stores/ProcessFootprintStore.swift",
                 "Tally/Stores/ProcessFootprintTiming.swift"]
        .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.joined()
    // BOTH HALVES OF THE CARD'S FOOTPRINT, for the reason the store's two are read as one: the
    // trend row became a file of its own at this repository's line cap
    // (SessionCardTrendRow.swift), along the seam the header of the other one already named, and a
    // suite that read only the first would have gone quietly green on every assertion about the
    // row. Read as one string, so a line moving between them cannot stop being asserted.
    let card = ["Tally/Views/SessionCardFootprint.swift", "Tally/Views/SessionCardTrendRow.swift"]
        .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.joined()
    let spark = (try? String(contentsOfFile: "Tally/Views/FootprintSparklineView.swift",
                             encoding: .utf8)) ?? ""
    // AND THE LAYERS THAT DRAW IT, which is where the figure's motion went: the shell decides what
    // is drawn and the layers commit it, so a suite that read only the shell would go quietly green
    // on every assertion about how a reading arrives (`FootprintSparklineLayerView`).
    let layers = (try? String(contentsOfFile: "Tally/Views/FootprintSparklineLayerView.swift",
                              encoding: .utf8)) ?? ""
    // AND THE LAYERS THAT DRAW THE FIGURE BESIDE IT, which went the same way and for the same
    // reason: the digits are one `CATextLayer` per character now, so a suite that read only the
    // view tree would go quietly green on every assertion about how a figure changes
    // (`RollingFigureLayerView`).
    let rolling = (try? String(contentsOfFile: "Tally/Views/RollingFigureLayerView.swift",
                               encoding: .utf8)) ?? ""
    check("the five sources this suite reads are readable from it",
          !store.isEmpty && !card.isEmpty && !spark.isEmpty && !layers.isEmpty
              && !rolling.isEmpty)
    // THE HISTORY IS THE REASON THE STORE SAMPLES WITH NOTHING OPEN. A trend that only existed
    // while somebody was looking would be empty at the moment it is wanted, since a person opens
    // this board BECAUSE something already felt wrong.
    check("the store samples for the life of the process, not only while the page is up",
          store.contains("func install() { retime() }")
              && store.contains("static let backgroundInterval: TimeInterval = 10"))
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
          card.contains("FootprintSparklineView(values: trend.values, level: trend.segment.level,")
              && card.contains("Self.figure(trend.figure, level: trend.segment.level)"))
    check("…and it is the loudest small text on the card",
          card.contains(".foregroundStyle(.primary)")
              && card.contains(".font(.caption2.monospacedDigit())"))
    check("…with the peak beside it the quietest",
          card.contains("Text(verbatim: FootprintPeak.spelled(trend.peak))\n")
              && card.contains(".foregroundStyle(.tertiary)"))
    check("the row above the readings is quieter than they are",
          card.contains(".font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)"))
    // A metric sampled once has a number and no line: the group falls back to the figure alone
    // rather than waiting half a minute to say anything at all.
    check("a metric with too few readings draws its figure without a line",
          card.contains("let drawn = FootprintSparkline.drawn(readings, now: now)")
              && FootprintSparkline.drawn([1], now: 3).isEmpty)
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
          layers.contains("guard let tint = level.tint else { return calm.cgColor }")
              && layers.contains("return NSColor(tint).withAlphaComponent(step).cgColor")
              && layers.contains("line.strokeColor = tone(calm: .tertiaryLabelColor,"
                                 + " step: FootprintSparklineView.alertLine)")
              && layers.contains("peak.fillColor = tone(calm: .secondaryLabelColor,"
                                 + " step: FootprintSparklineView.alertPeak)")
              && layers.contains("current.fillColor = tone(calm: .labelColor,"
                                 + " step: FootprintSparklineView.alertCurrent)"))
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
        guard let mark = spark.range(of: "static let \(name): CGFloat = ") else { return nil }
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
    // WHAT IS FORBIDDEN IS A GLYPH IN A FIGURE'S COLUMN, which is what this used to say by proxy: it
    // banned the string `marked:` anywhere in the file, on the reasoning that a mark would arrive as
    // a flag on the figure. The row has since gained a mark that is none of those things - the
    // machine's flame, at the trailing END of the row, on the leftovers count rather than on any
    // reading (`SessionLeftoversMark`) - so the ban is stated as what it is about instead: the
    // groups themselves draw no glyph, at any width, warned or not.
    let groups = (card.components(separatedBy: "ForEach(trends) { trend in").last ?? "")
        .components(separatedBy: "leftoversMark").first ?? ""
    check("…and no triangle rides on this row at all",
          !spark.contains("exclamationmark.triangle")
              && !card.contains("Self.drawn(trend.figure")
              && !groups.isEmpty && !groups.contains("Image(systemName:")
              && !groups.contains("exclamationmark.triangle"))
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
              && card.contains("Self.column(FootprintPeak.mark + trend.metric.widestFigure)"))
    check("…sized by a hidden copy of that reading rather than by a number in points",
          card.contains("ZStack(alignment: .trailing)")
              && card.contains("Text(verbatim: widest).hidden()"))
    // A peak is hidden exactly when the reading has just become the highest of the window, so on a
    // climbing session the arrow leaves and comes back every few seconds; a column held only while
    // there is something to put in it would take the group beside it along both ways.
    check("…and a tracked metric keeps its ceiling's column whether or not it has one to print",
          card.contains("if named.contains(trend.metric), !trend.values.isEmpty {")
              && card.contains("Text(verbatim: FootprintPeak.spelled(trend.peak))")
              && FootprintPeak.spelled(nil).isEmpty)
    // HOW A CEILING IS SPELLED, stated as a value rather than as a line of source. The arrow is the
    // whole of what marks a figure as the ceiling rather than as the current reading.
    check("…a ceiling being spelled with the arrow that marks it",
          FootprintPeak.spelled("42%") == FootprintPeak.mark + "42%"
              && FootprintPeak.mark == "\u{2191}")
    // AND BOTH SURFACES ASK FOR IT rather than composing it. Under the default roller the `Text` is
    // hidden and what a reader sees is the layers' copy of the string (`FigureRoller.layers`), so
    // the figure handed to the motion is not a second-best spelling of that reading: it IS what is
    // read, and written out twice the two drifted the day they were introduced - the motion was
    // handed the bare number, so every ceiling on the board lost its arrow (codex review of
    // 40054b3, where nine new assertions all stayed green).
    check("…and the ceiling the layers draw is spelled by the very function the Text asks",
          card.contains("Text(verbatim: FootprintPeak.spelled(trend.peak))")
              && card.contains(".figureMotion(FootprintPeak.spelled(trend.peak), value: nil,")
              && !card.contains("trend.peak.map {"))
    check("…and the widest cases are the ones a session actually reaches",
          FootprintTrendMetric.cpu.widestFigure == "100%"
              && FootprintTrendMetric.memory.widestFigure == "99.9 GB"
              && FootprintTrendMetric.processes.widestFigure == "99")

    // THE TWO DOTS ARE THE TWO FIGURES PRINTED BESIDE THE LINE, and the bright one is only honest
    // because the row hands over the live reading with the kept ones: from the ring alone it marked
    // 20% on a session whose card said 400%, the newest KEPT point being up to a bucket old.
    check("the line marks the peak and the newest reading, quiet and bright",
          layers.contains("let ceiling = FootprintSparkline.peakIndex(values).flatMap {")
              && layers.contains("place(peak, diameter: FootprintSparklineView.peakDot,"
                                 + " at: now.peak)")
              && layers.contains("place(current, diameter: FootprintSparklineView.currentDot,"
                                 + " at: now.current)"))
    check("…and the newest one is this instant's reading, drawn and never stored",
          card.contains("let drawn = FootprintSparkline.drawn(readings, now: now)")
              && FootprintSparkline.drawn([1, 9], now: 3) == [1, 9, 3])

    // THE FIGURE TRAVELS TO ITS NEW READING RATHER THAN BEING REPAINTED (Albert, 2026-09-03). A
    // board redraws every couple of seconds, and every number and every line on it used to arrive
    // between two frames: the digits swapped and the whole outline was replaced, which reads as a
    // flicker rather than as a change.
    //
    // AND THE INTERPOLATION IS THE RENDER SERVER'S, NOT THIS PROCESS'S, which is the property this
    // row's cost turned on (Albert, 2026-09-03, feeling the board lag). A `Shape` whose
    // `animatableData` is the series has a layout computer that depends on the shape's value, so
    // every frame of every spring made the leaf dirty and nothing between it and the root truncates
    // that: the whole panel was laid out per frame, at 41.3% of one core against 12.4% still. What
    // is committed now is one animation per reading, and the frames between them cost nothing here.
    check("the readings are interpolated by a layer rather than by the view tree",
          layers.contains("struct FootprintSparklineLayerView: NSViewRepresentable")
              && !spark.contains(": Shape {")
              && !spark.contains("var animatableData")
              && !spark.contains("Circle()"))
    // AND THE MEASUREMENT IT ANSWERS WITH IS A CONSTANT, which is the other half of it: a leaf whose
    // size cannot depend on its contents cannot make an ancestor's layout computer dirty either,
    // and the seven-candidate ladder above this measures a constant rather than walking a figure
    // seven times (`SessionCardTrendRow.sessionFootprintTrends`).
    check("…and the size it reports asks its own contents nothing",
          layers.contains("func sizeThatFits(_ proposal: ProposedViewSize,"
                          + " nsView: FootprintSparklineLayerHost,")
              && layers.contains("        FootprintSparklineView.size\n    }"))
    // THE THREE PIECES OF A GROUP TRAVEL ON ONE ANIMATION, which is the property worth pinning: the
    // line and both of its dots are computed from the SAME pair of series, so a dot can never leave
    // the line it sits on. The dots were `Circle`s at an `.offset` - which interpolates between two
    // POSITIONS while the line interpolates between two SERIES - and two interpolations of one
    // figure is exactly that defect.
    check("…both dots travelling on the same pair of series the line does",
          layers.contains("let (before, after) = FootprintSparkline.aligned(previous, values)")
              && layers.contains("let start = geometry(before, grow: grow)")
              && layers.contains("let end = geometry(after)")
              && layers.contains("private func geometry(_ values: [Double], grow: Double = 1)"))
    // AND THE ONE DOT THAT IS NOT ON THAT PAIR OF SERIES IS THE ONE FADING OUT. A window still
    // filling is aligned by repeating its newest reading, which re-spaces every point at the NEW
    // gap: the dot drawn at x=24 of a two point series is at x=12 of the three point one it is read
    // as. The dot that TRAVELS has to start from that re-spaced point, being on an outline that
    // starts there too; the stand-in is on no line at all and belongs where the reader last saw it,
    // which is what its own prose already claimed (codex review of 36b653b).
    check("…and the dot that fades out does so where it was actually standing",
          layers.contains("let stood = peak.isHidden ? nil :"
                          + " (peak.presentation()?.position ?? peak.position)\n        redraw()")
              && layers.contains("crossfadePeak(from: stood)"))
    // AND WHICH READING THE DOT IS ON IS NOT ITS INDEX. Every reading kept moves one place left on
    // every tick of a full window (`FootprintTrendSeries.record`), so the pair is read raw - the
    // alignment repeats a reading and puts the two oldest ends out of step - and told how far the
    // window slid (codex review of 36b653b, where bare indices misjudged 84 of 120 rollovers).
    check("…and whether it is the same reading is asked of the shift, not of the index",
          layers.contains("let shifted = origin - shownOrigin")
              && layers.contains("shown = values\n        shownOrigin = origin")
              && layers.contains("FootprintSparkline.peakMotion(from: previous, to: values,"
                                 + " shifted: shifted)")
              && card.contains("origin: series?.origin ?? 0")
              && card.contains("origin: trend.origin,"))
    // AND IT IS ASKED OF THE PAIR THAT ARRIVED, NOT OF THE PAIR A STYLE HANDS THE GEOMETRY. The
    // growing line replaces its outline whole and travels between the new series and ITSELF,
    // holding back only its newest segment, so the rule asked of THAT pair could only ever answer
    // `.move`: a peak the live tail overtook slid across the figure instead of fading out where it
    // stood (codex review of 9e3b89d). So the answer is read once, before the styles fork, and the
    // travelling is TOLD it - there is no shift left in that signature for a style to be wrong
    // about, which is what makes this structural rather than a rule somebody has to remember.
    check("…and asked of the readings that arrived, not of the pair the style draws",
          layers.contains("let ceiling = FootprintSparkline.peakMotion(from: previous, to: values,"
                          + " shifted: shifted)\n        switch lineStyle {")
              && layers.contains("travel(from: values, to: values, curve: curve, grow: 0,"
                                 + " ceiling: ceiling)")
              && layers.contains("private func travel(from previous: [Double], to values: [Double],"
                                 + "\n                        curve: MotionChoice.Curve,"
                                 + " grow: Double = 1,\n                        "
                                 + "ceiling: FootprintSparkline.PeakMotion) {")
              && layers.contains("switch ceiling {")
              && !layers.contains("peakMotion(from: values"))
    // AND THE OUTLINE ONLY TRAVELS WHERE THE STYLE SAYS IT DOES. The styles that arrive whole put
    // their outline up in one step and announce the reading with a phase instead, which is the same
    // fork the shapes drew and is still the style's own answer (`MotionChoice.Lines`).
    check("…and only the styles that travel interpolate the readings",
          layers.contains("case .morph, .bounce:\n            travel(from: previous, to: values,"
                          + " curve: curve, ceiling: ceiling)")
              && layers.contains("case .plain:\n            redraw()")
              && layers.contains("plot.add(spring(curve, keyPath: \"transform.translation.x\","
                                 + " from: step, to: 0),"))
    // A FIGURE, NOT A CONTROL, AND NOT A SECOND VOICE. An AppKit view inside this card would
    // otherwise take the click meant for the card's own button and be read out as an unlabelled
    // element beside the row that already states every figure on it in words.
    check("…and the view those layers hang in takes no click and says nothing",
          layers.contains("override func hitTest(_ point: NSPoint) -> NSView? { nil }")
              && layers.contains("setAccessibilityElement(false)"))
    // THE CALM GREYS ARE THE SYSTEM'S OWN and are different colours in the two appearances, and the
    // figure is drawn at the resolution of whichever display it is on: both are asked again when
    // they change, which a layer does not do for itself.
    check("…the greys and the resolution being resolved again when either changes",
          layers.contains("override func viewDidChangeEffectiveAppearance()")
              && layers.contains("override func viewDidChangeBackingProperties()")
              && layers.contains("effectiveAppearance.performAsCurrentDrawingAppearance {"))
    // A SERIES THAT GAINS A POINT IS ALIGNED AT ITS OLDEST END, which is the only end two lengths
    // can share: the window grows by appending until it is full, so the shorter series is a PREFIX
    // of the longer one and index 0 is the same instant in both. Extended with the NEWEST reading
    // rather than with zero, because zero is a value on all three metrics and the line is measured
    // from it - a window growing by a point would otherwise drop to the floor at its right edge.
    // DRAWN IN ONCE PER FIGURE, and the key is what makes that true: the candidate ladder above
    // this swaps subtrees whenever the figures change width class, and a swapped candidate is a NEW
    // view, so a line keyed on nothing blinked out and stroked itself back in on a card that had
    // been on screen for minutes. The decision is the shell's, being about a key that outlives any
    // one view; the layers are told, and refuse to run it twice.
    check("the outline strokes itself in once per figure, not once per rebuild",
          spark.contains("guard !Self.alreadyDrawn.contains(identity) else"
                         + " { reveal = .instant; return }")
              && spark.contains("Self.alreadyDrawn.insert(identity)")
              && spark.contains("reveal = .stroked")
              && layers.contains("guard !strokedIn else { return }")
              && layers.contains("line.add(fade(\"strokeEnd\", from: 0, to: 1,"))
    check("two lengths of one series are read as one length, extended at the end",
          FootprintSparkline.padded([4, 5], to: 4) == [4, 5, 5, 5]
              && FootprintSparkline.padded([4, 5], to: 2) == [4, 5]
              && FootprintSparkline.padded([], to: 3) == [0, 0, 0])
    // AND THE POINT OF IT: the reading taken at t1 stays at t1 through a frame of interpolation. Put
    // in front, it was made to travel to t2 and every point behind it slid one place left, on every
    // window that had not yet filled (codex review of 34b4147).
    check("…so a window that gains a point keeps every instant it already had",
          FootprintSparkline.aligned([1, 2], [1, 2, 3]).0 == [1, 2, 2])
    check("…which is what makes the empty series the zero the interpolation starts from",
          FootprintSparkline.aligned([], [7, 8]).0 == [0, 0]
              && FootprintSparkline.aligned([1, 2, 3], [9]).1 == [9, 9, 9])
    // AND IT IS ALL HELD STILL FOR SOMEBODY WHO ASKED FOR THAT, on both surfaces: a need rather
    // than a preference, and the same environment key the rest of this app reads.
    let motion = (try? String(contentsOfFile: "Tally/Views/CardReorder.swift",
                              encoding: .utf8)) ?? ""
    check("every motion this row gained is off under Reduce Motion",
          spark.contains("@Environment(\\.accessibilityReduceMotion) private var"
                         + " motionFromEnvironment")
              // The shell asks the question and the layers are TOLD the answer, which is the one
              // arrangement in which the outline, its dots and the phase that announces a reading
              // cannot answer it differently: there is only one answer, and it is passed down.
              && spark.contains("still: reduceMotion, reveal: reveal")
              // The one gate every motion on this figure passes through. A style that never moves
              // is refused by the same line, so the baseline and the styles are one implementation
              // (`MotionChoice.Lines.moves`).
              && layers.contains("if arriving, !still, lineStyle.moves {")
              && layers.contains("            redraw()\n        }")
              && card.contains(".figureMotion(trend.figure, value: trend.value,"
                               + " still: reduceMotion,")
              // The figures' own gate, which refuses on three counts now: the reader asked for
              // stillness, the chosen style is the baseline that never moved
              // (`MotionChoice.Figures.moves`), or the motion is not in this tree at all because
              // the digits are a layer's (`FigureRoller`).
              && motion.contains(".animation(still || !style.moves || rollsInLayers ? nil"
                                 + " : curve.animation, value: text)")
              // AND THE LAYERS ARE TOLD, the same way the outline's are: a reader who switches
              // Reduce Motion on mid-roll must have the roll stopped THEN, so the characters in
              // flight are cut off rather than left to settle, and the ones on their way out go
              // with them - they exist only for the motion.
              && rolling.contains("if still {\n            for glyph in glyphs"
                                  + " { glyph.removeAllAnimations() }")
              && rolling.contains("for ghost in ghosts { ghost.removeAllAnimations();"
                                  + " ghost.removeFromSuperlayer() }")
              // AND THE OUTLINE'S ARE CUT OFF THE SAME WAY, where the four pieces were not the
              // whole of it: the scroll style slides their PARENT and a stand-in dot holds its own
              // fade, and `removeAllAnimations` reaches one layer without recursing, so a reader
              // who asked for stillness mid-slide got the rest of the slide and a dot fading on top
              // of it anyway (codex review of 36b653b).
              && layers.contains("for piece in [line, tail, peak, current]"
                                 + " { piece.removeAllAnimations() }\n"
                                 + "            plot.removeAllAnimations()")
              && layers.contains("for ghost in ghosts { ghost.removeAllAnimations();"
                                 + " ghost.removeFromSuperlayer() }"))
    // AND WHICH STYLES TRAVEL IS THE STYLE'S OWN ANSWER rather than a test by name where the line is
    // drawn, so one added here has to say which half it is in.
    check("…and whether the readings themselves move is asked of the style",
          MotionChoice.Lines.allCases.filter(\.interpolatesReadings).map(\.rawValue)
              == ["morph", "bounce", "comet"])
    // THE DIRECTION IS THE READING'S OWN, which the spelling cannot supply: "999 MB" to "1.0 GB" is
    // a rise that reads as a fall, so the layers are handed the quantity and the CHANGE is keyed on
    // the spelling - a CPU wandering between 9.1 and 9.4 per cent draws nothing at all.
    check("the digits roll in the direction the reading moved",
          rolling.contains("let rising = MotionChoice.rising(from: self.value, to: value)")
              && motion.contains("let rising = MotionChoice.rising(from: previous, to: value)")
              && card.contains("let value: Double?")
              && card.contains("figure: figure, value: now,"))
    // AND THE ROLL IS THE RENDER SERVER'S, which is the whole of what this cost: a transition in
    // the view tree made a leaf's layout computer dirty on every frame and the panel was laid out
    // again with it, so the digits rolling alone cost 38.9% of one core against 13.2% still
    // (measured 2026-09-04, the line already being layers). One commit per reading buys that back.
    check("the board's rolling digits are drawn by layers rather than by the view tree",
          motion.contains("case .roll where roller == .layers:")
              && motion.contains("RollingFigureLayerView(text: text, value: value, tone: tone,"
                                 + " still: still,")
              && motion.contains("roller: FigureRoller = .layers")
              // ONE LAYER PER CHARACTER, which is what makes a roll a roll: what changed travels
              // and what did not stays exactly where it is, so `459 MB` becoming `460 MB` moves one
              // character and not a number.
              && rolling.contains("let aligned = before.count == after.count")
              && rolling.contains("aligned ? before.indices.filter { before[$0] != after[$0] }")
              // AND THE SIZE ASKS THE SUBTREE NOTHING, which is the other half of the cost: a leaf
              // that walks a subtree to answer a measurement makes every ancestor's computer dirty
              // (`FootprintSparklineLayerView.sizeThatFits` carries the same rule for the outline).
              && rolling.contains("return CGSize(width: proposal.width ?? measured.width,"))
    // THE COLUMN IS STILL WHAT PINS THE WIDTH. The hidden copy of the widest reading is half of
    // that measurement, so the speller stays where it is and is hidden rather than removed: a box
    // sized by the layers would be a column that changes width as the number does, which is the
    // reflow the column was introduced to stop.
    check("…in the very box the speller measures, right where the speller drew",
          motion.contains("content.hidden().overlay(alignment: .trailing) {")
              && card.contains("Text(verbatim: widest).hidden()"))
    // A FIGURE, NOT A CONTROL, and nothing a listener is given twice: the card underneath is one
    // button, the row carries a drag, and every figure on the row is already said in words
    // (`SessionCardTrendRow.spokenTrends`).
    check("…and the layers take neither a click nor a listener's attention",
          rolling.contains("override func hitTest(_ point: NSPoint) -> NSView? { nil }")
              && rolling.contains("setAccessibilityElement(false)"))
    // AND THE COLOUR IS HANDED DOWN, because a `foregroundStyle` is a view tree thing and reaches
    // no layer: the two spellings below are the same question in the same order, and a drift
    // between them is an amber reading whose digits roll in grey (`FigureTone`).
    check("…drawn in the colour the speller beside them picked",
          card.contains("flamesTheFigure(trend) ? Self.flamed(trend.figure)")
              && card.contains("tone: flamesTheFigure(trend)"
                               + " ? .tinted(SessionCardView.flameTint)")
              && card.contains(": .tint(trend.segment.level.tint))")
              && card.contains("tone: .tertiary)")
              && rolling.contains("case .tertiary: .tertiaryLabelColor"))
    // WHICH MOTION IS A LAUNCH FLAG ON A DEV BUILD, because how a quarter-second change LOOKS cannot
    // be judged from a diff: the samples window puts every combination on one clock and the board
    // runs whichever was picked, out of the same styles (`MotionDemoWindow`, `-TallyMotion`).
    check("the board and the samples window choose from one set of styles",
          motion.contains("typealias FigureStyle = MotionChoice.Figures")
              && motion.contains("typealias LineStyle = MotionChoice.Lines")
              && motion.contains("typealias Curve = MotionChoice.Curve")
              && ((try? String(contentsOfFile: "Tally/Views/MotionDemoWindow.swift",
                               encoding: .utf8)) ?? "").contains("CardMotion.FigureStyle.allCases"))
    // AND THE ONE DIFFERENCE A DIFF CANNOT SETTLE IS PUT ON THAT SAME CLOCK: what a layer cannot
    // spell is `numericText`'s own blur, so the sample the defaults name is drawn BOTH ways, side
    // by side, and which is preferred is answered by looking (`FigureRoller`).
    check("…and the picked sample is drawn both ways, beside itself",
          ((try? String(contentsOfFile: "Tally/Views/MotionDemoWindow.swift",
                        encoding: .utf8)) ?? "")
              .contains("if pair.0 == Self.picked.figures, pair.1 == Self.picked.curve {")
              && ((try? String(contentsOfFile: "Tally/Views/MotionDemoWindow.swift",
                               encoding: .utf8)) ?? "")
              .contains("sample(style: pair.0, curve: pair.1, roller: .viewTree)"))
    // EACH AXIS IS READ OFF ITS OWN POSITION, `<figures>,<lines>,<curve>`, which is the grammar the
    // window's own footer documents. It has to be positional because `none` is a style on TWO of the
    // axes: offered to all three, the line's `none` turned the figures off as well, so the fallback
    // spelling below meant no motion at all and the three words in the WRONG order were what
    // produced rolling digits on a still line (codex review of 34b4147).
    check("the flag is positional, so the fallback spelling means what it says",
          MotionChoice("roll,none,bouncy").figures == .roll
              && MotionChoice("roll,none,bouncy").lines == .plain
              && MotionChoice("roll,none,bouncy").curve == .bouncy)
    check("…and the same three words in another order are another launch",
          MotionChoice("none,roll,bouncy").figures == .plain
              // `roll` is not a line style, so that position keeps its default rather than
              // reaching back to the axis it belongs to.
              && MotionChoice("none,roll,bouncy").lines == MotionChoice(nil).lines
              && MotionChoice("none,roll,bouncy").curve == .bouncy)
    check("…with case and spacing not mattering inside a position",
          MotionChoice("push,scroll,bouncy") == MotionChoice(" PUSH , Scroll ,BOUNCY"))
    check("…a token nothing recognises leaving its own axis at the default",
          MotionChoice("wobble,scroll") == MotionChoice(",scroll")
              && MotionChoice("fade").lines == MotionChoice(nil).lines
              && MotionChoice("fade").curve == MotionChoice(nil).curve
              // An empty position is the same as a missing one, which is how a launch asks for the
              // curve alone.
              && MotionChoice(",,smooth") == MotionChoice("roll,grow,smooth"))
    // WHICH WAY A READING MOVED, which is the one thing the spelling cannot supply and the one
    // thing both styles that have a direction turn on. It was written out at each of them and could
    // only be read as a string there, so reversing either left every assertion green (codex review
    // of 40054b3): what is stated here is the rule itself.
    check("a reading that went up rises, and one that went down falls",
          MotionChoice.rising(from: 9.4, to: 10) && !MotionChoice.rising(from: 10, to: 9.4))
    // 999 MB becoming 1.0 GB is a rise that reads as a fall, which is why the quantity is asked for
    // at all: the spelling of these figures does not order them.
    check("…the quantity deciding it rather than the spelling it arrives in",
          MotionChoice.rising(from: 999_000_000, to: 1_000_000_000))
    // There are two answers and no third one, so the cases with nothing to compare against have to
    // land somewhere: a first reading has nothing to have fallen from, and one that did not move
    // has not fallen either.
    check("…a first reading rising, having nothing behind it",
          MotionChoice.rising(from: nil, to: 42) && MotionChoice.rising(from: nil, to: nil))
    check("…and a reading that did not move rising too",
          MotionChoice.rising(from: 42, to: 42))
    // A metric that stops being stateable turns downward, which is the one case where the direction
    // carries no meaning: it is a figure going quiet rather than a reading that fell.
    check("…while a metric this tick could not state turns down rather than up",
          !MotionChoice.rising(from: 5, to: nil) && MotionChoice.rising(from: nil, to: 0))

    // AND `none` ON ITS OWN IS THE BASELINE, both axes off: the state the cost of the motion is
    // measured against, rather than a figures style with the line left running.
    check("…and none on its own being every motion off",
          MotionChoice("none").figures == .plain && MotionChoice("none").lines == .plain
              && MotionChoice("none") == MotionChoice("none,none"))
    // BOTH AXES ARE THE ONES CHOSEN BY LOOKING: rolling digits on the bouncy curve (Albert,
    // 2026-09-03, sample N3) and a growing line (Albert, 2026-09-04). The line was still while it
    // was a price - a moving outline cost the whole panel a layout pass per frame, 70.6% of a core
    // against 27.3% with the digits alone - and it stopped being one when the motion moved into the
    // render server, where the same board measured 14.8% still against 14.7% growing
    // (`FootprintSparklineLayerView`, `MotionChoice.lines`). Written out here rather than read off
    // the type: an edit that changes what an ordinary launch does has to change this line too.
    check("…and an absent flag being the two styles that were picked, line included",
          MotionChoice(nil) == MotionChoice("")
              && MotionChoice(nil) == MotionChoice("roll,grow,bouncy"))
    // AND THE WINDOW THAT SHOWS THEM SAYS WHICH TWO THEY ARE. Its footer is the one place a reader
    // is told what an ordinary launch does, and it is prose: it went on naming the old default for
    // a day after the line started growing (codex review of 9e3b89d), which is a sample cell the
    // reader would be comparing everything against and looking at the wrong one.
    let samples = (try? String(contentsOfFile: "Tally/Views/MotionDemoWindow.swift",
                               encoding: .utf8)) ?? ""
    // L6 IS AN ORDINAL, so what makes the second half of that sentence true is where the cell sits
    // rather than what it says: counted here, in the list the labels number, so that a cell
    // inserted before the growing one moves the number the footer prints and is caught, while an
    // edit to any of their descriptions is not.
    let growCell = samples.components(separatedBy: "LineCell(style: ")
        .dropFirst().prefix { !$0.hasPrefix(".grow") }.count
    check("…and the samples window's footer naming those same two, by name and by cell",
          samples.contains("Defaults are roll, grow, bouncy (N3 and L6)") && growCell == 6)
    check("…with every style the samples window offers reachable through it",
          MotionChoice.Figures.allCases.allSatisfy { MotionChoice($0.rawValue).figures == $0 }
              && MotionChoice.Lines.allCases.allSatisfy { MotionChoice(",\($0.rawValue)").lines == $0 }
              && MotionChoice.Curve.allCases
                  .allSatisfy { MotionChoice(",,\($0.rawValue)").curve == $0 })

    // THE FLAME NAMES A CARD AND THE FIGURE NAMES WHICH READING EARNED IT (Albert, 2026-09-03). The
    // mark on the headline says this checkout is the heaviest thing on the machine and this is the
    // card spending it (`SessionBoardGhosts.marked`), which is decided on CPU and on nothing else -
    // so the CPU figure is the one it is pointing at, and it is the only figure this lights.
    check("the flamed card says which of its readings the flame is about",
          card.contains("marked && trend.metric == .cpu && trend.segment.level == .calm")
              && card.contains("flamesTheFigure(trend) ? Self.flamed(trend.figure)"))
    // ASKED OF THE FLAME FOR THE COLOUR, not of an amber spelled here: a mark and the figure it
    // points at have to be one colour or the pointing is not visible, and this row's standing rule
    // is that it names no colour of its own (asserted just above, over both halves of the file).
    check("…in the flame's own colour, from the one spelling of it",
          card.contains("Text(verbatim: text).foregroundStyle(SessionCardView.flameTint)")
              && ((try? String(contentsOfFile: "Tally/Views/SessionCardState.swift",
                               encoding: .utf8)) ?? "")
                  .contains("static let flameTint: Color = TallyColor.warning"))
    // AND THE TIER WINS WHEREVER BOTH ARE TRUE. The alert levels are a different axis read off the
    // same figure, and this amber over the machine-level RED would take "somebody has to do
    // something now" and print it as "worth an eye".
    check("…and never over a figure that already has a colour of its own",
          card.contains("trend.segment.level == .calm"))

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
    // rather than exercised, which is a choice again rather than a limit: this suite does compile
    // DemoUsage.swift now (the session board's own fixtures needed it - demoboardchecks.swift), and
    // what these lines pin is the WRITTEN rule, so the de-duplication cannot be lost to a rewrite
    // that still happens to number four distinct keys correctly.
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
          store.contains("ProcessTree.held(ProcessTree.listeningPorts(of: measured),")
              && store.contains("var ports: [String: [UInt16: ProcessPortHolder]] = [:]")
              // The loop's own body has since gained a second thing to collect (the live process
              // groups the ledger's sweep is decided on), so what is locked here is that the table
              // is still built by ONE unconditional pass over the walk rather than the whole line.
              && store.contains("for one in processes { identities[one.pid] = one"))
    check("…and named only while the pid is still that process",
          store.contains("portNames: ProcessTree.portNames(holding, startedAt: began,"))
    // THAT TABLE IS NOW BUILT BEHIND A CLOSED PANEL TOO, which it deliberately was not: it was the
    // ports' own lookup and nothing draws a port with no card up. The group ledger reads the same
    // field for the same reason one number over - a job is identified by when its LEADER began
    // (`SessionProcessGroup.leaderStartedAt`) - and it is written whether or not anybody is
    // looking, because a session detaches a dev server at three in the morning and a claim not
    // written then can never be made afterwards.
    check("…and the table it is compared against is built on every tick, not only a visible one",
          !store.contains("if viewers > 0 { for one in processes"))

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
