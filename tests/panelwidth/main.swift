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
