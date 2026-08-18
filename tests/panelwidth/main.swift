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
/// The widest one session card is laid out at. A copy, pinned to its line below like the two above:
/// what a cap leaves over stays empty, so this is the figure the empty space is measured against.
let sessionCardCap: CGFloat = 480
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
check(boardSource.contains("static let defaultSessionCardCap: CGFloat = \(Int(sessionCardCap))"),
      "…and the cap here is the one a card is laid out up to")
// THE CAP CAN BE MOVED FOR A LOOK, AND ONLY FOR A LOOK: the flag that judges two ceilings side by
// side is gated on the demo data or a dev build, exactly as the capture flags that put a surface on
// screen are, so a release instance somebody is using cannot be argued into another layout.
check(boardSource.contains(#"UserDefaults.standard.double(forKey: "TallySessionCardCap")"#)
        && boardSource.contains("guard DemoUsage.isActive || BuildVariant.isDev,"),
      "…and the flag that overrides it for a capture is a demo or dev build's alone")
func sessionGrid(width: CGFloat) -> CGFloat { width - 2 * PanelGeometry.contentPadding }
/// What one session card comes out at: the grid's width, less the gutters, split between the cards,
/// and then held between the narrowest it may be and the widest it is worth reading.
func sessionCardWidth(panel: CGFloat, columns: Int, cap: CGFloat = sessionCardCap) -> CGFloat {
    PanelGeometry.flexibleCardWidth(inGridOf: sessionGrid(width: panel), columns: columns,
                                    gap: sessionGap, minimum: sessionCard, cap: cap)
}
/// How many columns the board lays out for a count (nil for auto) and a number of cards on it.
func sessionColumns(_ chosen: Int?, cards: Int = 1, panel: CGFloat) -> Int {
    PanelGeometry.boardColumns(chosen: chosen, cards: cards, in: sessionGrid(width: panel),
                               minimum: sessionCard, gap: sessionGap)
}
check(sessionColumns(1, panel: PanelGeometry.listPanelWidth(columns: 1, rowWidth: listRowWidth))
      == 1, "the reported case: one comfortable row wide, one session card across")
check(sessionColumns(2, cards: 2,
                     panel: PanelGeometry.listPanelWidth(columns: 2, rowWidth: listRowWidth))
      == 2, "two list columns, two session cards")
check(sessionColumns(1, panel: PanelGeometry.cardPanelWidth(columns: 1)) == 1,
      "one card column, one session card")
check(sessionColumns(2, cards: 2, panel: PanelGeometry.cardPanelWidth(columns: 2)) == 2,
      "two card columns, two session cards")
check(sessionColumns(4, cards: 4, panel: PanelGeometry.cardPanelWidth(columns: 4)) == 4,
      "four card columns, four session cards")
// AUTO ASKS FOR AS MANY COLUMNS AS THERE ARE CARDS, taken when the page is opened: a board of one
// reads as one column of its own rather than a card squeezed into a fifth of a wide panel, and a
// board of five uses every column the width can seat.
check(sessionColumns(nil, cards: 1, panel: PanelGeometry.cardPanelWidth(columns: 4)) == 1,
      "auto with one card on the board asks for one column")
check(sessionColumns(nil, cards: 3, panel: PanelGeometry.cardPanelWidth(columns: 4)) == 3,
      "…three cards, three columns")
check(sessionColumns(nil, cards: 9, panel: PanelGeometry.cardPanelWidth(columns: 4)) == 5,
      "…and nine cards take every column a 1108pt panel seats, which is five")
check(sessionColumns(nil, cards: 0, panel: PanelGeometry.cardPanelWidth(columns: 2)) == 1,
      "an empty board is still one column rather than none")
// A COUNT THE WIDTH CANNOT SEAT STEPS DOWN rather than pushing the surface out: a page under auto
// is living in the width another page decided, and a page with a width of its own has already had
// that width bounded by the display before the grid inside it is laid out.
check(sessionColumns(4, cards: 4, panel: PanelGeometry.cardPanelWidth(columns: 1)) == 1,
      "four columns asked for in a one-column panel steps down to one")
check(sessionColumns(3, cards: 3, panel: PanelGeometry.cardPanelWidth(columns: 2)) == 2,
      "three in a two-column panel steps down to two")

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
// FOUR, WHERE IT WAS TWO: the ceiling of two was reasoning about a card frozen at the account
// ladder's width, and it outlived it - auto was already using every column that fits while an
// explicit choice stopped at two (Albert, 2026-08-18).
let maxSessionsColumns = 4
check(storeSource.contains("static let maxSessionsColumns = \(maxSessionsColumns)"),
      "the highest sessions count here is the one the store offers")
// ONE SETTING READ BY BOTH SIDES, which is the whole of what keeps the count and the width honest:
// the width asks `sessionsColumnChoice`, and so does the grid that lays the cards out in it.
check(storeSource.contains("var sessionsColumns: Int"),
      "the board's count is its own stored setting")
check(reorderSource.contains("(1 ... SettingsStore.maxSessionsColumns).contains(settings.sessionsColumns)"),
      "…and the choice itself is read from that setting")
check(reorderSource.contains("PanelGeometry.boardColumns(chosen: sessionsColumnChoice"),
      "…which is the same choice the grid lays out")
// THE PREFERENCE IS NEVER REWRITTEN BY THE WIDTH. A count the surface cannot seat steps down for
// the layout only: the number stays where the user put it, so widening the panel brings the board
// they asked for back without them having to pick it again.
check(!reorderSource.contains("settings.sessionsColumns ="),
      "nothing on the board writes the remembered count back")
// AUTO'S COUNT IS TAKEN WHEN THE PAGE IS OPENED, not read live off the roster: the scan runs twice
// a second, and a board that re-flowed as sessions came and went would move under the reader.
check(boardSource.contains(".onAppear { sessionsAutoColumns = listed.isEmpty ? nil : listed.count }"),
      "auto resolves its count as the board is opened")
// …and from the first board that has cards on it. The roster scans on its own clock, so the first
// frame of a new surface is an empty board: a count taken there froze auto at one column on a
// machine running eight sessions (measured on the dev instance, 2026-08-18).
check(boardSource.contains("if sessionsAutoColumns == nil, count > 0 { sessionsAutoColumns = count }"),
      "…or at the first scan that has any, when the surface opened before the roster answered")
check(reorderSource.contains("cards: sessionsAutoColumns ?? cards"),
      "…and the grid lays out that frozen count rather than the live one")

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
/// The alignment of the stack the PAGES are crossfaded in, found by position: the innermost
/// `ZStack` opened before the page condition.
///
/// Not `contains("ZStack(alignment: .topLeading)")`, which is what this replaced and what it could
/// not see: the view's outer stack already carried that alignment before the crossfade was fixed,
/// so a file-wide test was green either way and said nothing about the line it named (review of
/// c85061f).
func crossfadeAlignment(_ source: String) -> String? {
    guard let pages = source.range(of: "if tab == .usage"),
          let opener = source[..<pages.lowerBound].range(of: "ZStack(alignment: .",
                                                         options: .backwards) else { return nil }
    let rest = source[opener.upperBound...]
    guard let close = rest.firstIndex(of: ")") else { return nil }
    return String(rest[..<close])
}
// And the leaving page is not centred while it fades: a ZStack aligned to the bare `.top` splits
// any difference in width either side of its children, which is sideways movement in a switch whose
// whole vocabulary is a fade in place.
check(crossfadeAlignment(rootSource) == "topLeading",
      "the pages are stacked against the leading edge, not centred")

print("a chosen count is spent on the cards, inside the surface it is given")
// WHAT THE COUNT BUYS NOW: at most that many columns, dividing up the room the surface offers, held
// against the leading edge. So a chosen "1" is a card that takes the width it is given up to the
// point a line stops being comfortable to read, and never a band across a four-column panel (the
// complaint the count was added for), and the surface never moves either way.
check(reorderSource.contains("func sessionsBoardWidth(columns: Int) -> CGFloat"),
      "the board has a laid-out width of its own")
check(reorderSource.contains("PanelGeometry.flexibleRunWidth(inGridOf: sessionsGridWidth"),
      "…built from the flexible arithmetic this suite compiles")
check(reorderSource.contains(
        ".frame(maxWidth: sessionsBoardWidth(columns: columns), alignment: .leading)"),
      "…applied to the grid as a cap, against the leading edge")
// ONE READING OF THE COUNT PER PASS, which the cells and the run are both laid out from: two
// readings are two chances for the grid and the width holding it to disagree about how many cards
// are on the page.
check(reorderSource.contains("let columns = sessionColumnCount(cards: listed.count)")
        && reorderSource.contains("sessionGridItems(columns: columns)"),
      "…and the count behind both is resolved once for the pass")
/// The board's own width: its columns of cards and the gutters between them. The board's gutter
/// rather than the account grid's, which is why the arithmetic takes one: the two are spaced
/// differently.
func boardWidth(panel: CGFloat, columns: Int, cap: CGFloat = sessionCardCap) -> CGFloat {
    PanelGeometry.flexibleRunWidth(inGridOf: sessionGrid(width: panel), columns: columns,
                                   gap: sessionGap, minimum: sessionCard, cap: cap)
}
/// What the board is actually laid out as, for a count (nil for auto) on a board of `cards`.
func laidOutBoard(chosen: Int?, cards: Int = 4,
                  panel: CGFloat, cap: CGFloat = sessionCardCap)
    -> (columns: Int, width: CGFloat, card: CGFloat) {
    let columns = sessionColumns(chosen, cards: cards, panel: panel)
    return (columns, boardWidth(panel: panel, columns: columns, cap: cap),
            sessionCardWidth(panel: panel, columns: columns, cap: cap))
}

// THE 2026-08-18 REPORT, AS ONE CELL: a list panel one comfortable row wide, the board set to one
// column, and 217pt of nothing beside a card frozen at a width borrowed from the account ladder.
// The card takes the room now. This is the assertion the old arithmetic fails.
let reported = PanelGeometry.listPanelWidth(columns: 1, rowWidth: listRowWidth)
check(laidOutBoard(chosen: 1, panel: reported).card, 480,
      "504pt panel, one column: the card is the width it is given, not 263")
check(laidOutBoard(chosen: 1, panel: reported).width, 480,
      "…and the board with it, so nothing is left over at that width")
// AND THE OTHER END OF THE SAME ARITHMETIC, which is the 2026-08-17 complaint: a lone card must not
// stretch across a wide panel. 834pt offers 810pt of grid and the card stops at the cap.
check(laidOutBoard(chosen: 1, panel: PanelGeometry.cardPanelWidth(columns: 3)).card, sessionCardCap,
      "834pt panel, one column: the card stops at the cap rather than becoming a band")
check(laidOutBoard(chosen: 1, panel: PanelGeometry.cardPanelWidth(columns: 4)).card, sessionCardCap,
      "…and the widest panel changes nothing about that")
// The cap is one constant, and moving it moves the card: the demo builds that judge it on screen
// pass another number through the same arithmetic (`-TallySessionCardCap`).
check(laidOutBoard(chosen: 1, panel: reported, cap: 356).card, 356,
      "a capture asking for a 356pt cap gets a 356pt card in that same panel")
check(laidOutBoard(chosen: 1, panel: reported, cap: 356).width, 356,
      "…and a board that leaves the remaining 124pt to the surface")
// The two-column readings the same panels produce.
check(laidOutBoard(chosen: 2, panel: reported).card, 236,
      "504pt panel, two columns: two 236pt cards")
check(laidOutBoard(chosen: 2, panel: PanelGeometry.cardPanelWidth(columns: 2)).card, 264,
      "560pt panel, two columns: two 264pt cards")
check(laidOutBoard(chosen: 1, panel: PanelGeometry.cardPanelWidth(columns: 2)).card, sessionCardCap,
      "…and one column there is a card at the cap, 56pt short of the grid")
// The narrow direction, where the count cannot be kept: the board lays out the one column that
// fits, and the picker says "up to" rather than promising the two it cannot seat.
check(laidOutBoard(chosen: 2, panel: PanelGeometry.cardPanelWidth(columns: 1)).columns == 1,
      "380pt panel, two asked for: one column, because two do not fit")
check(laidOutBoard(chosen: 2, panel: PanelGeometry.cardPanelWidth(columns: 1)).card, 356,
      "…laid out at the whole 356pt grid rather than at 263")

// EVERY COUNT IN EVERY PANEL EITHER DENSITY PRODUCES, auto included: the board fits inside the
// panel, the count inside it is the one that was asked for or less, and a card is never squeezed
// below the width the board's arithmetic is built on nor stretched past the cap.
let panels = [PanelGeometry.cardPanelWidth(columns: 1), PanelGeometry.cardPanelWidth(columns: 2),
              PanelGeometry.cardPanelWidth(columns: 3), PanelGeometry.cardPanelWidth(columns: 4),
              PanelGeometry.listPanelWidth(columns: 1, rowWidth: listRowWidth),
              PanelGeometry.listPanelWidth(columns: 2, rowWidth: listRowWidth),
              PanelGeometry.listPanelWidth(columns: 3, rowWidth: listRowWidth)]
for panel in panels {
    for cards in [0, 1, 2, 3, 5, 9] {
        for chosen in [nil] + (1 ... maxSessionsColumns).map(Optional.init) {
            let board = laidOutBoard(chosen: chosen, cards: cards, panel: panel)
            let asked = chosen ?? max(1, cards)
            check(board.columns <= asked && board.columns >= 1
                    && board.width <= sessionGrid(width: panel)
                    && board.card >= sessionCard && board.card <= sessionCardCap,
                  "\(Int(panel))pt panel, \(cards) cards, \(chosen.map(String.init) ?? "auto") "
                    + "-> \(board.columns) column(s) of \(board.card)pt")
        }
    }
}
// The run is exactly its cards and its gutters, which is what makes the flexible cells inside the
// frame come out at the card width asserted above rather than at some share of a wider box.
for panel in panels {
    for columns in 1 ... 4 {
        check(boardWidth(panel: panel, columns: columns),
              CGFloat(columns) * sessionCardWidth(panel: panel, columns: columns)
                + CGFloat(columns - 1) * sessionGap,
              "\(Int(panel))pt panel, \(columns) columns: the run is its cards and its gutters")
    }
}

print("a remembered count comes back into the range still on offer")
check(PanelGeometry.storedColumns(0, max: maxSessionsColumns) == 0, "nothing stored is auto")
check(PanelGeometry.storedColumns(-3, max: maxSessionsColumns) == 0, "and so is a nonsense count")
check(PanelGeometry.storedColumns(1, max: maxSessionsColumns) == 1, "a count on offer is kept")
check(PanelGeometry.storedColumns(4, max: maxSessionsColumns) == 4, "…including the highest one")
// THE RANGE ONLY OPENED UPWARD, so every count anybody has stored means what it always meant: this
// is the whole of the migration the ceiling moving from two to four needs.
check(PanelGeometry.storedColumns(2, max: maxSessionsColumns) == 2,
      "a two remembered under the old ceiling still comes back as two")
check(PanelGeometry.storedColumns(6, max: maxSessionsColumns) == 4,
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

print("the picker offers the promise the board can keep")
// A TILE THAT CANNOT BE SEATED IS STILL SELECTABLE, and what changes instead is what the tiles are
// CALLED: "up to 2 columns" is true in every width, where "2 columns" is the control lying about
// the page in any panel that seats one (Albert, 2026-08-15, still live in the narrow direction
// until now). The preference is kept either way, so widening the panel brings it back by itself.
let pickerSource = (try? String(contentsOfFile: "Tally/Views/LayoutColumnPicker.swift",
                                encoding: .utf8)) ?? ""
let footerSource = (try? String(contentsOfFile: "Tally/Views/PopoverFooterView.swift",
                                encoding: .utf8)) ?? ""
let settingsPaneSource = (try? String(contentsOfFile: "Tally/Views/SettingsDisplayPane.swift",
                                      encoding: .utf8)) ?? ""
check(!pickerSource.isEmpty && !footerSource.isEmpty && !settingsPaneSource.isEmpty,
      "the picker and both surfaces that show it are readable from this suite")
check(pickerSource.contains("var atMost: Bool = false"),
      "the picker knows whether a number here is a maximum")
check(pickerSource.contains(#"return atMost ? L("Up to one column") : L("One column")"#)
        && pickerSource.contains(#"String(localized: "Up to \(option) columns""#),
      "…and says so in the words each tile is described in")
check(pickerSource.contains("var maxColumns: Int = 4") && !pickerSource.contains("disabled("),
      "…while every tile it offers stays selectable")
// BOTH SESSIONS SURFACES SPEAK IT, which is the rule the picker exists for: one control, so the
// panel and the Settings pane cannot describe the same setting two ways.
/// What a call site passes, read as the 200 characters after the binding it edits: a file-wide
/// `contains("atMost")` would be green off any other call in the same file.
func callSite(_ source: String, editing binding: String) -> String {
    String((source.components(separatedBy: binding).dropFirst().first ?? "").prefix(200))
}
for (name, source) in [("the panel's view options", footerSource),
                       ("the Settings pane", settingsPaneSource)] {
    check(callSite(source, editing: "$settings.sessionsColumns").contains("atMost: true"),
          "\(name) offers the sessions count as a maximum")
}
// …and the account pages' own count is NOT a maximum: it decides the panel's width, so it is always
// kept exactly, and describing it as "up to" would be the mirror-image lie.
for (name, source) in [("the panel's view options", footerSource),
                       ("the Settings pane", settingsPaneSource)] {
    check(!callSite(source, editing: "$settings.densityColumns").contains("atMost"),
          "\(name) still offers the account count as the exact number it keeps")
}
// THE SENTENCE THAT ANSWERS "WHY DID MY 2 LAY OUT 1", standing on the card rather than waiting in a
// callout nobody hovers.
let standingLine = "Panel width follows the Usage pages. Auto takes the columns that fit when the "
    + "board is opened, and a number is the most it will use."
check(footerSource.contains(standingLine),
      "the sessions layout section explains what the panel's width follows")
// EVERY WORD OF IT IS IN THE CATALOGUE, in all four translations: the app ships five languages, and
// a sentence that reaches somebody in English on a Japanese machine is a missing translation
// nobody notices until they see it.
let catalogue = (try? Data(contentsOf: URL(fileURLWithPath:
    "Tally/Resources/Localizable.xcstrings")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
let catalogueStrings = catalogue?["strings"] as? [String: Any] ?? [:]
check(!catalogueStrings.isEmpty, "the string catalogue is readable from this suite")
for word in ["Up to one column", "Up to %lld columns", standingLine] {
    let entry = catalogueStrings[word] as? [String: Any]
    let localizations = entry?["localizations"] as? [String: Any] ?? [:]
    check(["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { localizations[$0] != nil },
          "\(word.prefix(28)) is translated into every language Tally ships")
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
    // The sessions page is bounded by the same reading, and by way of the same panel: it has no
    // width of its own to bound, so what is checked here is that the board laid out inside every
    // panel this display allows still fits it, at cards never below the width the board's
    // arithmetic is built on.
    let widest = PanelGeometry.cardPanelWidth(
        columns: PanelGeometry.seated(4, columnWidth: PanelGeometry.cardColumnWidth, in: usable))
    for chosen in 1 ... maxSessionsColumns {
        let board = laidOutBoard(chosen: chosen, panel: widest)
        check(widest <= usable && board.width <= sessionGrid(width: widest)
                && board.columns <= chosen && board.card >= sessionCard
                && board.card <= sessionCardCap,
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
