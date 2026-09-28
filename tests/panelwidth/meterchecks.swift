import CoreGraphics

// The list row's meter columns (`PanelGeometry.meterClusterWidths`): every row of a block lays its
// windows on the block's columns, and a row with fewer windows lets its leading one span the rest.
func checkMeterColumns() {
    print("list row meter columns")
    let gap: CGFloat = 8
    let three = PanelGeometry.meterClusterWidths(in: 272, count: 3, slots: 3, gap: gap)
    check(three.count == 3 && Set(three).count == 1 && three.reduce(0, +) + 2 * gap == 272,
          "three windows on three columns are three equal tracks filling the width exactly")
    check(PanelGeometry.meterClusterWidths(in: 272, count: 1, slots: 3, gap: gap) == [272],
          "a one-window row lays one cluster across all three columns")
    let two = PanelGeometry.meterClusterWidths(in: 272, count: 2, slots: 3, gap: gap)
    let slot = (272 - 2 * gap) / 3
    check(two == [2 * slot + gap, slot],
          "a two-window row: the leading cluster spans the missing column, the second keeps the last")
    check(PanelGeometry.meterClusterWidths(in: 272, count: 0, slots: 3, gap: gap).isEmpty,
          "nothing to lay out lays out nothing")
    check(PanelGeometry.meterClusterWidths(in: 272, count: 3, slots: 0, gap: gap) == three,
          "an unset slot count is the row's own count")
}
