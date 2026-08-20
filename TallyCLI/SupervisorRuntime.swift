import Darwin
import Foundation

// Supervisor value types, pure decision helpers, and the small pieces of plumbing the resident loop
// needs but does not have to hold: split from Supervisor.swift so that file stays under the size cap
// and the logic that CAN be tested without spawning a child is testable on its own
// (tests/supervisor compiles this alongside Supervisor.swift + Snapshot.swift).

// MARK: - The poll tick

/// What one poll tick tells its loop to do next.
///
/// The tick is a FUNCTION rather than the loop's own body because it runs inside an
/// `autoreleasepool` (Supervisor.swift says why), and neither `continue` nor `break` crosses a
/// closure boundary. So the two escapes the body used to spell are values here: the stand-down that
/// leaves the child running, and the relaunch that has already replaced it.
enum TickOutcome {
    /// Nothing ended the child: poll again in two seconds.
    case keepPolling
    /// This tick performed the relaunch (or the self-update exec failed and fell through to one),
    /// so the child it was watching is gone and the outer loop takes over.
    case childReplaced
}

// MARK: - Child process

/// posix_spawnp keeping the child in OUR process group. Foundation's `Process` puts the child in
/// a NEW process group, so the interactive child is background to the terminal and job control
/// stops it with SIGTTIN the moment it reads (claude suspended `T`, blank screen, 2026-07-18).
/// Same-group spawn reproduces what a plain exec gives: the child shares the foreground group.
///
/// The PROGRAM is resolved past Tally's PATH shim first (ProviderExecutable.swift): this supervisor
/// has already picked the account, and the shim would pick again and undo the handoff that just
/// happened (session c80ebeb2, 2026-07-26). Resolved here rather than at the call site so no future
/// spawn can forget, and per spawn rather than once per process because a session outlives PATH
/// changes and the walk costs a handful of `stat`s once per child launch. `argv[0]` keeps the name
/// the caller passed, which is what a shell leaves there and what `ps` shows.
func spawnChild(_ argv: [String], environment: [String: String],
                shimDirectory: URL = tallyShimDirectory) -> pid_t? {
    let program = resolveProviderExecutable(argv[0], shimDirectory: shimDirectory)
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    cEnv.append(nil)
    defer { for pointer in cArgs + cEnv { free(pointer) } }
    var pid: pid_t = 0
    return posix_spawnp(&pid, program, nil, nil, cArgs, cEnv) == 0 ? pid : nil
}

// MARK: - The child's environment

/// The environment a supervised child is launched with: the account's config home, plus the markers
/// the surfaces outside this process read back out of it.
///
/// Three of them are a contract with something else in this repo, which is why they are assembled in
/// one place rather than at the spawn:
///
///   - `TALLY_LAUNCHED` tells the status line this session runs under Tally (the ✦).
///   - `TALLY_SUPERVISOR_VERSION` lets it tell whether the supervisor watching the session is the
///     current build (a session launched before an app update runs stale logic).
///   - `TALLY_SUPERVISOR_PID` addresses the session. The status line reads the drift badge and the
///     pending notice under that pid, and `tally switch` writes its request there
///     (SwitchRequest.swift) - it reaches the agent's own shell because every process the child
///     spawns inherits this.
///
/// The provider's own home variable is cleared first and then set from the account, so a home
/// exported in the parent's environment can never leak into a child the supervisor placed somewhere
/// else; `launchEnv` returning nil is the DEFAULT home, which must launch with the variable unset
/// (Snapshot.swift explains why).
func supervisedChildEnvironment(provider: Provider, home: String, supervisorVersion: String?,
                                supervisorPID: String,
                                base: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String] {
    var environment = base
    environment.removeValue(forKey: provider.envKey)
    environment["TALLY_LAUNCHED"] = "1"
    if let supervisorVersion { environment["TALLY_SUPERVISOR_VERSION"] = supervisorVersion }
    environment["TALLY_SUPERVISOR_PID"] = supervisorPID
    // No spawn from here stops at Claude Code's "resume the whole conversation?" prompt: a relaunch
    // resumes by id with nobody at the keyboard, and a first launch was asked for by somebody who
    // typed the command (ResumePrompt.swift carries the reversal and the way back to the prompt).
    for (key, value) in resumePromptSuppression(environment) {
        environment[key] = value
    }
    if let env = launchEnv(provider, home: home) { environment[env.key] = env.value }
    return environment
}

// MARK: - Non-urgent idle bar

/// How still a session must be before a NON-URGENT relaunch takes it (a follow adoption, a reload
/// request). The 5s default of `isQuiet` proves only that no turn is streaming, which is the right
/// bar for a REPAIR (a cap handoff, a degradation rescue: the sooner the better) but far too low
/// for a preference change: five seconds of silence is also what "read the answer, now typing the
/// next prompt" looks like, and the relaunch would take the half-typed prompt with it. A preference
/// can wait for the session to actually be left alone (owner request, 2026-07-25).
let followIdleSeconds: TimeInterval = 120

// MARK: - Build version and supervision status

/// The app version this `tally` binary ships inside, read from the enclosing bundle's Info.plist.
/// The CLI is embedded at <App>/Contents/Helpers/tally, so the plist is two directories up from
/// the executable. nil when not running from inside the app bundle (a standalone or dev build),
/// which the status line renders as "unknown" rather than asserting "outdated".
///
/// The path is resolved first: the installed command is a symlink (/usr/local/bin/tally points into
/// the bundle), and `executableURL` reports the path as invoked, so walking up from the symlink
/// looked for /Info.plist and found nothing. Every launch through the installed command therefore
/// stamped no version and every supervised session then read as "status unknown" forever, which no
/// restart could clear (2026-07-25).
func supervisorBuildVersion(executable: URL? = Bundle.main.executableURL) -> String? {
    guard let exe = executable?.resolvingSymlinksInPath() else { return nil }
    let plistURL = exe.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
          let version = plist["CFBundleShortVersionString"] as? String else { return nil }
    return version
}

/// The health of the supervisor watching THIS session, judged by the status line from the version
/// the supervisor stamped into the child env against the installed binary's own version.
enum SupervisionStatus: Equatable {
    case notSteered      // not launched through Tally at all - no note
    case notSupervised   // launched through Tally but deliberately without a supervisor - no note
    case ok              // supervisor version matches the installed app
    case unknown         // no version and no opt-out marker: an old pre-update supervisor
    case outdated        // supervisor version differs from the installed app: it runs stale logic

    /// The status-line note, or nil when there is nothing to say. `outdated` describes what is
    /// already under way rather than asking for anything: since 0.26.0 the supervisor replaces
    /// itself with the new build at the next idle moment (or on the next relaunch it is making
    /// anyway), so the old "restart after update" read as an instruction to do by hand what happens
    /// on its own. `unknown` still asks, and must: a supervisor too old to stamp its version is also
    /// too old to self-update, so only the user can end that session.
    var note: String? {
        switch self {
        case .notSteered, .notSupervised, .ok: return nil
        case .unknown: return "supervisor status unknown, restart after update"
        case .outdated: return "supervisor updating at next idle"
        }
    }
}

/// Pure comparison so the status-line note is testable without a bundle. `supervised` is false when
/// the launcher stamped the opt-out marker (a --account/--no-handoff plain exec, or a shim-steered
/// bare launch): a deliberate choice, so it stays quiet rather than nagging. Only a launch that
/// SHOULD have a supervisor but carries no version is "unknown" (an old pre-marker supervisor); a
/// missing INSTALLED version means we can't compare, so assume ok.
func supervisionStatus(steered: Bool, supervised: Bool, supervisorVersion: String?,
                       installedVersion: String?) -> SupervisionStatus {
    guard steered else { return .notSteered }
    guard supervised else { return .notSupervised }
    guard let supervisorVersion else { return .unknown }
    guard let installedVersion else { return .ok }
    return supervisorVersion == installedVersion ? .ok : .outdated
}

// MARK: - Recovery fuse (per supervised session, in memory)

/// At most `max` AUTOMATIC cross-account recoveries (a cap handoff or a degradation rescue) per
/// rolling `window`, so a systemic failure can't burn through logins in a loop. Scoped to ONE
/// supervised session and held in memory, unlike the old shared file gate: five sessions hitting
/// a model-window drain at the same instant each recorded into one file and tripped every other
/// session's fuse, so nobody could hand off (2026-07-24). Deliberate moves (a pin switch, a follow
/// adoption) and same-account relaunches (the fallback profile) are never counted.
///
/// Per SESSION, not per process, and the difference is not academic: a self-update replaces the
/// supervisor with `execv`, so a fuse that reset there would enforce a limit the user never
/// experiences. The sequence is reachable in one sitting: two recoveries spent, the current account
/// not capped at that instant (so nothing blocks the upgrade), the app updates, the fuse is back to
/// zero, and the same conversation can be restarted three more times, each restart a visible
/// interruption. So the recoveries ride across the exec in the `__resupervise` contract
/// (SelfUpdate.swift) and seed the new process's fuse.
struct RecoveryFuse {
    let max: Int
    let window: TimeInterval
    private var recent: [Date] = []

    /// `recovered` seeds the fuse from the supervisor this process replaced; empty (the default) is
    /// a supervisor started normally. Filtered against `now` on the way in as well as on the way
    /// out, because the exec takes real time: an entry that was live when it was encoded may have
    /// left the window by the time the new image reads it.
    init(max: Int = 3, window: TimeInterval = 10 * 60, recovered: [Date] = [], now: Date = Date()) {
        self.max = max
        self.window = window
        recent = recovered.filter { now.timeIntervalSince($0) < window }
    }

    /// True while the fuse has room. Prunes entries older than the window as a side effect.
    mutating func allows(now: Date = Date()) -> Bool {
        recent.removeAll { now.timeIntervalSince($0) >= window }
        return recent.count < max
    }

    mutating func record(now: Date = Date()) {
        recent.append(now)
    }

    /// The recoveries to hand to the process replacing this one. Pruned first (via `allows`), so an
    /// entry past the window never travels: it could only be dead weight the new process would have
    /// to drop anyway, and carrying it invites reading the list as a count rather than as times.
    mutating func carried(now: Date = Date()) -> [Date] {
        _ = allows(now: now)
        return recent
    }
}

/// The shared handoff audit log (pure observability now the fuse is per supervisor). Kept for
/// after-the-fact debugging: which session moved from which account to which, and why.
let handoffLog = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/handoff.log")

/// The name a relaunch is recorded under, which is the question this log exists to answer: WHY did
/// this conversation end up on a different account. The plan's own reason is an internal tag shared
/// with the terminal warnings, so the three that a reader has to tell apart after the fact are given
/// the names the feature uses out loud - a hand-typed `tally switch`, a hard cap, and the quota
/// reasoning that re-picks an account on its own. The rest keep their tag: `pin` (moved in the
/// panel), `reload`, `follow`, `degraded`, `fallback`, `safeguard`, `self-update`.
///
/// `pinCleared` outranks all of it, because that move is the one an owner reading this log is
/// looking for: the session was pinned by hand, and something moved it anyway (SessionSwitch.swift).
func handoffReason(_ planReason: String, pinCleared: Bool) -> String {
    if pinCleared { return "pin-cleared-cap" }
    switch planReason {
    case "switch": return "manual-switch"
    case "cap": return "cap-handoff"
    case "rebalance": return "auto-select"
    default: return planReason
    }
}

/// One audit line, formatted. Pure, so the shape can be asserted without a home directory - the
/// whole point of the fields is that somebody reads them back weeks later, and a format nothing
/// tests is a format that drifts.
///
/// `cwd` goes LAST because it is the one field that can contain a space: everything before it stays
/// at a fixed offset for a reader with an eye or a `grep`. Never contains a token; the fields are
/// the session id prefix, the supervisor's pid, the from->to labels, the reason, and the directory
/// the session runs in.
func handoffLogLine(sessionID: String?, from: String, to: String, reason: String, pid: String,
                    cwd: String, now: Date = Date()) -> String {
    let stamp = ISO8601DateFormatter().string(from: now)
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    return "\(stamp) session=\(sid) pid=\(pid) \(from)->\(to) reason=\(reason) cwd=\(cwd)\n"
}

/// Append one audit line.
///
/// The pid and the cwd are here because the reason alone could not answer the question this log was
/// consulted for: with several sessions moving accounts on one machine, "which session was this, and
/// where was it running" had no answer at all, and the account a conversation ended up on could not
/// be traced back to the decision that put it there (2026-08-06).
func logHandoff(sessionID: String?, from: String, to: String, reason: String, pid: String,
                cwd: String, now: Date = Date(), log: URL = handoffLog) {
    appendHandoffLine(handoffLogLine(sessionID: sessionID, from: from, to: to, reason: reason,
                                     pid: pid, cwd: cwd, now: now), to: log)
}

/// The line a relaunch HELD by an unresolved fork leaves (grep `hold=unresolved-fork`): the tick
/// stood its restart down because a new transcript here has no turn in it yet, so it cannot be told
/// apart from the file this conversation moved to (TranscriptFork.swift).
///
/// A log line rather than a terminal one, which is what it used to be: this tick relaunches nothing,
/// so the child is still drawing when it is written (PendingNotice.swift's rule). Said once per
/// session either way - the caller latches it - and this is the only trace of a restart that was
/// asked for and did not happen.
func unresolvedForkHoldLine(pid: String, cwd: String, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) hold=unresolved-fork cwd=\(cwd)\n"
}

/// The line an AMBIGUOUS fork leaves (grep `fork=ambiguous`): two transcripts continue this
/// conversation and their mtimes tie, so the watcher keeps the file it is bound to rather than
/// guessing. Same channel, same reason as the hold above; the session id is the one it stayed on.
func forkAmbiguityLine(boundID: String, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) session=\(boundID.prefix(8)) fork=ambiguous "
        + "action=staying-on-parent\n"
}

/// Append one whole line to the shared handoff log, O_APPEND so concurrent supervisors interleave
/// without a lock. Best-effort: a logging failure must never disturb the caller. Internal, not
/// private: the drift writers in DriftMonitor.swift share it.
///
/// `log` is injectable for the reason every directory on this track is (`switchRequestDir`,
/// `supervisorStateDir`, `quarantineDir`): a test that reaches a code path which logs must not write
/// into the user's own audit history. It did - a suite run put 1,231 invented lines into a real
/// `~/.tally/handoff.log` before this parameter existed (2026-08-07), which is the same rule the
/// suites already keep for every other home-directory file.
///
/// AND IT HAS NO DEFAULT, deliberately. A default is what let a call site reach the user's file by
/// saying nothing, which is exactly how the ninth one was missed while the eight above it were being
/// threaded (review, 2026-08-07). Naming the sink is now the compiler's requirement rather than a
/// reviewer's, and a logging path added later cannot inherit the old hazard by omission.
func appendHandoffLine(_ line: String, to log: URL) {
    try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

/// Make a conversation's transcript visible to the account a handoff moves it to, so the relaunch
/// can `--resume` it there. A no-op on a shared tree (both homes resolve to the same file) and when
/// the destination already holds it. Best-effort throughout: a copy that fails costs the resume, not
/// the handoff, and the child then starts fresh on the target rather than not starting at all.
func shareTranscript(_ sessionFile: URL, toHome home: String, slug: String) {
    let sourceResolved = sessionFile.resolvingSymlinksInPath()
    let destDir = URL(fileURLWithPath: home).appendingPathComponent("projects/\(slug)")
    let dest = destDir.appendingPathComponent(sessionFile.lastPathComponent)
    guard dest.resolvingSymlinksInPath() != sourceResolved,
          !FileManager.default.fileExists(atPath: dest.path) else { return }
    try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: sessionFile, to: dest)
}

// MARK: - Cap recovery

/// How often a blocked cap recovery re-attempts the handoff. The poll loop already ticks every 2s,
/// but the recovery attempt re-reads the snapshot and re-scores, so it backs off to avoid churn;
/// short enough that a sibling freeing up (snapshots refresh far slower than this) is adopted
/// promptly, which is the whole point of not giving up.
let capRetryBackoff: TimeInterval = 15

/// A cap hit that could not hand off immediately (fuse spent, snapshot stale, or no eligible
/// sibling). The supervisor remembers it and retries at `capRetryBackoff` instead of ending
/// supervision - the old code broke out of the loop and left the session stuck on a 0% account
/// forever (esgnote, 2026-07-24). It is cleared only when the session actually recovers: it hands
/// off, or a real assistant turn appears on the main chain after the cap (the account's window
/// refilled, or the user waited the cooldown out).
struct PendingCapRecovery {
    let cappedAccountID: String
    /// When the cap was noticed. A main-chain assistant event newer than this clears the pending
    /// state (the session came back on its own).
    let cappedAt: Date
    /// The model this session actually runs (a hand-typed `--model` outranks the configured
    /// default), so the handoff target is scored against the right quota window.
    let primaryModel: String?
    /// When the window this cap was hit on refills, fixed at the moment of the cap
    /// (`capRecoveryDeadline`) and never recomputed. Reaching it is the second way the pending
    /// state clears, for a session nobody typed into. nil when the snapshot could not name one.
    let recoveryResetsAt: Date?
    /// Earliest time to re-attempt the handoff (backoff gate).
    var nextRetry: Date
    /// The last waiting-state note shown, so the terminal warns only when the reason changes.
    var reason: String
}

/// The pending cap recovery a relaunch hands to the next child, or nil to start it clean.
///
/// Two reasons carry it, and they are the two that change nothing about the cap: a RELOAD and a
/// SELF-UPDATE. Both restart the same conversation on the same account for reasons of their own, and
/// a capped session with no sibling to take it is by definition quiet, so both always get to restart
/// it - while the new child's watcher filters the original cap event away as history. Dropping the
/// pending state there would leave the session waiting on an account that has stopped serving, with
/// nothing left to notice when a sibling frees up: the automatic handoff would only resume after the
/// user hit the wall a second time (2026-07-25). Every other reason genuinely changes the situation
/// - a cap handoff moved account, a pin or follow re-pointed the session, a fallback changed the
/// model pairing - so the next child starts from scratch, as it always has.
///
/// The self-update is the newer of the two, and its answer here is read twice: the new image gets it
/// through the exec argv (`resupervisePendingCapFlag`, SelfUpdate.swift), and a respawn after an
/// exec that FAILED gets it from this same value in memory. One decision, so the two paths cannot
/// disagree about what the session is still waiting for.
func capCarriedAcrossRelaunch(_ pending: PendingCapRecovery?,
                              reason: String) -> PendingCapRecovery? {
    reason == "reload" || reason == "self-update" ? pending : nil
}

/// When the window this cap was hit on comes back, decided ONCE at the moment of the cap and then
/// carried in the pending state. nil when the snapshot cannot name a boundary, which means this
/// session has only the assistant-turn clear path, exactly as before.
///
/// Fixed at the cap rather than recomputed each tick, and that is the whole design. The app
/// refreshes the snapshot every minute by default (`UsageStore.scheduleTimer`), and that refresh
/// ERASES the evidence: the window that capped goes back to 100% and its `resetsAt` jumps to the
/// next cycle, so from the tick after it the emptiest window is some healthy one whose reset is
/// still ahead and a recomputing check answers "not yet" forever. It would only ever fire inside
/// the gap between the reset and the next refresh, which is to say it would be a coin flip that
/// loses back to the original bug. A boundary captured once cannot be erased by a refresh.
///
/// EVERY window at or below the shared nearly-dry line counts, and the LATEST of their resets wins.
/// Not the emptiest window, and not an exact tie with it: the snapshot lags, so two windows that are
/// both really spent routinely read as different numbers (1% and 2%), and an exact tie would lock
/// onto the 1% window's reset a few hours out while the 2% weekly stays empty for days. The line is
/// `nearlyDryPercent`, the same 5% the launch pick, the cap handoff and the dry-pool alert draw, so
/// "dry" keeps meaning one thing in this repo. Raw remaining, not the comfort gate's effective
/// remaining (`effectiveRemaining` reads a window minutes from resetting as already full, which is
/// right for "can this account take work" and wrong for "which reset ends this drought"). The
/// windows are the ones `ratedWindows` counts for the model this session runs, so a flagship window
/// it does not spend is not one it can have capped on.
///
/// The residual risk, stated plainly because the previous version of this comment claimed there was
/// none: if the snapshot lags so far that a window which is really empty still reads ABOVE the line,
/// it is left out, and the boundary can then be earlier than the end of the real drought. The badge
/// would clear while the account is still capped. Two things make that acceptable. It is self
/// healing: the next thing the user types hits the wall again, and that cap raises a fresh pending
/// state with a fresh boundary. And the opposite bias, never clearing, is the bug this whole path
/// exists to fix, which does not heal on its own at all.
func capRecoveryDeadline(accounts: [Snapshot.Account], cappedAccountID: String,
                         primaryModel: String?, cappedAt: Date) -> Date? {
    guard let account = accounts.first(where: { $0.id == cappedAccountID }) else { return nil }
    let dry = ratedWindows(account, primaryModel: primaryModel, now: cappedAt)
        .filter { $0.remaining <= nearlyDryPercent }
    // EVERY dry window has to name a reset, and every one of those has to be a reset this cap
    // could be waiting for: we set a boundary only when we know, for each dry window, when it
    // comes back. Checking only the latest would let a stale stamp (a window already spent when
    // the session hit the wall, or a snapshot that has not moved since) hide behind a sibling's
    // later reset, and the boundary would then name a window this cap was never about.
    //
    // The alternative, dropping the stale window and taking the max of the rest, is rejected: a
    // reset time in the past can mean "it refilled and the remaining figure has not caught up" or
    // "this whole snapshot is stale and the window is still empty", and we cannot tell which. The
    // wrong guess clears the badge on a recovery that never happened. Answering nil instead puts
    // the session back on the assistant-turn path, which is what every other incomplete picture
    // here does. Nothing dry at all falls out of the same guard: no resets, so no latest.
    let resets = dry.compactMap(\.resetsAt)
    guard resets.count == dry.count, resets.allSatisfy({ $0 > cappedAt }),
          let latest = resets.max() else { return nil }
    return latest
}

/// Whether the reset this cap was waiting for has arrived, so the pending recovery no longer
/// describes anything that is still true.
///
/// The other clear path needs a real assistant turn newer than the cap, which only a user who
/// types can produce, and the handoff's candidate list excludes the account the session is already
/// on. Between them, "the account I am on came back while nobody typed" had no path at all: the
/// badge said "no account with quota to spare" for hours after that account was back at 100% (five
/// sessions in that state at 01:15, 2026-07-31, on a window that had reset at 00:59).
///
/// A reset boundary rather than "the account looks comfortable again", deliberately. The snapshot
/// still reads healthy at the moment of the cap (the lag `capRecoveryDeadline` above describes), so
/// a comfort check would clear the pending state on the very tick that raised it and the recovery
/// would never fire. A reset that has come and gone is not an opinion about the numbers.
func capRecoveredByReset(_ pending: PendingCapRecovery, now: Date = Date()) -> Bool {
    pending.recoveryResetsAt.map { now >= $0 } == true
}

/// What to do about a pending cap this tick, given the live launch policy and account picture.
/// Pure so the priority order (observe-only > pinned > fuse > stale snapshot > no target > handoff)
/// is testable without spawning a child.
///
/// `steering` leads because it is the only answer that is not about this cap: a fleet set to
/// observe only has said Tally may not choose an account, and the cap is a reason to move rather
/// than a licence to (AutoSteering.swift). The session then behaves exactly as `--no-handoff`
/// leaves it - capped, supervised, waiting for the user - which is what "a dashboard, nothing more"
/// promises.
enum CapAction: Equatable {
    case handoff          // fuse has room, a fresh snapshot, and an eligible sibling: move now
    case waitSteeringOff  // the fleet is set to observe only: Tally may not pick an account at all
    case waitPinned       // manual pin on the capped account: staying put is what pinning means
    case waitFuse         // too many recent handoffs: cool down before burning another login
    case waitStale        // snapshot too old to trust a target pick
    case waitNoTarget     // no other account worth moving to right now

    /// The waiting-state note shown to the user (state-change-only); nil for `.handoff`.
    var waitingNote: String? {
        switch self {
        case .handoff: return nil
        // The one wait that will not lift by itself, so the sentence names the two things that end
        // it rather than describing a situation: this is the mode saying Tally never picks an
        // account (AutoSteering.swift), and the session stays exactly where `--no-handoff` would
        // have left it.
        case .waitSteeringOff:
            return "staying put (launches are set to observe only; move it with `tally account`)"
        case .waitPinned: return "staying put (pinned in Tally; unpin to allow handoff)"
        case .waitFuse: return "too many handoffs recently, cooling down before another"
        case .waitStale: return "waiting for a fresh snapshot before handing off"
        // Since the handoff started requiring a comfortable target, the usual reason is not that
        // there is no sibling but that every sibling is nearly dry too, so the note names quota
        // rather than eligibility: "no other account" would read as a lie to someone looking at a
        // second account in the panel, and hide that the wait ends when quota returns.
        case .waitNoTarget: return "no account with quota to spare, waiting for one to free up"
        }
    }
}

func capRecoveryAction(steering: Bool, mode: String, fuseAllows: Bool, snapshotStale: Bool,
                       hasTarget: Bool) -> CapAction {
    if !steering { return .waitSteeringOff }
    if mode == "manual" { return .waitPinned }
    if !fuseAllows { return .waitFuse }
    if snapshotStale { return .waitStale }
    if !hasTarget { return .waitNoTarget }
    return .handoff
}
