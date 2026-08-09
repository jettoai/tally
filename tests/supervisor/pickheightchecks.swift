import CoreGraphics
import Foundation

// HOW TALL THE PICK PANEL'S LIST IS. Split from pickerchecks.swift the way pickgracechecks.swift is,
// and for the same reason: this is one decision with its own incident behind it.
//
// THE INCIDENT (2026-08-09, on a real `/tally-model`): the panel came up as a message with NOTHING
// under it, 460x85, the rows gone and the space above the text empty. The window takes its size from
// its content, and the content's height was being asked of a ScrollView, which has no height it
// prefers along its scroll axis. Reproduced four times out of four on the dev preview, then twice
// more with the stack made eager and twice with a `ViewThatFits` in front of it: what collapses is
// not laziness, it is asking a scrolling container how tall it wants to be.
//
// So the list is TOLD its height, from the rows: measured once they have laid out, computed from
// their shape until then. The arithmetic is here because it is the half that can be asserted without
// a screen, and because it is what makes the collapsed state unreachable rather than unlikely.
func runPickHeightChecks() {
    func plain(_ n: Int) -> [PickRow] {
        (0 ..< n).map { PickRow(value: "v\($0)", label: "row \($0)") }
    }
    func detailed(_ n: Int) -> [PickRow] {
        (0 ..< n).map { PickRow(value: "v\($0)", label: "row \($0)", detail: "session 90%") }
    }

    // MARK: - 36h. The seed can never be the height that lost the rows

    check("a list with rows always wants some height", pickRowsSeedHeight(plain(1)) > 0)
    check("…and every row that scrolls adds to it", (2 ..< 8).allSatisfy {
        pickRowsSeedHeight(plain($0 + 1)) > pickRowsSeedHeight(plain($0))
    })
    // The pinned row is the one exception, and it is measured apart rather than not measured: a
    // two-row list scrolls one row and pins the other, so the scrolling region is the same height as
    // a one-row list's and the panel is taller by the block underneath.
    check("…while the row pinned under the list is added to the panel, not to the scroll",
          pickRowsSeedHeight(plain(2)) == pickRowsSeedHeight(plain(1))
              && pickStickyHeight(plain(2)) > 0)
    check("a row carrying a second line is taller than one without",
          pickRowsSeedHeight(detailed(1)) > pickRowsSeedHeight(plain(1)))
    check("…and an empty detail is not a second line, it is no line",
          pickRowsSeedHeight([PickRow(value: "v", label: "l", detail: "")])
              == pickRowsSeedHeight(plain(1)))
    check("a fleet nobody could read on one screen stops at the cap",
          pickRowsSeedHeight(detailed(40)) == pickRowsMaxHeight)
    // A request with no rows never reaches the panel (`PickPanelController.present` refuses one), so
    // this is the one case that is allowed to be zero, and it is stated rather than left to chance.
    check("no rows is the only zero there is", pickRowsSeedHeight([]) == 0)

    // THE TWO LISTS THIS PANEL ACTUALLY DRAWS, against what they measure on screen. Both fixtures
    // are built the way the dev preview builds them, and both numbers were read off the window with
    // the cap moved out of the way (2026-08-10): 221 points for the account list, 371 for the model
    // list. A few points either way is all this has to be, since the measurement replaces it one
    // pass later, but being right to the point is what says the constants were measured rather than
    // guessed.
    let accountRows = detailed(3) + [PickRow(value: "--auto", label: pickAutoLabel)]
    check("the account list's seed and its pinned row are what it lays out at (221, +/- 4)",
          abs(pickRowsSeedHeight(accountRows) + pickStickyHeight(accountRows) - 221) <= 4)
    var modelRows: [PickRow] = []
    for model in ["fable", "opus", "sonnet"] {
        modelRows.append(PickRow(value: model, label: model))
        for effort in ["high", "xhigh"] {
            modelRows.append(PickRow(value: model, effort: effort, label: "\(model) · \(effort)"))
        }
    }
    modelRows.append(PickRow(value: "auto",
                             label: "auto  (follow this project's profile, then the fleet default)"))
    check("the model list lays out at 371 points all told (+/- 4), before the cap",
          abs(pickRowsSeedHeight(modelRows, cap: 1000) + pickStickyHeight(modelRows) - 371) <= 4)
    check("…and a list long enough to need it scrolls at the cap",
          pickRowsSeedHeight(detailed(20) + [PickRow(value: "--auto", label: pickAutoLabel)])
              == pickRowsMaxHeight)

    // MARK: - 36h6. The way out does not scroll away

    // THE PINNED ROW IS OUTSIDE THE CAP, which is the point of pinning it: a fleet long enough to
    // scroll must not be able to push the release row off the bottom, so its height is added to the
    // panel rather than taken out of the scrolling region's budget.
    check("the release row is not one of the rows that scroll",
          pickScrollingIndices(of: modelRows) == 0 ..< (modelRows.count - 1)
              && pickScrollingIndices(of: accountRows) == 0 ..< (accountRows.count - 1))
    check("…and a list with nothing to pin scrolls all of itself",
          pickScrollingIndices(of: plain(1)) == 0 ..< 1)
    check("the pinned block is the rule plus the row it sets apart",
          pickStickyHeight(modelRows)
              == pickRowGap(before: modelRows.count - 1, rows: modelRows)
                  + pickRowHeight(modelRows[modelRows.count - 1]))
    check("…which is the same block on both lists, since both end the same way",
          pickStickyHeight(modelRows) == pickStickyHeight(accountRows))
    check("a list with nothing to pin has no block under it", pickStickyHeight(plain(1)) == 0)
    // The two-line row it draws: the release row's sentence is under it, so it is a tall row.
    check("the pinned row is drawn with its sentence under it",
          pickRowHeight(accountRows[accountRows.count - 1]) == pickDetailRowHeight)
    // And the scrolling region stops at the cap whatever is pinned below it, which is what keeps a
    // long fleet from growing the panel past the screen.
    check("a scrolling region long enough is capped, pinned row or not",
          pickRowsSeedHeight(detailed(20) + [PickRow(value: "--auto", label: pickAutoLabel)])
              == pickRowsSeedHeight(detailed(30)))

    // MARK: - 36h4. The list reads as groups, not as one run of rows

    check("two depths of one model sit close together",
          pickRowGap(before: 1, rows: modelRows) == pickRowSpacing)
    check("…and the next model starts a group of its own",
          pickRowGap(before: 3, rows: modelRows) == pickRowGroupSpacing)
    check("nothing is spaced above the first row",
          pickRowGap(before: 0, rows: modelRows) == 0)
    // The way out of the list is not another row in it: a rule, with a group gap on each side.
    check("the release row is set apart by a rule",
          pickRowGap(before: modelRows.count - 1, rows: modelRows)
              == pickRowGroupSpacing * 2 + pickRowDividerHeight)
    check("…which is the last row, on both lists",
          pickRowIsRelease(index: modelRows.count - 1, of: modelRows)
              && pickRowIsRelease(index: accountRows.count - 1, of: accountRows))
    check("a one-row list has nothing to set apart",
          !pickRowIsRelease(index: 0, of: plain(1)))

    // MARK: - 36h5. Each thing said once

    let depthRow = PickRow(value: "opus", effort: "high", label: "opus · high")
    check("a depth the chip already shows is not repeated in the name",
          pickPanelLabel(depthRow) == "opus" && pickPanelDetail(depthRow) == nil)
    check("a name that merely contains the separator is left alone",
          pickPanelLabel(PickRow(value: "o", label: "opus · high · extra")) == "opus · high · extra")
    let auto = PickRow(value: "auto",
                       label: "auto  (follow this project's profile, then the fleet default)")
    check("the release row's sentence moves to its own line",
          pickPanelLabel(auto) == "auto"
              && pickPanelDetail(auto) == "follow this project's profile, then the fleet default")
    check("…and the account list's release row reads the same way",
          pickPanelLabel(PickRow(value: "--auto", label: pickAutoLabel)) == "automatic selection")
    let account = PickRow(value: "claude:.claude", label: "Claude", detail: "session 86%")
    check("a row that already has a second line keeps the one it was given",
          pickPanelDetail(account) == "session 86%" && pickPanelLabel(account) == "Claude")
    check("a plain name is untouched", pickPanelLabel(plain(1)[0]) == "row 0")

    // The identity line names the axis, in the same English the wire speaks.
    check("the panel says which of the two it is",
          pickPanelKindName(.model) == "Model" && pickPanelKindName(.account) == "Account")

    // MARK: - 36h2. One authority at a time

    check("a measured height is what the list is drawn at",
          pickRowsHeight(measured: 123, rows: plain(10)) == 123)
    check("…capped, however tall the rows turned out to be",
          pickRowsHeight(measured: 900, rows: plain(2)) == pickRowsMaxHeight)
    // ZERO IS NOT A MEASUREMENT. It is what a collapsed layout reports, which is exactly the state
    // this whole change exists to refuse, so it falls back to the arithmetic rather than being
    // believed.
    check("nothing measured yet means the seed, not nothing",
          pickRowsHeight(measured: 0, rows: plain(4)) == pickRowsSeedHeight(plain(4)))
    check("…and that is never zero for a list with rows",
          pickRowsHeight(measured: 0, rows: plain(1)) > 0)
    check("a nonsense measurement is refused the same way",
          pickRowsHeight(measured: -50, rows: plain(3)) == pickRowsSeedHeight(plain(3)))

    // MARK: - 36h3. The view asks the way this file says it does

    // The layout itself needs a screen, so the wiring is carried by the source: an eager stack (a
    // lazy one measures only what it has materialized), the height told rather than asked, and no
    // `maxHeight` left on the scrolling container, which is the exact line that shipped the defect.
    let view = (try? String(contentsOfFile: "Tally/Views/PickPanelView.swift", encoding: .utf8)) ?? ""
    check("the panel view is readable from this suite", !view.isEmpty)
    check("the list is told its height by the rule above",
          view.contains(".frame(height: pickRowsHeight(measured: rowsHeight, rows: request.rows))"))
    check("…measured off an EAGER stack, which is the only kind that measures whole",
          view.contains("VStack(spacing: 0)") && !view.contains("LazyVStack"))
    check("…and nothing asks the scrolling container for a height it does not have",
          !view.contains(".frame(maxHeight:"))
    check("the gaps between rows come from the rule the arithmetic sums, not from the stack",
          view.contains("pickRowGap(before: index, rows: request.rows)"))
    check("…and the release row is set apart by the same test the arithmetic uses",
          view.contains("pickRowIsRelease(index: index, of: request.rows)"))
    check("only the scrolling rows are inside the scroll region",
          view.contains("ForEach(pickScrollingIndices(of: request.rows)"))
    check("…and the release row is drawn after it, outside",
          view.contains("pickRowIsRelease(index: release, of: request.rows)"))
    check("each row is drawn with the name and the second line the rule decides",
          view.contains("pickPanelLabel(row)") && view.contains("pickPanelDetail(row)"))
}
