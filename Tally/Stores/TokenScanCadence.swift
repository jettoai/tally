import Foundation

/// How often the token scan runs while no surface is open, so `~/.tally/project-cost.json` stays
/// fresh for whoever reads it with the app in the background (`tally cost`, other tools; B-5671).
///
/// It rides the quota poll (`UsageStore.refresh`) rather than a timer of its own, the way the
/// morning schedule and the limit-reset records do: as often as that poll, and never more often
/// than `maxAge`.
///
/// A minute under the slowest poll Settings offers (15 minutes). Due at exactly 15 minutes, a
/// 15-minute poll would find the last scan 14m59s old on every other tick to timer jitter, and the
/// file would go 30 minutes between updates.
enum TokenScanCadence {
    static let maxAge: TimeInterval = 14 * 60

    /// Whether a scan should start now. Never scanned: yes. A start in the future (the clock was
    /// set back) is treated as due, so a clock change cannot hold the file still for the length of
    /// the change.
    static func isDue(lastStart: Date?, now: Date) -> Bool {
        guard let lastStart else { return true }
        return lastStart > now || now.timeIntervalSince(lastStart) >= maxAge
    }
}
