import Foundation

// Rows a private build adds to `tally status --json`. The public build adds none, so its output
// is exactly the sessions supervised on this Mac.
#if !TALLY_OVERLAY
enum OverlayStatus {
    /// Read-only session rows from beyond this Mac, appended after the local ones.
    static func extraSessions(now: Date) -> [StatusReport.Session] { [] }
}
#endif
