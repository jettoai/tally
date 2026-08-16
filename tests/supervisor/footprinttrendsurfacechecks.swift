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
    check("the trend is recorded from the same measured tree the figures are",
          store.contains("processes: measured.count),")
              && store.contains("trends.record(FootprintTrendSample(cpuPercent: percent,"))
    // The rate and the span it covers are handed over together: the two sampling rates meet inside
    // one bucket every time the board is opened, and a fold that weighted every reading alike made
    // a peak out of the opening (`FootprintTrendSample.folded`).
    check("…and only once there is an interval to state a rate over, which goes with it",
          store.contains("if let percent = cpu.percent, let since = previous?.at {")
              && store.contains("seconds: now.timeIntervalSince(since),"))
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
          card.contains("FootprintSparklineView(values: trend.values, alert: trend.segment.alert)")
              && card.contains("Self.figure(trend.figure, alert: trend.segment.alert)"))
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
    alarmed.alerts = FootprintAlerts(memory: true)
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
          card.contains("guard alert else { return Text(verbatim: text).foregroundStyle(.primary) }")
              && card.contains("return Text(verbatim: text).foregroundStyle(TallyColor.warning)"))
    // Asked once per piece and answered in one place, so the three cannot drift into a figure that
    // is warned in parts: the line, the peak dot and the current dot each state the grey they wear
    // on a calm card and take the warning colour from the same rule.
    check("…the line and both of its dots turning amber with the figure",
          spark.contains("alert ? AnyShapeStyle(warned) : AnyShapeStyle(calm)")
              && spark.contains(".stroke(tone(calm: .tertiary),")
              && spark.contains("tone(calm: .secondary,\n")
              && spark.contains(".foregroundStyle(tone(calm: .primary))"))
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
          card.contains("static func figure(_ text: String, alert: Bool) -> Text")
              && card.contains("Self.figure(trend.figure, alert: trend.segment.alert)"))
    // The row above is unchanged: it has no columns to hold still, and its fields are one sentence.
    check("the fields with no shape are still marked in the sentence itself",
          card.contains("Self.drawn(part.element.text, alert: part.element.alert)")
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
              && card.contains("trendRow(trends, peaks: 3)")
              && card.contains("trendRow(trends, peaks: 0)"))
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
