import CoreGraphics

// The list row's meter columns: a block's columns come from the window kinds its rows report
// (`MeterColumns`), each window stands in the column of its kind, and the columns share the row's
// width equally (`PanelGeometry.meterColumnFrames`).
func checkMeterColumns() {
    print("list row meter columns")
    let gap: CGFloat = 8
    let three = PanelGeometry.meterColumnFrames(in: 272, columns: 3, gap: gap)
    let slot = (272 - 2 * gap) / 3
    check(three.count == 3 && three.allSatisfy { $0.width == slot }
          && three.map(\.x) == [0, slot + gap, 2 * (slot + gap)]
          && three[2].x + three[2].width == 272,
          "three columns are three equal tracks filling the width exactly")
    let one = PanelGeometry.meterColumnFrames(in: 272, columns: 1, gap: gap)
    check(one.count == 1 && one[0].x == 0 && one[0].width == 272, "one column is the whole width")
    check(PanelGeometry.meterColumnFrames(in: 272, columns: 0, gap: gap).isEmpty,
          "no columns lays out nothing")

    let withSession = MeterColumns.keys([.model, .session, .weekly])
    check(MeterColumns.block([withSession]) == withSession, "a row's own block is its own keys, in order")

    // Fable and the weekly window stand at one x with or without a 5-hour window.
    let without = MeterColumns.keys([.model, .weekly])
    let cols = MeterColumns.block([withSession, without])
    let f = PanelGeometry.meterColumnFrames(in: 272, columns: cols.count, gap: gap)
    func frame(_ key: MeterColumnKey) -> (x: CGFloat, width: CGFloat) { f[cols.firstIndex(of: key)!] }
    check(frame(withSession[0]).x == frame(without[0]).x, "the flagship window has one x with and without a 5-hour window")
    check(frame(withSession[2]).x == frame(without[1]).x && frame(withSession[2]).width == frame(without[1]).width,
          "the weekly window has one x and one length with and without a 5-hour window")
    check(!without.contains(.session) && cols == [.model(0), .session, .weekly],
          "a row with no 5-hour window leaves that column empty and does not widen the flagship")

    check(MeterColumns.block([withSession, [.weekly], [.model(0), .other(0), .weekly]]).last == .weekly,
          "the weekly window is always the rightmost column")
    check(MeterColumns.block([without, without]) == [.model(0), .weekly],
          "a block with no 5-hour window at all has two columns")
    let weeklyFirst = MeterColumns.keys([.weekly, .session])
    check(MeterColumns.block([withSession, weeklyFirst]) == [.model(0), .session, .weekly],
          "a row with no flagship window keeps its weekly window in the rightmost column, by kind not position")
    check(MeterColumns.keys([.model, .model, .session, .weekly]) == [.model(0), .model(1), .session, .weekly],
          "showAllModels: two model windows take two columns")
    let doubled = MeterColumns.keys([.session, .session, .weekly])
    check(doubled == [.session, .other(0), .weekly] && MeterColumns.block([doubled]).count == 3,
          "two windows of one single-slot kind never share a column")
    check(MeterColumns.block([]).isEmpty, "an empty block has no columns")
}
