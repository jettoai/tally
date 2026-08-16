import SwiftUI

// WHAT THE SESSION IS DOING TO THE MACHINE, as the card draws it. Split from SessionCardView.swift
// on file size, along the seam the card itself already reads: everything above this line is what a
// session IS (its name, its account, what it has spent), and this is the one MEASUREMENT on it -
// taken by a store that samples whether or not the page is on screen (`ProcessFootprintStore`),
// decided in pure functions next door (`ProcessTree.segments`, `FootprintTrend.swift`), and drawn
// here because only a view has the bundle the plurals come out of and the colour a warning is
// marked in.
//
// TWO ROWS, AND THE READINGS ARE ON THE SECOND ONE. Each trended metric is drawn as one group -
// its shape, its current figure, and the ceiling it came off - because those three are about the
// same number and had been laid out as two separate rows of three, where nothing said which figure
// belonged to which line (Albert, 2026-08-15: "is the current value even in there? it looks like
// only peaks"). What is left on the first row is what has no shape: the fan-out, the writing, the
// ports.
extension SessionCardView {

    /// Every field of the footprint, or nothing at all when this session's tree cannot be read: the
    /// numbers come from a store that samples whether or not this page is on screen, so "no entry"
    /// covers both the tick that has not happened yet and the supervisor that has ended, and
    /// neither of those is a card's business to explain.
    ///
    /// THE PLURALS ARE DECIDED HERE, where the bundle is, and the shape of the line is decided in a
    /// pure function the assertion harness can state without one (`ProcessTree.segments`).
    var sessionFootprintSegments: [ProcessFootprintSegment] {
        guard let footprint = ProcessFootprintStore.shared.footprints[row.id] else { return [] }
        return ProcessTree.segments(footprint,
                                    unit: L(footprint.processes == 1 ? "proc" : "procs"),
                                    agentUnit: L(footprint.agents == 1 ? "agent" : "agents"))
    }

    /// The fields no shape is kept for, in the order the whole line is written in: how many agents
    /// are working, what is being written, what is being listened on (`FootprintTrendMetric`). The
    /// three that DO have a shape are drawn with it, one row down.
    var sessionFootprintRest: [ProcessFootprintSegment] {
        sessionFootprintSegments.filter { FootprintTrendMetric($0.kind) == nil }
    }

    /// The first row, drawn from the pieces rather than from one string, because one field of it
    /// can be a warning and the rest of the line must not become one with it.
    ///
    /// QUIETER THAN THE ROW BELOW IT, which is new: these are the fields that survive on a card
    /// nobody is worried about (a port, a fan-out), and the figures somebody opened this board to
    /// read are the ones under them.
    ///
    /// A WARNING IS NOT A COLOUR. The amber says "look here" to most people and nothing at all to
    /// somebody who cannot separate it from the tertiary grey beside it, so the mark carries the
    /// meaning and the colour only makes it faster to find - the same pairing every other warning
    /// in this app draws (`AccountCardView`). VoiceOver gets neither, and is handed the condition
    /// in words instead.
    ///
    /// NO HOVER AND NO BADGE. The explanation lives in the line itself, where the number it is
    /// about already is; a callout would be a second surface to open for a sentence that fits
    /// beside the number, and this card just had one taken off it.
    @ViewBuilder
    var sessionFootprint: some View {
        let rest = sessionFootprintRest
        if !rest.isEmpty {
            rest.enumerated()
                .reduce(Text(verbatim: "")) { line, part in
                    let lead = part.offset == 0 ? Text(verbatim: "")
                                                : Text(verbatim: pickEffortSeparator)
                    return line + lead + Self.drawn(part.element.text, alert: part.element.alert)
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.tail)
                // A style a run sets for itself wins over the one the view sets around it, which is
                // what lets the warned field carry the amber while the rest of the line does not.
                .accessibilityLabel(Self.spoken(rest))
        }
    }

    /// One metric as the card draws it: what it reads now, the shape it arrived by, and the ceiling
    /// it came off.
    struct Trend: Identifiable {
        let metric: FootprintTrendMetric
        /// The value line's own field, kept whole for the reader who HEARS the row: it carries the
        /// words the figure below drops, the kind a warning is named by, and whether it is warned.
        let segment: ProcessFootprintSegment
        /// The current reading, spelled as tersely as three of these on one row can be
        /// (`FootprintTrendMetric.figureText`). The NUMBER, and the unit that is part of it.
        let figure: String
        /// The word beside that number, drawn a shade down from it: what a count is counting, or
        /// the program blamed for a rate (`ProcessFootprintSegment.aside`).
        let aside: String?
        /// The readings behind it with this instant's own appended, or nothing when there are too
        /// few kept ones to be a line at all. The live reading is drawn and never stored, so the
        /// line's bright end point is the figure printed beside it (`FootprintSparklineView`).
        let values: [Double]
        /// The highest reading in the window, or nothing when there is none worth printing.
        ///
        /// A PEAK THAT EQUALS THE READING IS NOT PRINTED, which is what makes this row fit a narrow
        /// card in the ordinary case: a session sitting at its own maximum (every steady tree, most
        /// process counts) would otherwise print the same number twice with an arrow between them.
        let peak: String?
        var id: FootprintTrendMetric { metric }
    }

    /// WHAT EACH TRENDED METRIC HAS TO SAY, built from the FIGURES rather than from the history, so
    /// a session that has not been sampled twice yet still states its numbers and simply has no
    /// line behind them yet.
    ///
    /// ONE ORDER ON EVERY CARD, WARNED OR NOT (`FootprintTrendMetric.allCases`). The value line
    /// above brings a warned field to the front because that line is one sentence truncated at its
    /// tail, where a warning left in reading order loses its number off the end
    /// (`ProcessTree.segments`). This row is not that line: it never truncates, it drops CEILINGS
    /// to fit (`sessionFootprintTrends`), so moving a group buys nothing here and costs the only
    /// thing this row is read for. A board is read DOWN the cards, and `procs · 4.1 GB · 1%` on a
    /// warned card beside `procs · 1% · 3.4 GB` on a calm one puts two different quantities in the
    /// same place and asks the reader to check the unit on every one (Albert, 2026-08-16). So the
    /// order is fixed, and a warning stays on the group whose number it is about: the figure and
    /// its line turn amber, and the mark rides on the line (`figure`, `FootprintSparklineView`).
    var sessionFootprintTrendGroups: [Trend] {
        guard let footprint = ProcessFootprintStore.shared.footprints[row.id] else { return [] }
        let series = ProcessFootprintStore.shared.history[row.id]
        // The value line's own field per metric, which is what carries the words, the culprit's
        // name and the warning into the group. Its POSITION is what is left behind here.
        var fields: [FootprintTrendMetric: ProcessFootprintSegment] = [:]
        for segment in sessionFootprintSegments {
            if let metric = FootprintTrendMetric(segment.kind) { fields[metric] = segment }
        }
        return FootprintTrendMetric.allCases.compactMap { metric in
            guard let segment = fields[metric] else { return nil }
            let readings = series?.values(of: metric) ?? []
            let now = metric.reading(of: footprint)
            // The value line's own words are the fallback, so a reading the terse speller has no
            // form for is still on the card as the sentence above it would have said it.
            let figure = now.flatMap(metric.figureText) ?? segment.text
            // THE CEILING INCLUDES THE READING PRINTED BESIDE IT, which is not a detail: the ring's
            // own maximum is up to a bucket behind the live figure, so a session that had just
            // jumped to 16% drew `16% ↑1%` - a ceiling under the number it is the ceiling of
            // (measured on a live board, 2026-08-15). Taken together the two agree by construction,
            // and a reading that IS the highest of the window simply prints no arrow at all.
            let peak = [series?.peak(of: metric), now].compactMap { $0 }.max()
                .flatMap(metric.peakText)
            // Drawn from the kept readings plus this instant's, so the line ends where the figure
            // beside it says the session is; the ring itself is never told about that last point.
            let drawn = readings.count >= FootprintSparkline.minimumReadings
                ? readings + [now].compactMap { $0 } : []
            return Trend(metric: metric, segment: segment, figure: figure, aside: segment.aside,
                         values: drawn, peak: peak == figure ? nil : peak)
        }
    }

    /// The row the readings are on: each trended metric's shape, its figure, and its ceiling.
    ///
    /// THE PEAK IS THE ONE NUMBER A SHAPE CANNOT STATE. A line drawn from zero says how the session
    /// got here and says nothing about the scale it did it on - the same rising curve is a session
    /// that reached 40% and one that reached 400% - so the ceiling is printed, and the line's own
    /// dot points at the moment it happened.
    ///
    /// AND IT IS WHAT GIVES WAY WHEN THE CARD IS TOO NARROW, in the order below. Measured at 10pt
    /// (2026-08-15): three shapes, three figures and the process word are 211pt, which fits the
    /// 236pt a 264pt card gives its content; one ceiling column takes it to 251 and all three to
    /// 327, which fits the 328pt of a single-column panel. So the figures and their lines are never
    /// dropped - they are what the row is - and the ceilings go one at a time, the process count's
    /// first (a count barely moves, so its peak is most often the figure already printed) and the
    /// CPU's last (the spikiest of the three, and the one a fifteen-minute line most understates).
    /// A two-column board therefore keeps its figures and loses its arrows, which is the trade in
    /// the order it was asked for; the peak is still marked on the line and still spoken.
    @ViewBuilder
    var sessionFootprintTrends: some View {
        let trends = sessionFootprintTrendGroups
        if !trends.isEmpty {
            ViewThatFits(in: .horizontal) {
                trendRow(trends, peaks: 3)
                trendRow(trends, peaks: 2)
                trendRow(trends, peaks: 1)
                trendRow(trends, peaks: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spokenTrends(trends))
        }
    }

    /// One candidate layout of that row: every group's shape and figure, and the ceilings of the
    /// first `peaks` metrics that are entitled to one.
    ///
    /// THE NUMBER IS BRIGHT AND EVERY WORD AROUND IT IS NOT, which is the second half of the same
    /// correction. Reported as one string of equal parts - `2 procs · 1% CPU (claude) · 459 MB` -
    /// this row asks the reader to segment it themselves: three heterogeneous facts, six words and
    /// two numbers all at one weight (Albert, 2026-08-15). Drawn in two tones the eye lands on the
    /// figures and reads the words only if it wants them. A unit that is part of its number stays
    /// with it (`%`, `GB`) and only the words that are not (`procs`, a culprit's name, the ceiling)
    /// step back.
    ///
    /// AND NO SEPARATOR BETWEEN GROUPS. A dot between them would put the three heterogeneous facts
    /// back in one string; the gutter is what says these are three things (`trendGap`, wider than
    /// the space inside a group). The dot is still what separates the plain fields on the row above.
    private func trendRow(_ trends: [Trend], peaks: Int) -> some View {
        let named = Set(Self.peakOrder.prefix(peaks))
        return HStack(spacing: Self.trendGap) {
            ForEach(trends) { trend in
                HStack(spacing: Self.trendSpacing) {
                    // A metric sampled once has no line yet and still has a number: the group falls
                    // back to the figure alone rather than waiting half a minute to say anything.
                    if !trend.values.isEmpty {
                        FootprintSparklineView(values: trend.values, alert: trend.segment.alert)
                    }
                    Self.column(trend.metric.widestFigure) {
                        Self.figure(trend.figure, alert: trend.segment.alert,
                                    marked: trend.values.isEmpty)
                    }
                    if let aside = trend.aside {
                        // LAST IN THE QUEUE FOR ROOM, because it is the one piece here that can be
                        // arbitrarily long: a culprit called `Google Chrome Helper` is 100pt of a
                        // 236pt card, and left at the ordinary priority the layout would take that
                        // width off a figure instead. A truncated name still points at a program;
                        // a truncated figure is a wrong number.
                        Text(verbatim: aside).foregroundStyle(.tertiary).layoutPriority(-1)
                    }
                    // THE COLUMN IS HELD EVEN WHEN THERE IS NO CEILING TO PRINT IN IT, which is the
                    // last thing in this row that moved: a peak is hidden exactly when the reading
                    // has just become the highest of the window, so on a climbing session the
                    // arrow left and came back every few seconds and took the memory group with it
                    // both ways. A metric that is being tracked at all keeps its column, so
                    // everything a candidate lays out is the same width from tick to tick.
                    if named.contains(trend.metric), !trend.values.isEmpty {
                        Self.column(Self.peakMark + trend.metric.widestFigure) {
                            Text(verbatim: trend.peak.map { Self.peakMark + $0 } ?? "")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
    }

    /// A figure held in a column as wide as the widest reading it will print, right aligned so the
    /// digits end in the same place whatever the number is.
    ///
    /// A ROW OF LIVE NUMBERS THAT IS LAID OUT TO ITS OWN CONTENT MOVES CONSTANTLY: every figure
    /// here is re-read every two seconds, so a CPU going from 9% to 10% used to push the memory
    /// figure and its whole group along, and a card being read was a card in motion (Albert,
    /// 2026-08-15). Sized by a HIDDEN COPY of the widest case rather than by a number in points,
    /// the same way this board sizes an empty line by the type it would have held
    /// (`SessionCardView.sessionCardLine`): nothing here has to know what 10pt digits measure, and
    /// a figure that outgrows its column widens it rather than being clipped.
    static func column(_ widest: String, @ViewBuilder _ figure: () -> Text) -> some View {
        ZStack(alignment: .trailing) {
            Text(verbatim: widest).hidden()
            figure()
        }
    }

    /// Which ceilings a row keeps as it runs out of room, most worth keeping last (see
    /// `sessionFootprintTrends`).
    static let peakOrder: [FootprintTrendMetric] = [.cpu, .memory, .processes]

    /// Between one metric's group and the next: the gutter the board's own cards are laid out with,
    /// and wider than the gap inside a group, so the row reads as three things rather than as nine.
    static let trendGap: CGFloat = PopoverRootView.sessionCardGap
    /// Between the three pieces that are all about one number.
    static let trendSpacing: CGFloat = 3

    /// What marks a figure as the ceiling rather than the current reading. A glyph rather than the
    /// word, because "peak" three times costs about a third of the card's width and this row has to
    /// hold three of everything; the word itself is what VoiceOver is given instead.
    static let peakMark = "\u{2191}"

    /// The row in words, for a reader who gets no shape at all: each metric said in the VALUE
    /// LINE'S own sentence rather than in the terse figure the row draws ("4 procs", not "4"), each
    /// warning named, each peak said. One catalogue key per metric rather than a name substituted
    /// into a shared sentence, so every one of them is a phrase a translator sees whole
    /// (`FootprintTrendMetric.peakLabelKey`).
    ///
    /// A PEAK THE ROW DROPPED FOR ROOM IS STILL SAID HERE, because speech has no width to run out
    /// of: what a narrow card gives up is a column, and a listener has no columns. The one peak
    /// this drops is the one the row drops for the other reason - a ceiling equal to the reading
    /// just said is not a second fact, at any width (`Trend.peak` is already nothing for it).
    static func spokenTrends(_ trends: [Trend]) -> String {
        trends.map { trend in
            let reading = spoken([trend.segment])
            guard let peak = trend.peak else { return reading }
            return "\(reading), \(String(format: L(trend.metric.peakLabelKey), peak))"
        }.joined(separator: ", ")
    }

    /// ONE GROUP'S FIGURE, amber when its reading is the one worth somebody's eye - and WITHOUT the
    /// triangle, which is drawn over the shape beside it instead (`FootprintSparklineView`).
    ///
    /// THE MARK LEFT THE TEXT BECAUSE IT MOVED THE ROW. It is about nine points wide, so a warning
    /// arriving widened its group and pushed every figure after it along, on the one row this card
    /// had just pinned into fixed columns for exactly that reason (Albert, 2026-08-16). Both
    /// channels of the warning survive the move: the colour is on the number, and the mark is on the
    /// shape the number belongs to.
    ///
    /// - Parameter marked: whether this figure has to carry the mark itself, which it does only when
    ///   there is no shape yet to put it on - a session in its first half-minute, where one reflow
    ///   is cheaper than a column held empty on every card forever.
    static func figure(_ text: String, alert: Bool, marked: Bool) -> Text {
        guard alert else { return Text(verbatim: text).foregroundStyle(.primary) }
        return (marked ? drawn(text, alert: true) : Text(verbatim: text))
            .foregroundStyle(TallyColor.warning)
    }

    /// One field as it is drawn, with a warning marked as well as coloured.
    static func drawn(_ text: String, alert: Bool) -> Text {
        guard alert else { return Text(verbatim: text) }
        return (Text(Image(systemName: "exclamationmark.triangle.fill")) + Text(verbatim: " ")
                    + Text(verbatim: text))
            .foregroundStyle(TallyColor.warning)
    }

    /// The same fields for a reader who cannot see them, with every warning said rather than drawn.
    /// Read as a list, because it is one: the separator between fields is a dot on screen and a
    /// pause in speech.
    static func spoken(_ segments: [ProcessFootprintSegment]) -> String {
        segments.map { segment in
            guard segment.alert, let warning = warning(about: segment.kind) else {
                return segment.text
            }
            return "\(segment.text), \(warning)"
        }.joined(separator: ", ")
    }

    /// What each warning is about, in the words a person would use for it. All three name the
    /// idleness because that is the whole of why they are warnings: the same numbers on a working
    /// session are just work (`FootprintAlarm`).
    static func warning(about kind: ProcessFootprintSegment.Kind) -> String? {
        switch kind {
        case .cpu: L("high CPU while nothing is running")
        case .disk: L("writing to disk while nothing is running")
        case .memory: L("holding a lot of memory while nothing is running")
        default: nil
        }
    }
}
