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

// MARK: - One figure for every human surface

// `tally status`'s fleet line reads the same way as the status line's pool slot, because the app is
// where the accounts'-worth reading belongs (with the room to say what the units are). Neither
// surface can be asked for its output here - one prints and exits, the other prints and returns
// nothing - so the source carries the invariant, the same technique the supervisor suite uses for
// its call-site rules. Run from the repo root (run-statusline-tests.sh cds there), and a missing
// file FAILS rather than quietly passing.
let statusSource = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
check("the status source is readable from the status line checks", !statusSource.isEmpty)
check("`tally status` prints the same pool figure",
      statusSource.contains("poolRemainingFigure(remaining: pool.remaining, capacity: pool.capacity)"))
check("and the same pool label", statusSource.contains("poolLabel(pool.poolName)"))
check("with no accounts'-worth formatting left in either human surface",
      !statusSource.contains("%.1f/%d")
          && !((try? String(contentsOfFile: "TallyCLI/Statusline.swift", encoding: .utf8)) ?? "")
              .contains("%.1f/%d"))
// The machine-readable side is deliberately untouched: `status --json` carries the pool's raw
// `remaining` and `capacity` in account-week units, which is a versioned additive contract scripts
// read (pinned in tests/statusjson). A display change must never reach through to it.
let reportSource = (try? String(contentsOfFile: "TallyCLI/StatusReport.swift",
                                encoding: .utf8)) ?? ""
check("the report source is readable from the status line checks", !reportSource.isEmpty)
check("the JSON report formats no percentages of its own",
      !reportSource.contains("poolRemainingFigure"))

// MARK: - Where the rest of the binary is

// Bare `tally` IS `tally status`, so this report is what somebody typing the name gets - and it used
// to be all they got: nothing on screen said the binary had any other command, and the list existed
// only behind a word you had to already know (Albert, 2026-08-10). Asserted through the source for
// the reason the section above gives: the human surface prints and returns nothing.
let statusBody = statusSource.range(of: "func runStatus(").flatMap { start in
    statusSource.range(of: "func runResume(").map { end in
        String(statusSource[start.lowerBound ..< end.lowerBound])
    }
} ?? ""
check("the status command is readable on its own", statusBody.contains("func runStatus("))
check("…and the slice stopped at the next command rather than swallowing the file",
      !statusBody.contains("func runWorktree("))
// A LINE THAT IS THE STATEMENT, not a line that mentions it: the first version of this check asked
// whether the text appeared anywhere in the function, and a mutation that commented the print out
// passed it (2026-08-10, caught by running that mutation rather than by reading the check).
let hintStatements = statusBody.components(separatedBy: "\n").filter {
    $0.trimmingCharacters(in: .whitespaces) == "print(tallyStatusHelpHint)"
}
check("the report ends by naming the way into everything else", hintStatements.count == 1)
check("…and that line names a command that exists rather than a flag to guess at",
      tallyStatusHelpHint.contains("tally help"))
// The machine-readable shape must not grow a sentence: it returns before the hint, which is what
// the early `return` in the `if json` branch is for.
if let jsonReturn = statusBody.range(of: "return\n    }"),
   let hint = statusBody.range(of: "print(tallyStatusHelpHint)") {
    check("the JSON shape returns before it, so no script has to parse prose",
          jsonReturn.upperBound < hint.lowerBound)
} else {
    check("the JSON shape returns before it, so no script has to parse prose", false)
}

// MARK: - `tally help`, and that it describes this binary rather than a past one

/// Every command the usage text documents, taken off the lines that show one.
let documented = tallyUsage.components(separatedBy: "\n").compactMap { line -> String? in
    guard line.hasPrefix("  tally ") else { return nil }
    return line.dropFirst("  tally ".count).split(separator: " ").first.map(String.init)
}
// The extractor's own sanity: a prefix that stopped matching would find nothing and pass every
// check below by saying nothing about anything.
check("the extractor really found the command lines",
      documented.count >= 14 && documented.contains("status") && documented.contains("help"))
for command in Set(documented).sorted() {
    check("`tally \(command)` is documented AND dispatched",
          statusSource.contains("case \"\(command)\""))
}
// ASKED FOR vs COMPLAINED ABOUT: same text, two streams and two exit codes, which is what a shell
// pipeline reads. `tally help | less` needs the first; every wrapper that checks whether a
// subcommand exists (the self-update's `__resupervise` probe among them) needs the second.
check("help is a command of its own, answering on stdout with a zero exit",
      statusSource.contains("case \"help\", \"--help\", \"-h\":")
          && statusSource.contains("    print(tallyUsage)\n    exit(0)"))
check("…while a word this binary does not know is still an error on stderr",
      statusSource.contains("default:\n    warn(tallyUsage)\n    exit(2)"))

exit(failures == 0 ? 0 : 1)
