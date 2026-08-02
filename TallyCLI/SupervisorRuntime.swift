import Darwin
import Foundation

// Supervisor value types, pure decision helpers, and the small pieces of plumbing the resident loop
// needs but does not have to hold: split from Supervisor.swift so that file stays under the size cap
// and the logic that CAN be tested without spawning a child is testable on its own
// (tests/supervisor compiles this alongside Supervisor.swift + Snapshot.swift).

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

/// Append one audit line. Never contains a token; the fields are the session id prefix, from->to
/// labels, and the reason.
func logHandoff(sessionID: String?, from: String, to: String, reason: String, now: Date = Date()) {
    let stamp = ISO8601DateFormatter().string(from: now)
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    appendHandoffLine("\(stamp) session=\(sid) \(from)->\(to) reason=\(reason)\n")
}

/// Append one whole line to the shared handoff log, O_APPEND so concurrent supervisors interleave
/// without a lock. Best-effort: a logging failure must never disturb the caller. Internal, not
/// private: the drift writers in DriftMonitor.swift share it.
func appendHandoffLine(_ line: String) {
    try? FileManager.default.createDirectory(at: handoffLog.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let fd = open(handoffLog.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
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
/// Only a RELOAD carries it. That relaunch restarts the same conversation on the same account for
/// reasons that have nothing to do with the cap, and a capped session with no sibling to take it is
/// by definition quiet, so a reload always restarts it - while the new child's watcher filters the
/// original cap event away as history. Dropping the pending state there would leave the session
/// waiting on an account that has stopped serving, with nothing left to notice when a sibling frees
/// up: the automatic handoff would only resume after the user hit the wall a second time
/// (2026-07-25). Every other reason genuinely changes the situation - a cap handoff moved account,
/// a pin or follow re-pointed the session, a fallback changed the model pairing - so the next child
/// starts from scratch, as it always has.
func capCarriedAcrossRelaunch(_ pending: PendingCapRecovery?,
                              reason: String) -> PendingCapRecovery? {
    reason == "reload" ? pending : nil
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
/// Pure so the priority order (pinned > fuse > stale snapshot > no target > handoff) is testable
/// without spawning a child.
enum CapAction: Equatable {
    case handoff       // fuse has room, a fresh snapshot, and an eligible sibling: move now
    case waitPinned    // manual pin on the capped account: staying put is what pinning means
    case waitFuse      // too many recent handoffs: cool down before burning another login
    case waitStale     // snapshot too old to trust a target pick
    case waitNoTarget  // no other account worth moving to right now

    /// The waiting-state note shown to the user (state-change-only); nil for `.handoff`.
    var waitingNote: String? {
        switch self {
        case .handoff: return nil
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

func capRecoveryAction(mode: String, fuseAllows: Bool, snapshotStale: Bool,
                       hasTarget: Bool) -> CapAction {
    if mode == "manual" { return .waitPinned }
    if !fuseAllows { return .waitFuse }
    if snapshotStale { return .waitStale }
    if !hasTarget { return .waitNoTarget }
    return .handoff
}

// MARK: - Relaunch plan (coalesce one poll tick's reasons into a single respawn)

/// The relaunch a single poll tick decided. The loop folds every reason that fired this tick into
/// ONE plan so the child is killed and respawned exactly once: a cap handoff and a Settings Apply
/// landing together used to fire two SIGTERMs and relaunch twice (2026-07-24). The account move is
/// owned by the FIRST reason (pin > cap > degradation > fallback); a follow adoption only enriches
/// the model/effort on whatever target that reason chose.
struct RelaunchPlan {
    /// The account to run on (may be the current one - follow/fallback stay put).
    var target: Snapshot.Account
    /// Audit-log tag.
    var reason: String
    /// Records against the recovery fuse: true only for automatic cross-account recoveries.
    var countsFuse: Bool
    /// Model/effort to set on the relaunch; nil leaves the current args' pairing untouched. A
    /// follow adoption and a fallback fill these; a plain cap handoff or pin switch leaves them nil.
    var model: String?
    var effort: String?
    /// Extra flags the fallback profile appends (e.g. --append-system-prompt).
    var extraArgs: [String] = []
    /// True once a follow adoption has folded its pair in, so the same tick does not do it twice.
    var followFolded = false
}

/// The launch args a plan's relaunch runs with: the pairing it carries replaces whatever `--model`
/// and `--effort` the current args hold, and its extra flags follow. A plan carrying none (a plain
/// cap handoff, a pin switch, a reload) leaves the args exactly as the resume path produced them.
/// One function rather than an inline rewrite because a self-update folded into the plan execs with
/// these same args: the new build must receive what the child would have been given.
func planLaunchArgs(_ args: [String], plan: RelaunchPlan) -> [String] {
    guard plan.model != nil || plan.effort != nil || !plan.extraArgs.isEmpty else { return args }
    // Gathered first, then placed where they will be READ (`injectingOptions`, Snapshot.swift).
    // Appended, a relaunch that changed the model landed it past the user's `--` and into the
    // prompt: claude ran the OLD pairing, `FollowState` could not see the new one either, and its
    // baseline had already been re-pointed - so the session ran on a setting nobody could observe
    // and no later tick would ever correct it, while each pass added another copy to the prompt.
    var injected: [String] = []
    if let model = plan.model { injected += ["--model", model] }
    if let effort = plan.effort { injected += ["--effort", effort] }
    return injectingOptions(removingFlagPairs(args, ["--model", "--effort"]),
                            injected + plan.extraArgs)
}
