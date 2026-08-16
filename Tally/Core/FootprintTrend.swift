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
    /// How long that interval was, in seconds: the gap between the two readings the rate was
    /// differenced from (`ProcessTree.cpuPercent`), which is what the fold below weights by.
    ///
    /// CARRIED RATHER THAN ASSUMED, because it is not the sampler's own interval whenever the rate
    /// changes: opening the board takes a reading at once and puts the timer on the fast rate
    /// (`ProcessFootprintStore.beginViewing`), so the reading that lands there covers however long
    /// the slow rate had been running. No default, so a caller with one cannot forget to say it.
    var seconds: Double
    /// What the tree was holding in physical memory at that instant.
    var memoryBytes: UInt64
    /// How many processes the session had STARTED at that instant: Tally's own already taken out
    /// (`ProcessTree.ownFamily`) and the session's own CLI with them (`ProcessTree.dispatched`), so
    /// the line and the figure printed beside it are the same quantity.
    var processes: Int

    func value(_ metric: FootprintTrendMetric) -> Double {
        switch metric {
        case .processes: Double(processes)
        case .cpu: cpuPercent
        case .memory: Double(memoryBytes)
        }
    }

    /// THE ONE POINT A HANDFUL OF FAST READINGS IS KEPT AS, which is three decisions rather than
    /// one, because these three numbers are not the same kind of number.
    ///
    /// The CPU is a RATE over the interval that ended at its reading, so the readings are averaged
    /// WEIGHTED BY THE TIME EACH OF THEM COVERS. Where the intervals are equal - the five
    /// two-second readings of an open board - that is the plain mean, and it is exactly the
    /// ten-second reading the background pass would have taken over the same span: the identity
    /// that makes one series out of two sampling rates is kept.
    ///
    /// AND WHERE THEY ARE NOT EQUAL, THE WEIGHTING IS THE WHOLE OF WHAT KEEPS IT HONEST. The rates
    /// meet inside a single bucket every time somebody opens the board, which samples at once and
    /// re-times (`ProcessFootprintStore.beginViewing`): eight seconds of an idle tree followed by
    /// two of a busy one is a bucket that reads 50% averaged flat and 20% weighted, and 20% is what
    /// those ten seconds held. The flat mean therefore drew a peak on the line that was created by
    /// the act of LOOKING at it (codex review of 4868f2f, 2026-08-16).
    ///
    /// The memory and the process count are INSTANTS, and an instant folds to the last one taken -
    /// averaged, they would draw a tree at a size it was never at.
    ///
    /// THE DEFECT THIS ENDS: the ring used to keep one fast reading in five and discard the rest,
    /// so eight seconds out of every ten simply never happened while somebody was watching - a
    /// spike inside them was gone, and the shape of a session depended on whether its panel was
    /// open. Averaging is the conservative half of the fix: a two-second burst is now IN the point
    /// rather than dropped, and it is drawn at the height it contributed to the ten seconds rather
    /// than at its own (a bucket's own maximum could be carried too, and would be a second series
    /// rather than a better one).
    static func folded(_ readings: [FootprintTrendSample]) -> FootprintTrendSample? {
        guard let last = readings.last else { return nil }
        let span = readings.reduce(0) { $0 + max(0, $1.seconds) }
        // The flat mean is the fallback rather than the rule, and it is reached only by a bucket
        // whose readings all claim no interval at all - which the sampler cannot produce (a rate
        // exists only once there is a span to state it over) and which has to say SOMETHING if it
        // ever does.
        let cpu = span > 0
            ? readings.reduce(0) { $0 + $1.cpuPercent * max(0, $1.seconds) } / span
            : readings.reduce(0) { $0 + $1.cpuPercent } / Double(readings.count)
        // The span the point states is the whole bucket's rather than the last reading's, because
        // that is what the rate above is a rate OVER: a point that claimed its closing reading's two
        // seconds would be a ten-second average labelled as two seconds of one.
        return FootprintTrendSample(cpuPercent: cpu, seconds: span, memoryBytes: last.memoryBytes,
                                    processes: last.processes)
    }
}

/// The three readings that are worth a line, in the order every card prints them in
/// (`SessionCardView.sessionFootprintTrendGroups`): what the session HAS first, because it is the
/// context the other two are read under, then what it is burning and what it is holding.
///
/// THE ORDER IS FIXED HERE RATHER THAN TAKEN FROM THE VALUE LINE, whose fields move a warned one to
/// the front (`ProcessTree.segments`). That rule is right about a sentence that gets truncated and
/// wrong about a row of figures read down a board: a column that is a percentage on one card and a
/// gigabyte figure on the next is not a column.
///
/// DISK IS NOT ONE OF THEM, and its absence is a measurement rather than an omission. Writing is
/// bursty by nature: a session writes nothing for minutes and then puts out 40 MB in one interval,
/// so a line of it is a flat zero with a spike in it, which says less than the one number already
/// on the card. The ports are not here for a different reason: they are not a quantity at all, and
/// they are not on this row either - they are up on the identity line (`ProcessTree.portsText`).
enum FootprintTrendMetric: Hashable, CaseIterable {
    case processes, cpu, memory

    /// Which trend a field of the value line belongs to, or nothing when it has none.
    ///
    /// EXHAUSTIVE ON PURPOSE, so a field added to that line has to be given an answer here rather
    /// than defaulting into "no trend" without anybody noticing (`ProcessTree.segments`).
    init?(_ kind: ProcessFootprintSegment.Kind) {
        switch kind {
        case .processes: self = .processes
        case .cpu: self = .cpu
        case .memory: self = .memory
        case .agents, .disk: return nil
        }
    }

    /// This metric's reading in a footprint, or nothing when the footprint cannot state it yet: a
    /// cumulative counter says nothing about a rate until it has been read twice.
    func reading(of footprint: ProcessFootprint) -> Double? {
        switch self {
        case .processes: Double(footprint.processes)
        case .cpu: footprint.cpuPercent
        case .memory: Double(footprint.memoryBytes)
        }
    }

    /// A figure of this metric in the words the card spells it in. ONE SPELLER FOR BOTH FIGURES a
    /// group carries - the reading and the ceiling above it - so a peak reading "4200 MB" can never
    /// appear beside a current value reading "3.9 GB".
    ///
    /// TERSER THAN THE VALUE LINE'S OWN WORDS, and the unit is what carries the meaning: `%` is the
    /// CPU, `GB` is the memory, a bare count is the processes. Measured (2026-08-15, 10pt): the
    /// three fields spelled in full are 118.2pt against the 236pt a 264pt card gives its content,
    /// which leaves no room for the shapes they belong to, let alone a peak. The words are not
    /// lost, they move: VoiceOver is handed the value line's own sentence
    /// (`SessionCardView.spokenTrends`).
    func figureText(_ value: Double) -> String? {
        switch self {
        case .processes: "\(Int(value.rounded()))"
        case .cpu: "\(Int(value.rounded()))%"
        case .memory: ProcessTree.memoryText(UInt64(max(0, value)))
        }
    }

    /// The widest figure this metric prints in ordinary use, which is what its column on a card is
    /// sized from: a hundred per cent of three cores, a tree holding ninety-nine and a half
    /// gigabytes, a session running ninety-nine processes. Nothing is clipped when a reading passes
    /// it - the column grows and the row reflows once, which is what a rare event should cost.
    ///
    /// IT EXISTS BECAUSE THE NUMBERS MOVE. Every one of these is re-read every two seconds, and a
    /// figure laid out to its own width takes the whole row with it as it changes digits: the
    /// memory shifts because the CPU went from 9% to 10%, and a person trying to read a card is
    /// reading a moving target (Albert, 2026-08-15). Held in a column of this width, right
    /// aligned, a changing digit changes a glyph and nothing else moves.
    var widestFigure: String {
        switch self {
        case .processes: "99"
        case .cpu: "100%"
        case .memory: "99.9 GB"
        }
    }

    /// The peak, or nothing when it is too small to be worth saying.
    ///
    /// THE FLOOR IS THE PEAK'S OWN AND THE VALUE LINE HAS NONE, which this used to claim the
    /// opposite of ("the thresholds the value line already keeps"): a tree at 0.4% is printed as
    /// `0% CPU` there and has no peak worth an arrow here. The two are not required to agree,
    /// because they answer different questions - what a session IS doing has to be stated at any
    /// size, and a fifteen-minute ceiling of nought per cent is not a fact about anything. What
    /// they do share is the SPELLING (`figureText`), which is what stops the same quantity being
    /// written two ways. A group is never dropped for want of a peak: it is built from the reading
    /// (`SessionCardView.sessionFootprintTrendGroups`), and the arrow is what goes missing.
    func peakText(_ value: Double) -> String? {
        switch self {
        case .processes, .cpu: value >= 1 ? figureText(value) : nil
        case .memory: figureText(value)
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
/// halfway along is not a trend, it is two trends drawn on top of each other.
///
/// SO THE FAST TICKS ARE FOLDED, NOT REFUSED, which they used to be. Keeping one reading in five
/// holds the cadence and quietly changes what a point MEANS: eight seconds out of every ten were
/// thrown away with the panel open and averaged in with it closed, so the same session drew a
/// different shape depending on whether anybody was looking at it. Every reading now lands in the
/// point being assembled (`FootprintTrendSample.folded`), and the two rates produce the same
/// series out of the same load.
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
    /// How long a silence has to run before what comes after it is a NEW line rather than the
    /// continuation of the old one. Three cadences: one or two missed ticks are a main thread that
    /// was busy, and anything past that is the machine having been away - a lid opened after a
    /// night would otherwise draw yesterday's eighty-nine readings as "the last quarter hour", with
    /// nothing on the line to say that the last two points are twelve hours apart.
    static let staleAfter: TimeInterval = 3 * cadence

    private(set) var samples: [FootprintTrendSample] = []
    /// When the newest kept reading was taken, which is what the cadence is measured from.
    private(set) var lastAcceptedAt: Date?
    /// When the newest reading was OFFERED, kept or folded, which is what the silence is measured
    /// from.
    ///
    /// THE TWO ARE DIFFERENT CLOCKS AND ONLY ONE OF THEM IS A SILENCE. A reading that joins the
    /// point being assembled is a reading the sampler took, so the machine was demonstrably there;
    /// but with the board open it does not move `lastAcceptedAt`, which advances once a bucket.
    /// Measured against that one, a tree sampled every two seconds and then interrupted for
    /// twenty-three was already "away" - past `staleAfter` - and threw a quarter of an hour of
    /// history away over a silence the warning next door counts as one unbroken run of evidence
    /// (`FootprintAlarm.gapAfter`, the same thirty seconds about the same silence). The two clocks
    /// now read the same instants, which is what that pairing was always supposed to mean.
    ///
    /// The cost of the reset was not only the line: a series that drops under two points takes the
    /// shape off the card altogether (`SessionCardView.sessionFootprintTrendGroups`), so every
    /// figure on that row moves, on the one row this card pinned into fixed columns to stop exactly
    /// that.
    private(set) var lastOfferedAt: Date?
    /// The readings taken since the last point was kept, waiting to be folded into the next one. At
    /// the background rate this holds the one reading that becomes the point; with the board open
    /// it holds the five that make it up.
    private(set) var pending: [FootprintTrendSample] = []

    /// Whether a reading taken at `at` closes the point being assembled, rather than joining it.
    func accepts(_ at: Date) -> Bool {
        guard let lastAcceptedAt else { return true }
        return at.timeIntervalSince(lastAcceptedAt) >= Self.cadence - Self.tolerance
    }

    /// Whether so long has passed that what is held is a different session's afternoon rather than
    /// this reading's own recent past (see `staleAfter`).
    ///
    /// MEASURED FROM THE LAST READING OFFERED, not from the last one kept: what this asks is whether
    /// anything was sampling in between, and a reading folded into the point being assembled is a
    /// reading that was taken (`lastOfferedAt`).
    func isStale(at: Date) -> Bool {
        guard let lastOfferedAt else { return false }
        return at.timeIntervalSince(lastOfferedAt) > Self.staleAfter
    }

    /// Offer a reading. EVERY ONE OF THEM IS KEPT SOMEWHERE - in the point being assembled, or as
    /// the point itself - which is what holds the series to one meaning across both rates.
    mutating func record(_ sample: FootprintTrendSample, at: Date) {
        // A line that starts again says "the last quarter hour" honestly from its first point; one
        // that carried on would say it about readings taken before the machine slept.
        if isStale(at: at) { self = FootprintTrendSeries() }
        // Every offer, kept or folded, is evidence that something was sampling at this instant,
        // which is the whole of what the silence above is measured over.
        lastOfferedAt = at
        pending.append(sample)
        guard accepts(at) else { return }
        if let point = FootprintTrendSample.folded(pending) { samples.append(point) }
        pending = []
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
