import Darwin
import Foundation

// Supervisor value types and pure decision helpers, split from Supervisor.swift so the resident
// loop stays under the file-size cap and the logic that CAN be tested without spawning a child is
// testable on its own (tests/supervisor compiles this alongside Supervisor.swift + Snapshot.swift).

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

// MARK: - Recovery fuse (per supervisor, in memory)

/// At most `max` AUTOMATIC cross-account recoveries (a cap handoff or a degradation rescue) per
/// rolling `window`, so a systemic failure can't burn through logins in a loop. Scoped to ONE
/// supervisor process and held in memory, unlike the old shared file gate: five sessions hitting
/// a model-window drain at the same instant each recorded into one file and tripped every other
/// session's fuse, so nobody could hand off (2026-07-24). Deliberate moves (a pin switch, a follow
/// adoption) and same-account relaunches (the fallback profile) are never counted.
struct RecoveryFuse {
    let max: Int
    let window: TimeInterval
    private var recent: [Date] = []

    init(max: Int = 3, window: TimeInterval = 10 * 60) {
        self.max = max
        self.window = window
    }

    /// True while the fuse has room. Prunes entries older than the window as a side effect.
    mutating func allows(now: Date = Date()) -> Bool {
        recent.removeAll { now.timeIntervalSince($0) >= window }
        return recent.count < max
    }

    mutating func record(now: Date = Date()) {
        recent.append(now)
    }
}

/// The shared handoff audit log (pure observability now the fuse is per supervisor). Kept for
/// after-the-fact debugging: which session moved from which account to which, and why.
let handoffLog = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/handoff.log")

/// Append one audit line, O_APPEND so concurrent supervisors interleave whole lines without a
/// lock. Never contains a token; the fields are the session id prefix, from->to labels, and the
/// reason. Best-effort: a logging failure must never disturb a handoff.
func logHandoff(sessionID: String?, from: String, to: String, reason: String, now: Date = Date()) {
    try? FileManager.default.createDirectory(at: handoffLog.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: now)
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    let line = "\(stamp) session=\(sid) \(from)->\(to) reason=\(reason)\n"
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

/// What to do about a pending cap this tick, given the live launch policy and account picture.
/// Pure so the priority order (pinned > fuse > stale snapshot > no target > handoff) is testable
/// without spawning a child.
enum CapAction: Equatable {
    case handoff       // fuse has room, a fresh snapshot, and an eligible sibling: move now
    case waitPinned    // manual pin on the capped account: staying put is what pinning means
    case waitFuse      // too many recent handoffs: cool down before burning another login
    case waitStale     // snapshot too old to trust a target pick
    case waitNoTarget  // no other eligible account right now

    /// The waiting-state note shown to the user (state-change-only); nil for `.handoff`.
    var waitingNote: String? {
        switch self {
        case .handoff: return nil
        case .waitPinned: return "staying put (pinned in Tally; unpin to allow handoff)"
        case .waitFuse: return "too many handoffs recently, cooling down before another"
        case .waitStale: return "waiting for a fresh snapshot before handing off"
        case .waitNoTarget: return "no other eligible account, waiting for one to free up"
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

// MARK: - Cap quarantine (recently-capped accounts, don't re-pick)

/// How long a just-capped account is kept out of AUTOMATIC target selection. The app's snapshot
/// lags the real cap - the account still reads healthy for a while after it stops serving - so a
/// handoff (or a fresh launch moments later) would bounce right onto the wall that just failed.
/// One shared constant for now; the right value is the P99 lag between a cap and the snapshot
/// showing 0%, to be measured from handoff.log against snapshot history (2026-07-24 placeholder).
let capQuarantineTTL: TimeInterval = 10 * 60

/// Per-account quarantine records (~/.tally/quarantine/<account>). One file per account so
/// concurrent supervisors never corrupt a shared document, each written atomically (Foundation's
/// atomic write is temp + rename). This layer ONLY filters automatic selection; the snapshot,
/// `tally status`, and the status line are never touched.
let quarantineDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/quarantine")

/// Record that `accountID` just capped: excluded from automatic picks until `until`, across every
/// supervisor via the shared file. The account id rides in the file body (the filename is a
/// filesystem-safe derivative), so ids with a slash still round-trip. Best-effort.
func quarantineAccount(_ accountID: String, until: Date, dir: URL = quarantineDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let safe = accountID.replacingOccurrences(of: "/", with: "_")
    try? "\(until.timeIntervalSince1970) \(accountID)"
        .write(to: dir.appendingPathComponent(safe), atomically: true, encoding: .utf8)
}

/// Account ids quarantined right now by ANY supervisor, unioned with this supervisor's own
/// `sessionLocal` map (authoritative for accounts it capped this run). Expired records are ignored
/// and opportunistically deleted.
func quarantinedAccounts(sessionLocal: [String: Date] = [:], now: Date = Date(),
                         dir: URL = quarantineDir) -> Set<String> {
    var excluded = Set(sessionLocal.filter { $0.value > now }.keys)
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    for file in files {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let parts = raw.split(separator: " ", maxSplits: 1)
        guard let epoch = parts.first.flatMap({ Double($0) }) else { continue }
        let accountID = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : file.lastPathComponent
        if Date(timeIntervalSince1970: epoch) > now { excluded.insert(accountID) }
        else { try? FileManager.default.removeItem(at: file) }
    }
    return excluded
}
