import Foundation

// How a `tally switch` reaches ONE running session: the request file it writes, and the two ways a
// session can be identified. The decision a supervisor then makes about that request, and the
// command that writes it, live next door in SessionSwitch.swift; this side is the addressing, split
// out because it is what the CLI, the supervisor and the state-directory sweep all have to agree on
// (the same division ReloadRequest.swift keeps from Reload.swift).
//
// A reload speaks to EVERY session through one file. This speaks to one, so the file is named for
// its reader: the supervisor's pid, which that supervisor stamps into its child's environment
// (`TALLY_SUPERVISOR_PID`, Supervisor.swift) and every process the child spawns inherits - the
// agent's own shell included, which is the main path (Claude asked mid-conversation to move
// accounts runs the command itself). A shell opened separately in the project directory carries no
// such marker, and falls back to the registry of live supervisors and the directory each publishes.

// MARK: - The request file

/// One request file per supervised session, named for the supervisor pid that will read it.
/// A directory rather than a single file because these are addressed: two sessions can each have one
/// pending, and neither may read the other's.
let switchRequestDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/switch")

/// The account id that means "no account": `tally switch --auto`, asking the supervisor to drop the
/// session pin a previous switch left behind (SessionSwitch.swift).
///
/// The flag the user types and the token the file carries are ONE string on purpose: the request
/// file is the only channel between the command and the supervisor, so a second spelling would be a
/// second thing to keep in step for no gain. It cannot collide with a real account: an id is
/// `<provider>:<config-dir name>` (Snapshot.swift), so it always carries a colon and never starts
/// with a dash.
let switchAutoRequest = "--auto"

/// A parsed switch request: when it was made, and the account it names.
struct SwitchRequest: Equatable {
    /// MILLISECONDS since the unix epoch, unlike the reload stamp's seconds. The supervisor acts
    /// only on a stamp strictly newer than the one it has served, and this request is typed by hand
    /// INSIDE the session it moves: "switch to A" and, on seeing the wrong account, "switch to B" a
    /// moment later are one sequence a person really performs, and at second resolution the second
    /// one reads as already served and vanishes silently.
    let epoch: Int
    /// The account id the snapshot lists, not the name that was typed: the CLI resolves the name
    /// against the live fleet at write time (the same rule `tally project set --account` follows),
    /// so a label renamed while the request sat here still moves the session to the right account.
    let accountID: String

    /// This request releases the session pin rather than naming somewhere to go.
    var isUnpin: Bool { accountID == switchAutoRequest }
}

/// Parse the file body: the stamp on line 1, the account id on line 2. Pure, so the format is
/// testable without a home directory. Anything unparseable is nil - no request - rather than a
/// partial one: a truncated write must never read as a switch to an account nobody named.
func parseSwitchRequest(_ raw: String) -> SwitchRequest? {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let epoch = lines.first.flatMap({ Int($0) }),
          let accountID = lines.dropFirst().first, !accountID.isEmpty else { return nil }
    return SwitchRequest(epoch: epoch, accountID: accountID)
}

func switchRequestFile(sessionKey: String, dir: URL = switchRequestDir) -> URL {
    dir.appendingPathComponent(sessionKey)
}

/// This session's pending request, or nil when there is none (or it cannot be read).
func readSwitchRequest(sessionKey: String, dir: URL = switchRequestDir) -> SwitchRequest? {
    guard let raw = try? String(contentsOf: switchRequestFile(sessionKey: sessionKey, dir: dir),
                                encoding: .utf8) else { return nil }
    return parseSwitchRequest(raw)
}

/// Stamp a request for one session. Atomic (Foundation writes temp + rename), so a supervisor
/// polling mid-write reads either the previous request or this one, never half of either.
func writeSwitchRequest(accountID: String, sessionKey: String, now: Date = Date(),
                        dir: URL = switchRequestDir) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "\(Int(now.timeIntervalSince1970 * 1000))\n\(accountID)\n"
        .write(to: switchRequestFile(sessionKey: sessionKey, dir: dir), atomically: true,
               encoding: .utf8)
}

/// The request is served (or found to be about nothing): unlink it. The served stamp in memory is
/// what makes the decision idempotent; this only keeps the directory from collecting husks.
func clearSwitchRequest(sessionKey: String, dir: URL = switchRequestDir) {
    try? FileManager.default.removeItem(at: switchRequestFile(sessionKey: sessionKey, dir: dir))
}

/// Drop requests addressed to supervisors that are gone: a session can exit with one still pending
/// (it was queued behind a turn that never ended), and the OS reuses pids. Swept by the CLI as it
/// writes, which is the only moment anything here grows.
///
/// Its own function rather than `sweepDeadSupervisorState` pointed at this directory, though the
/// two loops look alike: that one reads names through `supervisorStatePid`, which accepts the
/// suffixed documents the state directory holds, and NOTHING here is ever suffixed. Sharing it would
/// make this directory's naming contract the other one's, so a document added there could start
/// being deleted from here.
func sweepDeadSwitchRequests(dir: URL = switchRequestDir) {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    for file in files {
        guard let pid = pid_t(file.lastPathComponent), !supervisorAlive(pid) else { continue }
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - Which session is asking

/// The suffix under which a supervisor publishes the directory its session runs in, beside its
/// presence entry in `supervisorStateDir` (the track the drift badge and the pending notice share).
///
/// It exists only for the fallback below - a shell opened separately in a project directory, with no
/// session marker in its environment. The supervisor's own cwd cannot change while it runs, so this
/// is written once at startup and never again.
let supervisorCwdSuffix = ".cwd"

func supervisorCwdFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + supervisorCwdSuffix)
}

/// Publish this supervisor's working directory. Best-effort, like everything else on this track:
/// failing to write it costs the fallback, never the session.
func writeSupervisorCwd(_ cwd: String, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? realpathString(cwd).write(to: supervisorCwdFile(pid: pid, dir: dir), atomically: true,
                                   encoding: .utf8)
}

func readSupervisorCwd(pid: String, dir: URL = supervisorStateDir) -> String? {
    guard let raw = try? String(contentsOf: supervisorCwdFile(pid: pid, dir: dir), encoding: .utf8)
    else { return nil }
    let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}

/// The live supervisors running in `cwd`, sorted so the answer is stable. Fully resolved on both
/// sides (/tmp -> /private/tmp), which is how the supervisor wrote it.
func supervisorsInDirectory(_ cwd: String, dir: URL = supervisorStateDir) -> [String] {
    let target = realpathString(cwd)
    return liveSupervisorPids(dir: dir)
        .filter { readSupervisorCwd(pid: String($0), dir: dir) == target }
        .map(String.init)
        .sorted()
}

/// Which session a `tally switch` belongs to.
enum SessionLookup: Equatable {
    /// The supervisor pid to address the request to.
    case session(String)
    /// Nothing supervised is running here: an unsupervised launch (`--no-handoff`, an `--account`
    /// pin, a piped run) or a bare `claude`, neither of which anything can move.
    case none
    /// Several sessions share this directory and the command came from outside all of them, so
    /// there is no way to tell which one was meant.
    case ambiguous([String])
}

/// The choice itself, pure. `envPid` is the marker the supervisor stamped into this session's
/// environment, already checked for liveness by the caller; `here` is every live supervisor in this
/// directory. The environment wins whenever it is present, and that is the whole design: it names
/// the session the command was actually run in, while the directory can only ever name candidates.
func sessionLookup(envPid: String?, here: [String]) -> SessionLookup {
    if let envPid { return .session(envPid) }
    if here.count == 1, let only = here.first { return .session(only) }
    return here.isEmpty ? .none : .ambiguous(here)
}

/// The account a supervised session is running on RIGHT NOW, or nil when nothing can say.
///
/// The supervisor publishes it beside its presence entry, rewritten by every handoff
/// (SessionContext.swift), which makes it the only answer that describes the session being asked
/// about rather than the shell doing the asking. It appears once that session has had a turn with a
/// usage reading in it, so a conversation that has not said anything yet has none.
///
/// TWO WITNESSES, and the answer is only given when they do not contradict each other.
///
/// From ANOTHER shell in the project directory there is only one: that shell's own config home
/// describes whatever launched IT, so the published reading is all there is. Its staleness window is
/// stated rather than hidden - from a handoff until the supervisor publishes again, it can name the
/// account the session just left - and the supervisor narrows it by republishing at the relaunch
/// itself (`SessionContextWriter.accountChanged`).
///
/// From INSIDE the session (`isThisSession`) there are two, and each is fresh in a way the other is
/// not. The environment IS that session's, exported when the supervisor spawned the child this shell
/// descends from... unless this shell is OLDER than the last handoff. A long-lived background
/// process started before the move still carries the pre-handoff `CLAUDE_CONFIG_DIR` and still sees
/// a live `TALLY_SUPERVISOR_PID` (the pid does not change when the child does), so on its own the
/// environment would answer "already on A" for a session that has since moved to B - dropping a
/// deliberate "switch back to A" as a no-op. The published file is fresh in the opposite direction:
/// written on a poll tick and at every relaunch, it follows the moves and lags the seconds after
/// one.
///
/// So they are required to AGREE. Agreement means both describe the same account, and either being
/// silent (nothing published yet; a home that matches no account) leaves the other to answer alone.
/// A disagreement is exactly the case where neither can be trusted, and it answers nil.
///
/// nil is not "not there": the caller reads it as "do not decide here", writes the request anyway,
/// and the supervisor settles it against the account the session is really on at that moment (its
/// `alreadyThere` branch consumes the request and restarts nothing).
func sessionAccountID(sessionKey: String, isThisSession: Bool, provider: Provider,
                      accounts: [Snapshot.Account],
                      dir: URL = supervisorStateDir,
                      environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String? {
    let published = readSessionContext(pid: sessionKey, dir: dir)?.accountID
    guard isThisSession else { return published }
    let home = environment[provider.envKey] ?? defaultHome(provider)
    let fromEnvironment = accounts.first { $0.provider == provider.id && $0.launchHome == home }?.id
    guard let fromEnvironment else { return published }
    guard let published else { return fromEnvironment }
    return fromEnvironment == published ? fromEnvironment : nil
}

/// The session marker in this process's environment, or nil when there is none (or its supervisor
/// has died, which a marker inherited by something long-lived could outlive).
func liveSessionMarker(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    guard let value = env["TALLY_SUPERVISOR_PID"], let pid = pid_t(value),
          supervisorAlive(pid) else { return nil }
    return value
}

/// Whether the supervisor watching this session will act on a request at all, judged from the build
/// it stamped into the environment against the installed one - the same two values the status line's
/// supervision note compares (SupervisorRuntime.swift).
///
/// It exists because the failure it prevents is SILENT. A supervisor from a build without this
/// feature registers, stamps its pid, and polls nothing here: the request would be written, read by
/// nobody, and the session would sit where it was while the command reported success.
enum SwitchHonourability: Equatable {
    /// The supervisor is the current build and reads these requests.
    case honoured
    /// A different build, which replaces itself at the next idle moment (since 0.26.0) and reads the
    /// request when it comes back. Worth saying, because that wait is the whole delay.
    case afterSelfUpdate
    /// No version stamp at all: a supervisor too old to self-update, so nothing will ever read it.
    case tooOld
}

/// Read off the status line's own supervision note rather than comparing the two versions again
/// (SupervisorRuntime.swift): what "outdated" means is one rule, and a second copy of it here would
/// be free to drift into telling the user something the badge on their status line denies. Asked
/// only where a live session marker was found, so `steered` and `supervised` are true by
/// construction. `.ok` covers the case with no installed version to compare against (a standalone or
/// dev build of this CLI), which assumes it works rather than asserting a problem it cannot see.
func switchHonourability(supervisorVersion: String?, installedVersion: String?)
    -> SwitchHonourability {
    switch supervisionStatus(steered: true, supervised: true, supervisorVersion: supervisorVersion,
                             installedVersion: installedVersion) {
    case .unknown: return .tooOld
    case .outdated: return .afterSelfUpdate
    case .ok, .notSteered, .notSupervised: return .honoured
    }
}
