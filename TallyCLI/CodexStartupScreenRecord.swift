import Foundation

// Its own file, with nothing to depend on, because three readers compile it: the supervisor that
// writes it (SessionState.swift), the panel that reads it (the app target), and `status --json`
// (StatusReport.swift), whose test suites compile the report without the session record.

/// What a supervised Codex publishes about a launch stuck before its prompt: the screen's name, the
/// update menu's rows (only that screen's), the id `tally session skip-update` must quote, and since when.
struct CodexStartupScreenRecord: Codable, Equatable, Sendable {
    var title: String?
    var lines: [String]?
    var screenID: String?
    var since: Date
}
