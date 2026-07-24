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

// MARK: - Build version and supervision status

/// The app version this `tally` binary ships inside, read from the enclosing bundle's Info.plist.
/// The CLI is embedded at <App>/Contents/Helpers/tally, so the plist is two directories up from
/// the executable. nil when not running from inside the app bundle (a standalone or dev build),
/// which the status line renders as "unknown" rather than asserting "outdated".
func supervisorBuildVersion() -> String? {
    guard let exe = Bundle.main.executableURL else { return nil }
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

/// Append one audit line. Never contains a token; the fields are the session id prefix, from->to
/// labels, and the reason.
func logHandoff(sessionID: String?, from: String, to: String, reason: String, now: Date = Date()) {
    let stamp = ISO8601DateFormatter().string(from: now)
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    appendHandoffLine("\(stamp) session=\(sid) \(from)->\(to) reason=\(reason)\n")
}

/// Append one whole line to the shared handoff log, O_APPEND so concurrent supervisors interleave
/// without a lock. Best-effort: a logging failure must never disturb the caller.
private func appendHandoffLine(_ line: String) {
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

/// One recorded cap: an account, the model window that capped (nil = a whole-account quarantine,
/// e.g. a legacy record or a flagship-first cap), and when the record expires.
struct QuarantineRecord {
    let accountID: String
    let model: String?
    let until: Date
}

/// Record that `accountID` just capped on `model`'s window, excluded from automatic picks for that
/// model until `until`, across every supervisor via the shared file. Tab-separated so an id or a
/// model with a space round-trips; the account id also rides in the body (the filename is a
/// filesystem-safe derivative) so a slash survives. Best-effort.
func quarantineAccount(_ accountID: String, model: String?, until: Date, dir: URL = quarantineDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let safe = accountID.replacingOccurrences(of: "/", with: "_")
    try? "\(until.timeIntervalSince1970)\t\(model ?? "")\t\(accountID)"
        .write(to: dir.appendingPathComponent(safe), atomically: true, encoding: .utf8)
}

/// Parse one quarantine file body. New format is tab-separated `epoch\tmodel\taccountID` (an empty
/// model field means whole-account); a legacy space-separated `epoch accountID` line is read as a
/// whole-account record so an old file still quarantines conservatively.
func parseQuarantineLine(_ raw: String, fallbackID: String) -> QuarantineRecord? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("\t") {
        let parts = trimmed.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let epoch = Double(parts[0]) else { return nil }
        return QuarantineRecord(accountID: String(parts[2]),
                                model: parts[1].isEmpty ? nil : String(parts[1]),
                                until: Date(timeIntervalSince1970: epoch))
    }
    let parts = trimmed.split(separator: " ", maxSplits: 1)
    guard let epoch = parts.first.flatMap({ Double($0) }) else { return nil }
    let accountID = parts.count > 1 ? String(parts[1]) : fallbackID
    return QuarantineRecord(accountID: accountID, model: nil,
                            until: Date(timeIntervalSince1970: epoch))
}

/// Whether a quarantine on `quarantineModel` blocks a pick made for `pickModel`. Same bidirectional
/// contains rule as `headroom`'s model-window matching: a cap on the fable window never blocks a
/// sonnet pick (that pick does not spend the fable window), but a nil on either side (a whole-
/// account quarantine, or a flagship-first pick with no declared primary) blocks conservatively.
func quarantineBlocks(quarantineModel: String?, pickModel: String?) -> Bool {
    guard let quarantined = quarantineModel?.lowercased(),
          let pick = pickModel?.lowercased() else { return true }
    return quarantined.contains(pick) || pick.contains(quarantined)
}

/// Every live quarantine record right now: this supervisor's own `sessionLocal` map (authoritative
/// for what it capped this run) unioned with the cross-supervisor shared files. Session-local wins
/// on a duplicate account. Expired shared records are ignored and opportunistically deleted.
func quarantineRecords(sessionLocal: [String: (model: String?, until: Date)] = [:],
                       now: Date = Date(), dir: URL = quarantineDir) -> [QuarantineRecord] {
    var records: [QuarantineRecord] = []
    var seen = Set<String>()
    for (id, value) in sessionLocal where value.until > now {
        records.append(QuarantineRecord(accountID: id, model: value.model, until: value.until))
        seen.insert(id)
    }
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    for file in files {
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let record = parseQuarantineLine(raw, fallbackID: file.lastPathComponent) else { continue }
        if record.until > now {
            if !seen.contains(record.accountID) { records.append(record); seen.insert(record.accountID) }
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
    return records
}

/// Account ids to exclude from an automatic pick made for `pickModel`: a quarantine only bites when
/// its capped model window matches the pick's primary (or either side is nil). So an account whose
/// fable window capped stays available for a sonnet launch.
func quarantinedAccounts(forPrimary pickModel: String?,
                         sessionLocal: [String: (model: String?, until: Date)] = [:],
                         now: Date = Date(), dir: URL = quarantineDir) -> Set<String> {
    Set(quarantineRecords(sessionLocal: sessionLocal, now: now, dir: dir)
        .filter { quarantineBlocks(quarantineModel: $0.model, pickModel: pickModel) }
        .map(\.accountID))
}

// MARK: - Safeguard model drift (Fable falls back to Opus and stays there)

/// One Fable safeguard fallback event from the transcript (`model_refusal_fallback`): the model it
/// swapped away from, the model it landed on, the API's refusal category, when it happened, and the
/// uuid of the user message that triggered it (for looking up a log excerpt). A structured system
/// event, shape-distinct from a quota cap, so the two never cross-classify.
struct SafeguardFlag: Equatable {
    let at: Date
    let from: String
    let to: String
    let category: String
    let refusedUUID: String?
}

/// A model id trimmed to its family for a compact display: drop a leading `claude-`, keep the first
/// dash-separated segment (`claude-fable-5` -> `fable`, `claude-opus-4-8` -> `opus`).
func shortModelName(_ id: String) -> String {
    var name = id.lowercased()
    if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
    return String(name.prefix { $0 != "-" })
}

/// Pure state machine tracking one supervised session's drift episode, so the poll loop's wiring
/// (warn, log, nudge, gate) is testable without spawning a child. It is fed the newest safeguard
/// flag, the actual serving model, and the session's expected primary each tick; it emits a
/// `started`/`cleared` edge and answers `isActive` (the gate the quota-degradation paths read) and
/// `shouldNudge`. A drift persists until the actual model returns to the primary (the user ran
/// `/model` to switch back); a session with no declared primary clears against the model the flag
/// drifted from, so the episode always has an exit. Nothing here restarts a child - observation
/// only.
struct DriftMonitor {
    enum Event: Equatable {
        case started(SafeguardFlag)
        case cleared(TimeInterval)   // episode duration in seconds
    }

    private(set) var isActive = false
    /// The model the session drifted away from (for the nudge's `/model <from>` hint).
    private(set) var activeFrom: String?
    /// The newest flag consumed. Strictly-newer comparison dedups a flag re-read on later scans and,
    /// held past a clear, stops the same flag from re-opening a closed episode.
    private var lastFlagAt: Date?
    private var episodeStart: Date?
    private var nudged = false

    /// Fold this tick's inputs into the episode, returning an edge event or nil. A strictly-newer
    /// flag opens an episode (or, mid-episode, resets the nudge cooldown); the actual model matching
    /// the primary again closes it.
    mutating func tick(flag: SafeguardFlag?, actualModel: String?, primary: String?,
                       now: Date = Date()) -> Event? {
        if let flag, lastFlagAt.map({ flag.at > $0 }) ?? true {
            lastFlagAt = flag.at
            nudged = false
            if !isActive {
                isActive = true
                activeFrom = flag.from
                episodeStart = flag.at
                return .started(flag)
            }
            return nil
        }
        if isActive, let actual = actualModel?.lowercased(),
           let expected = (primary ?? activeFrom)?.lowercased(), actual.contains(expected) {
            let duration = now.timeIntervalSince(episodeStart ?? now)
            isActive = false
            activeFrom = nil
            episodeStart = nil
            nudged = false
            return .cleared(duration)
        }
        return nil
    }

    /// True once a live episode has held for the cooldown and has not been nudged yet. The caller
    /// still gates on a quiet transcript before warning, and calls `markNudged` after.
    func shouldNudge(now: Date = Date(), cooldown: TimeInterval = 5 * 60) -> Bool {
        guard isActive, !nudged, let lastFlagAt else { return false }
        return now.timeIntervalSince(lastFlagAt) >= cooldown
    }

    mutating func markNudged() { nudged = true }
}

/// Normalize a trigger excerpt for the log: control whitespace collapsed to spaces, inner quotes
/// dropped (the field is quoted), capped at `limit`. nil in -> nil out; an empty result is nil.
func sanitizeExcerpt(_ raw: String?, limit: Int = 160) -> String? {
    guard let raw else { return nil }
    let flattened = raw
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\"", with: "'")
        .trimmingCharacters(in: .whitespaces)
    guard !flattened.isEmpty else { return nil }
    return String(flattened.prefix(limit))
}

/// Append a drift episode to the handoff log (grep `drift=`). The excerpt is sanitized and never
/// carries a token; a user prompt is trimmed to a snippet, not stored whole.
func logDrift(sessionID: String?, flag: SafeguardFlag, excerpt: String?, now: Date = Date()) {
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    var line = "\(ISO8601DateFormatter().string(from: now)) session=\(sid) " +
        "drift=\(flag.from)->\(flag.to) category=\(flag.category)"
    if let excerpt = sanitizeExcerpt(excerpt) { line += " excerpt=\"\(excerpt)\"" }
    appendHandoffLine(line + "\n")
}

/// Append a drift-cleared line (grep `drift-cleared`) with the episode's duration in whole minutes.
func logDriftCleared(sessionID: String?, duration: TimeInterval, now: Date = Date()) {
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    appendHandoffLine("\(ISO8601DateFormatter().string(from: now)) session=\(sid) " +
        "drift-cleared after=\(Int(duration / 60))m\n")
}

/// Per-supervisor drift state (~/.tally/supervisor-state/<supervisorPID>). The status line of the
/// drifted session reads it to paint its badge; one file per supervisor pid so concurrent sessions
/// never share a document, written atomically (temp + rename). Cleared on clear, handoff, and exit.
let supervisorStateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/supervisor-state")

/// What the status line needs to render the drift badge (`from -> to (category)`).
struct DriftState: Equatable {
    let from: String
    let to: String
    let category: String
}

/// Write the active drift to this supervisor's state file. Tab-separated `from\tto\tcategory\tepoch`
/// (the epoch rides along for after-the-fact debugging; the badge uses the first three). Best-effort.
func writeDriftState(_ flag: SafeguardFlag, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? "\(flag.from)\t\(flag.to)\t\(flag.category)\t\(flag.at.timeIntervalSince1970)"
        .write(to: dir.appendingPathComponent(pid), atomically: true, encoding: .utf8)
}

/// Remove this supervisor's drift state file (episode cleared, or the supervisor is handing off /
/// exiting). Best-effort; a missing file is a no-op.
func clearDriftState(pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.removeItem(at: dir.appendingPathComponent(pid))
}

/// Read a supervisor's drift state, or nil when the file is absent or malformed.
func readDriftState(pid: String, dir: URL = supervisorStateDir) -> DriftState? {
    guard let raw = try? String(contentsOf: dir.appendingPathComponent(pid), encoding: .utf8)
    else { return nil }
    let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\t", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    return DriftState(from: String(parts[0]), to: String(parts[1]), category: String(parts[2]))
}

/// Whether a supervisor pid is still running. A leftover state file from a crashed supervisor must
/// not paint a stale badge; EPERM (exists under another uid) counts as alive rather than risk
/// hiding a real one, though our own launches never hit it.
func supervisorAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}
