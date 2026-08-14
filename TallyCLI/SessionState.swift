import Foundation

// WHAT A SUPERVISED SESSION IS DOING, published for the surfaces outside its terminal.
//
// One file per supervisor pid in `supervisorStateDir`, exactly like the drift badge, the pending
// notice and the context reading beside it: read only while that pid is alive, swept when it is
// not, best-effort and atomic at every step, and additive-only in its fields. A `.state` suffix
// keeps it beside the presence entry rather than replacing it, so `liveSupervisorPids` (which
// parses names as pids) still counts one live session per supervisor.
//
// COMPILED INTO BOTH TARGETS (see project.yml), which is what the split in this file is about: the
// record, where it lives and how to read it are here, and everything that DECIDES a state stays in
// SessionStateSync.swift with the supervisor. Only the supervisor can decide one - the transcript,
// the open tool call, the subagent walk and the terminal's own keyboard are all in its hands and
// none of them are in the app's - so the app reads and never computes. That is the same division
// the drift badge and the pending notice already keep, one question over.

/// The four things a session can be, and the only vocabulary any surface uses for them.
///
/// `unknown` is a first-class answer rather than a failure: a supervisor whose child has not bound
/// a transcript yet knows the session is running and knows nothing else about it, and saying "idle"
/// there would be a guess dressed as a reading (`WorktreeActivity` sets the same precedent).
enum SupervisedState: String, Codable, Sendable {
    /// The conversation is moving: the transcript is being written, a tool call is still open, or a
    /// subagent is still writing.
    case working
    /// Claude Code has asked for something and nobody has answered yet (a permission request, a
    /// question). The one state that is a CALL FOR SOMEBODY, which is what the panel's red dot and
    /// the menu bar's are for.
    case blocked
    /// Quiet, with nothing waiting on an answer.
    case idle
    /// Running, with nothing to say about it yet.
    case unknown
}

/// The suffix separating a state reading from the presence/drift file of the same pid.
let sessionStateSuffix = ".state"

/// The knock that says a session's state word has moved. The FILE IS THE TRUTH and this only saves
/// the app from polling a directory it is not looking at, which is the rule every channel under
/// `~/.tally` follows (PickContract.swift states it in full). Reverse-DNS because a distributed
/// notification name is a machine-wide namespace.
let sessionStateChangedNotification = "ai.jetto.tally.sessionStateChanged"

/// One session as the status board reads it: what it is doing, since when, and the identity a row
/// needs to name it and to jump to its terminal.
///
/// THE STATE IS A STRING RATHER THAN THE ENUM ABOVE, deliberately. A `Codable` enum rejects a raw
/// value it has never heard of, and rejecting is decoding the WHOLE record as nil - so an app one
/// version behind a CLI that grew a fifth state would drop those sessions off the board entirely
/// instead of drawing them as unknown. The string decodes whatever is written and `supervised`
/// below maps an unfamiliar word onto `unknown`, which is what that word means to a reader that
/// does not know it.
///
/// EVERY FIELD BUT THE FIRST THREE IS OPTIONAL, on the additive rule this whole track is under: a
/// record written by an older supervisor decodes with nil rather than being rejected.
struct SessionStateRecord: Codable, Equatable, Sendable {
    /// One of `SupervisedState`'s raw values.
    var state: String
    /// When the session ENTERED this state, preserved for as long as it holds. What a row shows as
    /// the age of the wait rather than the age of the last poll tick.
    var since: Date
    /// When this record was last written.
    var updatedAt: Date
    /// What Claude Code said it was waiting for, while it is waiting. nil in every other state.
    var reason: String?
    /// WHICH KIND OF EVENT is standing unanswered (`UserNotice.type`): the difference between a
    /// permission request and "the floor is free", which the sentence above does not carry. nil
    /// when no event stands, and when the one that does named no type.
    ///
    /// ABOUT THE EVENT RATHER THAN ABOUT THE DECISION, which is why it is published even where the
    /// state word is not `blocked`. That combination is the single most diagnostic reading this
    /// record can carry: `working` beside `idle_prompt` says the hook fired, the event is standing,
    /// and the session is not red because the conversation is not quiet - which is precisely the
    /// judgement that was wrong before 2026-08-15 and precisely what somebody re-opening the
    /// question needs to see. `reason` is the other half and follows the decision, because it is
    /// what a card PRINTS about a wait.
    ///
    /// PUBLISHED FOR THE DIAGNOSIS RATHER THAN FOR THE DECISION. Nothing reads it back to decide
    /// anything - the supervisor decides from the notice itself, on the tick. It is here because a
    /// red dot was, until then, unanswerable from outside the process that drew it: `blocked` on
    /// its own says nothing about which of six events produced it, and answering that question took
    /// a strings dump of Claude Code's binary.
    var noticeType: String?
    /// Whether the conversation was quiet on the tick this record was written (`isQuiet`: the file
    /// silent, no tool call outstanding, no subagent writing). The other half of the same
    /// diagnosis - a soft wait is only a call for somebody while this is true - and the one input
    /// that cannot be recovered afterwards, since it is read from mtimes that keep moving.
    var quiet: Bool?
    /// The account this session runs on right now, so a row can name it without knowing anything
    /// about supervisor pids.
    var accountID: String?
    /// The checkout this session was launched in, fully resolved: what the terminal jump matches a
    /// window's working directory against.
    var directory: String?
    /// The repository this session is in, by name (`pickProject`).
    var project: String?
    /// The parallel line's own name, or nil on the trunk (`pickProject`).
    var worktree: String?
    /// The model serving this session, short form: what was OBSERVED answering the last turn where
    /// there is one, and what the child was launched with otherwise (SessionContext.swift states
    /// why those are different questions).
    var model: String?
    /// The Claude Code process itself, for the terminal jump's fallback: its ancestors lead to the
    /// terminal emulator that owns the window. Published only while it can be proved
    /// (`readSupervisorChild`), so this names a running Claude Code rather than a number that was
    /// one.
    var childPid: Int?

    /// The state this record names, with anything unfamiliar read as `unknown` (see above).
    var supervised: SupervisedState { SupervisedState(rawValue: state) ?? .unknown }
}

// MARK: - Which notifications are a WAIT

// Claude Code fires its `Notification` event for a dozen different things, and only some of them
// mean somebody is being waited for. Four are NEWS - a login that succeeded, a background agent
// that finished, an elicitation that completed or was answered - and every one of them arrives at
// the end of something rather than at a stop in it.
//
// Reading them all as a wait is not a small over-count, it is the failure mode this feature cannot
// have: a session that dispatches subagents would go red every time one FINISHED and stay red until
// somebody typed in that terminal. The proposal's own success measure is "misreporting low enough
// not to cost trust", and a red dot that means "an agent completed" costs exactly that.
//
// BOTH ENDS READ THIS ONE VOCABULARY, which is why it is here rather than beside either of them:
// the app builds the registration's `matcher` from the waiting list (so Claude Code never fires the
// hook for the rest), and the hook itself refuses a settled type it recognises (so a registration
// written by an older app, or a matcher a future Claude Code stops honouring, is still filtered).
// Two hand-written copies of a list like this is how one end comes to allow what the other blocks.

/// The `Notification` types that mean a person is being waited for, and the whole of what the
/// registration's matcher asks for.
///
/// THE MATCHER IS A LIST RATHER THAN A PATTERN at the far end: Claude Code compares a matcher made
/// only of `[A-Za-z0-9_|]` against the type by splitting on `|` and testing membership, and reaches
/// for a regular expression only when it holds anything else (read off 2.1.233, 2026-08-15). So a
/// type absent from this list is one the hook is never fired for at all, and the fail-open belt in
/// `notificationWaitsForUser` cannot reach it. Adding one is therefore the only way to hear about
/// it.
///
/// `worker_permission_prompt` is here for exactly that reason: it is a permission request raised
/// for a background worker rather than the main conversation, it exists in 2.1.233, and until it
/// was named here that request stood with nothing on the board.
///
/// KNOWN AND DELIBERATELY UNASKED-FOR, so the omissions are a choice rather than an oversight:
/// `push_notification`, `computer_use_enter` and `computer_use_exit` are in the same enumeration
/// and none of them is a person being waited for.
let waitingNotificationTypes = ["permission_prompt", "worker_permission_prompt", "idle_prompt",
                                "agent_needs_input", "elicitation_dialog",
                                "elicitation_url_dialog"]

/// The four that are news rather than a wait. Held as its own list rather than derived as "not one
/// of the waiting ones above", and that is the fail-open rule in the type system: a type invented
/// by a later Claude Code is in neither list, and must be treated as a possible wait rather than
/// silently dropped, because a missed wait is the state this board exists to show.
let settledNotificationTypes: Set<String> = ["auth_success", "agent_completed",
                                             "elicitation_complete", "elicitation_response"]

/// The matcher the registration carries, built from the list above so the two cannot drift.
/// Claude Code compares it against the notification's type as an exact `|`-separated list, because
/// it holds nothing outside `[A-Za-z0-9_|]` (`waitingNotificationTypes` states what that costs).
let notificationHookMatcher = waitingNotificationTypes.joined(separator: "|")

/// Whether an event of this type is somebody being waited for.
///
/// FAIL-OPEN, deliberately and in both directions: a type this build does not recognise, and an
/// event that carries no type at all (an older Claude Code, or a payload whose field is spelled
/// differently), are both treated as a wait. The cost of that is a state that clears on the next
/// tick anyway; the cost of the opposite is a session sitting blocked with nothing on the board.
func notificationWaitsForUser(_ type: String?) -> Bool {
    guard let type else { return true }
    return !settledNotificationTypes.contains(type)
}

// MARK: - And which KIND of wait it is

/// How much a standing wait outranks what the transcript says.
///
/// TWO KINDS, because the events are not alike and reading them alike is what the board was getting
/// wrong. `permission_prompt` means the session cannot proceed until somebody answers, and it is
/// true whatever the transcript is doing - a dialog is open, and a subagent writing in the
/// background is not an answer to it. `idle_prompt` means only that Claude Code has finished
/// speaking and nobody has typed since, which is ALSO true of a session that has dispatched a
/// fan-out and is waiting on it: the main transcript stops, the 60s timer fires, and nobody is
/// being waited for at all.
enum UserWait: Sendable {
    /// The session cannot move until a person answers. Outranks everything.
    case hard
    /// The floor is free, which is a call for somebody only if nothing else is happening.
    case soft
}

/// The waiting types that are merely an invitation to speak. Held as its own list, and small on
/// purpose: everything not named here is hard, which is the direction a wrong guess is free in.
let softWaitNotificationTypes: Set<String> = ["idle_prompt"]

/// Which kind of wait an event of this type is.
///
/// FAIL-OPEN TO HARD, on the same rule as `notificationWaitsForUser` above and for the same reason:
/// an event with no type (an older Claude Code, or a notice written before the type was recorded)
/// and a type this build has never heard of both keep the behaviour that stood before this
/// distinction existed. A hard reading over-reports; a soft one can hide a permission request
/// behind a subagent that happens to be writing.
func userWait(notificationType type: String?) -> UserWait {
    guard let type, softWaitNotificationTypes.contains(type) else { return .hard }
    return .soft
}

/// The file a supervisor's state reading lives in.
func sessionStateFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + sessionStateSuffix)
}

/// Write the reading. Best-effort and atomic, like every other file on this track.
///
/// IT SAYS WHETHER IT WORKED, unlike its neighbours, and the caller is required to look. The writer
/// on top of this keeps an in-memory copy of what it believes is on disk and suppresses a write
/// that would not change it; a failure it never heard about would leave that copy describing a
/// record that was never published, and the guard would then suppress every retry for the life of
/// the session. That is the shape of the defect `writeSupervisorAccount` carries a comment about
/// (a silent publish failure plus a delta that suppresses the retry), one document over.
@discardableResult
func writeSessionState(_ record: SessionStateRecord, pid: String,
                       dir: URL = supervisorStateDir) -> Bool {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(record) else { return false }
    do {
        try data.write(to: sessionStateFile(pid: pid, dir: dir), options: .atomic)
    } catch {
        return false
    }
    return true
}

/// Knock, so a panel that is not polling finds out now rather than at its next glance.
///
/// THE FILE IS THE TRUTH AND THIS IS ONLY A KNOCK (SessionState.swift's header states the rule the
/// whole `~/.tally` channel follows): delivery is not guaranteed, nothing is carried but the pid,
/// and every reader re-reads the directory when it arrives.
func postSessionStateChanged(pid: String) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(sessionStateChangedNotification), object: pid,
        userInfo: nil, deliverImmediately: true)
}

/// Read a supervisor's state reading, or nil when there is none (or the file is from a format this
/// build does not know, which reads the same way: nothing to say).
func readSessionState(pid: String, dir: URL = supervisorStateDir) -> SessionStateRecord? {
    guard let data = try? Data(contentsOf: sessionStateFile(pid: pid, dir: dir)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SessionStateRecord.self, from: data)
}

/// This session is over. Unlinked rather than emptied: absence is the whole signal, and the
/// presence entry beside it is the one that has to keep existing until the supervisor exits.
func clearSessionState(pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.removeItem(at: sessionStateFile(pid: pid, dir: dir))
}

// MARK: - Reading the board

/// One live session as the board sees it: which supervisor it is, and what that supervisor has
/// published about it so far.
///
/// THE RECORD IS OPTIONAL BECAUSE THE SESSION IS NOT, the same rule `LiveSupervisor` is under. A
/// supervisor from a build that predates this feature publishes nothing here and is running all
/// the same, as is one in the two seconds between its registration and its first tick. Dropping
/// those would make the board quietly under-count, which is the failure `reloadLegacyNotice` was
/// written for one question over: the count is what makes the silence a lie.
struct LiveSessionState: Equatable, Sendable {
    let supervisorPid: pid_t
    let record: SessionStateRecord?
}

/// Every live session on this machine, oldest supervisor first so the board's order is stable.
///
/// FROM THE PRESENCE ENTRY, which a supervisor writes before it spawns anything and keeps until it
/// exits, so the roster is complete from the first instant of a session rather than from its first
/// published state. A supervisor that is gone is ignored rather than trusted, exactly as the drift
/// badge treats one: the startup sweep unlinks its files, but a reader running in between must not
/// paint a session that has already exited.
func liveSessionStates(dir: URL = supervisorStateDir) -> [LiveSessionState] {
    // On the pid as a NUMBER, like `liveSupervisors`: the directory listing has no order worth
    // relying on, and sorting names as text puts 9000 after 10000.
    liveSupervisorPids(dir: dir).sorted().map {
        LiveSessionState(supervisorPid: $0, record: readSessionState(pid: String($0), dir: dir))
    }
}
