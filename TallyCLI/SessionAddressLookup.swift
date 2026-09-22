import Foundation

// WHICH SESSION AN ADDRESS NAMES, for every verb that takes one.
//
// A file of its own rather than more of SessionAddressing.swift, and the seam is a dependency
// rather than a taste: that file is compiled by suites that know nothing about `SessionSendIntent`
// or the roster behind `namedSession`, and this lookup needs both.

/// The session an address names, or why it names none.
///
/// THE ONE ADDRESSING EVERY VERB TAKES. `tally type` types into the session this finds and `tally
/// message` writes a native message to it (MessageVerb.swift); the day the two resolved an address
/// differently would be the day two commands written the same way reached two conversations. The
/// refusals are worded here once, for that same reason.
enum SessionAddressed: Equatable {
    /// The supervisor pid this address names.
    case session(String)
    /// A live monitored Codex supervisor that cannot prove a direct terminal target. Named apart
    /// from a refusal because what a caller is told about it depends on what it was asking that
    /// session to do.
    case monitoringOnly(String)
    /// Nothing was addressed, in the wording the caller prints.
    case refused(String)
}

/// Which session `--session <pid>`, or this command's own descent, names.
///
/// `--project` IS NOT ASKED HERE, which is the order both callers keep: a directory becomes a pid
/// before this is reached (`resolveSessionProject`), so what arrives is a pid or nothing at all.
func addressedSessionKey(_ intent: SessionSendIntent,
                         marker: SessionMarkerTrust) -> SessionAddressed {
    if let named = intent.session {
        switch namedSession(named) {
        case .session(let key):
            return .session(key)
        case .monitoringOnly(let key):
            return .monitoringOnly(key)
        case .notRunning:
            return .refused("no supervisor is running as pid \(named). `tally status --json` lists "
                + "the sessions this machine is supervising")
        case .notSupervised:
            // Named apart from the case above because the two want different things done: one is a
            // pid that has gone, the other is a live process this machine never supervised, and
            // writing a request to the second would leave somebody's text in a file addressed to a
            // stranger.
            return .refused("pid \(named) is running, but it is not a session this machine "
                + "supervises, so nothing there would ever read the request. `tally status --json` "
                + "lists the ones that would; a session supervised by a build too old to register "
                + "is refused here too, and one restart (exit, then `tally claude`) is what fixes "
                + "that")
        }
    }
    switch marker.resolve(here: supervisorsInDirectory(FileManager.default.currentDirectoryPath)) {
    case .session(let key):
        return .session(key)
    case .none:
        return .refused("this session is not supervised, so nothing here can send into it: it was "
            + "launched bare, with --no-handoff, or with an --account pin. Sessions started with "
            + "`tally claude` can be typed into.")
    case .ambiguous(let pids):
        return .refused("\(pids.count) supervised sessions are running in this directory, so this "
            + "command cannot tell which one you mean (pids \(pids.joined(separator: ", "))). Run "
            + "it inside the session you mean, or name it with --session <pid>.")
    }
}
