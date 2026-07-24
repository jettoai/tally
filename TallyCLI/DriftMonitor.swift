import Darwin
import Foundation

// Safeguard model-drift observation: the value types, the pure episode state machine, the audit-log
// writers, and the per-supervisor state file the status line reads. Split from
// SupervisorRuntime.swift for file size; the poll-loop wiring stays in Supervisor.swift.

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

/// Unlink state files whose supervisor is gone. A SIGKILLed supervisor never runs its clear path,
/// so files would otherwise accumulate, and once the OS reuses that pid for an unrelated process
/// the liveness probe would repaint a stale badge. Every supervisor sweeps once at startup, which
/// keeps the window between death and reuse short. Files that are not named for a pid are left
/// alone (nothing of ours, or a future format).
func sweepDeadSupervisorState(dir: URL = supervisorStateDir) {
    let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? []
    for file in files {
        guard let pid = pid_t(file.lastPathComponent), !supervisorAlive(pid) else { continue }
        try? FileManager.default.removeItem(at: file)
    }
}
