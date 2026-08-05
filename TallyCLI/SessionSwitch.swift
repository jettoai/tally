import Foundation

// `tally switch <account>` - move THIS conversation onto a named account, and the live pin switch it
// shares a shape with. Both are the same instruction from different surfaces ("run this session over
// there"), so they are decided in one place, in one order, with one rule about what happens when
// they disagree.
//
// The whole feature is assembled from parts that already existed: the request is a file a supervisor
// reads on its poll tick (ReloadRequest.swift's shape), the move is the cap handoff's relaunch with
// a target chosen by hand (`RelaunchPlan`), and the account name is resolved by the matcher
// `tally claude --account` and `tally project set --account` already share (AccountPick.swift). What
// is new is only the addressing: a reload speaks to EVERY session, this speaks to ONE.
//
// The session it speaks to is the one that ran the command. Its supervisor stamps its own pid into
// the child's environment (`TALLY_SUPERVISOR_PID`, Supervisor.swift), and every process the child
// spawns inherits it - the agent's own shell included, which is the point: the main use is Claude
// being asked mid-conversation to move to another account and running `tally switch` itself. A shell
// opened separately in the same directory has no such marker and falls back to the registry.
//
// ONE-SHOT, deliberately. It moves this conversation now and changes nothing else: no pin is
// written, no project profile is touched, and once the session is over there, automatic handoff
// carries on exactly as before (a cap still moves it, a nearly dry account still rebalances it).
// "This project always runs on that account" is a different instruction with a home of its own,
// `tally project set --account`.

// MARK: - The request file

/// One request file per supervised session, named for the supervisor pid that will read it.
/// A directory rather than a single file because these are addressed: two sessions can each have one
/// pending, and neither may read the other's.
let switchRequestDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/switch")

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

func switchHonourability(supervisorVersion: String?, installedVersion: String?)
    -> SwitchHonourability {
    guard let supervisorVersion else { return .tooOld }
    // No installed version to compare against (a standalone or dev build of this CLI): assume it
    // works, exactly as the status line's note does rather than asserting a problem it cannot see.
    guard let installedVersion else { return .honoured }
    return supervisorVersion == installedVersion ? .honoured : .afterSelfUpdate
}

// MARK: - Supervisor-side decision

/// The quiet bar the moves in this file wait for: the short "no turn is streaming" gap
/// `tally reload --now` settles for, rather than the 120s "left alone" bar the preference changes
/// use. The user acted a second ago, so there is nothing to be careful about EXCEPT the turn in
/// flight. It is the bar the pin switch has always used (`isQuiet`'s own default), named here
/// because the switch has to use the same one and a shared bar should be one value, not two 5s.
///
/// And there almost always is one. The command's main caller is the agent inside the session,
/// running it as a tool call, so at the moment the request lands the session is by definition
/// mid-turn - the call itself is an unanswered `tool_use` and `TranscriptWatcher.isQuiet` reports
/// the session busy for exactly that reason (OpenTurn.swift). So the short bar shortens the IDLE
/// WAIT and nothing else: the turn that asked for the switch finishes, the assistant says what it
/// was going to say, and the move happens in the gap after it.
let manualMoveIdleSeconds = reloadNowIdleSeconds

/// What one poll tick does about the switch request it just read.
enum SwitchDecision: Equatable {
    case none          // no request, or one this supervisor has already served
    case gone          // the account it names is no longer listed or has signed out: drop it
    case alreadyThere  // the session is on that account already (a handoff got there first)
    case relaunch      // move now
    case queued        // the session is mid-turn: hold the request until it goes quiet
}

/// Pure decision, so the bookkeeping is testable without a child. A request fires exactly once (it
/// must be strictly newer than the stamp this supervisor captured at startup, which is what stops a
/// leftover file addressed to a REUSED pid from moving an unrelated session), and a busy session
/// holds it rather than losing it.
///
/// ORDER IS PART OF THE CONTRACT: whether the target still exists is asked BEFORE whether the
/// session is quiet. A request naming an account that has signed out is not going to become
/// actionable by waiting, and holding it would leave the file pending for the life of the session.
func switchDecision(served: Int, request: SwitchRequest, targetFound: Bool, onTarget: Bool,
                    isQuiet: Bool) -> SwitchDecision {
    guard request.epoch > served else { return .none }
    guard targetFound else { return .gone }
    if onTarget { return .alreadyThere }
    return isQuiet ? .relaunch : .queued
}

/// What the supervisor remembers about the moves its user has asked for by hand. Held across
/// relaunches, like the recovery fuse and the quarantine.
struct ManualMoveState {
    /// This session's address: the supervisor's own pid, the same key the request file is named for.
    let sessionKey: String
    /// The newest switch stamp this supervisor has served.
    var servedEpoch: Int
    /// The pin this session was moved OFF by hand, so the live pin switch below stops dragging it
    /// back. Scoped to that exact pin: moving the pin somewhere NEW in the panel afterwards is a
    /// fresh instruction and takes effect as it always did.
    var overriddenPin: String?

    /// `servedEpoch` defaults to whatever is pending right now, so a request written before this
    /// supervisor existed is never replayed (the file is addressed by pid, and pids come round
    /// again). A test supplies it directly, and so does the ONE caller for which that default is
    /// wrong: a self-update exec keeps the pid and IS the same session, so a request written
    /// moments before it was written for this conversation and would be swallowed by the seed
    /// (`resumed`, Supervisor.swift).
    init(sessionKey: String, servedEpoch: Int? = nil, dir: URL = switchRequestDir) {
        self.sessionKey = sessionKey
        self.servedEpoch = servedEpoch
            ?? (readSwitchRequest(sessionKey: sessionKey, dir: dir)?.epoch ?? 0)
    }

    func pinOverridden(_ pinnedAccountID: String) -> Bool { pinnedAccountID == overriddenPin }
}

/// The bookkeeping a PLANNED switch owes, carried from the decision to the execution point and
/// written only once the relaunch is certain.
///
/// Recording it while planning is what the unresolved-fork hold turns into a lost request: the tick
/// stands the relaunch down, and a stamp already marked served makes every later tick read the
/// request as one it has handled (StandDown.swift, where a `tally reload` proved it). Nothing here
/// is undone on a stand-down because nothing has been written yet.
struct PendingSwitchConsumption {
    let epoch: Int
    let pinOverride: String?
    let dir: URL

    func commit(_ state: inout ManualMoveState) {
        state.servedEpoch = epoch
        state.overriddenPin = pinOverride
        clearSwitchRequest(sessionKey: state.sessionKey, dir: dir)
    }
}

// MARK: - Poll-loop wiring

/// One poll tick's handling of the moves the user asked for by hand, in priority order: a
/// `tally switch` they just typed, then the pin they moved in the panel. Both are explicit human
/// acts, so neither counts against the recovery fuse, and both outrank every automatic reason to
/// move (cap, degradation, rebalance) by running first - the loop's later planners are all gated on
/// `plan == nil`.
///
/// The switch wins over the pin when they disagree, and keeps winning: it is the newer and the more
/// specific of the two ("move THIS conversation", against "new sessions go there"), and without the
/// override a pinned project would drag the session home on the very next tick, which is the one
/// outcome that would make the command useless to the person most likely to want it.
///
/// `accounts` is a closure because the snapshot read behind it is one most ticks do not need;
/// `request` is one because a default argument cannot name `state.sessionKey`, and the file it
/// reads is what every tick is polling for anyway. Both are also the seam that makes this testable
/// without a home directory or a snapshot.
func applyManualMoves(plan: inout RelaunchPlan?, state: inout ManualMoveState,
                      record: inout PendingSwitchConsumption?,
                      account: Snapshot.Account, providerID: String, policy: LaunchPolicy,
                      watcher: inout TranscriptWatcher, childAge: TimeInterval,
                      keyboardIdle: (TimeInterval) -> Bool,
                      dir: URL = switchRequestDir,
                      request: (String) -> SwitchRequest? = {
                          readSwitchRequest(sessionKey: $0)
                      },
                      accounts: @escaping () -> [Snapshot.Account] = {
                          loadSnapshot().0?.accounts ?? []
                      }) {
    applySwitchRequest(plan: &plan, state: &state, record: &record, account: account,
                       providerID: providerID, policy: policy, watcher: &watcher,
                       childAge: childAge, keyboardIdle: keyboardIdle, dir: dir,
                       request: request(state.sessionKey), accounts: accounts)
    guard plan == nil else { return }
    applyPinSwitch(plan: &plan, state: state, account: account, providerID: providerID,
                   policy: policy, watcher: &watcher, keyboardIdle: keyboardIdle,
                   accounts: accounts)
}

/// The account an id names, when it is one this session could actually be launched on: the right
/// provider, still listed, still logged in. Both moves below ask it of their own target, and a nil
/// means the same thing to each - the instruction has nothing to act on any more.
private func launchableAccount(_ id: String?, provider: String,
                               in accounts: () -> [Snapshot.Account]) -> Snapshot.Account? {
    guard let id else { return nil }
    return accounts().first { $0.id == id && $0.provider == provider && $0.launchHome != nil }
}

/// The `tally switch` half. Consumes nothing on the branch that plans a relaunch (see
/// `PendingSwitchConsumption`); the two branches that plan NOTHING consume immediately, because
/// there is no execution point to hang the bookkeeping on and a request about a vanished account
/// would otherwise be re-read forever.
private func applySwitchRequest(plan: inout RelaunchPlan?, state: inout ManualMoveState,
                                record: inout PendingSwitchConsumption?,
                                account: Snapshot.Account, providerID: String,
                                policy: LaunchPolicy,
                                watcher: inout TranscriptWatcher, childAge: TimeInterval,
                                keyboardIdle: (TimeInterval) -> Bool,
                                dir: URL, request: SwitchRequest?,
                                accounts: () -> [Snapshot.Account]) {
    // No request, or one this supervisor has already served. The staleness rule is answered here as
    // well as inside the decision below, because everything between costs a snapshot read and a
    // transcript tail: `isQuiet` locates and tails the file, which is not free per tick.
    guard let request, request.epoch > state.servedEpoch else { return }
    /// Consume without moving anything: whatever pin override stands, stands - nothing here took
    /// this session off a pin.
    func consume() {
        PendingSwitchConsumption(epoch: request.epoch, pinOverride: state.overriddenPin, dir: dir)
            .commit(&state)
    }
    let target = launchableAccount(request.accountID, provider: providerID, in: accounts)
    let quiet = reloadQuiet(transcriptQuiet: watcher.isQuiet(manualMoveIdleSeconds),
                            hasTranscript: watcher.file != nil, childAge: childAge,
                            bar: manualMoveIdleSeconds,
                            keyboardQuiet: keyboardIdle(manualMoveIdleSeconds))
    switch switchDecision(served: state.servedEpoch, request: request, targetFound: target != nil,
                          onTarget: target?.id == account.id, isQuiet: quiet) {
    case .none, .queued:
        // Queued says nothing here: the child is drawing on this terminal and is not about to be
        // terminated, and the wait is at most the rest of the turn that asked for the switch. What
        // the person who typed it needs to know was printed by the command itself.
        break
    case .gone:
        warn("the account `tally switch` named is not available - staying on \(account.label)")
        consume()
    case .alreadyThere:
        consume()
    case .relaunch:
        guard let target else { return }
        warn("switching to \(target.label) as asked")
        plan = RelaunchPlan(target: target, reason: "switch", countsFuse: false)
        record = PendingSwitchConsumption(epoch: request.epoch,
                                          pinOverride: policy.pinnedAccountID, dir: dir)
    }
}

/// Live pin switch: pinning another account in the Tally panel moves the RUNNING session there. An
/// explicit human act, so no fuse; the pinned account is used even when capped (that is what pinning
/// means). Waits for a quiet transcript so an in-flight response is never cut mid-stream (the next
/// 2s poll retries) and a quiet keyboard so a prompt being typed survives too; both default to the
/// same 5s bar.
///
/// It stands down while the pin it names is the one a `tally switch` took this session off.
private func applyPinSwitch(plan: inout RelaunchPlan?, state: ManualMoveState,
                            account: Snapshot.Account, providerID: String, policy: LaunchPolicy,
                            watcher: inout TranscriptWatcher,
                            keyboardIdle: (TimeInterval) -> Bool,
                            accounts: () -> [Snapshot.Account]) {
    guard policy.mode == "manual", let pinnedID = policy.pinnedAccountID, pinnedID != account.id,
          !state.pinOverridden(pinnedID), watcher.isQuiet(manualMoveIdleSeconds),
          keyboardIdle(manualMoveIdleSeconds),
          let target = launchableAccount(pinnedID, provider: providerID, in: accounts)
    else { return }
    warn("pinned in Tally → switching to \(target.label)")
    plan = RelaunchPlan(target: target, reason: "pin", countsFuse: false)
}

// MARK: - CLI entry

/// `tally switch <account>`: move the session this command was run in onto the named account, at the
/// end of the turn that asked for it.
///
/// Unconfirmed, like `tally reload`: typing the command IS the intent. It writes a request and
/// returns at once - the supervisor performs the move - so it never blocks the turn it was run in,
/// which matters because that turn has to END before the move can happen.
func runSwitch(args: [String]) -> Int32 {
    guard args.count == 1, let name = args.first, !name.hasPrefix("-") else {
        warn("usage: tally switch <account>   (label or config-dir name, as `tally status` lists " +
             "them). Moves THIS session to that account at the end of the current turn; to make a " +
             "project always launch there, use `tally project set --account`")
        return 2
    }
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    // Claude only for now, exactly as the supervisor is: codex launches are a plain exec with
    // nothing resident to act on a request.
    let provider = providers[0]
    guard let target = accountMatching(name, provider: provider.id, in: snapshot) else {
        warn("no claude account matches \"\(name)\" - try `tally status`")
        return 1
    }
    // The account this session is on, read from the config home it was launched with - the same
    // signal the status line uses to name it, and the only one that is true before the session has
    // written anything.
    let home = ProcessInfo.processInfo.environment[provider.envKey] ?? defaultHome(provider)
    if target.launchHome == home {
        print("already on \(target.label)")
        return 0
    }
    let sessionKey: String
    let marker = liveSessionMarker()
    switch sessionLookup(envPid: marker,
                         here: supervisorsInDirectory(FileManager.default.currentDirectoryPath)) {
    case .session(let key):
        sessionKey = key
    case .none:
        warn("this session is not supervised, so there is nothing here to move it: it was launched "
            + "bare, with --no-handoff, or with an --account pin. Sessions started with "
            + "`tally claude` can be switched.")
        return 1
    case .ambiguous(let pids):
        warn("\(pids.count) supervised sessions are running in this directory, so this command "
            + "cannot tell which one you mean (pids \(pids.joined(separator: ", "))). Run it "
            + "inside the session you want to move - or ask the agent in that session to run it.")
        return 1
    }
    // Whether anything will read the request, asked only when the session named ITSELF: the
    // environment carries that session's supervisor build, and a directory match carries nothing.
    let honourability = marker == nil ? SwitchHonourability.honoured
        : switchHonourability(supervisorVersion:
                                ProcessInfo.processInfo.environment["TALLY_SUPERVISOR_VERSION"],
                              installedVersion: supervisorBuildVersion())
    if honourability == .tooOld {
        warn("this session's supervisor predates `tally switch` and would never read the request, "
            + "so nothing was queued. Restart this session once (exit, then launch again with "
            + "`tally claude`) and it can be switched from then on.")
        return 1
    }
    // Said, not refused: naming an account is an instruction, and its quota is the user's business
    // (the same reading a pin gets - `tally claude` launches a pinned account that is out too).
    if headroom(target) <= 0 {
        warn("\(target.label) is out of quota - switching anyway (you asked)")
    }
    sweepDeadSwitchRequests()
    do {
        try writeSwitchRequest(accountID: target.id, sessionKey: sessionKey)
    } catch {
        warn("cannot write \(switchRequestFile(sessionKey: sessionKey).path): " +
             "\(error.localizedDescription)")
        return 1
    }
    // The timing, spelled out, because the caller is usually an agent that has to relay it: the
    // move waits for the turn making this tool call to finish (OpenTurn.swift), so the session
    // stays exactly where it is until the answer is delivered, and comes back on the other account
    // with the conversation intact.
    print("switch queued: this session moves to \(target.label) when the current turn ends, "
        + "and the conversation continues there")
    if honourability == .afterSelfUpdate {
        warn("this session runs a supervisor from another build: it replaces itself with the "
            + "installed one at the next idle moment, and the switch happens after that")
    }
    return 0
}
