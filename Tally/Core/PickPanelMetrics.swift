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

/// How tall one row is drawn: a line, or two when it has something under it.
func pickRowHeight(_ row: PickRow) -> CGFloat {
    pickPanelDetail(row) == nil ? pickPlainRowHeight : pickDetailRowHeight
}

/// WHAT ONE COLUMN'S SCROLLING REGION IS GIVEN before anything has been laid out.
///
/// Arithmetic from the row shapes, with the two row heights taken from what this panel actually
/// renders at. Measured 2026-08-10 by raising the cap out of the way and reading the window: the
/// four-row account list lays out at 221 points and the ten-row model list at 371, which this
/// arithmetic reproduces to the point. (The first pass at these constants was fitted against a
/// GUESSED window chrome and was wrong in both of them by amounts that cancelled; the cap was moved
/// to 200 and then to 1000 to measure the chrome instead of assuming it.) A SEED, not an authority:
/// the moment the rows report their real height that is what the list uses, so an inaccuracy here
/// costs at most a slightly wrong first frame and never a wrong panel. What it buys is that the
/// first frame is already the right size, and that a measurement which never arrives still leaves a
/// usable list rather than a sliver.
func pickColumnSeedHeight(_ column: PickColumn, cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    // A column its own filter emptied still draws one line saying so, and that line is measured
    // like any other (`pickNoMatchesText`): an empty region and a broken one look the same.
    guard !column.items.isEmpty else {
        return column.isEmptyOfMatches ? pickRowsPadding * 2 + pickPlainRowHeight : 0
    }
    // Each row as the panel will draw it, gaps included: the second line is whatever
    // `pickPanelDetail` decides it is, and the space above each row is the gap the column already
    // decided. Nothing here reads the rows a second time, which is what keeps it from drifting away
    // from the layout. The pinned row is not in here, because it is not in the scrolling region
    // either (`pickColumnStickyHeight`).
    let stacked = column.items.reduce(pickRowsPadding * 2) { total, item in
        total + item.gapAbove + item.height
    }
    return min(stacked, cap)
}

/// The same seed for one list of rows: the single-column shape a request without sections has.
func pickRowsSeedHeight(_ rows: [PickRow], cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    pickColumnSeedHeight(pickColumn(rows: rows), cap: cap)
}

/// The block pinned under one column's scrolling region: the rule that sets it apart, and the row
/// itself. Zero when that column has no way out of its own.
///
/// THE WAY OUT DOES NOT SCROLL AWAY, which is what this is for: a fleet or an effort table can be
/// taller than the cap, and the row that releases the pin is the one a person reaches for when the
/// list is not what they wanted. Below the scrolling region it is always on screen; inside it, it is
/// wherever the list happens to have been left. It stays the last member of `PickColumn.rows`, so
/// the keyboard walks off the last scrolling row straight onto it with nothing to special case.
func pickColumnStickyHeight(_ column: PickColumn) -> CGFloat {
    guard let sticky = column.sticky else { return 0 }
    return sticky.gapAbove + sticky.height
}

/// The same block for one list of rows.
func pickStickyHeight(_ rows: [PickRow]) -> CGFloat {
    pickColumnStickyHeight(pickColumn(rows: rows))
}

/// THE HEIGHT BOTH SCROLLING REGIONS ARE DRAWN AT: the taller of them, capped.
///
/// ONE HEIGHT FOR BOTH COLUMNS, so the two ways out line up along the foot of the panel instead of
/// hanging at two different heights, and so a filter emptying one column does not make the panel
/// jump. The shorter column simply has room under its rows.
///
/// One authority at a time, which is the rule this whole family of bugs is about: a column's
/// MEASURED height wins whenever there is one, and the seed is only ever the answer before the
/// first layout pass has happened. A measurement of zero is not a measurement (it is what a
/// collapsed layout reports), so it does not count as one.
func pickPaletteListHeight(_ palette: PickPalette, measured: [PickKind: CGFloat] = [:],
                           cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    let tallest = palette.columns.map { column -> CGFloat in
        let seen = measured[column.kind] ?? 0
        return seen > 0 ? seen : pickColumnSeedHeight(column, cap: cap)
    }.max() ?? 0
    return min(tallest, cap)
}

/// THE HEIGHT THE PANEL KEEPS FOR AS LONG AS IT IS UP, which is the height of the UNFILTERED lists.
///
/// THE DEFECT THIS EXISTS FOR (codex review, 2026-08-10): the shared height was read off the columns
/// AS FILTERED, so every keystroke that narrowed the longer column shortened the panel, and a person
/// typing four letters watched the window jump under their hands four times. A summoned dialog that
/// resizes while it is being typed into is also a moving target for the pointer that is about to
/// click a row in it.
///
/// So the filter narrows what is IN the lists and never how tall they are. A column the query
/// emptied keeps its space and says "No matches" inside it, which is the honest shape anyway: the
/// rows are hidden, not gone.
///
/// `filters` is taken and deliberately not read. The call site has them and a reader will reach for
/// them, so they are named here and refused here, in the one place that can say why - rather than
/// left as an argument nobody passed and a rule nobody can see.
func pickPanelListHeight(_ request: PickRequest, filters: [PickKind: String] = [:],
                         measured: [PickKind: CGFloat] = [:],
                         cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    _ = filters
    return pickPaletteListHeight(pickPalette(request), measured: measured, cap: cap)
}

/// What one column comes to all told: its field (which carries its name), the rows, and the way out.
///
/// NO HEADING LINE ANY MORE, and the sum lost exactly that: the column's name is a scope prefix
/// inside its own search box now (`PickPanelView.searchField`), which took a line off the top of
/// both columns.
func pickColumnHeight(_ column: PickColumn, listHeight: CGFloat) -> CGFloat {
    pickSearchBlockHeight + listHeight + pickColumnStickyHeight(column)
}

/// What the columns come to, which is the tallest of them. The panel adds its own chrome around
/// this (the wordmark line and the sentence under it), which AppKit measures rather than this file.
func pickPaletteColumnsHeight(_ palette: PickPalette, measured: [PickKind: CGFloat] = [:],
                              cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    let list = pickPaletteListHeight(palette, measured: measured, cap: cap)
    return palette.columns.map { pickColumnHeight($0, listHeight: list) }.max() ?? 0
}

/// THE BAR UNDER THE COLUMNS: what one press would do, and the button that does it.
///
/// ITS SPACE IS KEPT WHETHER OR NOT IT HAS ANYTHING IN IT, which is the same rule the shared list
/// height is under (`pickPanelListHeight`) and it is the same defect being refused: a panel that
/// grows the moment a row is circled moves every row under the pointer that just circled it, and the
/// next click lands on a row the person did not aim at. So the height is constant for as long as the
/// panel is up and only the CONTENT appears.
let pickApplyBarHeight: CGFloat = 26
/// The air between the columns and that bar.
let pickApplyBarGap: CGFloat = 10
let pickApplyBlockHeight = pickApplyBarGap + pickApplyBarHeight

/// The columns and the bar kept under them: everything between the sentence at the top of the panel
/// and its bottom margin.
func pickPaletteBodyHeight(_ palette: PickPalette, measured: [PickKind: CGFloat] = [:],
                           cap: CGFloat = pickRowsMaxHeight) -> CGFloat {
    pickPaletteColumnsHeight(palette, measured: measured, cap: cap) + pickApplyBlockHeight
}

// MARK: - How wide

/// How wide one column's rows are drawn.
///
/// TWO WIDTHS, BECAUSE THE TWO ROWS ARE NOT THE SAME SHAPE: an account row carries three windows on
/// its second line and a tag beside its name, while a model row carries a word and a chip. Measured
/// against the panel as it was drawn at 460 points wide: the account detail line reaches about 195
/// points and its tag about 90, and the model release row's sentence about 235.
///
/// A LONE COLUMN KEEPS THE WIDTH THIS PANEL HAS ALWAYS HAD, which is the older request shape
/// (`PickRequest.sections`): degrading to one list must not also narrow it.
func pickColumnWidth(_ kind: PickKind, alone: Bool = false) -> CGFloat {
    guard !alone else { return pickLoneColumnWidth }
    switch kind {
    // Measured against a real fleet (2026-08-10): five accounts at 100% put "fable 100% · session
    // 100% · weekly 100%" beside a "most headroom" tag, which wrapped at 340 - and a wrapped detail
    // line is not merely untidy, it is a row two lines tall where the arithmetic says one
    // (`pickDetailRowHeight`). The row holds itself to one line as well, so a longer label truncates
    // rather than breaking the height contract.
    //
    // WIDENED TWICE SINCE, and both times for something the row gained rather than for taste: the
    // circle at the head of every row (`pickRowMarkWidth`, plus its gap), and the reset countdowns
    // on the windows line, which take "fable 100% · session 100% · weekly 100%" to "fable 100% ·
    // session 100% (4h59m) · weekly 100% (6d23h)" - about 100 points more of a line that must not
    // wrap and must not truncate, since the countdown is at the END of it.
    case .account: return 400
    case .model: return 322
    }
}

/// The row width a single-column panel draws at: the 460 points this surface has always been, less
/// its content line either side.
let pickLoneColumnWidth: CGFloat = 460 - 2 * PanelGeometry.contentPadding

/// The gap between the two columns. Wider than the gap between two groups of rows, because it
/// separates two questions rather than two answers to one.
let pickColumnGap: CGFloat = 12

/// How wide the panel is: its content line either side, the columns, and the gaps between them.
func pickPanelWidth(_ palette: PickPalette) -> CGFloat {
    let widths = palette.columns.map { pickColumnWidth($0.kind, alone: palette.isSingleColumn) }
    guard !widths.isEmpty else { return 2 * PanelGeometry.contentPadding + pickLoneColumnWidth }
    return 2 * PanelGeometry.contentPadding + widths.reduce(0, +)
        + pickColumnGap * CGFloat(widths.count - 1)
}

/// The slot at the head of every row that carries its circle (`PickRowView.mark`). Always there
/// rather than only under the circled row: a glyph that appears when a row is circled would shift
/// every name in the column sideways at the moment somebody circles one.
let pickRowMarkWidth: CGFloat = 14

/// The column's own search field, and the air under it. Same rule: drawn at exactly this height.
let pickSearchFieldHeight: CGFloat = 26
let pickSearchFieldGap: CGFloat = 6
let pickSearchBlockHeight = pickSearchFieldHeight + pickSearchFieldGap
