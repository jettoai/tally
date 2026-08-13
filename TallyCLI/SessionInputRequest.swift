import Foundation

// How `tally session type` reaches ONE running session: the request file it writes, the answer the
// supervisor writes back, and the two limits both ends have to agree on. The decision a poll tick
// makes about a request lives next door in SessionInput.swift; the command that writes one is in
// SessionInputCommand.swift. That is the same three-way split `tally account` keeps (SwitchRequest /
// SessionSwitch / SwitchCommand) and `tally model` after it, and it is kept here for the same
// reason: the channel is what the CLI, the supervisor and the state-directory sweep all read.
//
// ADDRESSED THE SAME WAY EVERY PER-SESSION REQUEST IS: a directory of files named for the supervisor
// pid that will read one, which that supervisor stamped into its child's environment
// (`TALLY_SUPERVISOR_PID`) and everything the child spawns inherits. So the ordinary caller - an
// agent inside the conversation, running this as a tool call - addresses its own session by simply
// being in it, and a shell opened separately in the project directory falls back to the registry of
// live supervisors (SessionAddressing.swift owns that rule).
//
// JSON RATHER THAN THE LINE-PER-FIELD FORMAT ITS NEIGHBOURS USE, and that is the one deliberate
// departure. The payload is arbitrary user text: a newline in it would end the record under a
// line-based reader, and every escaping scheme that fixes it is a second format to keep in step
// across two processes. `Codable` costs nothing here because nothing has to read this file with an
// eye or a `grep` - the audit log is what a person reads (SessionInput.swift).

// MARK: - The two limits

/// The most text one request may carry, in UTF-8 BYTES rather than characters.
///
/// Bytes because the cost being bounded is bytes: injection is one `ioctl` per byte with a pause
/// between them (SessionInput.swift), so 200 bytes is the worst case the poll tick pays for - a
/// character limit would let one emoji-heavy line cost four times what a Latin one does.
///
/// 200 rather than a round thousand because of what this is FOR: a slash command, a permission
/// answer, a short instruction typed into a composer. Anything longer is a prompt, and a prompt
/// belongs in the conversation rather than in a supervisor's terminal write.
let sessionInputMaxBytes = 200

/// How long a request stays actionable. Beyond this it is refused rather than typed.
///
/// TWO MINUTES RATHER THAN THE THIRTY SECONDS THE DESIGN FIRST PROPOSED, and the reason is the whole
/// shape of this feature: the caller is normally an agent INSIDE the session, running this as a tool
/// call, so at the instant the request lands that session is by definition `working` - the tool call
/// itself is the turn that has not closed yet. A request that expired in thirty seconds would expire
/// while the only state it can ever be served from is still on its way.
///
/// It is not merely a courtesy either. Pids are reused, so a request left behind by a session that
/// exited must not be typed into whatever gets that pid next; the served-epoch seed
/// (`SessionInputState`) closes the common case and this closes the rest.
let sessionInputTTL: TimeInterval = 120

// MARK: - The files

/// One request file per supervised session, named for the supervisor pid that will read it. A
/// directory rather than a single file for the reason `switchRequestDir` gives: these are addressed,
/// two sessions can each have one pending, and neither may read the other's.
let sessionInputDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/input")

/// The suffix under which the supervisor writes back what became of a request.
///
/// A FILE OF ITS OWN rather than a rewrite of the request, because the two have different writers
/// and different lifetimes: the CLI owns the request until it is served, the supervisor owns the
/// answer, and a channel where both ends write the same path has a lost-update window in it for
/// nothing gained.
let sessionInputResultSuffix = ".result"

/// What one invocation asks to be typed.
struct SessionInputRequest: Codable, Equatable {
    /// MILLISECONDS since the unix epoch, like the switch stamp and for the same reason: a
    /// supervisor acts only on a stamp strictly newer than the one it has served, and two requests a
    /// second apart are two requests a caller really makes.
    var epoch: Int
    /// The text to type, verbatim. May be empty, which is a request to press Return and nothing else
    /// (`submit` is then the whole instruction) - the shape that answers a permission prompt sitting
    /// on its default.
    var text: String
    /// Whether to press Return once the text is in.
    var submit: Bool
}

/// What became of one request, in the vocabulary both ends share.
enum SessionInputOutcome: String {
    /// Typed and sent.
    case submitted
    /// Typed into the composer and left there, because the request did not ask for Return.
    case injected
    /// Longer than `sessionInputMaxBytes`. Normally caught by the command before anything is
    /// written; the supervisor checks it again because the channel is a directory anything running
    /// as this user can write into.
    case refusedTooLong = "refused-too-long"
    /// It expired while the session had nothing to say about itself (`unknown`), which is the one
    /// state that never becomes injectable on its own: a session that cannot report what it is doing
    /// is not one to type into blind.
    case refusedNotReporting = "refused-not-reporting"
    /// It expired while the session was busy, or while somebody was typing in that terminal.
    case refusedExpired = "refused-expired"
    /// The terminal refused the write. `detail` carries the errno, because the two that happen -
    /// no controlling terminal, and a kernel that has retired this ioctl - are told apart by nothing
    /// else.
    case failedTTY = "failed-tty"

    /// Whether this outcome means the text reached the session.
    var delivered: Bool { self == .submitted || self == .injected }
}

/// The supervisor's answer to one request.
struct SessionInputResult: Codable, Equatable {
    /// The request this answers. The caller checks it, because a husk from an earlier request can
    /// still be on disk when a new one is written - and reading somebody else's outcome as your own
    /// is the one failure a fire-and-forget channel can hide completely.
    var epoch: Int
    /// One of `SessionInputOutcome`'s raw values.
    ///
    /// A STRING RATHER THAN THE ENUM, the rule `SessionStateRecord` states one directory over: a
    /// `Codable` enum rejects a raw value it has never heard of, and rejecting is decoding the WHOLE
    /// record as nil - so a CLI one version behind a supervisor that grew a sixth outcome would poll
    /// until it timed out rather than reporting the word it was handed.
    var outcome: String
    /// Worth saying alongside it: an errno, the state it expired in, the limit it exceeded.
    var detail: String?

    /// The outcome this names, or nil when it is a word this build has never heard of.
    var resolved: SessionInputOutcome? { SessionInputOutcome(rawValue: outcome) }

    /// Whether the text reached the session. FAIL-CLOSED on an unfamiliar word: a caller deciding
    /// whether to retry must not read "I do not know that outcome" as "it landed".
    var delivered: Bool { resolved?.delivered ?? false }
}

func sessionInputFile(sessionKey: String, dir: URL = sessionInputDir) -> URL {
    dir.appendingPathComponent(sessionKey)
}

func sessionInputResultFile(sessionKey: String, dir: URL = sessionInputDir) -> URL {
    dir.appendingPathComponent(sessionKey + sessionInputResultSuffix)
}

// MARK: - The format, pure

/// Encode a record for this channel, or nil when it cannot be encoded. Pure, so a round trip is
/// assertable without a home directory.
func sessionInputData<Record: Encodable>(_ record: Record) -> Data? {
    try? JSONEncoder().encode(record)
}

/// Decode one, or nil when the bytes are not a whole record.
///
/// Anything unparseable reads as ABSENT rather than as a partial request, the rule
/// `parseSwitchRequest` states: a truncated write must never read as an instruction to type half a
/// line into somebody's terminal.
func parseSessionInput<Record: Decodable>(_ data: Data, as type: Record.Type = Record.self)
    -> Record? {
    try? JSONDecoder().decode(Record.self, from: data)
}

// MARK: - Reading and writing

/// This session's pending request, or nil when there is none (or it cannot be read).
func readSessionInputRequest(sessionKey: String, dir: URL = sessionInputDir)
    -> SessionInputRequest? {
    guard let data = try? Data(contentsOf: sessionInputFile(sessionKey: sessionKey, dir: dir))
    else { return nil }
    return parseSessionInput(data)
}

/// Stamp a request for one session. Atomic (a temp file renamed over the destination), so a
/// supervisor polling mid-write reads either the previous request or this one, never half of either.
func writeSessionInputRequest(_ request: SessionInputRequest, sessionKey: String,
                              dir: URL = sessionInputDir) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = sessionInputData(request) else {
        throw CocoaError(.coderInvalidValue)
    }
    try data.write(to: sessionInputFile(sessionKey: sessionKey, dir: dir), options: .atomic)
}

/// The request is served: unlink it. The served stamp in memory is what makes the decision
/// idempotent; this only keeps the directory from collecting husks.
func clearSessionInputRequest(sessionKey: String, dir: URL = sessionInputDir) {
    try? FileManager.default.removeItem(at: sessionInputFile(sessionKey: sessionKey, dir: dir))
}

/// The answer waiting for this session, or nil when there is none.
func readSessionInputResult(sessionKey: String, dir: URL = sessionInputDir) -> SessionInputResult? {
    guard let data = try? Data(contentsOf: sessionInputResultFile(sessionKey: sessionKey, dir: dir))
    else { return nil }
    return parseSessionInput(data)
}

/// Publish what became of a request. Best-effort and it says whether it worked, because the caller
/// is blocked on this file: a failure is worth an audit line rather than silence.
@discardableResult
func writeSessionInputResult(_ result: SessionInputResult, sessionKey: String,
                             dir: URL = sessionInputDir) -> Bool {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = sessionInputData(result) else { return false }
    do {
        try data.write(to: sessionInputResultFile(sessionKey: sessionKey, dir: dir),
                       options: .atomic)
    } catch {
        return false
    }
    return true
}

/// The answer has been read: unlink it, so the next request cannot find this one waiting.
func clearSessionInputResult(sessionKey: String, dir: URL = sessionInputDir) {
    try? FileManager.default.removeItem(at: sessionInputResultFile(sessionKey: sessionKey, dir: dir))
}

/// Drop ANSWERS addressed to supervisors that are gone.
///
/// Its own loop beside `sweepDeadSessionRequests` rather than a call to it, and the reason is
/// written on that function: it reads a file name as a pid outright, so nothing in the directories
/// it sweeps may be suffixed - a rule this channel breaks by holding two documents per session.
/// Pointing it here would make its naming contract this directory's, and the request husks it does
/// sweep would start depending on a suffix rule it never agreed to. So each function reads exactly
/// the names it owns: that one the bare pids, this one the `.result` neighbours.
///
/// Swept by the command as it writes, which is the only moment anything here grows. A result the
/// command read is unlinked by the command; this is for the ones nobody came back for (a caller
/// killed mid-wait, a wait that timed out).
func sweepDeadSessionInputResults(dir: URL = sessionInputDir) {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    for file in files {
        let name = file.lastPathComponent
        guard name.hasSuffix(sessionInputResultSuffix) else { continue }
        let stem = String(name.dropLast(sessionInputResultSuffix.count))
        guard let pid = pid_t(stem), !supervisorAlive(pid) else { continue }
        try? FileManager.default.removeItem(at: file)
    }
}
