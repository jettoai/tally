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
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.tail)
                // A style a run sets for itself wins over the one the view sets around it, which is
                // what lets a warned field stand out of a line that is otherwise tertiary.
                .accessibilityLabel(Self.spoken(segments))
        }
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
