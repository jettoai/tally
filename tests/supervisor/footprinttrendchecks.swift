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

    // MARK: one cadence across two sampling rates

    // THE DEFECT THIS PREVENTS: the store samples every two seconds while the board is up and every
    // ten behind it, so a ring that took whatever arrived would be five times denser over the
    // minutes somebody was watching - a line whose horizontal scale changes halfway along.
    var throttled = FootprintTrendSeries()
    for tick in stride(from: 0.0, through: 60.0, by: 2) {
        throttled.record(reading(tick), at: t0.addingTimeInterval(tick))
    }
    check("two-second ticks are kept at the trend's own cadence",
          throttled.values(of: .cpu) == [0, 10, 20, 30, 40, 50, 60])
    var slow = FootprintTrendSeries()
    for tick in stride(from: 0.0, through: 60.0, by: 10) {
        slow.record(reading(tick), at: t0.addingTimeInterval(tick))
    }
    check("…and the background rate produces the very same series",
          slow.values(of: .cpu) == throttled.values(of: .cpu))

    // The tolerance has to sit strictly between a timer's slack and the fast tick, and both bounds
    // are asserted rather than trusted: too small and a tick that fires at 9.98s is refused (the
    // next point lands at 11.98, a series that stutters by a fifth); too large and two consecutive
    // fast ticks both clear the bar.
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
    check("…and no two consecutive fast ticks are both taken",
          eager.values(of: .cpu) == [1, 3])
    // A gap longer than the cadence (the machine slept, the app was busy) is one point, not a run
    // of catch-up points: the ring records what it was handed and never invents the readings it
    // was not.
    var gapped = FootprintTrendSeries()
    gapped.record(reading(1), at: t0)
    gapped.record(reading(2), at: t0.addingTimeInterval(600))
    check("a long silence is one point rather than a backfill",
          gapped.values(of: .cpu) == [1, 2])

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
    // Below the thresholds the value line already keeps, a peak says nothing rather than "0".
    check("a peak under a whole percent is not worth printing",
          FootprintTrendMetric.cpu.peakText(0.4) == nil)
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
    check("the current figures are the loudest small text on the card",
          card.contains(".font(.caption2.monospacedDigit()).foregroundStyle(.primary)"))
    check("…and the peak beside the line is the quietest",
          card.contains("Text(verbatim: Self.peakMark + trend.peak)"))
    check("a metric with too few readings draws no line at all",
          card.contains("guard values.count >= FootprintSparkline.minimumReadings,"))
    check("the card draws the trend row it builds",
          ((try? String(contentsOfFile: "Tally/Views/SessionCardView.swift", encoding: .utf8)) ?? "")
              .contains("sessionCardLine { sessionFootprintTrends }"))

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
