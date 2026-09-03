import AppKit
import SwiftUI

// THE ROW THE READINGS ARE ON. Split from SessionCardFootprint.swift on file size, along the seam
// that file's own header already reads the card by: everything left there is the FIELDS WITH NO
// SHAPE - the fan-out, the writing, the ports' spelling - and this is the row where the three
// trended metrics are drawn, each as its shape, its current figure and the ceiling it came off.
//
// The pieces are still one unit and the assertion harness reads the two files as one string, so a
// line moving between them cannot silently stop being asserted (tests/supervisor/
// footprinttrendsurfacechecks.swift, which does the same for the store's own two halves).
extension SessionCardView {

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
        /// The same reading as a QUANTITY, which is what tells the digits which way to roll when
        /// they change (`ContentTransition.numericText(value:)`): a figure going up flips upward and
        /// one coming down flips down, and neither can be inferred from the spelling beside it
        /// ("999 MB" to "1.0 GB" is a rise that reads as a fall). Nothing at all where the metric
        /// has no reading yet, in which case there is no direction to state either.
        let value: Double?
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
    /// order is fixed, and a warning stays on the group whose number it is about: the figure, the
    /// line and both of its dots turn amber together (`figure`, `FootprintSparklineView`).
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
            return Trend(metric: metric, segment: segment, figure: figure, value: now,
                         aside: segment.aside, values: drawn, peak: peak == figure ? nil : peak)
        }
    }

    /// The row the readings are on: each trended metric's shape, its figure, and its ceiling.
    ///
    /// THE PEAK IS THE ONE NUMBER A SHAPE CANNOT STATE. A line drawn from zero says how the session
    /// got here and says nothing about the scale it did it on - the same rising curve is a session
    /// that reached 40% and one that reached 400% - so the ceiling is printed, and the line's own
    /// dot points at the moment it happened.
    ///
    /// AND IT IS WHAT GIVES WAY WHEN THE CARD IS TOO NARROW, in the order below. Re-measured at
    /// 10pt (2026-08-17, this app's own font) now that the memory figure carries a culprit's name:
    /// three shapes, three figures and the process word are 208pt, which fits the 236pt a 264pt
    /// card gives its content; the memory's `(claude)` takes it to 244 and the first ceiling column
    /// to 265, while all three ceilings and both words are 341, which fits the 328pt of a
    /// single-column panel only once one of them is gone.
    ///
    /// SO THE CEILINGS GO BEFORE THE NAMES DO, which is the order that moved. Attribution is the
    /// thing this row was asked for - a memory figure with no name beside it cannot say whether
    /// those gigabytes are the session's own Claude Code or the thing it started
    /// (`ProcessFootprint.memoryLeader`) - and a ceiling is a second reading of a number already
    /// printed. So every candidate keeps its culprits until all three arrows are gone, and only
    /// then does the row start dropping words: first the process count's `procs`, which is a UNIT
    /// rather than a culprit and the one aside here that says nothing a reader could act on, and
    /// last the names themselves. The figures and their lines are never dropped - they are what the
    /// row is - and the ceilings go one at a time, the process count's first (a count barely moves,
    /// so its peak is most often the figure already printed) and the CPU's last (the spikiest of
    /// the three, and the one a fifteen-minute line most understates). Everything dropped for room
    /// is still spoken in full (`spokenTrends`).
    ///
    /// AND THE TWO NAMES GO ONE AT A TIME, which the first version of this order did not do and is
    /// the whole of what it was reported for (codex review of 0cd4a09). Both names are culprits, so
    /// the `culpritsOnly` rung keeps or drops them together: measured at 10pt on the same ledger as
    /// the figures above (208pt for the shapes, the figures and the unit word; 244 with the unit
    /// word and the memory's name), that rung is 213pt on a card naming only the memory's holder
    /// and 240pt as soon as the CPU has one too, against
    /// the 236pt a 264pt card gives its content - so a session busy enough to blame a process for
    /// BOTH readings fell straight past it to the rung with no names at all. That is the session
    /// somebody has this board open for, and the name this commit was written to keep is the one it
    /// lost. There is therefore a rung between them that keeps the memory's name alone
    /// (`FootprintTrendMetric.asideSurvivesAlone` says why it is that one), and only under it does
    /// the row go silent.
    ///
    /// A NAME IS NOT GIVEN A COLUMN OF ITS OWN, unlike the figures and the ceilings, and that is a
    /// live trade rather than an oversight: culprits change length as the culprit changes (`bun` is
    /// 19pt, `Google Chrome Helper` 112pt), so a card whose heaviest process changes will reflow
    /// this row - the very thing the fixed columns were introduced to stop. A column wide enough
    /// for an arbitrary program name would cost more of a 236pt card than the whole memory group,
    /// and one sized to a short name would truncate most of them. Measured against the alternative
    /// of not naming the memory at all, the jitter is the cheaper of the two (Albert, 2026-08-16).
    @ViewBuilder
    var sessionFootprintTrends: some View {
        let trends = sessionFootprintTrendGroups
        // OR NOTHING BUT THE LEFTOVERS, which is a real card rather than a hypothetical one: the
        // groups are built from a footprint this store has read (`sessionFootprintTrendGroups`), and
        // a project's last session can be one whose tree could not be read on this tick. The
        // checkout's leftovers are a reading about the DIRECTORY and are known either way, so a row
        // gated on the session's own figures would take them off the board for that tick.
        if !trends.isEmpty || leftovers != nil {
            ViewThatFits(in: .horizontal) {
                trendRow(trends, peaks: 3, asides: .all)
                trendRow(trends, peaks: 2, asides: .all)
                trendRow(trends, peaks: 1, asides: .all)
                trendRow(trends, peaks: 0, asides: .all)
                trendRow(trends, peaks: 0, asides: .culpritsOnly)
                trendRow(trends, peaks: 0, asides: .memoryCulpritOnly)
                trendRow(trends, peaks: 0, asides: .none)
            }
            .accessibilityElement(children: .ignore)
            // THE ROW IS ONE ELEMENT AND THEREFORE SAYS EVERYTHING ON IT. `children: .ignore` is
            // what stops a listener being read nine unlabelled fragments, and it also swallows the
            // leftovers mark's own callout text - so what a hover would have shown is appended here
            // rather than left to a child nothing can land on. A listener has no width to run out
            // of and no pointer to hover with, which is the same rule this row already keeps about
            // the ceilings and culprit names a narrow card drops (`spokenTrends`).
            .accessibilityLabel([Self.spokenTrends(trends), leftoversSpoken]
                .filter { !$0.isEmpty }.joined(separator: ", "))
        }
    }

    /// The checkout's leftovers, on the card that is carrying them and nothing on every other card
    /// (`SessionCardView.unclaimed`, `SessionBoardGhosts.Seating.footnotes`). Nothing either once
    /// this app has ended the last of them: what is kept after that is a record, and a record is
    /// drawn on the project's own card rather than as a mark counting nothing
    /// (`SessionBoardGhosts.unclaimed(in:remembering:)`).
    private var leftovers: ProjectLoad? {
        guard let unclaimed, unclaimed.strayProcesses > 0 else { return nil }
        return unclaimed
    }

    /// The mark itself, at the end of the row (`SessionLeftoversMark`).
    @ViewBuilder
    private var leftoversMark: some View {
        if let leftovers {
            SessionLeftoversMark(project: leftovers, flamed: unclaimedMarked)
        }
    }

    /// What the mark's callout would have said, for the reader who gets no pointer.
    private var leftoversSpoken: String {
        leftovers.map { SessionUnclaimedFootnote.callout($0).spoken } ?? ""
    }

    /// WHETHER THIS FIGURE IS THE ONE THE MACHINE'S FLAME IS ABOUT.
    ///
    /// THE FLAME NAMES A CARD AND THIS NAMES THE NUMBER IT IS ABOUT (Albert, 2026-09-03, on the
    /// first live board). The mark on the headline says "this checkout is the heaviest thing on the
    /// machine and this is the card spending it" (`SessionBoardGhosts.marked`), and a reader who has
    /// found the card then has to work out WHICH of its readings earned it. It is always the cores:
    /// the heaviest checkout is decided on CPU and on nothing else, so the CPU figure is the one the
    /// flame is pointing at, and it is the only figure this lights.
    ///
    /// AND ONLY WHEN THE FIGURE HAS NO COLOUR OF ITS OWN. The alert tiers are a different axis - a
    /// share of THIS MACHINE, or a tree burning cores with nothing running - and they are read off
    /// the same figure. Where both are true the tier wins and nothing is layered on top: amber over
    /// amber would say nothing, and this amber over the saturation tier's red would take a "somebody
    /// has to do something now" and print it as "worth an eye".
    ///
    /// THE LEFTOVERS' OWN FLAME IS NOT THIS ONE. When the mark is on the checkout's strays the
    /// session's figures are not what is burning anything, so this stays false and the amber goes on
    /// the count at the end of the row instead (`SessionLeftoversMark`).
    private func flamesTheFigure(_ trend: Trend) -> Bool {
        marked && trend.metric == .cpu && trend.segment.level == .calm
    }

    /// Which of a row's quiet words a candidate layout keeps (see `sessionFootprintTrends`).
    enum TrendAsides {
        case all, culpritsOnly, memoryCulpritOnly, none

        /// Whether one metric's word survives this candidate. The rungs are the words in the order
        /// a reader can spare them: the units go first, which on this row is exactly the process
        /// count's `procs` (`FootprintTrendMetric.asideNamesACulprit`); then the CPU's culprit,
        /// whose figure means something on its own; and the memory's holder is the last word left
        /// (`FootprintTrendMetric.asideSurvivesAlone`).
        func keeps(_ metric: FootprintTrendMetric) -> Bool {
            switch self {
            case .all: true
            case .culpritsOnly: metric.asideNamesACulprit
            case .memoryCulpritOnly: metric.asideSurvivesAlone
            case .none: false
            }
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
    private func trendRow(_ trends: [Trend], peaks: Int, asides: TrendAsides) -> some View {
        let named = Set(Self.peakOrder.prefix(peaks))
        return HStack(spacing: Self.trendGap) {
            ForEach(trends) { trend in
                HStack(spacing: Self.trendSpacing) {
                    // A metric sampled once has no line yet and still has a number: the group falls
                    // back to the figure alone rather than waiting half a minute to say anything.
                    if !trend.values.isEmpty {
                        // KEYED BY THE CARD AND THE METRIC, which is what makes the draw-in happen
                        // once rather than once per rebuild: the candidate list around this swaps
                        // subtrees whenever the figures change width class
                        // (`FootprintSparklineView.identity`).
                        FootprintSparklineView(values: trend.values, level: trend.segment.level,
                                               identity: "\(row.id)/\(trend.metric)")
                    }
                    // THE DIGITS ROLL TO THEIR NEW VALUE rather than being replaced between two
                    // frames, and the direction is the reading's own: `numericText(value:)` is
                    // handed the QUANTITY, so a figure that went up flips up and one that came down
                    // flips down (`Trend.value` says why the spelling cannot answer that). Keyed on
                    // the SPELLING, so a CPU wandering between 9.1 and 9.4 per cent - which is most
                    // of them, every two seconds - draws nothing at all: what a reader sees change
                    // is what animates.
                    //
                    // AND THE COLUMN IS WHAT CARRIES IT, which is the one placement that costs
                    // nothing: the width is already pinned by a hidden copy of the widest reading
                    // (`column`), so a digit rolling in is a digit rolling inside a box that is not
                    // moving. On the figure itself it would be the same motion; on the row it would
                    // have to be one direction for three different numbers.
                    Self.column(trend.metric.widestFigure) {
                        flamesTheFigure(trend) ? Self.flamed(trend.figure)
                            : Self.figure(trend.figure, level: trend.segment.level)
                    }
                    .figureMotion(trend.figure, value: trend.value, still: reduceMotion)
                    if let aside = trend.aside, asides.keeps(trend.metric) {
                        // WHETHER THIS WORD IS HERE AT ALL IS THE CANDIDATE LIST'S DECISION AND
                        // NOTHING ELSE'S, which is what a `layoutPriority(-1)` here used to claim
                        // to be a second line of defence against and could not be: `ViewThatFits`
                        // takes a candidate only if that candidate's ideal width already fits, so
                        // nothing here is ever asked to give room up - and the one candidate it
                        // falls back on when none fit is the one with no names in it. A name too
                        // long for its rung does not shrink, it takes the whole rung out of the
                        // running (codex review of 0cd4a09, where the priority was dead code with a
                        // note explaining a mechanism that could not run).
                        Text(verbatim: aside).foregroundStyle(.tertiary)
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
                        // THE SAME MOTION, WITH NO DIRECTION STATED. A ceiling only ever climbs
                        // while the window holds it and only ever falls when an old maximum ages
                        // out of it, so the two cases are not a rise and a fall about one reading.
                        .figureMotion(trend.peak ?? "", value: nil, still: reduceMotion)
                    }
                }
            }
            // AND WHAT NOBODY IS ANSWERING FOR IN THIS CHECKOUT, at the end of the same row, on the
            // last card of the project and on no other (`SessionLeftoversMark`, which carries why
            // the reading is a mark here and a whole line on the project's own card). INSIDE the
            // candidate rather than after it: `ViewThatFits` measures what is in the candidate, so a
            // fourth group laid out beyond the row would be a group the ladder never knew to make
            // room for, and the card would give up its width instead of a ceiling.
            leftoversMark
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

    /// ONE GROUP'S FIGURE, in its tier's colour when its reading is one worth somebody's eye
    /// (`FootprintAlertLevel.tint`) - and NEVER with the triangle the row above marks a warning
    /// with, whether or not this group has a shape beside it yet.
    ///
    /// THE MARK LEFT THIS ROW BECAUSE THE ROW HAS NO ROOM FOR IT, in two senses that were learned in
    /// that order. It is about nine points wide, so a warning arriving widened its group and pushed
    /// every figure after it along, on the one row this card had just pinned into fixed columns for
    /// exactly that reason; moved onto the shape beside the figure it stopped moving anything and
    /// covered nearly half the readings instead (`FootprintSparklineView.alert`). A row of eleven
    /// point figures is simply not a surface a second GRAPHIC channel fits on, so the second channel
    /// here is the amber's own luminance against the primary grey it replaces, and the condition is
    /// SAID in full to anybody who gets neither (`spokenTrends`). The triangle stays where there are
    /// words to put it next to: the row above, and every account card (Albert, 2026-08-16).
    ///
    /// A GROUP WITH NO LINE YET IS UNDER THE SAME RULE, which it briefly was not: a session in its
    /// first half-minute has a figure and no shape, and putting the mark back into the text for
    /// those thirty seconds bought a channel this row cannot read anyway at the price of the reflow
    /// the columns exist to prevent - and of a card that draws its warnings one way for half a
    /// minute and another way afterwards.
    static func figure(_ text: String, level: FootprintAlertLevel) -> Text {
        guard let tint = level.tint else { return Text(verbatim: text).foregroundStyle(.primary) }
        return Text(verbatim: text).foregroundStyle(tint)
    }

    /// THE SAME FIGURE IN THE FLAME'S OWN COLOUR, for the one reading the flame on this card's
    /// headline is about (`flamesTheFigure` decides which, and when).
    ///
    /// IT ASKS THE FLAME FOR THE COLOUR rather than naming an amber, which is the rule every other
    /// surface on this row already keeps about the alert tiers (`FootprintAlertLevel.tint`, asked
    /// by `figure` above): a mark and the figure it points at have to be one colour or the pointing
    /// is not visible, and two spellings of "amber" would let them drift. The one spelling is the
    /// glyph's (`SessionCardView.flameTint`).
    ///
    /// NO GLYPH HERE, WHICH IS THE ROW'S STANDING RULE AND NOT AN OMISSION. A second flame beside
    /// the figure would be the same mark twice on one card, and this row has no room for a mark at
    /// all: nine points of glyph on an eleven point figure covers the reading it is marking, which
    /// is exactly why the warning triangle left this row (`figure`).
    static func flamed(_ text: String) -> Text {
        Text(verbatim: text).foregroundStyle(SessionCardView.flameTint)
    }
}
