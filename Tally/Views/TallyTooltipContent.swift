import SwiftUI

/// One line of a structured callout: a label on the left, its value on the right, and the severity
/// the value is tinted by (nil = no verdict, rendered in the callout's own quiet colour).
///
/// A row rather than a sentence because the values are numbers that want a column: three lines of
/// "Weekly pool 42% left" read as prose that has to be parsed one line at a time, where a column of
/// right-aligned figures is read at a glance. That is the whole reason this type exists.
struct TallyTooltipRow: Equatable {
    let label: String
    let value: String
    let severity: MetricSeverity?
    /// A label that loses its end rather than its middle when too wide (a process name reads from
    /// its start; an account or path keeps both ends).
    let tailTruncated: Bool
    let style: TallyTooltipRowStyle

    init(_ label: String, _ value: String, severity: MetricSeverity? = nil, tailTruncated: Bool = false,
         style: TallyTooltipRowStyle = .plain) {
        self.label = label
        self.value = value
        self.severity = severity
        self.tailTruncated = tailTruncated
        self.style = style
    }
}

/// How a block row reads, for a callout grouped under headings (the pool's by-project callout):
/// `strong` a heading with its figure, `detail` a quieter indented line under it with no figure,
/// `sub` an indented row of the heading above, `quiet` a closing figure such as Other, `note` a
/// closing sentence. A rule separates each heading, closing figure and note from what is above it.
enum TallyTooltipRowStyle: Equatable {
    case plain, strong, detail, sub, quiet, note
}

/// A titled group of rows: one subject per block, so a two-provider fleet reads as two small tables
/// rather than one list the reader has to re-sort in their head.
struct TallyTooltipBlock: Equatable {
    let title: String
    let rows: [TallyTooltipRow]
}

/// What a callout carries. Plain text stays the default and the common case (most call sites are
/// one short sentence); a second line is for the hovers that answer with a subject and something
/// qualifying it, and blocks are for the few that answer with figures.
enum TallyTooltipContent: Equatable {
    /// The first line is the subject, in the callout's primary ink; any after it are quieter. Empty
    /// lines are dropped by the modifier that builds this, so a missing qualifier never renders as
    /// a blank row under the subject.
    case lines([String])
    case blocks([TallyTooltipBlock])

    var isEmpty: Bool {
        switch self {
        case .lines(let lines): return lines.allSatisfy(\.isEmpty)
        case .blocks(let blocks): return blocks.allSatisfy { $0.rows.isEmpty && $0.title.isEmpty }
        }
    }

    /// The same content as one string, for the accessibility hint: VoiceOver reads what the pointer
    /// would have been shown, and there is one source for both so they cannot drift.
    var spoken: String {
        switch self {
        case .lines(let lines):
            return lines.filter { !$0.isEmpty }.joined(separator: ", ")
        case .blocks(let blocks):
            return blocks.map { block in
                ([block.title] + block.rows.map { "\($0.label) \($0.value)" })
                    .filter { !$0.isEmpty }.joined(separator: ", ")
            }.joined(separator: ". ")
        }
    }
}

/// Lays its content out at its own ideal width, held to `cap`, and measures the height at that width.
/// `frame(maxWidth:)` cannot do this under the chip's `fixedSize()`: the frame sizes itself from the
/// content's single-line ideal height and only narrows it when placing, so wrapped lines overflowed
/// the chip's background (B-1057, seen on screen).
struct TallyTooltipCappedWidth: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(content.sizeThatFits(.unspecified).width, cap, proposal.width ?? .infinity)
        return content.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
