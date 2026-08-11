import Foundation

// How a `tally switch` reaches ONE running session: the request file it writes, the documents a
// supervisor publishes so it can be found, and whether that supervisor will read one at all. The
// decision a supervisor then makes about that request, and the command that writes it, live next
// door in SessionSwitch.swift; this side is what the CLI, the supervisor and the state-directory
// sweep all have to agree on (the same division ReloadRequest.swift keeps from Reload.swift).
//
// WHICH session a command belongs to is next door again, in SessionAddressing.swift: the lookup, the
// trust rule a second-hand marker is weighed by, and the witnesses that narrow it. It was carved out
// of this file rather than written apart from it, so the reasoning there is this file's own history.
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
    /// The conversation this was typed into, as Claude Code itself reported it, or nil when the
    /// surface that wrote it had no such report (a person's own shell). What it is FOR, and why a
    /// request has to carry it at all, is RequestTranscript.swift.
    ///
    /// A `var` with a default so the memberwise initialiser keeps working unchanged, which is the
    /// same additivity the file format below promises the other way round.
    var transcriptID: String?

    /// This request releases the session pin rather than naming somewhere to go.
    var isUnpin: Bool { accountID == switchAutoRequest }
}

/// Parse the file body: the stamp on line 1, the account id on line 2, the conversation it was typed
/// into on line 3 (empty, or absent altogether, meaning "nothing can say"). Pure, so the format is
/// testable without a home directory. Anything unparseable is nil - no request - rather than a
/// partial one: a truncated write must never read as a switch to an account nobody named.
///
/// LINE 3 IS ADDITIVE IN BOTH DIRECTIONS, which is the whole of its compatibility story: a file
/// written before it existed simply has no third line and parses exactly as it always did, and a
/// supervisor from such a build reads lines 1 and 2 of a new file and ignores what follows. An
/// unusable value (one that could not name a transcript, `isTranscriptSessionID`) reads as ABSENT
/// rather than as a broken request: it says nothing about the account, which is the instruction.
func parseSwitchRequest(_ raw: String) -> SwitchRequest? {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let epoch = lines.first.flatMap({ Int($0) }),
          let accountID = lines.dropFirst().first, !accountID.isEmpty else { return nil }
    let transcript = lines.dropFirst(2).first.flatMap { isTranscriptSessionID($0) ? $0 : nil }
    return SwitchRequest(epoch: epoch, accountID: accountID, transcriptID: transcript)
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
///
/// The third line is written even when there is nothing to put on it, the way the model request
/// writes its own unnamed effort: one shape on disk is one shape to read back, and a reader old
/// enough to know only the first two lines is unaffected either way.
func writeSwitchRequest(accountID: String, sessionKey: String, transcriptID: String? = nil,
                        now: Date = Date(), dir: URL = switchRequestDir) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = "\(Int(now.timeIntervalSince1970 * 1000))\n\(accountID)\n"
        + "\(transcriptRequestLine(transcriptID))\n"
    try body.write(to: switchRequestFile(sessionKey: sessionKey, dir: dir), atomically: true,
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
/// Named for the SESSION rather than for the switch, and the directory is a required argument, so
/// every per-session request directory sweeps through this one loop: `tally model` writes into its
/// own (ModelRequest.swift) under the same naming rule, and a second copy of this loop would be a
/// second answer to "is that pid still alive".
///
/// Its own function rather than `sweepDeadSupervisorState` pointed at these directories, though the
/// two loops look alike: that one reads names through `supervisorStatePid`, which accepts the
/// suffixed documents the state directory holds, and NOTHING here is ever suffixed. Sharing it would
/// make these directories' naming contract the other one's, so a document added there could start
/// being deleted from here.
func sweepDeadSessionRequests(dir: URL) {
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

/// The suffix of the file naming the Claude Code a supervisor is running.
let supervisorChildSuffix = ".child"

func supervisorChildFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + supervisorChildSuffix)
}

/// Publish the pid of the Claude Code this supervisor just spawned.
///
/// A FILE OF ITS OWN, beside the directory this supervisor runs in and for the same reason: it is
/// known at spawn and it is true from that instant, where the context reading next door does not
/// exist until the conversation has had a turn with usage in it (`SessionContextWriter.sync`
/// returns on a nil token count, deliberately - inventing a number nobody measured would be worse
/// than silence). Riding this witness on that document made it arrive LATE, and a bare
/// `/tally-model` typed as the first thing in a fresh session is the single commonest way to reach
/// this feature: the witness has to be there before the first turn, not after it (codex review of
/// 49dcdcd). It also has to be replaced at a relaunch, which is why it is written at the spawn
/// rather than once at start-up.
///
/// Best-effort like everything else on this track: failing to write it costs the fallback witnesses,
/// never the session.
func writeSupervisorChild(_ child: pid_t, pid: String, dir: URL = supervisorStateDir) {
    let file = supervisorChildFile(pid: pid, dir: dir)
    // TAKEN AWAY FIRST, and the order is the guard. A publish that fails at a relaunch (a full
    // disk, a permission that changed under us) used to leave the PREVIOUS child's pid in place,
    // and a stale pid here is worse than no pid at all: it reads as a confident "not this session",
    // which removes the only real candidate and skips the fallbacks with it - so every `/tally-*`
    // in that session fails until it restarts (codex review of bc606c4). Removing first turns that
    // failure into an ABSENT file, which every witness reads as "cannot say" and passes on.
    try? FileManager.default.removeItem(at: file)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? String(child).write(to: file, atomically: true, encoding: .utf8)
}

/// The parent of a live process, straight from the kernel: the one field of `processIdentity`
/// (TranscriptIdentity.swift, which states why this is a `sysctl` and not the `ps` table next door)
/// that this track asks for. nil when the pid is gone or cannot be asked about.
func parentProcessID(_ pid: pid_t) -> pid_t? { processIdentity(pid)?.parent }

/// The Claude Code that supervisor is running, or nil when there is no answer to be had.
///
/// TWO THINGS ARE CHECKED, and neither is the file's contents. A publish that fails leaves the
/// previous child's pid behind (the removal above narrows that, and a directory which has become
/// unwritable defeats both halves of it), so the value on disk cannot be taken as a fact:
///
///   - THE PROCESS MUST BE RUNNING. A relaunch terminates the old child before spawning the new
///     one, so a stale value names a process that has exited - and reading it as a fact is exactly
///     the failure this guard exists to prevent: it makes the one real candidate look "provably not
///     it", removing it and skipping the fallbacks behind it.
///   - AND IT MUST BE THIS SUPERVISOR'S OWN CHILD. Liveness alone is not enough, because pids are
///     reused: the OS can hand a stale pid to something else entirely, and that process is alive.
///     The child is spawned directly by the supervisor (`spawnChild`, posix_spawnp), so its parent
///     IS the supervisor, and a reused pid would have to land under the very same parent to fool
///     this. Nothing sweeps the residue for us - the sweep is keyed on the SUPERVISOR's pid, and a
///     supervisor that is still alive keeps its own stale `.child` file forever (a claim to the
///     contrary stood in this comment until codex read it, 3c0635a) - so this check is the whole
///     defence rather than a narrowing of one.
func readSupervisorChild(pid: String, dir: URL = supervisorStateDir) -> Int? {
    guard let raw = try? String(contentsOf: supervisorChildFile(pid: pid, dir: dir),
                                encoding: .utf8),
          let child = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let running = pid_t(exactly: child), supervisorAlive(running),
          let supervisor = pid_t(pid), parentProcessID(running) == supervisor else { return nil }
    return child
}

/// One line a supervisor published beside its presence entry, or nil when there is none - and when
/// there is an empty one, which reads the same way: a write that got as far as the file and no
/// further said nothing.
private func supervisorStateLine(_ file: URL) -> String? {
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
}

func readSupervisorCwd(pid: String, dir: URL = supervisorStateDir) -> String? {
    supervisorStateLine(supervisorCwdFile(pid: pid, dir: dir))
}

/// The suffix of the file naming the account a supervisor spawned its child on.
let supervisorAccountSuffix = ".account"

func supervisorAccountFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + supervisorAccountSuffix)
}

/// Publish the account this supervisor just launched its child on.
///
/// THE SAME REASON THE CHILD PID IS A FILE OF ITS OWN, one question over: it is known at the spawn
/// and true from that instant, where the context reading next door does not exist until the
/// conversation has had a turn with usage in it. A roster built from the reading alone therefore
/// omits every session that has not answered yet, which is exactly the session somebody is looking
/// for when they ask what is running (codex review of d2d620e). Written at each spawn rather than
/// once at start-up, so a handoff republishes the account its next child actually runs on.
///
/// IT CANNOT CONTRADICT THE READING, which is what keeps two documents from becoming two answers:
/// a handoff writes both (this at the spawn, `SessionContextWriter.accountChanged` beside it), and
/// the only moment they differ is the one where the reading does not exist at all. So a reader
/// prefers this and falls back to the reading, which is all an older supervisor published.
///
/// Best-effort like everything else on this track: failing to write it costs the entry's account,
/// never the session.
func writeSupervisorAccount(_ accountID: String, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? accountID.write(to: supervisorAccountFile(pid: pid, dir: dir), atomically: true,
                         encoding: .utf8)
}

/// The account that supervisor's child was launched on, or nil when nothing was published (a
/// supervisor from a build before this file existed, which reads as "cannot say" rather than as "no
/// account").
func readSupervisorAccount(pid: String, dir: URL = supervisorStateDir) -> String? {
    supervisorStateLine(supervisorAccountFile(pid: pid, dir: dir))
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
/// It exists because the failure it prevents is SILENT. A supervisor from a build without a given
/// feature registers, stamps its pid, and polls nothing for it: the request would be written, read
/// by nobody, and the session would sit as it was while the command reported success.
///
/// Named for the REQUEST rather than for the switch, because the question is about the supervisor
/// and not about the axis: `tally model` writes into a directory of its own and asks exactly this
/// before it does (ModelCommand.swift). A second copy would be a second answer to "is that
/// supervisor new enough".
enum RequestHonourability: Equatable {
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
func requestHonourability(supervisorVersion: String?, installedVersion: String?)
    -> RequestHonourability {
    switch supervisionStatus(steered: true, supervised: true, supervisorVersion: supervisorVersion,
                             installedVersion: installedVersion) {
    case .unknown: return .tooOld
    case .outdated: return .afterSelfUpdate
    case .ok, .notSteered, .notSupervised: return .honoured
    }
}

/// The same question asked of the live world, which is what every command that writes a request has
/// to ask before it writes one (`attemptSwitch`, `attemptModel`).
///
/// `marker` is the session marker the caller already read for the lookup. It is asked ONLY when the
/// session named ITSELF: the environment carries that session's supervisor build, and a session
/// found through the directory fallback carries nothing to compare, so there is no version there to
/// judge and the request is written on the assumption that it will be read.
func liveRequestHonourability(marker: String?) -> RequestHonourability {
    guard marker != nil else { return .honoured }
    return requestHonourability(
        supervisorVersion: ProcessInfo.processInfo.environment["TALLY_SUPERVISOR_VERSION"],
        installedVersion: supervisorBuildVersion())
}
