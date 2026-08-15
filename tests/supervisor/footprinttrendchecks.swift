import CoreGraphics
import Foundation

// WHAT A SESSION'S FOOTPRINT HAS BEEN DOING (Tally/Core/FootprintTrend.swift): the ring the
// readings are kept in, the cadence it holds them to across two sampling rates, and the geometry a
// card draws them with.
//
// SPLIT FROM THE FOOTPRINT'S OWN CHECKS beside it (processtreechecks.swift, footprintalertchecks
// .swift) along the same seam those two are split on: those state what one reading MEANS and which
// readings are worth a warning, and these state what a SERIES of them is. The two surfaces that
// consume it (the store that samples and the card that draws) are scanned at the end, because
// neither can be constructed here: one is @MainActor and observable, the other is SwiftUI.

func runFootprintTrendChecks() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func reading(_ cpu: Double, memory: UInt64 = 0, processes: Int = 0) -> FootprintTrendSample {
        FootprintTrendSample(cpuPercent: cpu, memoryBytes: memory, processes: processes)
    }

    // MARK: the ring

    // A fresh series takes the first reading it is offered: there is no cadence to measure against
    // yet, and a card that waited ten seconds for its first point would draw nothing on a session
    // that had just been opened.
    var fresh = FootprintTrendSeries()
    fresh.record(reading(10), at: t0)
    check("the first reading is always taken", fresh.samples.count == 1)

    // The cap holds and the OLDEST is what leaves, which is what makes the line a window on the
    // last quarter hour rather than the first.
    var full = FootprintTrendSeries()
    for index in 0 ..< 200 {
        full.record(reading(Double(index)), at: t0.addingTimeInterval(Double(index) * 10))
    }
    check("the ring stops at its capacity", full.samples.count == FootprintTrendSeries.capacity)
    check("…and it is the oldest readings that fall out",
          full.samples.first?.cpuPercent == Double(200 - FootprintTrendSeries.capacity))
    check("…with the newest at the end", full.samples.last?.cpuPercent == 199)
    check("the window is a quarter of an hour of readings",
          Double(FootprintTrendSeries.capacity) * FootprintTrendSeries.cadence == 900)

    // MARK: one cadence, one MEANING, across two sampling rates

    // THE DEFECT THE CADENCE PREVENTS: the store samples every two seconds while the board is up
    // and every ten behind it, so a ring that took whatever arrived would be five times denser over
    // the minutes somebody was watching - a line whose horizontal scale changes halfway along.
    var throttled = FootprintTrendSeries()
    for tick in stride(from: 0.0, through: 60.0, by: 2) {
        throttled.record(reading(tick), at: t0.addingTimeInterval(tick))
    }
    check("two-second ticks are kept at the trend's own cadence",
          throttled.samples.count == 7)
    // AND THE DEFECT THE FOLD PREVENTS, which the cadence on its own introduced: keeping one fast
    // reading in five threw the other four away, so eight seconds out of every ten never happened
    // while somebody was watching. A kept point is now the mean of its bucket (the readings at 2, 4,
    // 6, 8 and 10 average 6), not the single reading that closed it.
    check("…as the mean of the readings inside them, not as the one that closed the bucket",
          throttled.values(of: .cpu) == [0, 6, 16, 26, 36, 46, 56])

    // THE PROPERTY THAT MATTERS: the same load, sampled either way, is the same series. The CPU is
    // a rate over the interval that ended at its reading, so five two-second readings average to
    // exactly the ten-second reading the background pass takes over the same span; memory and the
    // process count are instants and fold to the last one taken.
    let bursts: [[Double]] = [[10, 90, 10, 10, 10], [50, 50, 50, 50, 50], [0, 0, 0, 0, 100]]
    var watched = FootprintTrendSeries()
    watched.record(reading(0, memory: 1_000_000_000, processes: 3), at: t0)
    for (bucket, values) in bursts.enumerated() {
        for (step, cpu) in values.enumerated() {
            let at = t0.addingTimeInterval(Double(bucket) * 10 + Double(step + 1) * 2)
            watched.record(reading(cpu, memory: UInt64(bucket + 2) * 1_000_000_000,
                                   processes: bucket + 4),
                           at: at)
        }
    }
    var unwatched = FootprintTrendSeries()
    unwatched.record(reading(0, memory: 1_000_000_000, processes: 3), at: t0)
    for (bucket, values) in bursts.enumerated() {
        unwatched.record(reading(values.reduce(0, +) / Double(values.count),
                                 memory: UInt64(bucket + 2) * 1_000_000_000,
                                 processes: bucket + 4),
                         at: t0.addingTimeInterval(Double(bucket + 1) * 10))
    }
    check("the same load draws the same line at either sampling rate",
          watched.values(of: .cpu) == unwatched.values(of: .cpu)
              && watched.values(of: .memory) == unwatched.values(of: .memory)
              && watched.values(of: .processes) == unwatched.values(of: .processes))
    // The reading that used to be the whole point is the one at the end of the bucket, and the
    // burst that made the bucket what it is sat four readings earlier: kept alone it would have
    // drawn 10 where the ten seconds were 26.
    check("…and a spike between two kept points is in the line rather than gone",
          watched.values(of: .cpu)[1] == 26)
    // An instant is never averaged: a tree that grew from 1 GB to 2 GB inside a bucket is drawn at
    // the 2 GB it ended on, not at the 1.5 GB it never held.
    check("what a tree HOLDS folds to its last reading rather than to a mean",
          watched.values(of: .memory) == [1_000_000_000, 2_000_000_000, 3_000_000_000,
                                          4_000_000_000]
              && watched.values(of: .processes) == [3, 4, 5, 6])

    // The tolerance has to sit strictly between a timer's slack and the fast tick, and both bounds
    // are asserted rather than trusted: too small and a tick that fires at 9.98s is refused (the
    // next point lands at 11.98, a series that stutters by a fifth); too large and two consecutive
    // fast ticks both close a bucket.
    check("the tolerance is smaller than the fast tick it filters",
          FootprintTrendSeries.tolerance < 2)
    var jittery = FootprintTrendSeries()
    jittery.record(reading(1), at: t0)
    jittery.record(reading(2), at: t0.addingTimeInterval(9.98))
    check("a reading that arrives a hair early is still the next point",
          jittery.values(of: .cpu) == [1, 2])
    var eager = FootprintTrendSeries()
    eager.record(reading(1), at: t0)
    eager.record(reading(2), at: t0.addingTimeInterval(8))
    eager.record(reading(3), at: t0.addingTimeInterval(10))
    check("…and no two consecutive fast ticks both close a bucket",
          eager.samples.count == 2)
    check("…the early one being folded into the point rather than dropped",
          eager.values(of: .cpu) == [1, 2.5])

    // MARK: a silence long enough to be a different afternoon

    // A gap of a tick or two is a busy main thread, and the line carries on across it: the readings
    // it did not get are simply not in it, and nothing is invented to fill them.
    var gapped = FootprintTrendSeries()
    gapped.record(reading(1), at: t0)
    gapped.record(reading(2), at: t0.addingTimeInterval(FootprintTrendSeries.staleAfter))
    check("a missed tick or two is a gap in the line rather than a backfill",
          gapped.values(of: .cpu) == [1, 2])
    // THE DEFECT THIS PREVENTS: a Mac that slept overnight wakes with eighty-nine readings from
    // yesterday in the ring, and the card would draw them as "the last quarter hour" with nothing
    // on the line to say the last two points are twelve hours apart.
    var slept = FootprintTrendSeries()
    for tick in stride(from: 0.0, through: 300.0, by: 10) {
        slept.record(reading(tick), at: t0.addingTimeInterval(tick))
    }
    let woke = t0.addingTimeInterval(300 + FootprintTrendSeries.staleAfter + 1)
    slept.record(reading(7), at: woke)
    check("a silence past the stale mark starts the line again from now",
          slept.values(of: .cpu) == [7])
    check("…and the pending readings of the old line go with it",
          slept.samples.count == 1 && slept.lastAcceptedAt == woke)
    check("the stale mark is longer than any silence a busy main thread can cause",
          FootprintTrendSeries.staleAfter == 3 * FootprintTrendSeries.cadence)

    // MARK: the peak

    var peaked = FootprintTrendSeries()
    for (index, cpu) in [40.0, 340.0, 12.0].enumerated() {
        peaked.record(reading(cpu, memory: UInt64(index + 1) * 1_000_000_000,
                              processes: 9 - index),
                      at: t0.addingTimeInterval(Double(index) * 10))
    }
    check("the peak is the highest reading in the window", peaked.peak(of: .cpu) == 340)
    check("…per metric, not per series", peaked.peak(of: .memory) == 3_000_000_000)
    check("…including one whose highest reading is its first", peaked.peak(of: .processes) == 9)
    check("an empty series has no peak", FootprintTrendSeries().peak(of: .cpu) == nil)

    // The peak is spelt in the words the current figure beside it uses, so a card never states the
    // same quantity two ways (`ProcessTree.memoryText` is the one implementation).
    check("a CPU peak reads as a whole percentage", FootprintTrendMetric.cpu.peakText(339.6) == "340%")
    check("a memory peak reads as the value line spells memory",
          FootprintTrendMetric.memory.peakText(4_200_000_000) == "4.2 GB"
              && FootprintTrendMetric.memory.peakText(4_200_000_000)
                  == ProcessTree.memoryText(4_200_000_000))
    check("a process peak is a count", FootprintTrendMetric.processes.peakText(6) == "6")
    // A CEILING OF NOUGHT PER CENT IS NOT A FACT ABOUT ANYTHING, so no arrow is printed for one.
    // This used to be stated as "the threshold the value line keeps", which the value line does not
    // keep: it prints `0% CPU` for the same reading, because what a session IS doing has to be
    // stated at any size. The group is built from that reading and never from the peak, so what a
    // small ceiling costs is the arrow beside the figure and never the figure itself
    // (`SessionCardView.sessionFootprintTrendGroups`).
    check("a peak under a whole percent is not worth printing",
          FootprintTrendMetric.cpu.peakText(0.4) == nil
              && ProcessTree.line(ProcessFootprint(processes: 1, cpuPercent: 0.4,
                                                   listeningPorts: []),
                                  unit: "proc") == "1 proc · 0% CPU")
    // The memory threshold is decided on the ROUNDED megabyte, exactly as the value line's is, so
    // 900 kB reads as "1 MB" on both and only a tree holding less than half of one says nothing.
    check("…nor is a memory peak that rounds to no megabytes at all",
          FootprintTrendMetric.memory.peakText(400_000) == nil
              && FootprintTrendMetric.memory.peakText(900_000) == ProcessTree.memoryText(900_000))
    check("…nor an empty tree", FootprintTrendMetric.processes.peakText(0) == nil)
    // The order is the order the value line above is written in, so the leftmost shape belongs to
    // the leftmost figure (`ProcessTree.segments`).
    check("the metrics are in the value line's own order",
          FootprintTrendMetric.allCases == [.processes, .cpu, .memory])

    // MARK: the figure the group states, and where it comes from

    // ONE SPELLER FOR BOTH FIGURES A GROUP CARRIES, so the reading and the ceiling above it can
    // never be two spellings of the same quantity.
    check("the current reading is spelled the way its own peak is",
          FootprintTrendMetric.cpu.figureText(19.6) == "20%"
              && FootprintTrendMetric.cpu.peakText(19.6) == "20%")
    check("…tersely enough for three of them on one row",
          FootprintTrendMetric.processes.figureText(4) == "4"
              && FootprintTrendMetric.memory.figureText(3_400_000_000) == "3.4 GB")
    // The thresholds are the PEAK'S, not the figure's: a peak under a whole percent says nothing,
    // while an idle session reading 0% still has to print the 0% its value line prints.
    check("a reading too small to be worth a peak is still worth a figure",
          FootprintTrendMetric.cpu.figureText(0.4) == "0%"
              && FootprintTrendMetric.cpu.peakText(0.4) == nil)

    // Which field of the value line has a shape of its own, decided in one place and exhaustively,
    // so a field added to that line has to be given an answer here (`ProcessTree.segments`).
    check("the three trended fields know their own metric",
          FootprintTrendMetric(.processes) == .processes && FootprintTrendMetric(.cpu) == .cpu
              && FootprintTrendMetric(.memory) == .memory)
    check("…and the fields no shape is kept for have none",
          FootprintTrendMetric(.agents) == nil && FootprintTrendMetric(.disk) == nil
              && FootprintTrendMetric(.ports) == nil)

    // The figure is read from the live footprint rather than from the ring, so it is this tick's
    // number and not the one the last bucket closed on.
    let live = ProcessFootprint(processes: 6, cpuPercent: 34, memoryBytes: 2_100_000_000,
                                listeningPorts: [])
    check("a metric reads its own figure out of a footprint",
          FootprintTrendMetric.processes.reading(of: live) == 6
              && FootprintTrendMetric.cpu.reading(of: live) == 34
              && FootprintTrendMetric.memory.reading(of: live) == 2_100_000_000)
    check("…and says nothing where the footprint has no rate yet",
          FootprintTrendMetric.cpu.reading(of: ProcessFootprint(processes: 2, cpuPercent: nil,
                                                                listeningPorts: [])) == nil)

    // MARK: one series per session, swept

    var history = FootprintHistory()
    history.record(reading(10), for: "111", at: t0)
    history.record(reading(20), for: "222", at: t0)
    check("each session keeps its own series",
          history["111"]?.values(of: .cpu) == [10] && history["222"]?.values(of: .cpu) == [20])
    check("a session nobody has measured has none", history["333"] == nil)
    // A pid is handed out again once its session has gone, so a series left behind would be adopted
    // by an unrelated tree and drawn as its own history.
    history.retain(["111"])
    check("a session that has left the board takes its history with it", history["222"] == nil)
    check("…and the ones still on it keep theirs", history["111"]?.values(of: .cpu) == [10])
    // Closing the panel keeps everything: the readings go on being taken behind it.
    history.retain(["111"])
    check("a sweep that removes nothing changes nothing", history["111"]?.values(of: .cpu) == [10])

    // MARK: the shape

    let box = CGSize(width: 44, height: 11)
    check("nothing is drawn for a series that has not been read twice",
          FootprintSparkline.points([], in: box).isEmpty
              && FootprintSparkline.points([5], in: box).isEmpty)
    // MEASURED FROM ZERO rather than from the lowest reading: a tree that sat between 3.90 and 3.94
    // GB must not be drawn as a mountain range.
    let rising = FootprintSparkline.points([0, 50, 100], in: box, inset: 0)
    check("the readings span the width evenly",
          rising.map(\.x) == [0, box.width / 2, box.width])
    check("zero is the floor and the highest reading is the ceiling",
          rising.map(\.y) == [box.height, box.height / 2, 0])
    check("a reading half the peak sits half way up, not at the bottom",
          FootprintSparkline.points([50, 100], in: box, inset: 0).first?.y == box.height / 2)
    // The two boundary series a card actually meets: a tree that read zero throughout (nothing
    // could be sampled) and one that never moved.
    check("an all-zero series is a flat line on the floor",
          FootprintSparkline.points([0, 0, 0], in: box, inset: 0).allSatisfy { $0.y == box.height })
    check("a series that never moved is a flat line at its own ceiling",
          FootprintSparkline.points([4, 4, 4], in: box, inset: 0).allSatisfy { $0.y == 0 })
    // …which is why there is an inset at all: at the ceiling a 1pt stroke would be drawn half
    // outside the frame and clipped to a hairline.
    let inset = FootprintSparkline.points([4, 4], in: box, inset: 0.5)
    check("the line keeps half a stroke off the top edge", inset.allSatisfy { $0.y == 0.5 })
    check("…and off the bottom",
          FootprintSparkline.points([0, 0], in: box, inset: 0.5)
              .allSatisfy { $0.y == box.height - 0.5 })
    check("a box with no room for the inset draws nothing",
          FootprintSparkline.points([1, 2], in: CGSize(width: 44, height: 1), inset: 0.5).isEmpty)
    // A negative reading cannot happen (every metric is a count, a rate or a byte total) but a
    // clamp costs nothing and keeps the line inside its box if one ever does.
    check("a negative reading is drawn on the floor rather than below the box",
          FootprintSparkline.points([-5, 10], in: box, inset: 0).first?.y == box.height)

    check("the peak dot marks the highest reading",
          FootprintSparkline.peakIndex([1, 9, 3]) == 1)
    check("…the first of them when it repeats", FootprintSparkline.peakIndex([9, 1, 9]) == 0)
    check("a flat line has no peak to point at", FootprintSparkline.peakIndex([4, 4, 4]) == nil)
    check("…and neither does a series too short to be a line",
          FootprintSparkline.peakIndex([9]) == nil)

    runFootprintTrendSurfaceChecks()
}

/// THE TWO SURFACES THE SERIES REACHES, read from their source: the store that fills it and the
/// card that draws it. Neither can be constructed in this harness (one is an observable @MainActor
/// store, the other is SwiftUI), and both carry a property the arithmetic above cannot state.
func runFootprintTrendSurfaceChecks() {
    let store = (try? String(contentsOfFile: "Tally/Stores/ProcessFootprintStore.swift",
                             encoding: .utf8)) ?? ""
    check("the store's source is readable from this suite", !store.isEmpty)
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
    check("…and only once there is an interval to state a rate over",
          store.contains("if let percent = cpu.percent {"))
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

    let card = (try? String(contentsOfFile: "Tally/Views/SessionCardFootprint.swift",
                            encoding: .utf8)) ?? ""
    check("the card's source is readable from this suite", !card.isEmpty)
    // THE THREE PIECES OF A GROUP ARE ABOUT ONE NUMBER, which is the whole correction: the figure
    // sits between the shape it arrived by and the ceiling it came off, and the row above it holds
    // only the fields that have no shape.
    check("the figure is drawn inside its own metric's group",
          card.contains("if !trend.values.isEmpty { FootprintSparklineView(values: trend.values) }")
              && card.contains("Self.drawn(trend.figure, alert: trend.segment.alert)"))
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
          card.contains("return sessionFootprintSegments.compactMap { segment in")
              && card.contains("guard let metric = FootprintTrendMetric(segment.kind)"))
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
    let spark = (try? String(contentsOfFile: "Tally/Views/FootprintSparklineView.swift",
                             encoding: .utf8)) ?? ""
    check("the sparkline's source is readable from this suite", !spark.isEmpty)
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
