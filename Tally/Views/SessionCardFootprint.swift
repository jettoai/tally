import AppKit
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
// only peaks"). What is left on the first row is what has no shape: the fan-out and the writing.
// The ports left this pair of rows altogether and went up to the identity line, being the one
// reading here that is a fact about the machine rather than about the session
// (`SessionCardView.sessionIdentityRow`).
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

    /// What this session is holding open, as the identity line prints it, or nothing when it is
    /// holding nothing. How many of the ports say what is holding them is decided in the pure rule
    /// on a measured POINT budget rather than by the layout (`ProcessTree.portsText`, and
    /// `SessionCardView.sessionIdentityRow` for why it is not a choice between two candidates).
    ///
    /// THE RULE IS PURE AND THE RULER IS NOT, which is why the measuring is done from here. A
    /// budget in points needs somebody who can turn a spelling into points, and that is a font -
    /// which the rule's own file cannot see and the assertion harness has no target for. So the
    /// rule asks for a ruler and this hands it the real one, the same way it is handed the program
    /// a pid is running (`ProcessTree.held`).
    var sessionPortsText: String? {
        guard let footprint = ProcessFootprintStore.shared.footprints[row.id] else { return nil }
        return ProcessTree.portsText(footprint, width: Self.portsWidth)
    }

    /// The same ports with EVERY name said and every port listed, whatever the row had room to
    /// print (`SessionCardView.sessionIdentityRow` hands this to VoiceOver).
    ///
    /// A LISTENER HAS NO WIDTH TO RUN OUT OF, which is the rule the trend row one screen down
    /// already keeps about its own dropped words (`spokenTrends`). Both of the two budgets this
    /// spelling is subject to are about ROOM - how many points of names fit, and how many ports fit
    /// beside an identity before the rest become `+N` - so both are lifted here, and what is left is
    /// the whole fact: every port this session holds, each with whoever holds it.
    var sessionPortsSpoken: String? {
        guard let footprint = ProcessFootprintStore.shared.footprints[row.id] else { return nil }
        return ProcessTree.portsText(footprint, maxPorts: .max, budget: .infinity,
                                     width: Self.portsWidth)
    }

    /// How wide one spelling of the ports is, in the font the identity row draws them in.
    ///
    /// MEASURED IN THE FONT THAT IS ACTUALLY DRAWN, digits and all: the row asks for
    /// `.caption2.monospacedDigit()`, whose digits are a shade wider than the proportional ones, so
    /// a budget checked against the plain text style would be spending points these strings do not
    /// have (they are mostly digits). Held as a stored font rather than resolved per call - this is
    /// asked once per card per spelling on every tick of an open board.
    static func portsWidth(_ text: String) -> Double {
        NSAttributedString(string: text, attributes: [.font: portsFont]).size().width
    }

    private static let portsFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)

    /// The fields no shape is kept for, in the order the whole line is written in: how many agents
    /// are working and what is being written (`FootprintTrendMetric`). The three that DO have a
    /// shape are drawn with it, one row down, and the ports are a line further up.
    var sessionFootprintRest: [ProcessFootprintSegment] {
        sessionFootprintSegments.filter { FootprintTrendMetric($0.kind) == nil }
    }

    /// The first row, drawn from the pieces rather than from one string, because one field of it
    /// can be a warning and the rest of the line must not become one with it.
    ///
    /// QUIETER THAN THE ROW BELOW IT, which is new: these are the fields a card carries only when
    /// there is something to say (a fan-out, heavy writing), and the figures somebody opened this
    /// board to read are the ones under them.
    ///
    /// A WARNING IS NOT A COLOUR, WHEREVER THERE IS ROOM TO SAY SO IN SOMETHING ELSE. The amber says
    /// "look here" to most people and nothing at all to somebody who cannot separate it from the
    /// tertiary grey beside it, so on a row of WORDS - this one, an account card
    /// (`AccountCardView`) - the mark carries the meaning and the colour only makes it faster to
    /// find. The room is what the rule is contingent on: nine points of triangle beside a sentence
    /// is a sentence with a triangle in it, and the same nine points on the eleven-point shape one
    /// row down is a figure with its readings covered. So the trend row states the second channel
    /// differently rather than dropping it (`FootprintSparklineView.alert`, `figure`). VoiceOver
    /// gets neither channel anywhere, and is handed the condition in words on both rows.
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
                    return line + lead + Self.drawn(part.element.text, level: part.element.level)
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
        if !trends.isEmpty {
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
            .accessibilityLabel(Self.spokenTrends(trends))
        }
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
                        FootprintSparklineView(values: trend.values, level: trend.segment.level)
                    }
                    Self.column(trend.metric.widestFigure) {
                        Self.figure(trend.figure, level: trend.segment.level)
                    }
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

    /// One field as it is drawn, with a warning marked as well as coloured.
    static func drawn(_ text: String, level: FootprintAlertLevel) -> Text {
        guard let tint = level.tint else { return Text(verbatim: text) }
        return (Text(Image(systemName: "exclamationmark.triangle.fill")) + Text(verbatim: " ")
                    + Text(verbatim: text))
            .foregroundStyle(tint)
    }

    /// The same fields for a reader who cannot see them, with every warning said rather than drawn.
    /// Read as a list, because it is one: the separator between fields is a dot on screen and a
    /// pause in speech.
    static func spoken(_ segments: [ProcessFootprintSegment]) -> String {
        segments.map { segment in
            guard let warning = warning(about: segment.kind, level: segment.level) else {
                return segment.text
            }
            return "\(segment.text), \(warning)"
        }.joined(separator: ", ")
    }

    /// What a warning is about, in the words a person would use for it.
    ///
    /// THE TWO TIERS ARE TWO DIFFERENT SENTENCES, which is the whole of what the colour says to
    /// everybody else: the residue ones all name the IDLENESS, because that is why they are
    /// warnings at all (the same numbers on a working session are just work), and the
    /// machine-level ones name the MACHINE, because that is why they are said whether or not a turn
    /// is running (`FootprintAlarm`). A listener who was given one sentence for both would be told
    /// a working session is idle.
    ///
    /// The disk has no machine-level tier to name, because a write rate has no ceiling to be a
    /// share of and so no track that could light one (`FootprintAlertState`). That pair falls
    /// through to nothing rather than borrowing the idle sentence for a state it cannot be in.
    static func warning(about kind: ProcessFootprintSegment.Kind,
                        level: FootprintAlertLevel) -> String? {
        switch level {
        case .calm: nil
        case .saturation:
            switch kind {
            case .cpu: L("using most of this machine's CPU")
            case .memory: L("holding most of this machine's memory")
            default: nil
            }
        case .residue:
            switch kind {
            case .cpu: L("high CPU while nothing is running")
            case .disk: L("writing to disk while nothing is running")
            case .memory: L("holding a lot of memory while nothing is running")
            default: nil
            }
        }
    }
}
