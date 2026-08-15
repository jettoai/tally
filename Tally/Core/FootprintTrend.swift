import CoreGraphics
import Foundation

/// WHAT A SESSION HAS BEEN DOING, kept beside what it is doing this instant.
///
/// A single number answers "is this expensive right now" and nothing else, and that is the question
/// a card is least often opened for: 92% CPU on its own cannot tell a session that has been holding
/// a core for ten minutes from one that started a build four seconds ago. So the readings are kept,
/// and the card draws the SHAPE of them behind the current figure.
///
/// EVERYTHING HERE IS PURE, the same division the footprint's own arithmetic already lives under
/// (`ProcessTreeStats.swift`): the ring, the peak and the geometry a line is drawn from can all be
/// stated in an assertion harness with no processes and no views around them. What samples this is
/// the store next door (`ProcessFootprintStore`), and what draws it is one small view
/// (`FootprintSparklineView`).
///
/// THE HISTORY OUTLIVES THE PANEL, which is the whole reason the store gained a cadence it keeps
/// with nothing on screen. A trend that only existed while somebody was looking would be empty
/// exactly when it is wanted: a person opens this board BECAUSE something felt wrong, and a line
/// that starts drawing itself at the moment of asking has nothing to say about the minute before.
struct FootprintTrendSample: Equatable {
    /// The tree's share of one core over the interval that ended here.
    var cpuPercent: Double
    /// What the tree was holding in physical memory at that instant.
    var memoryBytes: UInt64
    /// How many processes it held, Tally's own already taken out (`ProcessTree.ownFamily`).
    var processes: Int

    func value(_ metric: FootprintTrendMetric) -> Double {
        switch metric {
        case .processes: Double(processes)
        case .cpu: cpuPercent
        case .memory: Double(memoryBytes)
        }
    }
}

/// The three readings that are worth a line, in the order the value line above them is written in
/// (`ProcessTree.segments`), so the leftmost trend is about the leftmost figure.
///
/// DISK IS NOT ONE OF THEM, and its absence is a measurement rather than an omission. Writing is
/// bursty by nature: a session writes nothing for minutes and then puts out 40 MB in one interval,
/// so a line of it is a flat zero with a spike in it, which says less than the one number already
/// on the card. The same goes for the ports, which are not a quantity at all.
enum FootprintTrendMetric: Hashable, CaseIterable {
    case processes, cpu, memory

    /// The peak of this metric in the same words the current figure beside it uses, or nothing when
    /// the number is too small to be worth saying (the thresholds the value line already keeps, so
    /// "shown as a figure" and "shown as a peak" cannot drift apart).
    func peakText(_ value: Double) -> String? {
        switch self {
        case .processes:
            guard value >= 1 else { return nil }
            return "\(Int(value.rounded()))"
        case .cpu:
            guard value >= 1 else { return nil }
            return "\(Int(value.rounded()))%"
        case .memory:
            return ProcessTree.memoryText(UInt64(max(0, value)))
        }
    }

    /// What a reader who cannot see the line is told instead. A key per metric rather than one
    /// key with the metric's name substituted into it: a sentence assembled from two catalogue
    /// entries is a sentence no translator ever gets to read whole.
    var peakLabelKey: String {
        switch self {
        case .processes: "processes peak %@"
        case .cpu: "CPU peak %@"
        case .memory: "memory peak %@"
        }
    }
}

/// One session's readings, oldest first, at an even cadence.
///
/// THE CADENCE IS DEFENDED HERE RATHER THAN AT THE TIMER, because there are two timers: the board
/// samples every two seconds while it is on screen and every ten with nothing open
/// (`ProcessFootprintStore`), and a series that simply took whatever arrived would be five times
/// denser over the minutes somebody was watching. A line whose horizontal axis changes scale
/// halfway along is not a trend, it is two trends drawn on top of each other, so the fast ticks are
/// offered and mostly refused.
struct FootprintTrendSeries: Equatable {
    /// About a quarter of an hour at the cadence below, which is the span a person is actually
    /// asking about ("has this been like this for a while?"). Ninety readings is also small enough
    /// that a board of twenty sessions costs a few kilobytes rather than a decision.
    static let capacity = 90
    /// One reading every ten seconds. Slow enough that the background pass costs nothing measurable
    /// (see the store), fine enough that a two-minute spike is several points wide rather than one.
    static let cadence: TimeInterval = 10
    /// How early a reading may arrive and still be taken. It has to be smaller than the fast tick,
    /// or two consecutive two-second ticks would both clear the bar and the series would drift
    /// dense; it has to be bigger than a timer's slack, or a tick that fires at 9.98s is refused
    /// and the next point lands at 11.98 (a series that stutters by a fifth). One second is the
    /// only interval that is both.
    static let tolerance: TimeInterval = 1

    private(set) var samples: [FootprintTrendSample] = []
    /// When the newest kept reading was taken, which is what the cadence is measured from.
    private(set) var lastAcceptedAt: Date?

    /// Whether a reading taken at `at` is the next point of the line rather than one of the fast
    /// ticks between two of them.
    func accepts(_ at: Date) -> Bool {
        guard let lastAcceptedAt else { return true }
        return at.timeIntervalSince(lastAcceptedAt) >= Self.cadence - Self.tolerance
    }

    /// Offer a reading. Refused readings cost nothing and are the common case while the panel is
    /// open: four of every five ticks land inside the cadence.
    mutating func record(_ sample: FootprintTrendSample, at: Date) {
        guard accepts(at) else { return }
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        lastAcceptedAt = at
    }

    func values(of metric: FootprintTrendMetric) -> [Double] { samples.map { $0.value(metric) } }

    /// The highest reading in the window, which is the one figure a shape cannot state precisely.
    func peak(of metric: FootprintTrendMetric) -> Double? { values(of: metric).max() }
}

/// Every live session's series, keyed by supervisor pid as the board spells it
/// (`SessionRosterStore.SessionRow.id`).
///
/// A DICTIONARY THAT IS SWEPT RATHER THAN ONE THAT GROWS. A pid is handed out again once its
/// session has gone, so a series left behind would be adopted by an unrelated session and drawn as
/// its own history; sweeping is therefore correctness before it is housekeeping.
struct FootprintHistory: Equatable {
    private(set) var series: [String: FootprintTrendSeries] = [:]

    subscript(key: String) -> FootprintTrendSeries? { series[key] }

    mutating func record(_ sample: FootprintTrendSample, for key: String, at: Date) {
        var one = series[key] ?? FootprintTrendSeries()
        one.record(sample, at: at)
        series[key] = one
    }

    /// Keep only the sessions the board still holds. Closing the panel keeps everything: the
    /// readings go on being taken behind it, and a person who comes back in a minute is asking
    /// about the minute they were away.
    mutating func retain(_ keys: Set<String>) {
        guard series.contains(where: { !keys.contains($0.key) }) else { return }
        series = series.filter { keys.contains($0.key) }
    }
}

/// THE SHAPE OF A SERIES, in points a view can stroke.
///
/// Hand-drawn rather than charted: a charting framework brings axes, ticks, legends and a scale
/// somebody has to configure away, all for a figure 44 points wide that carries none of them. What
/// is left once those are gone is this arithmetic, which fits on a screen and can be asserted.
enum FootprintSparkline {
    /// Two readings is the least that is a line at all. One point is a dot, and a dot drawn where a
    /// trend goes reads as a trend that is flat rather than as one that has not been measured yet.
    static let minimumReadings = 2

    /// The readings as points inside `size`, left to right, with y growing downward as a view's does.
    ///
    /// MEASURED FROM ZERO, NOT FROM THE LOWEST READING. A line stretched between its own minimum
    /// and maximum turns a tree that sat between 3.90 and 3.94 GB into a mountain range, and every
    /// one of these three metrics has a meaningful zero to measure from. The cost is honest: a
    /// series that never moves is drawn as a flat line at the top of its box, which is what "held
    /// at its peak the whole time" looks like.
    ///
    /// - Parameter inset: how far the line stays off the top and bottom edges. Half the stroke
    ///   width, so a reading at the ceiling is drawn whole rather than clipped in half by the frame.
    static func points(_ values: [Double], in size: CGSize, inset: CGFloat = 0.5) -> [CGPoint] {
        guard values.count >= minimumReadings, size.width > 0, size.height > 2 * inset else {
            return []
        }
        let ceiling = values.max() ?? 0
        let usable = size.height - 2 * inset
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let share = ceiling > 0 ? CGFloat(max(0, value) / ceiling) : 0
            return CGPoint(x: CGFloat(index) * step, y: inset + (1 - share) * usable)
        }
    }

    /// Which reading to mark with a dot, or nothing when there is no peak to point at: a flat line
    /// is at its maximum everywhere, and a dot on the first of those would be pointing at an
    /// arbitrary moment.
    static func peakIndex(_ values: [Double]) -> Int? {
        guard values.count >= minimumReadings, let top = values.max(), let bottom = values.min(),
              top > bottom else { return nil }
        return values.firstIndex(of: top)
    }
}
