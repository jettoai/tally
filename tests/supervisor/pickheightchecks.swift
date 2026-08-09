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
    check("…and every row adds to it", (1 ..< 8).allSatisfy {
        pickRowsSeedHeight(plain($0 + 1)) > pickRowsSeedHeight(plain($0))
    })
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

    // The two lists this panel actually draws, against what they measured on the day the arithmetic
    // was calibrated: an account pick (three rows with windows under them, plus the release row) at
    // 210 points, and a model pick (ten rows, no second lines) past the cap. Within a few points is
    // the whole requirement, because the seed is replaced by the real measurement one pass later.
    let accountSeed = pickRowsSeedHeight(detailed(3) + plain(1))
    check("the account list's seed is about what it measures (210 points, +/- 8)",
          abs(accountSeed - 210) <= 8)
    check("the model list's seed reaches the cap, exactly as the measured one does",
          pickRowsSeedHeight(plain(10)) == pickRowsMaxHeight)

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
          view.contains("VStack(spacing: pickRowSpacing)") && !view.contains("LazyVStack"))
    check("…and nothing asks the scrolling container for a height it does not have",
          !view.contains(".frame(maxHeight:"))
}
