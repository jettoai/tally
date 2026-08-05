import Foundation

// Assertion harness for what `tally statusline claude` renders, compiled against the real source.
//
// The status line is one row shared by four zones, so its formats are only ever as good as their
// worst fit: the pool slot used to be the single figure in the row quoted in a unit of its own
// (accounts' worth, "0.6/5") beside three windows all quoted in percent. These are the pure pieces
// behind that row; the row itself reads stdin and exits, so what is pinned here is the vocabulary
// every surface has to agree on.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// MARK: - The pool label

// A model pool says WHICH pool it is, because the panel's gauge focus can re-point this slot and a
// bare "pool" flipping between budgets reads as a wrong number. Lower-cased, because the rest of the
// row is.
check("a model pool names itself", poolLabel("Fable") == "fable pool")
check("a pool name is lower-cased into the row", poolLabel("OPUS") == "opus pool")
check("the weekly pool is the unnamed one", poolLabel(nil) == "pool")

// MARK: - The pool figure

// The change this suite was written for: the slot shows the share of the pool still unspent, in the
// same percent vocabulary as the 5h and 7d slots beside it. Accounts' worth stays in `tally status`
// and the panel, where there is room to say what the units are.
check("a pool with 60 of 500 account-points left reads as a percent",
      poolRemainingFigure(remaining: 60, capacity: 500) == "12%")
check("the figure carries no denominator any more",
      !poolRemainingFigure(remaining: 60, capacity: 500).contains("/"))
check("a full pool is 100%", poolRemainingFigure(remaining: 200, capacity: 200) == "100%")
check("a dry pool is 0%", poolRemainingFigure(remaining: 0, capacity: 200) == "0%")
// Whole numbers only: this shares a row with three other figures and a custom status line.
check("a half point rounds rather than truncating",
      poolRemainingFigure(remaining: 25, capacity: 200) == "13%")
check("and rounds down below the half",
      poolRemainingFigure(remaining: 24, capacity: 200) == "12%")
check("a fraction of a percent still shows as a percent",
      poolRemainingFigure(remaining: 1, capacity: 500) == "0%")
// The caller filters these out; the guard exists because `Int(Double.infinity)` traps, which would
// take the whole status line down rather than dropping one slot from it.
check("a pool with no capacity is a figure, not a crash",
      poolRemainingFigure(remaining: 5, capacity: 0) == "0%")

// MARK: - The bar beside it

// The meter and the figure now read the same ratio, which is the other half of the change: while the
// figure was accounts' worth, a bar drawn from the percentage was the only thing in the slot the
// number did not describe.
func filledCells(_ remaining: Double, _ capacity: Double) -> Int {
    let cells = 6
    let pct = remaining / capacity * 100
    return min(cells, max(pct > 0 ? 1 : 0, Int((pct / 100 * Double(cells)).rounded())))
}
check("half a pool fills half the bar", filledCells(100, 200) == 3)
check("a full pool fills every cell", filledCells(200, 200) == 6)
check("a nearly dry pool still shows one cell rather than vanishing", filledCells(2, 200) == 1)
check("an empty pool shows none", filledCells(0, 200) == 0)
check("the figure agrees with the bar it sits beside",
      poolRemainingFigure(remaining: 100, capacity: 200) == "50%" && filledCells(100, 200) == 3)

exit(failures == 0 ? 0 : 1)
