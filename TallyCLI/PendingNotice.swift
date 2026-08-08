import Foundation

// What the supervisor is WAITING to do, shown in the status line instead of shouted at the terminal.
//
// The supervisor and the child share one tty, and `warn` writes to stderr wherever the cursor
// happens to be. For a message that precedes a restart that is fine: the TUI is about to be torn
// down anyway. For a message about something the supervisor is NOT doing yet ("reload requested,
// restarting when this session goes idle") it is not: the child keeps drawing, so the line lands in
// the middle of the input box and the next redraw leaves half of it on screen (reported twice with
// screenshots, 2026-07-28, one of them a notice sheared down to "...e sensitive stretch is over").
//
// So the rule is the one distinction that matters to the terminal: IS THE CHILD ABOUT TO DIE?
//
//   - yes (handoff, adoption, fallback, self-update exec) -> stderr, unchanged. The tear-down is
//     coming, and the message explains a restart the user is about to see.
//   - no (queued, waiting, still drifted) -> here. The supervisor writes a per-pid file, the status
//     line renders it, and it disappears when the condition does.
//
// The track is the drift badge's, which has carried exactly this shape since it shipped: one file
// per supervisor pid in `supervisorStateDir`, read only while that pid is alive, best-effort at
// every step. This one is named `<pid>.notice` so it sits beside the presence/drift file without
// colliding, and so `liveSupervisorPids` keeps ignoring it (it parses names as pids, and this is
// not one, which is what stops a notice from inflating the reload count).

/// The suffix that separates a pending-notice file from the presence/drift file of the same pid.
let pendingNoticeSuffix = ".notice"

/// One thing the supervisor is waiting to do.
struct PendingNotice: Equatable, Codable {
    /// What the status line shows. Short: it shares a line with the quota meters.
    let badge: String
    /// The same thing at full length, for a surface with room for it. Written, deliberately not
    /// rendered yet: the badge has to fit a status line, and the reason a reload is stuck ("session
    /// or a subagent still writing") does not, so the long form is kept rather than thrown away.
    let detail: String?
    /// When THIS badge appeared. Preserved while the badge holds steady, which is what makes it the
    /// age of the wait rather than the age of the last poll tick.
    let since: Date
    /// What KIND of notice this is, for the one reader that has to tell them apart: the supervisor
    /// taking over its own file after a self-update (`ManualMoveState.adoptCancellation`). Every
    /// badge on this track describes a live wait and is re-derived from state each tick, except the
    /// cancellation notice, which is news nothing re-derives - so that one has to be recognisable
    /// on disk to be picked back up.
    ///
    /// Additive and optional: a notice written before this field decodes with nil, which reads as
    /// "an ordinary wait", and every existing reader ignores it.
    var kind: String?
}

/// The `PendingNotice.kind`s that mean anything: the two notices that are NEWS rather than live
/// waits, and therefore the two a supervisor has to be able to recognise in a file it did not write
/// itself - its own, from before a self-update replaced the image behind the pid. Every other badge
/// on this track is re-derived from state within a tick or two of the new image starting.
let cancellationNoticeKind = "switch-cancelled"

/// A `/model` choice taken as this session's pin (SessionModel.swift): news on the model axis
/// exactly as the cancellation is on the account axis.
let modelAdoptionNoticeKind = "model-adopted"

/// The file a supervisor's pending notice lives in.
func pendingNoticeFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + pendingNoticeSuffix)
}

/// The supervisor pid a file in the state directory belongs to: the presence/drift file (`<pid>`),
/// or any of the documents written beside it under a suffix. nil for anything else in there, which
/// is what keeps the sweep off files that are not ours - so a new document on this track is added
/// to the list below, or a dead session's copy of it is never swept.
let supervisorStateSuffixes = [pendingNoticeSuffix, sessionContextSuffix, supervisorCwdSuffix,
                               supervisorChildSuffix, transcriptIdentitySuffix]

func supervisorStatePid(ofFile name: String) -> pid_t? {
    if let pid = pid_t(name) { return pid }
    guard let suffix = supervisorStateSuffixes.first(where: { name.hasSuffix($0) }) else {
        return nil
    }
    return pid_t(String(name.dropLast(suffix.count)))
}

/// Write the notice. Best-effort and atomic, like every other file on this track.
func writePendingNotice(_ notice: PendingNotice, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(notice) else { return }
    try? data.write(to: pendingNoticeFile(pid: pid, dir: dir), options: .atomic)
}

/// Read a supervisor's pending notice, or nil when there is none (or the file is from a format this
/// build does not know, which reads the same way: no badge).
func readPendingNotice(pid: String, dir: URL = supervisorStateDir) -> PendingNotice? {
    guard let data = try? Data(contentsOf: pendingNoticeFile(pid: pid, dir: dir)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(PendingNotice.self, from: data)
}

/// Nothing is pending any more. Unlinked rather than emptied, because absence is the whole signal
/// here (the presence file next to it is the one that has to keep existing).
func clearPendingNotice(pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.removeItem(at: pendingNoticeFile(pid: pid, dir: dir))
}

// MARK: - Choosing the one to show

/// A badge and its long form, before anything decides whether it is the one on screen.
struct PendingBadge: Equatable {
    let badge: String
    let detail: String?
    /// Carried through to the file so a notice can be recognised when it is read back
    /// (`PendingNotice.kind`); nil for the waits, which nobody has to recognise.
    let kind: String?

    init(_ badge: String, detail: String? = nil, kind: String? = nil) {
        self.badge = badge
        self.detail = detail
        self.kind = kind
    }
}

/// Everything that could be waiting on this session at once, and which of them wins.
///
/// A status line badge is "the one thing worth knowing right now", not a log: two of these on one
/// line would push the quota meters off the edge, and a list of everything deferred is a worse
/// answer than the most consequential item. So they are ranked rather than joined, and the ones
/// underneath simply wait their turn (each is re-derived from live state every tick, so a badge
/// that was covered appears the moment the one above it clears).
///
/// The order is by how much the user is being kept from: a `tally switch` that cannot be carried out
/// leads, because it is the most specific instruction anyone has given this session and the command
/// that queued it has already returned, so this badge is the only thing left to say it is stuck;
/// then a `tally model` they typed, which is the same kind of instruction one axis over; then a
/// reload they asked for; then a model change that Settings will re-apply on its own, where a follow
/// with nowhere to land outranks one that is merely queued; and a capped session waiting for a
/// sibling is last because the transcript already told them the turn failed.
///
/// The typed model change sits under the switch and over the reload for the reason the order is
/// about: a held switch is STUCK and nobody has been told, while a queued model change is waiting
/// out the turn that asked for it and ends on its own.
struct PendingBadges: Equatable {
    var manualMove: PendingBadge?
    var sessionModel: PendingBadge?
    var reload: PendingBadge?
    var followDeadEnd: PendingBadge?
    var followQueued: PendingBadge?
    var capWaiting: PendingBadge?

    var chosen: PendingBadge? {
        manualMove ?? sessionModel ?? reload ?? followDeadEnd ?? followQueued ?? capWaiting
    }
}

/// One tick's worth of "what is this session waiting to do", written to the status line.
///
/// The whole of it lives here rather than in the poll loop because Supervisor.swift is over its size
/// cap: the loop hands over the four pieces of state it already holds, and everything else (ranking,
/// wording, deciding whether the file needs touching at all) happens on this side.
func syncPendingNotice(_ writer: inout PendingNoticeWriter, pid: String,
                       manualMove: PendingBadge?, sessionModel: PendingBadge? = nil,
                       reload: PendingBadge?,
                       followDeadEnd: Bool, followQueued: Bool, policy: LaunchPolicy,
                       capReason: String?, dir: URL = supervisorStateDir, now: Date = Date()) {
    writer.sync(supervisorPendingBadges(manualMove: manualMove, sessionModel: sessionModel,
                                        reload: reload,
                                        followDeadEnd: followDeadEnd, followQueued: followQueued,
                                        policy: policy, capReason: capReason).chosen,
                pid: pid, dir: dir, now: now)
}

/// Everything the poll loop knows about what it is deferring, turned into badges. The long forms are
/// the sentences these used to print on the terminal, kept verbatim so nothing is lost by moving
/// them off it.
func supervisorPendingBadges(manualMove: PendingBadge? = nil, sessionModel: PendingBadge? = nil,
                             reload: PendingBadge?,
                             followDeadEnd: Bool, followQueued: Bool,
                             policy: LaunchPolicy, capReason: String?) -> PendingBadges {
    let model = policy.model ?? "default"
    let effort = policy.effort ?? "default"
    return PendingBadges(
        manualMove: manualMove,
        // Already a finished badge when it arrives: what it says is about the pair the user typed,
        // which this function has no other way to know (SessionModel.swift raises it).
        sessionModel: sessionModel,
        reload: reload,
        followDeadEnd: followDeadEnd
            ? PendingBadge("no account for \(shortModelName(model))",
                           detail: "launch default changed to \(model), but no eligible account "
                               + "can serve it yet")
            : nil,
        followQueued: followQueued
            ? PendingBadge("model change at idle",
                           detail: "launch default changed to \(model)/\(effort), adopting when "
                               + "this session goes idle")
            : nil,
        // An empty reason is a cap the waiting branch has not yet explained (the first tick after
        // the hit), which is a thing to stay quiet about rather than to badge blankly.
        capWaiting: (capReason?.isEmpty == false)
            ? capReason.map { PendingBadge("cap: \($0)", detail: "capped, \($0)") }
            : nil)
}

/// Keeps the notice file in step with what is pending, writing only when the badge actually
/// changes.
///
/// The supervisor polls every 2 seconds and most ticks change nothing, so rewriting unconditionally
/// would be a file replace every 2s per session for the whole time something is queued. Holding the
/// last value in memory also preserves `since`: the badge is the identity of the wait, so as long as
/// it reads the same, the wait is the same one and keeps its start time.
///
/// THE IN-MEMORY COPY MUST BE SEEDED FROM THE FILE, and that is not an optimisation. A self-update
/// replaces the supervisor with `execv`, which keeps the pid: the new image starts with `current` at
/// nil while a notice file written by the image it replaced is still sitting at `<pid>.notice`. The
/// nil-in / nil-held case then short-circuits, nothing is ever unlinked, and whatever badge happened
/// to be up at the moment of the upgrade is displayed for the rest of the session - by a supervisor
/// that has no idea it is saying it. Both badges reported on 2026-08-06 ("cap: no account with quota
/// to spare" after the session had been switched away, "switch: account removed" with the account
/// present) came back to this one line, which is why they survived everything including the
/// conditions they described.
///
/// Seeding costs one read per supervisor start and buys the invariant this type is supposed to have:
/// what is on disk is what this writer last decided, whichever image decided it.
struct PendingNoticeWriter {
    private var current: String?

    /// `pid` is optional only so a test can build a writer with nothing to reconcile; the supervisor
    /// always passes its own, because the file it may have to take over is named for it.
    init(pid: String? = nil, dir: URL = supervisorStateDir) {
        current = pid.flatMap { readPendingNotice(pid: $0, dir: dir)?.badge }
    }

    /// Idempotent: same badge in, nothing happens.
    mutating func sync(_ pending: PendingBadge?, pid: String, dir: URL = supervisorStateDir,
                       now: Date = Date()) {
        guard pending?.badge != current else { return }
        guard let pending else {
            clearPendingNotice(pid: pid, dir: dir)
            current = nil
            return
        }
        writePendingNotice(PendingNotice(badge: pending.badge, detail: pending.detail, since: now,
                                         kind: pending.kind),
                           pid: pid, dir: dir)
        current = pending.badge
    }
}

// MARK: - Rendering

/// The status line's pending piece, or nil when that supervisor has nothing waiting.
///
/// Pure but for the read, so the shape is testable without a status line: Statusline.swift adds the
/// colour and the position, this decides whether there is anything to say and what it says.
func pendingNoticePiece(pid: String, dir: URL = supervisorStateDir) -> String? {
    readPendingNotice(pid: pid, dir: dir).map { "⏳ \($0.badge)" }
}
