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
func spawnChild(_ argv: [String], environment: [String: String]) -> pid_t? {
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    cEnv.append(nil)
    defer { for pointer in cArgs + cEnv { free(pointer) } }
    var pid: pid_t = 0
    return posix_spawnp(&pid, argv[0], nil, nil, cArgs, cEnv) == 0 ? pid : nil
}

// MARK: - Launch-flag helpers

/// Whether auto-handoff is on for this launch (opt out with `--no-handoff` or TALLY_AUTO_HANDOFF=0).
func autoHandoffEnabled(args: [String]) -> Bool {
    if args.contains("--no-handoff") { return false }
    if let raw = getenv("TALLY_AUTO_HANDOFF"), String(cString: raw) == "0" { return false }
    return true
}

/// Whether a running session adopts a later change to the launch-default model (Settings). Mirrors
/// the `--no-handoff` opt-out. A hand-typed `--model` is handled separately at the call site (a
/// deliberate model choice must never be overridden), so this only covers the explicit escape hatch.
func autoFollowEnabled(args: [String]) -> Bool {
    if args.contains("--no-follow") { return false }
    if let raw = getenv("TALLY_AUTO_FOLLOW"), String(cString: raw) == "0" { return false }
    return true
}

/// The value following `flag` in an argument vector (nil when absent or dangling).
func flagValue(_ args: [String], _ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

/// `args` minus the given value-taking flags (and their values).
func removingFlagPairs(_ args: [String], _ flags: Set<String>) -> [String] {
    var out: [String] = []
    var skip = false
    for argument in args {
        if skip { skip = false; continue }
        if flags.contains(argument) { skip = true; continue }
        out.append(argument)
    }
    return out
}

/// The launch args a relaunch runs with. A known session id resumes that conversation. With no id
/// (the child has not written a transcript yet, so the watcher located nothing) it depends on where
/// the relaunch lands: a move to ANOTHER account drops `--continue`/`--resume` so it cannot pull up
/// an unrelated old conversation there, but a relaunch on the SAME account keeps the original
/// `--continue` - stripping it would open an EMPTY session instead of the one the user resumed
/// (`tally claude --continue` restarted before its first turn, 2026-07-25). On the same home
/// `--continue` can only reach that same latest conversation.
func relaunchArgs(_ args: [String], sessionID: String?, sameAccount: Bool) -> [String] {
    var next: [String] = []
    var skip = false
    for argument in args {
        if skip { skip = false; continue }
        switch argument {
        case "--continue", "-c": continue
        case "--resume", "-r": skip = true; continue
        default: next.append(argument)
        }
    }
    if let sessionID { return ["--resume", sessionID] + next }
    guard sameAccount, args.contains(where: { $0 == "--continue" || $0 == "-c" }) else { return next }
    return ["--continue"] + next
}

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

    /// The status-line note, or nil when there is nothing to say.
    var note: String? {
        switch self {
        case .notSteered, .notSupervised, .ok: return nil
        case .unknown: return "supervisor status unknown, restart after update"
        case .outdated: return "supervisor outdated, restart after update"
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
