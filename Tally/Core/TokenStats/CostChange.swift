import Foundation

/// The rules behind the Cost table's "vs prev" column, kept free of the Rust core and the
/// localisation bundle so a test can compile them alone.
enum CostChange {
    /// Above this the label reads ">999%": past it the figure measures a near-empty previous
    /// window, not the project.
    static let cap = 999

    /// "+12%" / "-8%", or "+>999%" once the percentage passes `cap`.
    static func percentLabel(_ percent: Int) -> String {
        if percent > cap { return "+>\(cap)%" }
        return percent >= 0 ? "+\(percent)%" : "\(percent)%"
    }

    /// Below this share of the current window's spend, a previous window of a week or more is a
    /// remnant, not a baseline. Measured 2026-10-16: with Claude Code keeping 30 days, the 30D
    /// previous window held about 6% of the current spend (sessions that outlived the cleanup) and
    /// produced "+65482%" rows. Shorter windows are exempt: one quiet day (a Sunday before a
    /// Monday's Today) is a real baseline, not missing history.
    static let minPreviousShare = 0.1
    static let minDaysForShareTest = 7

    /// Whether the previous window holds enough history to compare against. Claude Code deletes
    /// transcripts after 30 days, so on 30D the previous window is mostly gone and any comparison
    /// against its remnant is noise. Two tests, either fails it: the scan's oldest priced record
    /// (`oldestDay`, nil when there is none) must reach the window's start, and (from a week up) the
    /// window must hold at least `minPreviousShare` of the current spend, because sessions that
    /// outlived the cleanup and a few stray old records satisfy the first test while the window is
    /// still nearly empty. `dayCount` is nil for All, which has no previous window and so nothing to
    /// be incomplete.
    static func previousWindowCovered(oldestDay: Int?, today: Int, dayCount: Int?,
                                      previous: Double, current: Double) -> Bool {
        guard let dayCount else { return true }
        if let oldestDay, oldestDay > today - (2 * dayCount - 1) { return false }
        return dayCount < minDaysForShareTest || previous >= current * minPreviousShare
    }
}
