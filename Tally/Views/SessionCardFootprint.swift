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
// TWO ROWS, AND THE READINGS ARE ON THE SECOND ONE - which is now a file of its own for size
// (SessionCardTrendRow.swift), along this very seam. Each trended metric is drawn as one group -
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
                                    agentUnit: L(footprint.agents == 1 ? "agent" : "agents"),
                                    // ONE WORD FOR ONE AND FOR MANY, unlike the two above: this
                                    // field says WHERE those processes came from rather than what
                                    // they are, so English has no plural to make of it and a
                                    // translator is not handed two keys that would take one phrase.
                                    //
                                    // AND IT SAYS `background jobs` RATHER THAN `background`,
                                    // because the bare word meant two different things on one page:
                                    // here it is what THIS session left running (a job whose own
                                    // shell exited, matched back by the group it carries), and in
                                    // the rollup above the board it was work no session accounts
                                    // for at all. That rollup is now a card of its own and says
                                    // `unclaimed` (`SessionGhostCardView`); this one names the
                                    // things it is counting, and the two can no longer be read as
                                    // one reading (Albert, 2026-09-03).
                                    backgroundUnit: L("background jobs"))
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
