import Foundation

/// The arithmetic behind a project's activity heatmap: which day lands in which square, and how
/// dark that square is.
///
/// The arithmetic is the Rust core's (rust/crates/core/src/tokenstats/heatmap.rs); this keeps the
/// Swift types the view draws. Kept out of the view, and covered by
/// `tests/run-tokenheatmap-tests.sh`, because both halves are
/// the kind of thing that is wrong on screen while everything still builds. The weekday of a day
/// integer is not obvious (samples carry local days since 1970-01-01, and 1970-01-01 was a
/// Thursday), and the level boundaries are the difference between a graph that reads and one
/// uniform wash.
enum TokenActivityHeatmap {
    /// Week columns drawn, the current week last. 53 rather than 52 because a year is 52 weeks plus
    /// a day or two, so 52 columns would cut days off the far end of "the past year".
    static let weekColumns = Int(heatmapWeekColumns())
    static let weekdays = Int(heatmapWeekdays())

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
    static func weekdayIndex(_ day: Int) -> Int { Int(heatmapWeekdayIndex(day: Int64(day))) }

    /// The first day the grid covers: the Monday of the leftmost column.
    static func windowStart(today: Int) -> Int {
        Int(heatmapWindowStart(today: Int64(today)))
    }

    /// Every square of the grid, in column-major order. The days after today in the current week
    /// are left out rather than drawn empty: an empty square means "nothing happened", and a future
    /// Saturday has not had its chance yet.
    static func cells(dailyTotals: [Int: Int64], today: Int) -> [Cell] {
        heatmapCells(dailyTotals: rustDays(dailyTotals), today: Int64(today)).map {
            Cell(day: Int($0.day), column: Int($0.column), row: Int($0.row), total: $0.total, level: Int($0.level))
        }
    }

    /// The p25 / p50 / p75 cuts of this project's own active days.
    ///
    /// Quartiles rather than a linear ramp because the corpus is extremely right skewed: cache
    /// reads make one agent-heavy day worth a hundred ordinary ones, and a linear scale on that
    /// paints a single bright square in a year of grey. Per project rather than one scale for the
    /// whole table, because the projects themselves differ by two or three orders of magnitude and
    /// a shared scale would leave every small project flat at level one for a year.
    static func thresholds(_ values: [Int64]) -> [Int64] {
        heatmapThresholds(values: values)
    }

    /// Which of the four steps a day belongs to, 0 for a day with nothing on it.
    ///
    /// A project whose days are all the same size lands entirely on the first step, because every
    /// cut sits on that one value and nothing here can call any of those days heavy. That reads
    /// correctly: a flat year IS flat, and level one is still plainly darker than an empty day.
    static func level(for total: Int64, thresholds: [Int64]) -> Int {
        Int(heatmapLevel(total: total, thresholds: thresholds))
    }

    /// What the caption states: the tokens inside the drawn window, not the project's whole history.
    /// The row above the graph is a range total and this one is a year, so the two figures disagree
    /// by design and the caption is what keeps that from reading as a bug.
    static func windowTotal(dailyTotals: [Int: Int64], today: Int) -> Int64 {
        heatmapWindowTotal(dailyTotals: rustDays(dailyTotals), today: Int64(today))
    }

    private static func rustDays(_ dailyTotals: [Int: Int64]) -> [Int64: Int64] {
        Dictionary(uniqueKeysWithValues: dailyTotals.map { (Int64($0.key), $0.value) })
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
