import CoreGraphics

/// The Detailed panel's measures, free of SwiftUI so a test can print the numbers the views are
/// laid out by (tests/panelcontrast). `PanelStyle` re-exports them under its own names, so the value
/// asserted and printed there is the value drawn.
enum PanelMetrics {
    static let bodyPadH: CGFloat = 12
    static let bodyPadTop: CGFloat = 0
    static let bodyPadBottom: CGFloat = 10
    static let cardGap: CGFloat = 10
    static let cardRadius: CGFloat = 18
    /// The pinned panel's own corner; the popover and the dashboard window keep the system's.
    static let panelRadius: CGFloat = 24
    /// A card's side padding, and how far a row's text sits inside the table (the row's own wash,
    /// the hot-row highlight, is drawn out to the card's padding).
    static let cardPadH: CGFloat = 14
    static let rowInsetH: CGFloat = 8
    static let rowRadius: CGFloat = 12
    static let ringSize: CGFloat = 80
    static let ringStroke: CGFloat = 8
    static let colHeadHeight: CGFloat = 22
    static let rowHeight: CGFloat = 40
    static let rowPadH: CGFloat = cardPadH + rowInsetH
    static let meterGap: CGFloat = 14
    static let barHeight: CGFloat = 5
    static let wallBarWidth: CGFloat = 3
    static let hairline: CGFloat = 1
    /// The round buttons of the header and the footer, and the header's height.
    static let chipSize: CGFloat = 28
    static let headerHeight: CGFloat = 44

    /// One meter cell: the figure and its reset over a full-width bar. 72pt for up to three windows;
    /// a fourth squeezes all of them so the identity column keeps room for a name.
    static func meterCellWidth(columns: Int) -> CGFloat { columns <= 3 ? 72 : 60 }

    /// The width of the whole meter block of one row.
    static func meterBlockWidth(columns: Int) -> CGFloat {
        guard columns > 0 else { return 0 }
        return CGFloat(columns) * meterCellWidth(columns: columns) + CGFloat(columns - 1) * meterGap
    }

    /// What is left of a row for the account's name, plan pill and marks: the panel less the body's
    /// padding, the card's and the table's padding, the meter block and the gap before it.
    static func identityColumnWidth(columns: Int) -> CGFloat {
        PanelGeometry.detailedPanelWidth - 2 * bodyPadH - 2 * cardPadH - 2 * rowInsetH
            - meterBlockWidth(columns: columns) - meterGap
    }
}
