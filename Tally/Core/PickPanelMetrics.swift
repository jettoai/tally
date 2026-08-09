import CoreGraphics

// HOW TALL THE PICK PANEL'S LIST IS, as arithmetic rather than as a question asked of the layout
// system, because asking turned out to have a zero answer.
//
// THE DEFECT THIS EXISTS FOR (2026-08-09, seen by the user on a real `/tally-model`): the panel came
// up 460x85 - the message, and then nothing. No rows at all, with the space above the text empty.
// The window is sized by its content (`PickPanelController` keeps `sizingOptions` the only size
// authority), and the content's ideal height was being asked of a `ScrollView`. A ScrollView HAS no
// ideal height along its scroll axis: it is happy at any height and answers an unspecified proposal
// with approximately nothing, so `.frame(maxHeight:)` clamped nothing to nothing and the window took
// the message alone. Measured three ways on the day, each 2 to 4 runs, all collapsing to 460x85: as
// shipped (a lazy stack), with the stack made eager, and with a `ViewThatFits` picking between the
// bare stack and the scrolling one. The laziness was never the cause, which is worth writing down
// because it is the obvious suspect: what collapses is any sizing path that has to ask a ScrollView
// how tall it wants to be.
//
// SO THE LIST IS TOLD ITS HEIGHT, and the number comes from the one place that can always answer:
// the rows. Measured when they have been laid out (`PickPanelView` reports the eager stack's real
// height), and computed from their shape until then. Neither can be zero for a request that has
// rows, and a request with no rows never reaches the panel (`PickPanelController.present` refuses
// it), so the collapsed state is not reachable rather than merely unlikely.

/// How tall the list may get before it scrolls instead of growing. The panel is a summoned dialog,
/// not a window: past this it is a wall of rows rather than a choice.
let pickRowsMaxHeight: CGFloat = 360

/// One row with a label only: the vertical padding it draws with, plus a line of `.body`.
let pickPlainRowHeight: CGFloat = 34

/// One row that also carries a second line (an account's three windows). The difference is a line of
/// `.caption` and the stack spacing above it.
let pickDetailRowHeight: CGFloat = 55

/// The gap between two rows, and the padding the list draws around the whole run.
let pickRowSpacing: CGFloat = 2
let pickRowsPadding: CGFloat = 2

/// What the list is given before anything has been laid out.
///
/// Arithmetic from the row shapes, with the two row heights taken from what this panel actually
/// renders at (measured 2026-08-09: a four-row account list came to 210 points and a ten-row model
/// list ran past the cap). A SEED, not an authority: the moment the rows report their real height
/// that is what the list uses, so an inaccuracy here costs at most a slightly wrong first frame and
/// never a wrong panel. What it buys is that the first frame is already the right size, and that a
/// measurement which never arrives still leaves a usable list rather than a sliver.
func pickRowsSeedHeight(_ rows: [PickRow], cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    guard !rows.isEmpty else { return 0 }
    let withDetail = rows.filter { !($0.detail ?? "").isEmpty }.count
    let plain = rows.count - withDetail
    let stacked = CGFloat(plain) * pickPlainRowHeight + CGFloat(withDetail) * pickDetailRowHeight
        + CGFloat(rows.count - 1) * pickRowSpacing + pickRowsPadding * 2
    return min(stacked, cap)
}

/// The height the list is drawn at: what it measured, or the seed until that lands, capped either
/// way.
///
/// One authority at a time, which is the rule this whole family of bugs is about: the measurement
/// wins whenever there is one, and the seed is only ever the answer before the first layout pass has
/// happened. A measurement of zero is not a measurement (it is what a collapsed layout reports), so
/// it does not count as one.
func pickRowsHeight(measured: CGFloat, rows: [PickRow],
                    cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    min(measured > 0 ? measured : pickRowsSeedHeight(rows, cap: cap), cap)
}
