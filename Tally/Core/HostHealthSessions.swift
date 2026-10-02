import Foundation

// WHICH SESSION A BUSY PROCESS BELONGS TO, for the load alarm's culprit list (B-693, 2026-10-02:
// a banner naming `node 104% (geo)` could not say which of three geo sessions was burning it).
//
// PURE, the split HostHealthLogic.swift keeps: the process table, the environment read and the
// files are handed in as closures by HostHealthReaders.swift, so the order below can be asserted
// against literals. App target only; the CLI never resolves sessions.

/// The variable every supervisor stamps its own pid into for the child it spawns
/// (TallyCLI/SupervisorRuntime.swift), inherited by everything that child starts.
let hostHealthSupervisorEnvKey = "TALLY_SUPERVISOR_PID"

/// One live session as the alarm needs it: the supervisor pid the board keys its rows by, the
/// Claude Code it spawned, and the account it is on.
struct HostHealthSession: Equatable, Sendable {
    var supervisor: Int32
    var child: Int?
    var accountID: String?
}

/// The supervisor pid a process belongs to, or nil. Three witnesses in order, first answer wins:
/// the parent chain (the process is still in a session's tree), the inherited environment marker
/// (its starting shell has gone and it was re-parented to launchd), and the process-group ledger
/// (the marker could not be read). Each answer must name a supervisor in `supervisors`.
func hostHealthSessionOwner(of pid: Int32, supervisors: Set<Int32>,
                            parent: (Int32) -> Int32?,
                            marker: (Int32) -> Int32?,
                            ledger: (Int32) -> Int32?) -> Int32? {
    var cursor = pid
    var seen: Set<Int32> = []
    while cursor > 1, seen.insert(cursor).inserted {
        if supervisors.contains(cursor) { return cursor }
        guard let up = parent(cursor) else { break }
        cursor = up
    }
    if let marked = marker(pid), supervisors.contains(marked) { return marked }
    if let claimed = ledger(pid), supervisors.contains(claimed) { return claimed }
    return nil
}

/// The Claude config home an account id names (`claude:.claude5` -> `<home>/.claude5`), or nil
/// for any other provider and for anything that is not one folder directly under the home.
func hostHealthClaudeConfigHome(accountID: String?, home: String) -> String? {
    let prefix = "claude:"
    guard let accountID, accountID.hasPrefix(prefix) else { return nil }
    let folder = accountID.dropFirst(prefix.count)
    guard folder.hasPrefix(".claude"), !folder.contains("/") else { return nil }
    return home + "/" + folder
}

/// The name Claude Code gave a session (`geo-12`) out of its registry record
/// (`<config home>/sessions/<pid>.json`), or nil when the record is unreadable, names another
/// pid, or carries no name. Same pid check `readClaudeRegistry` makes (TallyCLI/UserNotice.swift).
func hostHealthRegistryName(_ data: Data, childPid: Int) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (object["pid"] as? Int) == childPid,
          let name = object["name"] as? String, !name.isEmpty else { return nil }
    return name
}
