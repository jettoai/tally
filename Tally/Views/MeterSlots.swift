import SwiftUI

/// Which of the block's meter columns a cluster stands in (`MeterColumns`). Unset means "the cluster's
/// own index", which is what a row laid out without a block does.
struct MeterColumn: LayoutValueKey {
    static let defaultValue: Int? = nil
}

/// A row's meter clusters on the block's shared columns (`PanelGeometry.meterColumnFrames`): every
/// window stands in the column of its kind, and a column the row has no window for stays empty. Its
/// own minimum is every column at the shortest track, so the row gives up identity before it gives
/// up meters; anything above that is the room the row has left. It never reports an unbounded
/// width: a nil or infinite proposal answers the minimum.
struct MeterSlots: Layout {
    var columns: Int
    var gap: CGFloat

    /// A cluster at its shortest: the figure (scaled to its 0.8 minimum) and the reset on one line,
    /// over a track of at least `barWidth`.
    static let minimumCluster: CGFloat = max(AccountListRowView.barWidth,
                                             AccountListRowView.valueWidth * 0.8 + AccountListRowView.resetWidth)

    /// The least `columns` clusters and the `gap`s between them take; a row's width floor.
    static func minimumWidth(columns: Int, gap: CGFloat) -> CGFloat {
        CGFloat(columns) * minimumCluster + gap * CGFloat(max(0, columns - 1))
    }

    private func columnCount(_ subviews: Subviews) -> Int {
        let placed = subviews.enumerated().map { ($1[MeterColumn.self] ?? $0) + 1 }.max() ?? 0
        return max(columns, placed)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = columnCount(subviews)
        let floor = Self.minimumWidth(columns: count, gap: gap)
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = max(proposed, floor)
        } else {
            width = floor
        }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let frames = PanelGeometry.meterColumnFrames(in: bounds.width, columns: columnCount(subviews),
                                                     gap: gap)
        for (index, subview) in subviews.enumerated() {
            let frame = frames[subview[MeterColumn.self] ?? index]
            subview.place(at: CGPoint(x: bounds.minX + frame.x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: frame.width, height: bounds.height))
        }
    }
}
