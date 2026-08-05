import Foundation

// Assertions for the token activity heatmap's arithmetic (Tally/Core/TokenStats/
// TokenActivityHeatmap.swift): the grid a year of day integers folds into, and the levels the
// squares are tinted by. Both are invisible to the compiler and to a screenshot taken on one day.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func section(_ title: String) { print("\n\(title)") }

/// Foundation's own answer for "which weekday is this day integer", used as the independent oracle
/// the grid arithmetic is checked against.
func foundationWeekday(day: Int) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
    // Calendar counts Sunday as 1; the grid counts Monday as 0.
    return (calendar.component(.weekday, from: date) + 5) % 7
}

// MARK: Weekday mapping

section("weekday index (Monday first)")

check(TokenActivityHeatmap.weekdayIndex(0) == 3, "1970-01-01 is a Thursday (index 3)")

var weekdayMismatch = 0
// A whole year of days, so a mapping that is right for one week and drifts is caught.
for day in 20_600 ..< 20_966 where TokenActivityHeatmap.weekdayIndex(day) != foundationWeekday(day: day) {
    weekdayMismatch += 1
}
check(weekdayMismatch == 0, "366 consecutive days agree with Calendar's own weekday")
check(TokenActivityHeatmap.weekdayIndex(-1) == 2, "the day before the epoch is a Wednesday (index 2)")

// MARK: Grid

section("grid window")

// A Wednesday: 2026-08-05 is day 20_670, which the oracle above confirms.
let today = 20_670
check(foundationWeekday(day: today) == 2, "the fixture day is a Wednesday")

let cells = TokenActivityHeatmap.cells(dailyTotals: [:], today: today)
let expectedCount = TokenActivityHeatmap.weekColumns * TokenActivityHeatmap.weekdays
    - (TokenActivityHeatmap.weekdays - 1 - TokenActivityHeatmap.weekdayIndex(today))
check(cells.count == expectedCount, "the grid is 53 full weeks less the days after today (\(expectedCount))")
check(cells.last?.day == today, "the last square is today")
check(cells.last?.column == TokenActivityHeatmap.weekColumns - 1, "today sits in the last column")
check(cells.last?.row == TokenActivityHeatmap.weekdayIndex(today), "today sits on its own weekday row")
check(cells.first?.day == TokenActivityHeatmap.windowStart(today: today), "the first square is the window start")
check(cells.first?.row == 0, "the window starts on a Monday row")
check(foundationWeekday(day: TokenActivityHeatmap.windowStart(today: today)) == 0,
      "Calendar agrees the window starts on a Monday")
check(today - TokenActivityHeatmap.windowStart(today: today) >= 365,
      "the window covers at least a full year")

let days = cells.map(\.day)
check(!days.isEmpty && days == Array(days.first! ... days.last!),
      "every day in the window appears exactly once, in order")
check(cells.allSatisfy { $0.day == TokenActivityHeatmap.windowStart(today: today)
                                   + $0.column * 7 + $0.row },
      "column and row always reconstruct the day (the hover reverse-mapping's premise)")
check(cells.indices.allSatisfy { cells[$0].column * 7 + cells[$0].row == $0 },
      "a square's position IS its index, which is how the hover looks it up")

// Every weekday of a week lands on the grid, and the same weekday always lands on the same row -
// what a heatmap read column-by-column depends on.
for offset in 0 ..< 7 {
    let day = today - offset
    guard let cell = cells.first(where: { $0.day == day }) else {
        check(false, "day \(day) is on the grid"); continue
    }
    check(cell.row == foundationWeekday(day: day), "day \(day) sits on Calendar's own row")
}

// MARK: Levels

section("levels")

let empty = TokenActivityHeatmap.thresholds([])
check(TokenActivityHeatmap.level(for: 0, thresholds: empty) == 0, "a day with nothing on it is level 0")

let skewed: [Int64] = [1, 2, 3, 4, 10, 20, 30, 400, 5_000, 900_000, 40_000_000, 3_000_000_000]
let bounds = TokenActivityHeatmap.thresholds(skewed)
check(bounds.count == 3 && bounds[0] <= bounds[1] && bounds[1] <= bounds[2], "the cuts are ordered")
let levels = skewed.map { TokenActivityHeatmap.level(for: $0, thresholds: bounds) }
check(Set(levels) == [1, 2, 3, 4], "a right-skewed year uses all four levels")
check(levels == levels.sorted(), "a bigger day is never a paler square")
check(TokenActivityHeatmap.level(for: 3_000_000_000, thresholds: bounds) == 4, "the heaviest day is level 4")
check(TokenActivityHeatmap.level(for: 1, thresholds: bounds) == 1, "the lightest day is level 1")

let flat = TokenActivityHeatmap.thresholds([500, 500, 500, 500])
check(TokenActivityHeatmap.level(for: 500, thresholds: flat) == 1, "a flat year is all level 1, not level 0")

// The scale is the drawn window's, so history older than the grid cannot flatten it: the same
// window must come out identically whether or not a monstrous day sits behind it.
let ancient = TokenActivityHeatmap.windowStart(today: today) - 40
let window: [Int: Int64] = [today: 100, today - 1: 10, today - 2: 1, today - 3: 1_000]
let scaled = TokenActivityHeatmap.cells(dailyTotals: window, today: today)
let haunted = TokenActivityHeatmap.cells(dailyTotals: window.merging([ancient: 9_000_000_000]) { a, _ in a },
                                         today: today)
check(scaled == haunted, "an out-of-window monster does not set the scale")
check(scaled.first(where: { $0.day == today - 3 })?.level == 4, "the window's own heaviest day is level 4")
check(scaled.first(where: { $0.day == today })?.level ?? 0 > 1, "the window's second heaviest is above level 1")
check(haunted.first(where: { $0.day == ancient }) == nil, "days older than the window are not drawn")
// The same index invariant on a grid that HAS data, so a build that only kept the busy days would
// be caught here as well as by the empty-grid count above.
check(scaled.indices.allSatisfy { scaled[$0].column * 7 + scaled[$0].row == $0 },
      "a populated grid stays dense too (empty days are drawn, not skipped)")

// MARK: Caption total

section("window total")

let totals: [Int: Int64] = [ancient: 777, TokenActivityHeatmap.windowStart(today: today): 3,
                            today: 4, today + 1: 999]
check(TokenActivityHeatmap.windowTotal(dailyTotals: totals, today: today) == 7,
      "the caption counts the drawn window only, neither older history nor a future day")

// MARK: Day to date

section("day to date")

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(secondsFromGMT: 0)!
let parts = utc.dateComponents([.year, .month, .day], from: TokenActivityHeatmap.date(forDay: today))
check(parts.year == 2026 && parts.month == 8 && parts.day == 5,
      "day \(today) reads back as 2026-08-05 in UTC (the tooltip's date)")

print(failures == 0 ? "\nAll token heatmap tests passed." : "\n\(failures) token heatmap test(s) failed.")
exit(failures == 0 ? 0 : 1)
