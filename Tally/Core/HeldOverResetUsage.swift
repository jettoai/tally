import Foundation

extension AccountUsage {
    /// Whether the numbers on this account are held over from an earlier round. Both flags count:
    /// a figure is exactly as old on the first failed poll as on the second, and the badge's
    /// debounce is about flicker, not about age (`foldLastGood`).
    var numbersHeldOver: Bool { isStale || lastRefreshFailed }

    /// `HeldOverReset.passed` for one of this account's windows. Every app surface that draws a
    /// window's figure asks this rather than comparing dates itself.
    func resetPassed(_ metric: UsageMetric, now: Date = Date()) -> Bool {
        HeldOverReset.passed(resetsAt: metric.resetsAt, refreshedAt: refreshedAt,
                             heldOver: numbersHeldOver, now: now)
    }
}
