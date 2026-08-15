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
// THE PANEL NEVER WIDENS FOR THIS: its width is the usage page's to decide, so a count this width
// cannot seat steps down to what fits rather than pushing the surface out.
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
        let grid = sessionGrid(width: panel)
        let card = (grid - sessionGap * CGFloat(columns - 1)) / CGFloat(columns)
        check(columns <= chosen && card >= sessionCard,
              "\(Int(panel))pt panel, \(chosen) asked -> \(columns) cards of \(card)pt")
    }
}

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
}

if failures == 0 {
    print("\nall panel width assertions passed")
    exit(0)
} else {
    print("\n\(failures) assertion(s) failed")
    exit(1)
}
