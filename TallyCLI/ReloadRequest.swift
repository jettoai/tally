import Darwin
import Foundation

// The reload request file and the live-supervisor registry, shared by BOTH targets: the CLI writes
// the request from `tally reload`, the app writes the same request from its Settings row, and every
// supervisor reads it on its poll tick. Compiled into Tally.app as well as the tally tool (see
// project.yml, the same arrangement UsageAdvisor.swift uses), so it must stay dependency-free -
// no `warn`, no snapshot types, nothing that only exists in one target.

/// The reload request file: line 1 a unix timestamp in seconds, an optional line 2 carrying "now".
let reloadFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/reload")

/// A parsed reload request: when it was made, and which quiet bar it asked supervisors to use.
struct ReloadRequest: Equatable {
    let epoch: Int
    /// `--now`: use the short quiet bar instead of the 120s "left alone" bar.
    let immediate: Bool
}

/// Parse the file body. Pure, so the format is testable without a home directory. An unparseable
/// body is nil (no request) rather than 0: a truncated write must never read as an ancient reload.
func parseReloadRequest(_ raw: String) -> ReloadRequest? {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let epoch = lines.first.flatMap({ Int($0) }) else { return nil }
    return ReloadRequest(epoch: epoch, immediate: lines.dropFirst().contains("now"))
}

/// The current request, or nil when none was ever made (or the file is unreadable).
func readReloadRequest(from file: URL = reloadFile) -> ReloadRequest? {
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return parseReloadRequest(raw)
}

/// Stamp a request. Atomic (Foundation writes temp + rename), so a supervisor polling mid-write
/// reads either the previous request or this one, never half a timestamp. The ONE writer both the
/// `tally reload` command and the app's Settings button go through.
func writeReloadRequest(_ now: Date = Date(), immediate: Bool = false,
                        to file: URL = reloadFile) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try ("\(Int(now.timeIntervalSince1970))\n" + (immediate ? "now\n" : ""))
        .write(to: file, atomically: true, encoding: .utf8)
}

// MARK: - Live supervisor registry

/// Per-supervisor state (~/.tally/supervisor-state/<supervisorPID>). Two jobs in one file: its
/// EXISTENCE says a supervisor with that pid is alive (a reload request counts these to report how
/// many sessions will restart), and its CONTENT carries the drift episode the status line paints as
/// a badge (see DriftMonitor.swift, which owns the writing and sweeping).
let supervisorStateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/supervisor-state")

/// Whether a supervisor pid is still running. A leftover state file from a crashed supervisor must
/// not paint a stale badge or inflate the reload count; EPERM (exists under another uid) counts as
/// alive rather than risk hiding a real one, though our own launches never hit it.
func supervisorAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// The pids of every supervisor alive right now. `dir` is injectable so a test can point it at a
/// temp directory of fake state files. Files not named for a pid are ignored (nothing of ours, or
/// a future format), and a file whose pid the OS has already reused would over-count, which every
/// supervisor's startup sweep keeps to a short window.
func liveSupervisorPids(dir: URL = supervisorStateDir) -> [pid_t] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { pid_t($0.lastPathComponent) }.filter { supervisorAlive($0) }
}

/// How many sessions a reload request will restart.
func liveSupervisorCount(dir: URL = supervisorStateDir) -> Int {
    liveSupervisorPids(dir: dir).count
}
