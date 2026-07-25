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

// MARK: - Legacy supervisors (running, but from a build with no reload support)

// A supervisor started before this feature shipped registers nothing and polls no request file, so
// the registry above reports zero while sessions are plainly running (live case: five sessions,
// the oldest up three hours, and the panel said "no supervised sessions are running"). The COUNT is
// right - none of them will restart - but silence about them is a lie, so they are counted
// separately and named in the message.

/// How long a `tally` process must have been alive to be one. The status line shells out to `tally`
/// on every prompt and those live well under a second, so without a floor a passing statusline call
/// reads as a session.
let legacySupervisorMinAge: TimeInterval = 30

/// One live process reduced to what the legacy probe needs.
struct RunningProcess: Equatable {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let startedAt: Date
}

/// Which of `processes` are supervisors from an older build: our own binary's name, old enough to
/// be a session rather than a passing command, parenting some other process in the same scan, and
/// not one of `excluding`, the pids the caller has already accounted for. `currentReloadReadiness`
/// passes its own process and ancestors, since the caller's own `tally` and the shell that launched
/// it are not sessions to restart; it only ever reaches here with an empty registry, a registered
/// supervisor being a current build that was counted before the scan was worth running.
///
/// Requiring a child is what separates a supervisor from `tally worktree` or the worktree picker:
/// both block in a raw-mode read for as long as the user takes to choose, so age alone reads them as
/// sessions, and neither has a child until a session is actually launched. It is matched
/// structurally rather than by name because provider CLIs do not keep theirs: measured 2026-07-25,
/// the claude child reports `2.1.220` (its version, so a different name every release) and a
/// homebrew codex reports `codex-aarch64-apple-darwin`, so a name test would have found none of the
/// eight supervisors then running. Two moments are missed in exchange, both harmless for a count
/// that only feeds a sentence: a supervisor between its child exiting and the replacement spawning,
/// and a menu during the milliseconds it shells out to git.
///
/// Pure, so the filtering is testable without libproc.
func legacySupervisorPids(_ processes: [RunningProcess], excluding: Set<pid_t>, now: Date = Date(),
                          minAge: TimeInterval = legacySupervisorMinAge) -> [pid_t] {
    let parents = Set(processes.map(\.ppid))
    return processes.filter {
        $0.name == "tally" && !excluding.contains($0.pid)
            && now.timeIntervalSince($0.startedAt) >= minAge && parents.contains($0.pid)
    }.map(\.pid)
}

/// How many entries of the pid buffer the scan below may read. `proc_listallpids` returns a COUNT
/// of pids from its second call, NOT the byte count its argument is given in: measured 2026-07-25
/// it returned 1010 against `ps -A`'s 1011 lines, so dividing that by the pid size stopped the scan
/// at 252 and every supervisor past that point was invisible. Clamped to the buffer because
/// processes launched between the sizing call and the fill can push the count past it.
func scannedPidCount(_ returned: Int32, capacity: Int) -> Int {
    returned <= 0 ? 0 : min(Int(returned), capacity)
}

/// Every process this user can inspect, with its parent, accounting name and start time. One
/// proc_pidinfo(PROC_PIDTBSDINFO) per pid carries all three, so the scan is a single pass;
/// processes belonging to another user simply fail that call and drop out, which is the same set
/// the teardown scan can see. `pbi_start_tvsec` is the process start in epoch seconds (verified
/// against `ps -o lstart` on a live supervisor, 2026-07-25).
func listRunningProcesses() -> [RunningProcess] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity))
    let returned = proc_listallpids(&pids, Int32(Int(capacity) * MemoryLayout<pid_t>.size))
    return pids.prefix(scannedPidCount(returned, capacity: pids.count)).compactMap { pid in
        guard pid > 0, let info = processInfo(pid) else { return nil }
        return RunningProcess(pid: pid, ppid: pid_t(info.pbi_ppid),
                              name: processAccountingName(info),
                              startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec)))
    }
}

/// This process's pid plus every ancestor, walked through the same BSD info.
func ancestorChain(of start: pid_t) -> Set<pid_t> {
    var chain: Set<pid_t> = [start]
    var pid = start
    while let info = processInfo(pid), info.pbi_ppid > 0, !chain.contains(pid_t(info.pbi_ppid)) {
        chain.insert(pid_t(info.pbi_ppid))
        pid = pid_t(info.pbi_ppid)
    }
    return chain
}

private func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info
}

/// `pbi_name` when the kernel has it, falling back to the truncated `pbi_comm`. Both are fixed-size
/// C tuples, so they are read as bytes rather than reinterpreted as Swift values, and the read stops
/// at the tuple's own end rather than at a terminator: `String(cString:)` walks until it finds a NUL,
/// which would run off a 17 or 33 byte array that the kernel had filled to its last byte.
private func processAccountingName(_ info: proc_bsdinfo) -> String {
    func string<Tuple>(_ tuple: Tuple) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    let name = string(info.pbi_name)
    return name.isEmpty ? string(info.pbi_comm) : name
}

// MARK: - What a reload can actually do right now

/// What the surfaces (the command, the confirmation, the footer tooltip, the Settings row) must
/// say. One shared answer so none of them can drift into claiming something another denies.
enum ReloadReadiness: Equatable {
    /// Sessions are registered and will act on a request.
    case ready(Int)
    /// Nothing supervised is running at all.
    case nothingRunning
    /// Sessions ARE running, but every one predates this feature: a request would reach none of
    /// them. The count is theirs, and the message has to say what to do about it.
    case legacyOnly(Int)
}

/// Pure selection between the three, so the priority (a registered session outranks a legacy one) is
/// testable. A mixed machine reports the registered count: those sessions really will restart, and
/// the legacy ones are covered by the same "restart it once" advice the next launch gives them.
func reloadReadiness(live: Int, legacy: Int) -> ReloadReadiness {
    if live > 0 { return .ready(live) }
    return legacy > 0 ? .legacyOnly(legacy) : .nothingRunning
}

/// The live answer. Which state it is stays with `reloadReadiness` above; the only thing decided
/// here is what the answer COSTS. The registry is a directory listing, so it is read every time,
/// while the whole-machine process scan runs only when the registry comes back empty, which on an
/// up-to-date machine is also when nothing is running at all.
func currentReloadReadiness(dir: URL = supervisorStateDir, now: Date = Date()) -> ReloadReadiness {
    let live = liveSupervisorPids(dir: dir).count
    let legacy = live > 0 ? 0 : legacySupervisorPids(listRunningProcesses(),
                                                     excluding: ancestorChain(of: getpid()),
                                                     now: now).count
    return reloadReadiness(live: live, legacy: legacy)
}

/// The sentence for `legacyOnly`, in ONE place so the command, the alert, the footer tooltip and the
/// Settings row say the same thing. The app passes `L` to localize it; the CLI takes the English as
/// written. Two sentences by design: what is true, then the single action that fixes it.
func reloadLegacyNotice(_ count: Int, localize: (String) -> String = { $0 }) -> String {
    let format = count == 1
        ? "%d session is running, but it started before this version and cannot reload yet. "
            + "Restart it once (exit, then launch again) and reload works from then on."
        : "%d sessions are running, but they started before this version and cannot reload yet. "
            + "Restart each one once (exit, then launch again) and reload works from then on."
    return String(format: localize(format), count)
}
