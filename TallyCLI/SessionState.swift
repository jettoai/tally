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

// Claude Code fires its `Notification` event for nine different things, and only five of them mean
// somebody is being waited for. The other four are NEWS - a login that succeeded, a background
// agent that finished, an elicitation that completed or was answered - and every one of them
// arrives at the end of something rather than at a stop in it.
//
// Reading all nine as a wait is not a small over-count, it is the failure mode this feature cannot
// have: a session that dispatches subagents would go red every time one FINISHED and stay red until
// somebody typed in that terminal. The proposal's own success measure is "misreporting low enough
// not to cost trust", and a red dot that means "an agent completed" costs exactly that.
//
// BOTH ENDS READ THIS ONE VOCABULARY, which is why it is here rather than beside either of them:
// the app builds the registration's `matcher` from the waiting list (so Claude Code never fires the
// hook for the rest), and the hook itself refuses a settled type it recognises (so a registration
// written by an older app, or a matcher a future Claude Code stops honouring, is still filtered).
// Two hand-written copies of a list like this is how one end comes to allow what the other blocks.

/// The five `Notification` types that mean a person is being waited for. In the order the
/// documentation lists them, and the whole of what the registration's matcher asks for.
let waitingNotificationTypes = ["permission_prompt", "idle_prompt", "agent_needs_input",
                                "elicitation_dialog", "elicitation_url_dialog"]

/// The four that are news rather than a wait. Held as its own list rather than derived as "not one
/// of the five above", and that is the fail-open rule in the type system: a TENTH type invented by
/// a later Claude Code is in neither list, and must be treated as a possible wait rather than
/// silently dropped, because a missed wait is the state this board exists to show.
let settledNotificationTypes: Set<String> = ["auth_success", "agent_completed",
                                             "elicitation_complete", "elicitation_response"]

/// The matcher the registration carries, built from the list above so the two cannot drift.
/// Claude Code matches this as a regular expression against the notification's type.
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

/// The file a supervisor's state reading lives in.
func sessionStateFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + sessionStateSuffix)
}

/// Write the reading. Best-effort and atomic, like every other file on this track.
func writeSessionState(_ record: SessionStateRecord, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(record) else { return }
    try? data.write(to: sessionStateFile(pid: pid, dir: dir), options: .atomic)
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
