import Foundation

/// The arithmetic behind a project's activity heatmap: which day lands in which square, and how
/// dark that square is.
///
/// Kept out of the view, and covered by `tests/run-tokenheatmap-tests.sh`, because both halves are
/// the kind of thing that is wrong on screen while everything still builds. The weekday of a day
/// integer is not obvious (samples carry local days since 1970-01-01, and 1970-01-01 was a
/// Thursday), and the level boundaries are the difference between a graph that reads and one
/// uniform wash.
enum TokenActivityHeatmap {
    /// Week columns drawn, the current week last. 53 rather than 52 because a year is 52 weeks plus
    /// a day or two, so 52 columns would cut days off the far end of "the past year".
    static let weekColumns = 53
    static let weekdays = 7

    /// How much accent colour each level carries. Four steps above the empty track, the same count
    /// GitHub's graph uses: fewer loses the difference between a normal day and a heavy one, more
    /// than four is not distinguishable at this size.
    static let levelOpacity: [Double] = [0.25, 0.45, 0.7, 1.0]

    /// One square: the day it stands for, where it sits, and how heavy it was.
    struct Cell: Sendable, Equatable {
        let day: Int
        let column: Int
        let row: Int
        let total: Int64
        /// 0 for a day with nothing on it, 1...4 by quartile of this project's own active days.
        let level: Int
    }

    /// Monday-first weekday index (0 = Monday), matching Jetto's activity graph. Day 0 was a
    /// Thursday, so +3 rotates the epoch onto a Monday; the second modulo keeps negative day
    /// numbers (a machine whose clock predates the epoch) from indexing backwards.
    static func weekdayIndex(_ day: Int) -> Int { ((day + 3) % 7 + 7) % 7 }

    /// The first day the grid covers: the Monday of the leftmost column.
    static func windowStart(today: Int) -> Int {
        today - weekdayIndex(today) - (weekColumns - 1) * weekdays
    }

    /// Every square of the grid, in column-major order. The days after today in the current week
    /// are left out rather than drawn empty: an empty square means "nothing happened", and a future
    /// Saturday has not had its chance yet.
    static func cells(dailyTotals: [Int: Int64], today: Int) -> [Cell] {
        let start = windowStart(today: today)
        // The scale comes from the days on screen only. A project that once had a monstrous week
        // and then went quiet must not spend the rest of the year at level one because of a square
        // nobody can see.
        let bounds = thresholds(dailyTotals.filter { $0.key >= start && $0.key <= today
                                                     && $0.value > 0 }.map(\.value))
        var cells: [Cell] = []
        cells.reserveCapacity(weekColumns * weekdays)
        for column in 0 ..< weekColumns {
            let monday = start + column * weekdays
            for row in 0 ..< weekdays where monday + row <= today {
                let day = monday + row
                let total = dailyTotals[day] ?? 0
                cells.append(Cell(day: day, column: column, row: row, total: total,
                                  level: level(for: total, thresholds: bounds)))
            }
        }
        return cells
    }

    /// The p25 / p50 / p75 cuts of this project's own active days.
    ///
    /// Quartiles rather than a linear ramp because the corpus is extremely right skewed: cache
    /// reads make one agent-heavy day worth a hundred ordinary ones, and a linear scale on that
    /// paints a single bright square in a year of grey. Per project rather than one scale for the
    /// whole table, because the projects themselves differ by two or three orders of magnitude and
    /// a shared scale would leave every small project flat at level one for a year.
    static func thresholds(_ values: [Int64]) -> [Int64] {
        guard !values.isEmpty else { return [0, 0, 0] }
        let sorted = values.sorted()
        return [0.25, 0.5, 0.75].map { quantile in
            let index = Int((Double(sorted.count - 1) * quantile).rounded())
            return sorted[min(max(index, 0), sorted.count - 1)]
        }
    }

    /// Which of the four steps a day belongs to, 0 for a day with nothing on it.
    ///
    /// A project whose days are all the same size lands entirely on the first step, because every
    /// cut sits on that one value and nothing here can call any of those days heavy. That reads
    /// correctly: a flat year IS flat, and level one is still plainly darker than an empty day.
    static func level(for total: Int64, thresholds: [Int64]) -> Int {
        guard total > 0 else { return 0 }
        guard thresholds.count == 3 else { return levelOpacity.count }
        if total <= thresholds[0] { return 1 }
        if total <= thresholds[1] { return 2 }
        if total <= thresholds[2] { return 3 }
        return 4
    }

    /// What the caption states: the tokens inside the drawn window, not the project's whole history.
    /// The row above the graph is a range total and this one is a year, so the two figures disagree
    /// by design and the caption is what keeps that from reading as a bug.
    static func windowTotal(dailyTotals: [Int: Int64], today: Int) -> Int64 {
        let start = windowStart(today: today)
        return dailyTotals.reduce(Int64(0)) { sum, entry in
            (entry.key >= start && entry.key <= today) ? sum + entry.value : sum
        }
    }

    /// The instant a day integer names: midnight UTC of that calendar date.
    ///
    /// Every caller formats it in UTC (see `TokenActivityHeatmapView`), because the integer already
    /// IS a local calendar day. Reading the same instant back in the local zone would name the day
    /// before it everywhere west of Greenwich.
    static func date(forDay day: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
    }
}
