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
let pickPlainRowHeight: CGFloat = 30

/// One row that also carries a second line (an account's three windows, or an aside taken off the
/// label). The difference is a line of `.caption` and the stack spacing above it.
let pickDetailRowHeight: CGFloat = 44

/// The gap between two rows of the same thing, and the padding the list draws around the whole run.
let pickRowSpacing: CGFloat = 2
let pickRowsPadding: CGFloat = 2

/// The gap between two rows that name DIFFERENT things: one model's depths and the next model's,
/// one account and the next. Even spacing made a model and its two depths read as three unrelated
/// rows, which is the opposite of what the list is trying to say.
let pickRowGroupSpacing: CGFloat = 10

/// The rule above the row that hands the axis back. Its own line because that row is not another
/// choice in the list, it is the way out of the list.
let pickRowDividerHeight: CGFloat = 1

/// Whether row `index` is the release row (`auto`, "automatic selection").
///
/// LAST IS THE TEST, because last is what the release row is: both builders append it after
/// everything else and say so, and both are pinned by assertions that would fail if either stopped
/// ("the release is the last row, where a list of escapes belongs" and "the release row is offered
/// last and is on nobody's account", tests/supervisor/pickerchecks). A list of one row has no
/// release row to separate from anything.
func pickRowIsRelease(index: Int, of rows: [PickRow]) -> Bool {
    rows.count > 1 && index == rows.count - 1
}

/// The space above one row, given what is drawn above it: nothing at the top of the list, a rule and
/// two group gaps above a way out, the tight gap inside one subject, and the group gap where the
/// list changes subject.
///
/// The one place this is decided, because the panel draws it and the height arithmetic has to agree
/// with what was drawn (`PickPalette` carries both).
///
/// `previous` is nil for the first row under a section heading: the heading is what separates it
/// from what came before, so the row itself only needs air.
func pickRowGap(above row: PickRow, after previous: PickRow?, ruled: Bool,
                atTop: Bool) -> CGFloat {
    if atTop { return 0 }
    if ruled { return pickRowGroupSpacing * 2 + pickRowDividerHeight }
    guard let previous else { return pickRowSpacing }
    return previous.value == row.value ? pickRowSpacing : pickRowGroupSpacing
}

/// The same rule, asked of a position in one list of rows.
func pickRowGap(before index: Int, rows: [PickRow]) -> CGFloat {
    guard index > 0, index < rows.count else { return 0 }
    return pickRowGap(above: rows[index], after: rows[index - 1],
                      ruled: pickRowIsRelease(index: index, of: rows), atTop: false)
}

/// What this panel is, for the identity line: the app's name is drawn beside it, so this only has to
/// name the axis. English, like every other string the CLI puts on this wire.
func pickPanelKindName(_ kind: PickKind) -> String {
    switch kind {
    case .model: return "Model"
    case .account: return "Account"
    }
}

/// What the panel writes ON a row, and what it writes UNDER it.
///
/// The wire carries one label per row because the elicitation form has one field and no second line
/// to put anything on: "fable · high" and "auto  (follow this project's profile, then the fleet
/// default)" are what a form can say. The panel has a chip for the depth and a caption line for the
/// aside, so saying it the form's way would say the depth twice and squeeze a sentence into a row.
///
/// SPLIT HERE RATHER THAN ON THE WIRE, which is the whole point: the two surfaces draw the same row
/// differently, so the difference belongs to the drawing. A second set of fields would have to be
/// filled in by every builder and kept in step with a panel it cannot see.
func pickPanelLabel(_ row: PickRow) -> String { pickRowText(row).label }

/// The second line: what the row already carries (an account's three windows), or the aside its
/// label was trailing.
func pickPanelDetail(_ row: PickRow) -> String? { pickRowText(row).detail }

/// Both halves at once, since neither can be decided without the other.
private func pickRowText(_ row: PickRow) -> (label: String, detail: String?) {
    var label = row.label
    // The depth, drawn once. The chip beside the name is the panel's way of saying it, so the
    // label's own copy comes off (`mcpModelPickRows` writes "opus · high", and the fixture the dev
    // preview draws writes the same).
    if let effort = row.effort, label.hasSuffix("\(pickEffortSeparator)\(effort)") {
        label.removeLast(pickEffortSeparator.count + effort.count)
    }
    if let detail = row.detail, !detail.isEmpty { return (label, detail) }
    // The aside, moved to its own line: "auto  (follow this project's profile, then the fleet
    // default)" is a row's worth of sentence, and it is written with two spaces before the bracket
    // by every builder that writes one (`pickAutoLabel`, `mcpModelOptions`).
    guard label.hasSuffix(")"), let opening = label.range(of: pickNoteSeparator, options: .backwards)
    else { return (label, nil) }
    let note = label[opening.upperBound ..< label.index(before: label.endIndex)]
    return (String(label[label.startIndex ..< opening.lowerBound]), String(note))
}

/// How a label spells the depth it already names, and how it opens a trailing aside. Here so the
/// panel takes apart exactly what the builders put together.
let pickEffortSeparator = " · "
let pickNoteSeparator = "  ("

/// What the list is given before anything has been laid out.
///
/// Arithmetic from the row shapes, with the two row heights taken from what this panel actually
/// renders at. Measured 2026-08-10 by raising the cap out of the way and reading the window: the
/// four-row account list lays out at 221 points and the ten-row model list at 371, which this
/// arithmetic reproduces to the point. (The first pass at these constants was fitted against a
/// GUESSED window chrome and was wrong in both of them by amounts that cancelled; the cap was moved
/// to 200 and then to 1000 to measure the chrome instead of assuming it.) A SEED, not an authority:
/// the moment the rows report their real height that is what the list uses, so an inaccuracy here
/// costs at most a slightly wrong first frame and never a wrong panel. What it buys is that the first frame is already the right size, and that a
/// measurement which never arrives still leaves a usable list rather than a sliver.
func pickPaletteSeedHeight(_ palette: PickPalette, cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    guard !palette.items.isEmpty else { return 0 }
    // Each item as the panel will draw it, gaps included: a row's second line is whatever
    // `pickPanelDetail` decides it is, a heading is drawn at exactly the height it reports, and the
    // space above each is the gap the palette already decided. Nothing here reads the rows a second
    // time, which is what keeps it from drifting away from the layout. The pinned row is not in
    // here, because it is not in the scrolling region either (`pickPaletteStickyHeight`).
    let stacked = palette.items.reduce(pickRowsPadding * 2) { total, item in
        total + item.gapAbove + item.height
    }
    return min(stacked, cap)
}

/// The same seed for one list of rows: the single-section shape a request without sections has.
func pickRowsSeedHeight(_ rows: [PickRow], cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    pickPaletteSeedHeight(pickPalette(rows: rows), cap: cap)
}

/// How tall one row is drawn: a line, or two when it has something under it.
func pickRowHeight(_ row: PickRow) -> CGFloat {
    pickPanelDetail(row) == nil ? pickPlainRowHeight : pickDetailRowHeight
}

/// The block pinned under the scrolling region: the rule that sets it apart, and the row itself.
/// Zero when there is nothing to pin, which is a list whose focus section has no way out of its own.
///
/// THE WAY OUT DOES NOT SCROLL AWAY, which is what this is for: a fleet or an effort table can be
/// taller than the cap, and the row that releases the pin is the one a person reaches for when the
/// list is not what they wanted. Below the scrolling region it is always on screen; inside it, it is
/// wherever the list happens to have been left. It stays a member of `PickPalette.choices`, so the
/// keyboard walks off the last scrolling row straight onto it with nothing to special case.
func pickPaletteStickyHeight(_ palette: PickPalette) -> CGFloat {
    guard let sticky = palette.sticky else { return 0 }
    return sticky.gapAbove + sticky.height
}

/// The same block for one list of rows.
func pickStickyHeight(_ rows: [PickRow]) -> CGFloat {
    pickPaletteStickyHeight(pickPalette(rows: rows))
}

/// The height the list is drawn at: what it measured, or the seed until that lands, capped either
/// way.
///
/// One authority at a time, which is the rule this whole family of bugs is about: the measurement
/// wins whenever there is one, and the seed is only ever the answer before the first layout pass has
/// happened. A measurement of zero is not a measurement (it is what a collapsed layout reports), so
/// it does not count as one.
func pickPaletteHeight(measured: CGFloat, palette: PickPalette,
                       cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    min(measured > 0 ? measured : pickPaletteSeedHeight(palette, cap: cap), cap)
}

/// The same reading for one list of rows.
func pickRowsHeight(measured: CGFloat, rows: [PickRow],
                    cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    pickPaletteHeight(measured: measured, palette: pickPalette(rows: rows), cap: cap)
}
