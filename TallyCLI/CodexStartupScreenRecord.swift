import Foundation

// Its own file, with nothing to depend on, because three readers compile it: the supervisor that
// writes it (SessionState.swift), the panel that reads it (the app target), and `status --json`
// (StatusReport.swift), whose test suites compile the report without the session record.

/// What a supervised Codex publishes about a launch stuck before its prompt: the screen's name, its
/// rows (only for the screens CodexStartupScreen.publishable names), the id `tally session skip-update`
/// must quote, since when, and what that command would choose there.
struct CodexStartupScreenRecord: Codable, Equatable, Sendable {
    var title: String?
    var lines: [String]?
    var screenID: String?
    var since: Date
    /// "Skip", "Use existing model" or "Trust and continue"; nil when Tally does not answer this
    /// screen, so a one-click button belongs only where it is set.
    var answer: String? = nil
}
