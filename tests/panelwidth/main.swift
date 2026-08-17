import CoreGraphics
import Foundation

// Asserts the usage panel's width arithmetic (Tally/Core/PanelGeometry.swift): the widths each
// column count produces, the card those widths are built to hold, and the one rule the whole file
// exists for - the panel never asks for more width than the display it opens on can give.

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

func check(_ actual: CGFloat, _ expected: CGFloat, _ label: String, tolerance: CGFloat = 0.001) {
    check(abs(actual - expected) <= tolerance, "\(label) (got \(actual), want \(expected))")
}

/// The comfortable list row, copied from `AccountListRowView` - the view lives in the app target
/// and this harness compiles the geometry alone (same shape as tests/windowanchor).
let listRowWidth: CGFloat = 480

/// `ScreenFitStack.maxWidth(on:)`, the reading the panel is bounded by: the display's usable width
/// less the margin the surface keeps off the edges, and never below one comfortable column.
func usableWidth(display: CGFloat) -> CGFloat { max(480, display - 64) }

print("panel widths, card density")
check(PanelGeometry.cardPanelWidth(columns: 1), 380, "one column is a reading width")
check(PanelGeometry.cardPanelWidth(columns: 2), 560, "two columns")
check(PanelGeometry.cardPanelWidth(columns: 3), 834, "three columns")
check(PanelGeometry.cardPanelWidth(columns: 4), 1108, "four columns")
check(PanelGeometry.cardPanelWidth(columns: 0), 380, "a nonsense count falls to one column")

print("panel widths, list density")
check(PanelGeometry.listPanelWidth(columns: 1, rowWidth: listRowWidth), 504, "one row column")
check(PanelGeometry.listPanelWidth(columns: 2, rowWidth: listRowWidth), 994, "two row columns")
check(PanelGeometry.listPanelWidth(columns: 3, rowWidth: listRowWidth), 1484, "three row columns")

print("a card stays the same size as columns are added")
for columns in 2 ... 4 {
    let width = PanelGeometry.cardWidth(inGridOf: PanelGeometry.cardPanelWidth(columns: columns),
                                        columns: columns)
    check(abs(width - PanelGeometry.cardColumnWidth) <= 0.5,
          "\(columns) columns seat a \(PanelGeometry.cardColumnWidth)pt card (got \(width))")
}

print("seats per display")
// The reported bug's machine: a 2048pt display seats every count either density offers, so nothing
// about that panel may change (four columns of cards stayed 1108pt wide).
check(PanelGeometry.seats(columnWidth: PanelGeometry.cardColumnWidth,
                          in: usableWidth(display: 2048)) >= 4, "2048pt display seats four cards")
check(PanelGeometry.seats(columnWidth: listRowWidth, in: usableWidth(display: 2048)) >= 3,
      "2048pt display seats three list columns")
check(PanelGeometry.seated(4, columnWidth: PanelGeometry.cardColumnWidth,
                           in: usableWidth(display: 2048)) == 4,
      "a chosen four columns survives on 2048pt")
check(PanelGeometry.cardPanelWidth(
        columns: PanelGeometry.seated(4, columnWidth: PanelGeometry.cardColumnWidth,
                                      in: usableWidth(display: 2048))) == 1108,
      "and the panel is still 1108pt")

// A laptop display cannot seat three 480pt rows (1484pt of panel), so the chosen count gives.
check(PanelGeometry.seated(3, columnWidth: listRowWidth, in: usableWidth(display: 1280)) == 2,
      "1280pt display bounds a chosen three list columns to two")
check(PanelGeometry.seated(1, columnWidth: listRowWidth, in: usableWidth(display: 1280)) == 1,
      "and leaves a chosen one alone")

print("a count is never zero, however narrow the display")
for display in [320, 480, 640, 800] as [CGFloat] {
    check(PanelGeometry.seats(columnWidth: listRowWidth, in: usableWidth(display: display)) >= 1,
          "\(Int(display))pt display still seats one list column")
    check(PanelGeometry.seated(4, columnWidth: PanelGeometry.cardColumnWidth,
                               in: usableWidth(display: display)) >= 1,
          "\(Int(display))pt display still seats one card column")
}

print("a grid inside the panel lays out the count the picker shows")
// THE DEFECT: the session board laid its cards out adaptively while the panel's width came from the
// usage page's column count, so a picker reading "1" in the list density opened a 504pt panel and
// the board quietly seated two 210pt cards in it (Albert, 2026-08-15). The numbers below are that
// panel and that card, with the board's own 8pt gutter and 12pt of content padding each side.
let sessionCard: CGFloat = 210
let sessionGap: CGFloat = 8
// BOTH ARE COPIES, AND A COPY IS A NUMBER FREE TO DRIFT. The board's views live in the app target
// and this harness compiles the geometry alone, so the two constants are pinned to the lines they
// were copied from instead - the same static read the other suites use for what they cannot
// construct (tests/supervisor/footprinttrendchecks.swift). Either side changed alone, and this
// fails rather than going on asserting arithmetic about a card that is no longer that wide.
let boardSource = (try? String(contentsOfFile: "Tally/Views/SessionBoardView.swift",
                               encoding: .utf8)) ?? ""
let reorderSource = (try? String(contentsOfFile: "Tally/Views/SessionBoardReorder.swift",
                                 encoding: .utf8)) ?? ""
check(!boardSource.isEmpty && !reorderSource.isEmpty,
      "the board's own sources are readable from this suite")
check(boardSource.contains("static let compactCardWidth: CGFloat = \(Int(sessionCard))"),
      "the card width here is the one the board lays its cards out at")
check(reorderSource.contains("static let sessionCardGap: CGFloat = \(Int(sessionGap))"),
      "…and the gutter here is the one the grid is spaced with")
func sessionGrid(width: CGFloat) -> CGFloat { width - 2 * PanelGeometry.contentPadding }
/// What one session card comes out at: the grid's width, less the gutters, split between the cards.
func sessionCardWidth(panel: CGFloat, columns: Int) -> CGFloat {
    (sessionGrid(width: panel) - sessionGap * CGFloat(columns - 1)) / CGFloat(columns)
}
func sessionColumns(_ chosen: Int?, panel: CGFloat) -> Int? {
    PanelGeometry.gridColumns(chosen: chosen, in: sessionGrid(width: panel),
                              minimum: sessionCard, gap: sessionGap)
}
check(sessionColumns(1, panel: PanelGeometry.listPanelWidth(columns: 1, rowWidth: listRowWidth))
      == 1, "the reported case: one comfortable row wide, one session card across")
check(sessionColumns(2, panel: PanelGeometry.listPanelWidth(columns: 2, rowWidth: listRowWidth))
      == 2, "two list columns, two session cards")
check(sessionColumns(1, panel: PanelGeometry.cardPanelWidth(columns: 1)) == 1,
      "one card column, one session card")
check(sessionColumns(2, panel: PanelGeometry.cardPanelWidth(columns: 2)) == 2,
      "two card columns, two session cards")
check(sessionColumns(4, panel: PanelGeometry.cardPanelWidth(columns: 4)) == 4,
      "four card columns, four session cards")
// Auto is the mode that hands the layout to the system, so it resolves to no count at all and the
// caller keeps its adaptive grid.
check(sessionColumns(nil, panel: PanelGeometry.cardPanelWidth(columns: 2)) == nil,
      "auto asks for no count")
check(sessionColumns(0, panel: PanelGeometry.cardPanelWidth(columns: 2)) == nil,
      "and so does a count that is not one")
// A COUNT THE WIDTH CANNOT SEAT STEPS DOWN rather than pushing the surface out: a page under auto
// is living in the width another page decided, and a page with a width of its own has already had
// that width bounded by the display before the grid inside it is laid out.
check(sessionColumns(4, panel: PanelGeometry.cardPanelWidth(columns: 1)) == 1,
      "four columns asked for in a one-column panel steps down to one")
check(sessionColumns(3, panel: PanelGeometry.cardPanelWidth(columns: 2)) == 2,
      "three in a two-column panel steps down to two")
// Every count either density offers, in every panel width either density produces: a card is never
// laid out narrower than the width the whole board's arithmetic is built on.
for panel in [PanelGeometry.cardPanelWidth(columns: 1), PanelGeometry.cardPanelWidth(columns: 2),
              PanelGeometry.cardPanelWidth(columns: 3), PanelGeometry.cardPanelWidth(columns: 4),
              PanelGeometry.listPanelWidth(columns: 1, rowWidth: listRowWidth),
              PanelGeometry.listPanelWidth(columns: 2, rowWidth: listRowWidth),
              PanelGeometry.listPanelWidth(columns: 3, rowWidth: listRowWidth)] {
    for chosen in 1 ... 4 {
        let columns = sessionColumns(chosen, panel: panel) ?? 1
        let card = sessionCardWidth(panel: panel, columns: columns)
        check(columns <= chosen && card >= sessionCard,
              "\(Int(panel))pt panel, \(chosen) asked -> \(columns) cards of \(card)pt")
    }
}

print("the sessions page keeps its own count, and spends it on the cards")
// THE SECOND TIME THIS FACE WAS QUESTIONED (Albert, 2026-08-17): the board obeyed the picker after
// the fix above, but the picker it obeyed was the account pages' - so a board read one card at a
// time could not be expressed while the accounts were in two columns. The page has a count of its
// own now, and it buys the width the CARDS are laid out at.
//
// AND THE THIRD TIME, the same evening: the first answer to it made the panel take the width the
// page in front asked for, so every tab switch resized the surface by 180pt and the header switch -
// centred in that width - moved the very tab that had just been clicked. The invariant is back and
// asserted below: this surface is one width, whichever page is up.
let storeSource = (try? String(contentsOfFile: "Tally/Stores/SettingsStore.swift",
                               encoding: .utf8)) ?? ""
let rootSource = (try? String(contentsOfFile: "Tally/Views/PopoverRootView.swift",
                              encoding: .utf8)) ?? ""
// The highest count on offer is the app target's to state and this harness compiles the geometry
// alone, so the number below is pinned to the line it was copied from (the same static read the
// board's card width uses above).
let maxSessionsColumns = 2
check(storeSource.contains("static let maxSessionsColumns = \(maxSessionsColumns)"),
      "the highest sessions count here is the one the store offers")
// ONE SETTING READ BY BOTH SIDES, which is the whole of what keeps the count and the width honest:
// the width asks `sessionsColumnChoice`, and so does the grid that lays the cards out in it.
check(storeSource.contains("var sessionsColumns: Int"),
      "the board's count is its own stored setting")
check(reorderSource.contains("(1 ... SettingsStore.maxSessionsColumns).contains(settings.sessionsColumns)"),
      "…and the choice itself is read from that setting")
check(reorderSource.contains("PanelGeometry.gridColumns(chosen: sessionsColumnChoice"),
      "…which is the same choice the grid lays out")

print("switching tabs never resizes the surface")
/// The body of a declaration, sliced out by brace depth so an assertion can be about what THAT
/// property reads rather than about words its file happens to use somewhere else - the page names
/// are all over this view, and the one place they must not appear is the width.
func declarationBody(_ source: String, _ declaration: String) -> String? {
    guard let start = source.range(of: declaration) else { return nil }
    var depth = 1
    var body = ""
    for character in source[start.upperBound...] {
        if character == "{" { depth += 1 }
        if character == "}" {
            depth -= 1
            if depth == 0 { return body }
        }
        body.append(character)
    }
    return nil
}
/// The identifiers a body mentions. Words rather than substrings, because the width measures a
/// comfor-TAB-le row and a rule written as `contains("tab")` would read that as the page being
/// asked about.
func identifiers(_ body: String) -> Set<String> {
    Set(body.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init))
}
let widthBody = declarationBody(rootSource, "var popoverWidth: CGFloat {")
check(widthBody != nil, "the surface's width is a property this suite can read")
// THE INVARIANT ITSELF, as a rule about the source rather than about a number: the width may ask
// about the density and the column count, and about nothing that changes when a tab is clicked. A
// width that names a page is the 2026-08-17 regression exactly - 560pt on Usage, 380pt on the
// board, and the header switch walking 90pt sideways under the pointer on every switch.
let widthWords = identifiers(widthBody ?? "tab session")
check(!widthWords.contains("tab") && !widthWords.contains("tabState"),
      "the width never asks which page is up")
check(!widthWords.contains(where: { $0.lowercased().hasPrefix("session") }),
      "…the session board's page included")
// And the leaving page is not centred while it fades: a ZStack aligned to the bare `.top` splits
// any difference in width either side of its children, which is sideways movement in a switch whose
// whole vocabulary is a fade in place.
check(rootSource.contains("ZStack(alignment: .topLeading) {"),
      "the pages are stacked against the leading edge, not centred")

print("a chosen count is spent on the cards, inside the surface it is given")
// WHAT THE COUNT BUYS NOW: that many card columns, at the width one card column gets on the account
// pages, held against the leading edge. So a chosen "1" is a card and not a band across a
// three-column panel (the complaint the count was added for), and the surface never moves.
check(reorderSource.contains("var sessionsBoardWidth: CGFloat?"),
      "the board has a laid-out width of its own")
check(reorderSource.contains("PanelGeometry.cardsWidth(columns: columns, gap: Self.sessionCardGap)"),
      "…built from the card ladder's own arithmetic, which this suite compiles")
check(reorderSource.contains(".frame(maxWidth: sessionsBoardWidth ?? .infinity, alignment: .leading)"),
      "…applied to the grid as a cap, against the leading edge")
/// The board's own width at a count. The board's gutter rather than the account grid's, which is
/// why the arithmetic takes one: the two boards are spaced differently.
func boardWidth(columns: Int) -> CGFloat {
    PanelGeometry.cardsWidth(columns: columns, gap: sessionGap)
}
check(boardWidth(columns: 1), 263, "one session column is one card wide")
check(boardWidth(columns: 2), 534, "two session columns are two cards and a gutter")
// Auto asks for nothing at all: no count, so no cap, and the board fills whatever width the account
// pages left it (`PanelGeometry.gridColumns` returns nil).
check(sessionColumns(nil, panel: PanelGeometry.cardPanelWidth(columns: 1)) == nil,
      "auto asks for no count, so the board is not capped at all")
/// What the board is actually laid out in: the cap, or the grid it is offered where that is
/// narrower - a `maxWidth` frame is proposed the lesser of the two, exactly as the view is.
func laidOutBoard(chosen: Int, panel: CGFloat) -> (columns: Int, width: CGFloat, card: CGFloat) {
    let columns = sessionColumns(chosen, panel: panel) ?? 1
    let width = min(boardWidth(columns: columns), sessionGrid(width: panel))
    return (columns, width, (width - sessionGap * CGFloat(columns - 1)) / CGFloat(columns))
}
// In every panel either density produces: the board fits inside the panel, the count inside it is
// the one that was asked for or less, and a card is never squeezed below the width the board's
// arithmetic is built on nor stretched past the card ladder's own column.
for panel in [PanelGeometry.cardPanelWidth(columns: 1), PanelGeometry.cardPanelWidth(columns: 2),
              PanelGeometry.cardPanelWidth(columns: 3), PanelGeometry.cardPanelWidth(columns: 4),
              PanelGeometry.listPanelWidth(columns: 1, rowWidth: listRowWidth),
              PanelGeometry.listPanelWidth(columns: 2, rowWidth: listRowWidth),
              PanelGeometry.listPanelWidth(columns: 3, rowWidth: listRowWidth)] {
    for chosen in 1 ... maxSessionsColumns {
        let board = laidOutBoard(chosen: chosen, panel: panel)
        check(board.columns <= chosen && board.width <= sessionGrid(width: panel)
                && board.card >= sessionCard && board.card <= PanelGeometry.cardColumnWidth,
              "\(Int(panel))pt panel, \(chosen) asked -> \(board.columns) card(s) of \(board.card)pt")
    }
}
// THE ONE THE 380pt PANEL IS FOR: a single column of accounts is a 356pt reading width, and a
// session card in it is still a card - narrower than the panel, and nothing about the panel changed
// to make it so.
check(boardWidth(columns: sessionColumns(1, panel: PanelGeometry.cardPanelWidth(columns: 1)) ?? 0),
      263, "a one-column panel seats a one-card board, and stays 380pt")
// A COUNT THE SURFACE CANNOT SEAT STEPS DOWN, which is the same direction it always stepped: the
// panel is the account pages' to decide, so two cards asked for in a panel that fits one is one.
check(sessionColumns(2, panel: PanelGeometry.cardPanelWidth(columns: 1)) == 1,
      "two asked for in a one-column panel lays out the one that fits")
check(sessionColumns(2, panel: PanelGeometry.cardPanelWidth(columns: 2)) == 2,
      "…and two in a two-column panel lays out both")

print("a remembered count comes back into the range still on offer")
check(PanelGeometry.storedColumns(0, max: maxSessionsColumns) == 0, "nothing stored is auto")
check(PanelGeometry.storedColumns(-3, max: maxSessionsColumns) == 0, "and so is a nonsense count")
check(PanelGeometry.storedColumns(1, max: maxSessionsColumns) == 1, "a count on offer is kept")
check(PanelGeometry.storedColumns(2, max: maxSessionsColumns) == 2, "…including the highest one")
check(PanelGeometry.storedColumns(4, max: maxSessionsColumns) == 2,
      "a count past the last tile comes back to that tile, not to auto")
check(PanelGeometry.storedColumns(4, max: 3) == 3,
      "the same rule the compact list is read back through")
// AND ALL THREE COUNTS ARE READ BACK THROUGH IT, which is a source reading because the store is an
// app-target file this harness does not compile. The cards' own count was the last one spelling the
// range by hand (`(1 ... 4).contains(...)`), where a stored count past the ladder fell back to auto
// rather than to the widest tile - one initializer answering the same question two ways.
check(storeSource.contains(
          "panelColumns = PanelGeometry.storedColumns(defaults.integer(forKey: \"panelColumns\")")
          && storeSource.contains("listColumns = PanelGeometry.storedColumns(")
          && storeSource.contains("sessionsColumns = PanelGeometry.storedColumns("),
      "every remembered column count is read back through the one clamping rule")
check(!storeSource.contains("(1 ... 4).contains(defaults.integer(forKey: \"panelColumns\"))"),
      "…the cards' count included, rather than spelling its own range")

print("the panel fits the display it opens on")
// Every display a Mac actually reports, against every count either density lets a user pick. This
// is the invariant the fix exists for: a panel wider than its display loses its right-hand column
// off the screen, and the popover cannot scroll sideways to bring it back.
let displays: [CGFloat] = [1024, 1152, 1280, 1440, 1512, 1680, 1710, 1920, 2048, 2560, 3008]
for display in displays {
    let usable = usableWidth(display: display)
    for chosen in 1 ... 4 {
        let columns = PanelGeometry.seated(chosen, columnWidth: PanelGeometry.cardColumnWidth,
                                           in: usable)
        check(PanelGeometry.cardPanelWidth(columns: columns) <= usable,
              "\(Int(display))pt display, \(chosen) card columns -> \(columns) fits")
    }
    for chosen in 1 ... 3 {
        let columns = PanelGeometry.seated(chosen, columnWidth: listRowWidth, in: usable)
        check(PanelGeometry.listPanelWidth(columns: columns, rowWidth: listRowWidth) <= usable,
              "\(Int(display))pt display, \(chosen) list columns -> \(columns) fits")
    }
    // The sessions page is bounded by the same reading, and by way of the same panel: it has no
    // width of its own to bound, so what is checked here is that the board laid out inside every
    // panel this display allows still fits it, at cards never below the width the board's
    // arithmetic is built on.
    let widest = PanelGeometry.cardPanelWidth(
        columns: PanelGeometry.seated(4, columnWidth: PanelGeometry.cardColumnWidth, in: usable))
    for chosen in 1 ... maxSessionsColumns {
        let board = laidOutBoard(chosen: chosen, panel: widest)
        check(widest <= usable && board.width <= sessionGrid(width: widest)
                && board.columns <= chosen && board.card >= sessionCard,
              "\(Int(display))pt display, \(chosen) session columns -> \(Int(board.width))pt of board in \(Int(widest))pt")
    }
}

if failures == 0 {
    print("\nall panel width assertions passed")
    exit(0)
} else {
    print("\n\(failures) assertion(s) failed")
    exit(1)
}
