import Foundation

/// Whether one usage window's held-over figure has been overtaken by that window's own reset.
///
/// THE ONE JUDGE for "this percentage was read before a reset that has already happened". Every
/// surface that draws a window asks it through a thin wrapper (`AccountUsage.resetPassed` in the
/// app, `Snapshot.Account.windowResetPassed` in the CLI), and both targets compile this file
/// (project.yml), so the panel, the menu bar and `tally status` cannot disagree about one row.
///
/// ONLY A HELD-OVER ROW QUALIFIES. A row whose latest poll landed is at most one poll old, and its
/// reset label already reads "resetting…" until the next read lands. A held-over row can sit hours
/// past its reset: on 2026-09-28 a five-hour window read 0% left seventy minutes after it had
/// refilled, because every poll since had failed, and the owner read it as a spent quota.
///
/// The time bound matches `ProbeCadence.resetPassed`: the reset lies strictly after the reading
/// and at or before now. `refreshedAt` nil is a snapshot from an app that predates the stamp; the
/// reading time is then unknown, and a held-over figure past its reset is treated as overtaken,
/// because a display that cannot vouch for a number should show it as unknown.
enum HeldOverReset {
    static func passed(resetsAt: Date?, refreshedAt: Date?, heldOver: Bool, now: Date) -> Bool {
        guard heldOver, let resetsAt, resetsAt <= now else { return false }
        guard let refreshedAt else { return true }
        return resetsAt > refreshedAt
    }
}
