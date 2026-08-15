import SwiftUI

// WHAT THE SESSION IS DOING TO THE MACHINE, as the card draws it. Split from SessionCardView.swift
// on file size, along the seam the card itself already reads: everything above this line is what a
// session IS (its name, its account, what it has spent), and this is the one line that is a
// MEASUREMENT - taken by a store that samples only while the page is on screen, decided in a pure
// function next door (`ProcessTree.segments`), and drawn here because only a view has the bundle
// the plurals come out of and the colour a warning is marked in.
extension SessionCardView {

    /// The footprint line, or nothing at all when this session's tree cannot be read: the numbers
    /// come from a store that samples only while this page is on screen (`ProcessFootprintStore`),
    /// so "no entry" covers both the tick that has not happened yet and the supervisor that has
    /// ended, and neither of those is a card's business to explain.
    ///
    /// THE PLURALS ARE DECIDED HERE, where the bundle is, and the shape of the line is decided in a
    /// pure function the assertion harness can state without one (`ProcessTree.segments`).
    var sessionFootprintSegments: [ProcessFootprintSegment] {
        guard let footprint = ProcessFootprintStore.shared.footprints[row.id] else { return [] }
        return ProcessTree.segments(footprint,
                                    unit: L(footprint.processes == 1 ? "proc" : "procs"),
                                    agentUnit: L(footprint.agents == 1 ? "agent" : "agents"))
    }

    /// The footprint line, drawn from the pieces rather than from one string, because one field of
    /// it can be a warning and the rest of the line must not become one with it.
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
        let segments = sessionFootprintSegments
        if !segments.isEmpty {
            segments.enumerated()
                .reduce(Text(verbatim: "")) { line, part in
                    let lead = part.offset == 0 ? Text(verbatim: "")
                                                : Text(verbatim: pickEffortSeparator)
                    return line + lead + Self.drawn(part.element)
                }
                // THE CURRENT FIGURES ARE THE LOUDEST SMALL TEXT ON THE CARD, which is new and is
                // the point of the trend row under them: this line is the reading, and everything
                // that gives it context - the shape it arrived by, the peak it came off - is drawn
                // quieter beneath it. Left tertiary, the numbers would have been the faintest thing
                // on a card that exists to state them.
                .font(.caption2.monospacedDigit()).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
                // A style a run sets for itself wins over the one the view sets around it, which is
                // what lets the warned field carry the amber while the rest of the line does not.
                .accessibilityLabel(Self.spoken(segments))
        }
    }

    /// One metric's line on this card: what to draw, and the ceiling to print beside it.
    struct Trend: Identifiable {
        let metric: FootprintTrendMetric
        let values: [Double]
        let peak: String
        var id: FootprintTrendMetric { metric }
    }

    /// WHICH TRENDS THIS CARD HAS ANYTHING TO DRAW, each with the readings and the peak beside it.
    /// A metric that has not been sampled twice yet contributes nothing rather than a flat stub: the
    /// row simply grows into its three groups over the first half minute of a session's life.
    var sessionFootprintTrendGroups: [Trend] {
        guard let series = ProcessFootprintStore.shared.history[row.id] else { return [] }
        return FootprintTrendMetric.allCases.compactMap { metric in
            let values = series.values(of: metric)
            guard values.count >= FootprintSparkline.minimumReadings,
                  let peak = series.peak(of: metric), let text = metric.peakText(peak)
            else { return nil }
            return Trend(metric: metric, values: values, peak: text)
        }
    }

    /// The row under the figures: each trended metric's shape, and the highest reading in it.
    ///
    /// THE PEAK IS THE ONE NUMBER A SHAPE CANNOT STATE. A line drawn from zero says how the session
    /// got here and says nothing about the scale it did it on - the same rising curve is a session
    /// that reached 40% and one that reached 400% - so the ceiling is printed, and the line's
    /// quieter dot points at the moment it happened.
    ///
    /// IN THE ORDER THE FIGURES ABOVE ARE WRITTEN IN, which is what makes the two rows read as one
    /// block rather than as two lists (`ProcessTree.segments`). The warned-first rule up there can
    /// move a figure out from over its own line; that is deliberate and cheap, because each peak
    /// carries the unit of the thing it is about ("340%", "4.2 GB", "6") and is legible on its own.
    @ViewBuilder
    var sessionFootprintTrends: some View {
        let trends = sessionFootprintTrendGroups
        if !trends.isEmpty {
            HStack(spacing: Self.trendGap) {
                ForEach(trends) { trend in
                    HStack(spacing: 3) {
                        FootprintSparklineView(values: trend.values)
                        Text(verbatim: Self.peakMark + trend.peak)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spokenTrends(trends))
        }
    }

    /// Between one metric's group and the next: the gutter the board's own cards are laid out with,
    /// and wider than the 3pt inside a group, so the row reads as three things rather than as six.
    static let trendGap: CGFloat = PopoverRootView.sessionCardGap

    /// What marks a figure as the ceiling rather than the current reading. A glyph rather than the
    /// word, because "peak" three times costs about a third of the card's width and this row has to
    /// hold three of everything; the word itself is what VoiceOver is given instead.
    static let peakMark = "\u{2191}"

    /// The trend row in words, for a reader who gets no shape at all: each metric named, each peak
    /// said. One catalogue key per metric rather than a name substituted into a shared sentence, so
    /// every one of them is a phrase a translator sees whole (`FootprintTrendMetric.peakLabelKey`).
    static func spokenTrends(_ trends: [Trend]) -> String {
        trends.map { String(format: L($0.metric.peakLabelKey), $0.peak) }
            .joined(separator: ", ")
    }

    static func drawn(_ segment: ProcessFootprintSegment) -> Text {
        guard segment.alert else { return Text(verbatim: segment.text) }
        return (Text(Image(systemName: "exclamationmark.triangle.fill")) + Text(verbatim: " ")
                    + Text(verbatim: segment.text))
            .foregroundStyle(TallyColor.warning)
    }

    /// The same line for a reader who cannot see it, with every warning said rather than drawn.
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
