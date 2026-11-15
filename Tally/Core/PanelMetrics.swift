import CoreGraphics

/// The Detailed panel's measures, free of SwiftUI so a test can print the numbers the views are
/// laid out by (tests/panelcontrast). `PanelStyle` re-exports them under its own names, so the value
/// asserted and printed there is the value drawn.
enum PanelMetrics {
    static let bodyPadH: CGFloat = 12
    static let bodyPadTop: CGFloat = 0
    static let bodyPadBottom: CGFloat = 10
    static let cardGap: CGFloat = 8
    static let cardRadius: CGFloat = 18
    /// The pinned panel's own corner; the popover and the dashboard window keep the system's.
    static let panelRadius: CGFloat = 24
    /// A card's side padding, and how far a row's text sits inside the table (the row's own wash,
    /// the hot-row highlight, is drawn out to the card's padding).
    static let cardPadH: CGFloat = 14
    static let rowInsetH: CGFloat = 8
    static let rowRadius: CGFloat = 12
    static let ringSize: CGFloat = 60
    static let ringStroke: CGFloat = 6
    static let colHeadHeight: CGFloat = 18
    static let rowHeight: CGFloat = 32
    static let rowPadH: CGFloat = cardPadH + rowInsetH
    static let meterGap: CGFloat = 10
    static let barHeight: CGFloat = 5
    static let wallBarWidth: CGFloat = 3
    static let hairline: CGFloat = 1
    /// The round buttons of the header and the footer, and the header's height.
    static let chipSize: CGFloat = 28
    static let headerHeight: CGFloat = 40

    /// One meter cell: the figure and its reset over a full-width bar. A block of one or two windows
    /// gives each 136pt; three windows take 68pt, and a fourth squeezes all of them to 60pt so the
    /// identity column keeps room for a name.
    static func meterCellWidth(columns: Int) -> CGFloat {
        switch columns {
        case ...2: return 136
        case 3: return 68
        default: return 60
        }
    }

    /// What the identity column keeps so the commonest names read whole beside their plan pill, the
    /// launch slot and the marks ("Claude 5" with ULTRA and the stale triangle, "Codex 2" with PRO and the
    /// banked-reset count). Measured in tests/panelcontrast, which asserts this constant covers it (B-4609).
    static let identityWithName: CGFloat = 164

    /// The cell for a row `rowWidth` wide (the card less its side padding), shared by every card of
    /// the panel (the widest block's column count): the table's width, narrowed only as far as keeps
    /// those names whole when the block has two windows or fewer (three and four keep their own table
    /// widths, which already hold the pill and what a name leaves).
    static func meterCellWidth(columns: Int, rowWidth: CGFloat) -> CGFloat {
        let table = meterCellWidth(columns: columns)
        guard (1 ... 2).contains(columns) else { return table }
        let n = CGFloat(columns)
        let fit = ((rowWidth - 2 * rowInsetH - meterGap - identityWithName - (n - 1) * meterGap) / n).rounded(.down)
        return min(table, fit)
    }

    /// The width of the whole meter block of one row.
    static func meterBlockWidth(columns: Int) -> CGFloat {
        meterBlockWidth(columns: columns, cell: meterCellWidth(columns: columns))
    }

    static func meterBlockWidth(columns: Int, cell: CGFloat) -> CGFloat {
        guard columns > 0 else { return 0 }
        return CGFloat(columns) * cell + CGFloat(columns - 1) * meterGap
    }

    /// The launch slot at the end of an account's identity (smart-pick glyph cell with its 3pt lead,
    /// a 2pt gap, the pin circle's cell), reserved on every row of a card, and the least a name
    /// keeps before the plan pill is given up (`AccountListRowView.identity`).
    static let launchSlotWidth: CGFloat = 28
    static let nameFloor: CGFloat = 40

    /// What is left of a row for the account's name, plan pill and marks: the panel less the body's
    /// padding, the card's and the table's padding, the meter block and the gap before it.
    static func identityColumnWidth(columns: Int) -> CGFloat {
        identityColumnWidth(columns: columns, cell: meterCellWidth(columns: columns))
    }

    static func identityColumnWidth(columns: Int, cell: CGFloat) -> CGFloat {
        PanelGeometry.detailedPanelWidth - 2 * bodyPadH - 2 * cardPadH - 2 * rowInsetH
            - meterBlockWidth(columns: columns, cell: cell) - meterGap
    }
}
