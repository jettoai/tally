import Foundation

// WHAT CLAUDE CODE ASKED THE USER FOR, and the only channel in this repo that carries it.
//
// "Waiting on a person" is the one thing the supervisor cannot see for itself. A transcript that
// has stopped moving looks identical whether the session finished its turn or is holding a
// permission dialog open, and every gate this repo has (`isQuiet`, the open tool call, the subagent
// walk, the terminal's atime) answers the first question rather than the second. So the signal
// comes from Claude Code's OWN `Notification` hook, which fires exactly when it wants the user: a
// permission request, and a prompt left unanswered long enough for it to say so.
//
// The hook writes a file per supervisor pid on the same track as everything else here
// (`supervisorStateDir`), and the supervisor's poll reads it back on its next tick. An event
// rather than a level: it is UNLINKED once the wait it describes has ended (SessionStateSync.swift
// decides when), so the file's presence is the whole of the blocked signal.

/// The suffix separating a user-notice event from the presence/drift file of the same pid.
let userNoticeSuffix = ".usernotice"

/// One thing Claude Code has asked for and not yet had.
struct UserNotice: Codable, Equatable, Sendable {
    /// The hook's own sentence ("Claude needs your permission to use Bash"), shown as the reason a
    /// session is waiting. Empty when the hook carried none, which is a wait with nothing to say
    /// about it rather than no wait.
    var message: String
    /// When the hook fired. The clock every clearing rule is measured against: an answer is
    /// anything that happened AFTER this instant, and something that happened before it cannot be
    /// the answer to it.
    var at: Date
    /// WHICH KIND OF WAIT THIS IS, in Claude Code's own vocabulary (`notification_type`), or nil
    /// when the event named none - and nil is also what every notice written before this field
    /// existed decodes as.
    ///
    /// The hook has always read this to decide whether the event is a wait at all; it is written
    /// down as well because the WAITS ARE NOT ALIKE (`userWait`, SessionState.swift). A permission
    /// request is somebody being asked for something and the session cannot move without them; an
    /// `idle_prompt` is Claude Code saying the floor is free, which is true of a session dispatching
    /// subagents for the whole time it dispatches them. Reading the second as the first is what put
    /// a red dot on every fan-out on this machine (measured 2026-08-15).
    ///
    /// NIL FAILS OPEN TO THE HARD READING, which is the compatibility rule the whole track is
    /// under: a notice written by a supervisor from before this field, or by a Claude Code that
    /// names no type, keeps exactly the behaviour it had. The over-count that costs is the one
    /// direction this list can be wrong in for free.
    var type: String?
    /// The conversation the hook named, when it named one. Written for the same reason the context
    /// reading publishes its transcript id: it is the only witness that binds an event to a
    /// session, where the environment marker is inherited by every descendant.
    var sessionID: String?
}

func userNoticeFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + userNoticeSuffix)
}

// MARK: - The clock this event is written on
//
// WHOLE SECONDS ARE NOT ENOUGH HERE, and that is the whole reason this file does not use the
// `.iso8601` strategy its neighbours do.
//
// `at` exists to be compared against the newest stamped conversation event in the transcript
// (`lastConversationEventAt`, millisecond-precise; it was the file's mtime until 2026-09-23), and
// the two events it separates land in the SAME SECOND as a matter of course: a tool call writes its
// result at T.600 and the permission prompt for the next one fires at T.900. Encoded to whole
// seconds, `at` decodes as T.000, the result's stamp is greater, and `userNoticeStillOpen` reads a
// write that happened BEFORE the prompt as the answer to it. The first tick after the prompt then clears it, and a
// permission request never reaches the board at all.
//
// So this pair is millisecond-precise and symmetric. Its neighbours are unaffected: nothing compares
// `SessionStateRecord.since` against another clock (it is rendered as an age and preserved by value),
// and `PendingNotice.since` is the same.
//
// SHARED WITH THE OTHER HOOK EVENT ON THIS TRACK rather than copied into it: `SessionTurnEnd.at`
// is compared against instants read out of the transcript for exactly this reason, and a second
// spelling of "the fractional clock" is how one of the two comes to be written in whole seconds
// while both files look right.

/// Built per call rather than held in a global, which is the house pattern here
/// (`recordManifest` does the same) and the only one this target's strict concurrency accepts:
/// `ISO8601DateFormatter` is not `Sendable`, so a global one is a shared mutable box the compiler
/// refuses. It costs an allocation on a path that runs once per hook and once per 2s tick.
///
/// File-scoped, unlike the two functions under it: what the other document on this track needs is
/// the pair of coding strategies, and a formatter a second file can reach for is how a third
/// spelling of the same clock gets written.
private func fractionalInstantFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

func encodeFractionalInstant(_ date: Date, _ encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(fractionalInstantFormatter().string(from: date))
}

/// The fractional form first, then the plain one: a notice on disk across the upgrade that
/// introduced the fractional clock is at most one wait old, but reading it as unparseable would
/// DROP that wait, and dropping a wait is the failure this whole file exists to prevent.
func decodeFractionalInstant(_ decoder: Decoder) throws -> Date {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let date = fractionalInstantFormatter().date(from: raw)
        ?? ISO8601DateFormatter().date(from: raw)
    else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "not an ISO 8601 instant"))
    }
    return date
}

/// Record the event. Best-effort and atomic, like every other file on this track: a hook that
/// cannot write costs the blocked reading, never the session.
func writeUserNotice(_ notice: UserNotice, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom(encodeFractionalInstant)
    guard let data = try? encoder.encode(notice) else { return }
    try? data.write(to: userNoticeFile(pid: pid, dir: dir), options: .atomic)
}

/// Record the event UNLESS A HEAVIER ONE IS ALREADY STANDING. Answers whether it was recorded.
///
/// THIS IS ONE SLOT PER SUPERVISOR and `writeUserNotice` replaces whatever is in it, which is fine
/// while the events are alike and is not fine now that they are not. Two of them land in that slot
/// within a minute of each other as a matter of course during a fan-out: a worker raises
/// `worker_permission_prompt` (hard, nobody moves until somebody answers), the main conversation
/// then sits still for 60s and Claude Code fires `idle_prompt` (soft, the floor is free). Written
/// over, the permission request becomes a soft wait, and a soft wait yields to a session that is
/// not quiet (SessionStateSync.swift) - which a fan-out is, for as long as its subagents write. The
/// board would read `working` for as much as a whole busy window (600s) with somebody's
/// authorisation dialog open behind it (codex review of 29ea45e, 2026-08-15).
///
/// So the heavier reading keeps the slot: a soft event does not displace a hard one nobody has
/// answered. Every other pairing replaces as it did, hard over hard included, because the newest
/// hard event is the one whose sentence names what is being asked for right now.
///
/// WHAT THE SINGLE SLOT STILL COSTS, so this is not read for more than it is: two hard waits
/// standing at once keep only the latest, so a permission request behind an `agent_needs_input` is
/// remembered as the second of them and answering that one takes both away. The queue that would
/// hold both is not here. Neither is the other half of the same review: clearing a worker's request
/// against THAT WORKER's own result rather than against any write in the main transcript, which is
/// still open. What is not a cost is a preserved hard event going stale, because it cannot: the
/// tick unlinks it within a poll of the conversation moving past it (SessionStateSync.swift), and a
/// dropped soft event is re-fired for as long as the floor stays free.
@discardableResult
func recordUserNotice(_ notice: UserNotice, pid: String, dir: URL = supervisorStateDir) -> Bool {
    if let standing = readUserNotice(pid: pid, dir: dir),
       userWait(notificationType: standing.type) == .hard,
       userWait(notificationType: notice.type) == .soft {
        return false
    }
    writeUserNotice(notice, pid: pid, dir: dir)
    return true
}

/// The event still standing against this session, or nil when there is none (or the file is from a
/// format this build does not know, which reads the same way: nothing is waiting).
func readUserNotice(pid: String, dir: URL = supervisorStateDir) -> UserNotice? {
    guard let data = try? Data(contentsOf: userNoticeFile(pid: pid, dir: dir)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(decodeFractionalInstant)
    return try? decoder.decode(UserNotice.self, from: data)
}

/// The wait is over. Unlinked rather than emptied, because absence IS the signal here.
func clearUserNotice(pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.removeItem(at: userNoticeFile(pid: pid, dir: dir))
}

/// Take the answered event away, BUT ONLY IF IT IS STILL THE ONE THAT WAS JUDGED.
///
/// Reading an event, deciding it has been answered and unlinking it are three steps with nothing
/// holding the path still between them, and the hook replaces that file by atomic rename at any
/// moment: a permission prompt landing in that gap would be deleted unread, leaving somebody
/// waiting on a session the board calls idle. Comparing the instant (millisecond-precise, which is
/// what makes two events one second apart distinguishable at all) narrows the window to the
/// microseconds between this read and the unlink.
///
/// IT IS NOT A COMPARE-AND-SWAP AND MUST NOT BE READ AS ONE: the file system offers no
/// rename-if-unchanged, so a write landing inside that last window is still lost. What keeps even
/// that recoverable is the SHAPE of the loss - a delete rather than a wrong answer, so the board
/// reads idle for a session that is waiting, which is the degradation an unregistered hook already
/// gives, and the next prompt republishes.
///
/// A function of its own rather than three lines at the call site because the property being
/// claimed ("only the judged event is removed") is the whole of what makes the narrowing worth
/// anything, and a property nothing can state is a property nothing can hold onto.
func clearAnsweredUserNotice(_ judged: UserNotice, pid: String, dir: URL = supervisorStateDir) {
    guard readUserNotice(pid: pid, dir: dir)?.at == judged.at else { return }
    clearUserNotice(pid: pid, dir: dir)
}

// MARK: - What Claude Code itself says about the dialog

/// Claude Code's name for a structured question dialog (`AskUserQuestion`) in its session registry.
let claudeQuestionDialogWaitingFor = "input needed"

/// One reading of the registry Claude Code keeps per session at `<config home>/sessions/<pid>.json`,
/// whatever its `status`. `idle`, `busy` and `waiting` are the values read off 2.1.280; `waitingFor`
/// is present only while `waiting` (`"permission prompt"` for every permission kind including
/// ExitPlanMode, `"input needed"` for the question kind); `version` is Claude Code's own.
///
/// WHY THIS FILE AND NOT THE NOTICE. From 2.1.280 a structured question fires the same
/// `permission_prompt` notification, with the same message, as a tool permission does, and its tool
/// call reaches the transcript only once it is answered (H1 rerun O5, measured 2026-09-23). The
/// registry is written the moment the dialog opens and the moment it closes.
struct ClaudeRegistryReading: Equatable {
    var status: String
    var waitingFor: String?
    var statusUpdatedAt: Date?
    var version: String?
    var isWaiting: Bool { status == "waiting" }
}

/// nil ONLY when the registry cannot speak for this child: no file, unparseable, no `status`, or a
/// record naming another pid. A readable record with any status is a reading, "not waiting"
/// included. The two are kept apart on purpose: "cannot say" hands the decision to the older rules,
/// "says the dialog is gone" is a fact (`claudeDialogOpen`).
func readClaudeRegistry(configHome: URL, childPid: Int) -> ClaudeRegistryReading? {
    let file = configHome.appendingPathComponent("sessions/\(childPid).json")
    guard let data = try? Data(contentsOf: file),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (object["pid"] as? Int) == childPid,
          let status = object["status"] as? String else { return nil }
    return ClaudeRegistryReading(
        status: status,
        waitingFor: object["waitingFor"] as? String,
        statusUpdatedAt: (object["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
        version: object["version"] as? String)
}

/// Whether the dialog behind a HARD notice is open, in Claude Code's own words, or nil when it has
/// none and the rules that stood before the registry was read must decide.
///
///   true   the registry is readable and says `waiting`: a dialog is on top and only a person closes
///          it. Nothing the transcript or the keyboard does counts (H1f B5t: the main turn's own
///          Read result closed a background agent's dialog that was still on screen).
///   false  the registry is readable, does not say `waiting`, and HAD said `waiting` for this very
///          notice on an earlier tick of the same child (`witnessed`): the dialog this notice was
///          about has been closed, and nothing the transcript failed to write keeps it open (H1f
///          B1x: a lone agent's dialog refused with Esc stood 116 s until the agent's own task
///          notification moved the main chain).
///   nil    unreadable, or never witnessed: no fact.
///
/// THE HANDSHAKE IS THE WHOLE SAFETY ARGUMENT. `status` is undocumented (2.1.280, measured on 7
/// dialogs across 5 shapes: the stamp never moved while a dialog stood, and left `waiting` within
/// 100 ms of every Esc and Enter). A version that never writes `waiting`, or spells it otherwise,
/// never reaches `false`, so the worst it can do is fall back to the older rules, never close a
/// dialog nobody has answered. `statusUpdatedAt` is deliberately not an input: if a future build
/// moved it while a dialog stood, reading it would close early.
func claudeDialogOpen(_ notice: UserNotice, registry: ClaudeRegistryReading?, witnessed: Bool) -> Bool? {
    guard userWait(notificationType: notice.type) == .hard, let registry else { return nil }
    if registry.isWaiting { return true }
    return witnessed ? false : nil
}
