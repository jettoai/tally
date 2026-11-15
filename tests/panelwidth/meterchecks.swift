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
    // The Detailed panel's reading order (B-4169, B-4059): 5-hour, the rest, the model windows with
    // the flagship first, then the weekly window last; the columns are the ones `block` names.
    check(MeterColumns.displayBlock([withSession]) == [.session, .model(0), .weekly],
          "display order: 5-hour, the flagship model, then weekly")
    check(MeterColumns.displayBlock([without]) == [.model(0), .weekly],
          "without a 5-hour window the flagship model sits left of weekly, no blank slot for the 5-hour")
    check(MeterColumns.displayBlock([MeterColumns.keys([.model, .model, .other, .session, .weekly])])
              == [.session, .other(0), .model(0), .model(1), .weekly],
          "display order puts other windows before the model windows, flagship first, weekly last")
    check(MeterColumns.displayBlock([withSession, [.weekly], [.model(0), .other(0), .weekly]]).last == .weekly,
          "the weekly column is the rightmost whatever else the block holds")
    check(Set(MeterColumns.displayBlock([withSession, weeklyFirst])) == Set(MeterColumns.block([withSession, weeklyFirst])),
          "display order is a permutation of the block, never a different set of columns")
    check(MeterColumns.displayBlock([]).isEmpty, "an empty display block has no columns")
}

// B-4609 (design A): on the 555pt panel of the reference capture every card's weekly column stands at
// one x with one right edge, and two windows take 136pt each. Positions go through meterColumnFrames,
// the function MeterSlots places with, so this is the arithmetic the row is drawn by.
func meterXs(_ keys: [MeterColumnKey], panel: CGFloat, sharedColumns: Int) -> [MeterColumnKey: (x: CGFloat, width: CGFloat)] {
    let rowWidth = panel - 2 * PanelMetrics.bodyPadH - 2 * PanelMetrics.cardPadH
    let cell = PanelMetrics.meterCellWidth(columns: sharedColumns, rowWidth: rowWidth)
    let block = PanelMetrics.meterBlockWidth(columns: keys.count, cell: cell)
    let start = panel - PanelMetrics.bodyPadH - PanelMetrics.rowPadH - block
    let frames = PanelGeometry.meterColumnFrames(in: block, columns: keys.count, gap: PanelMetrics.meterGap)
    return Dictionary(uniqueKeysWithValues: zip(keys, frames.map { (start + $0.x, $0.width) }))
}

func checkWeeklyRight() {
    print("weekly column at the right (B-4609)")
    let claude = MeterColumns.displayBlock([MeterColumns.keys([.model, .weekly])])
    let codex = MeterColumns.displayBlock([[.weekly]])
    let shared = max(claude.count, codex.count)
    let c555 = meterXs(claude, panel: 555, sharedColumns: shared), x555 = meterXs(codex, panel: 555, sharedColumns: shared)
    check(c555[.weekly]?.x == 385 && x555[.weekly]?.x == 385, "both cards' weekly column at x 385 on a 555pt panel")
    check(c555[.weekly].map { $0.x + $0.width } == 521 && x555[.weekly].map { $0.x + $0.width } == 521, "...ending at 521")
    check(c555[.weekly]?.width == 136 && c555[.model(0)]?.width == 136, "two windows take 136pt each")
    check(c555[.model(0)]?.x == 239, "the flagship stands left of weekly at x 239")
    // 303 is the old weekly-first block start on 555pt (two 104pt cells and the gap, ending at 521).
    check(303 - (c555[.model(0)]?.x ?? 0) == 64, "the block moved 64pt toward the name (old block start 303)")
    // The narrowest panel narrows the cell so the plan pill stays; both cards still share one weekly x.
    let c452 = meterXs(claude, panel: 452, sharedColumns: shared), x452 = meterXs(codex, panel: 452, sharedColumns: shared)
    check(c452[.weekly]?.x == x452[.weekly]?.x && c452[.weekly]?.width == 115,
          "on 452pt the cells narrow to 115 and weekly still shares one x")
    // A 5-hour window on one card makes every card use the three-window cell, so weekly stays aligned.
    let claude3 = MeterColumns.displayBlock([MeterColumns.keys([.model, .session, .weekly])])
    let s3 = max(claude3.count, codex.count)
    let a = meterXs(claude3, panel: 555, sharedColumns: s3), b = meterXs(codex, panel: 555, sharedColumns: s3)
    check(a[.weekly]?.x == b[.weekly]?.x && a[.weekly]?.width == 68, "a third window on one card leaves weekly at one x on both")
}
