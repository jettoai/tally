import CoreGraphics

/// The Detailed panel's measures, free of SwiftUI so a test can print the numbers the views are
/// laid out by (tests/panelcontrast). `PanelStyle` re-exports them under its own names, so the value
/// asserted and printed there is the value drawn.
enum PanelMetrics {
    static let bodyPadH: CGFloat = 10
    static let bodyPadTop: CGFloat = 2
    static let bodyPadBottom: CGFloat = 10
    static let cardGap: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let ringSize: CGFloat = 58
    static let colHeadHeight: CGFloat = 18
    static let rowHeight: CGFloat = 31
    static let rowPadH: CGFloat = 12
    static let meterGap: CGFloat = 6
    static let barHeight: CGFloat = 5
    static let wallBarWidth: CGFloat = 3
    static let hairline: CGFloat = 0.5

    /// One meter cell: bar, figure, reset. 92pt for up to three windows; a fourth squeezes all of
    /// them so the identity column keeps room for a name.
    static func meterCellWidth(columns: Int) -> CGFloat { columns <= 3 ? 92 : 80 }

    /// The width of the whole meter block of one row.
    static func meterBlockWidth(columns: Int) -> CGFloat {
        guard columns > 0 else { return 0 }
        return CGFloat(columns) * meterCellWidth(columns: columns) + CGFloat(columns - 1) * meterGap
    }

    /// What is left of a row for the account's name, plan pill and marks: the panel less the body's
    /// padding, the row's padding, the meter block and the gap before it.
    static func identityColumnWidth(columns: Int) -> CGFloat {
        PanelGeometry.detailedPanelWidth - 2 * bodyPadH - 2 * rowPadH - meterBlockWidth(columns: columns) - meterGap
    }
}
