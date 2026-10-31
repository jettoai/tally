import SwiftUI

/// A row's meter clusters on the block's shared columns (`PanelGeometry.meterClusterWidths`). Its
/// own minimum is the old fixed width, every window at the shortest track, so the row gives up
/// identity before it gives up meters; anything above that is the room the row has left. It never
/// reports an unbounded width: a nil or infinite proposal answers the minimum.
struct MeterSlots: Layout {
    var slots: Int
    var gap: CGFloat

    /// A cluster at its shortest: minimum track, the 4pt inside the cluster, the figure column.
    static let minimumCluster: CGFloat = AccountListRowView.barWidth + 4 + AccountListRowView.valueWidth

    private func minimumWidth(_ count: Int) -> CGFloat {
        let columns = max(slots, count)
        return CGFloat(columns) * Self.minimumCluster + gap * CGFloat(max(0, columns - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let floor = minimumWidth(subviews.count)
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
        let widths = PanelGeometry.meterClusterWidths(in: bounds.width, count: subviews.count,
                                                      slots: slots, gap: gap)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gap
        }
    }
}
