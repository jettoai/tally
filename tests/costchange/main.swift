import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "PASS: " : "FAIL: ") + name)
    if !ok { failures += 1 }
}

// 1. The cap: a percentage past 999 reads ">999%" with its direction sign, the rest is untouched.
check(CostChange.percentLabel(999) == "+999%", "999% is shown as is")
check(CostChange.percentLabel(1000) == "+>999%", "1000% is capped")
check(CostChange.percentLabel(65482) == "+>999%", "the B-2039 figure is capped")
check(CostChange.percentLabel(0) == "+0%", "zero keeps its sign")
check(CostChange.percentLabel(-37) == "-37%", "a drop is not capped or reworded")

// 2. Coverage: the previous window of N days ending today starts at today - (2N - 1); the scan
// has to reach that day, and the window has to hold a real share of the current spend.
// B-2039: 30D, previous window at 1.5% of the current spend, so not covered.
let today = 20_000
func covered(_ oldest: Int?, _ days: Int?, prev: Double = 50, cur: Double = 100) -> Bool {
    CostChange.previousWindowCovered(oldestDay: oldest, today: today, dayCount: days, previous: prev, current: cur)
}
check(!covered(today - 30, 30), "30D with a 30-day-old scan is incomplete")
check(!covered(today - 58, 30), "one day short of the window start is incomplete")
check(covered(today - 59, 30), "oldest on the window start is covered")
check(covered(today - 400, 30), "a long history is covered")
check(covered(today - 30, 7), "7D is covered by the same scan")
check(covered(today - 1, 1), "Today needs only yesterday")
check(!covered(today, 1), "Today with only today's data is incomplete")
check(covered(today - 30, nil, prev: 0, cur: 100), "All has no previous window")
check(covered(nil, 30), "no samples: nothing to flag")
check(!covered(today - 400, 30, prev: 6, cur: 100), "a 6% window is no baseline even with stray old records (B-2039)")
check(covered(today - 400, 30, prev: 10, cur: 100), "10% is the floor, inclusive")
check(covered(today - 400, 30, prev: 0, cur: 0), "nothing spent in either window")
check(!covered(today - 400, 7, prev: 0, cur: 100), "an empty previous week is no baseline")
check(covered(today - 400, 1, prev: 1, cur: 100), "Today after a quiet day still compares")

// 3. Wiring, asserted on the source: the table shows the placeholder when the summary says the
// window is incomplete, and the summary derives that from the Claude samples' oldest day.
func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
let page = read("Tally/Views/CostPage.swift")
let summary = read("Tally/Core/TokenStats/CostSummary.swift")
check(page.contains("guard cost.previousWindowCovered else { return (\"—\", nil) }"), "table gates the figures on previousWindowCovered")
check(summary.contains("CostChange.previousWindowCovered(") && summary.contains("$0.providerID == \"claude\""),
      "summary derives coverage from the Claude samples")
check(summary.contains("CostChange.percentLabel("), "CostFormat.change goes through the cap")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("all passed")
