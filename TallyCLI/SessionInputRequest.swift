import Foundation

// How `tally session send` reaches ONE running session: the request file it writes, the answer the
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
///
/// TYPING AND SENDING ARE ONE ACT, which is why there is no flag here saying which was meant. What
/// this feature is FOR is triggering the things a session cannot trigger for itself - `/clear`,
/// `/compact`, an answer to a permission prompt - and text left sitting in a composer triggers
/// nothing: it waits for a person to press Return, and a person who is there to press it did not
/// need any of this (Albert, 2026-08-13). So every request is a whole instruction, and the record
/// has one field for what to type.
struct SessionInputRequest: Codable, Equatable {
    /// MILLISECONDS since the unix epoch, like the switch stamp and for the same reason: a
    /// supervisor acts only on a stamp strictly newer than the one it has served, and two requests a
    /// second apart are two requests a caller really makes.
    var epoch: Int
    /// The text to type, verbatim, before Return is pressed. May be empty, which is a request to
    /// press Return and nothing else - the shape that answers a prompt sitting on its default.
    var text: String
    /// HOW LONG THE CALLER WILL BE THERE, in seconds from `epoch`, and nil when it did not say.
    ///
    /// It exists because the answer to this request occupies the address for as long as somebody
    /// might still come back for it, and one caller now leaves early by design: a send into its OWN
    /// session waits `sessionInputSelfWaitSeconds` and then returns, because staying would hold
    /// open the turn the line is waiting for (SessionSendWait.swift). Judging its answer by the
    /// long wait made a receipt nobody would ever read squat the address for the rest of two and a
    /// half minutes, and the next legitimate send there was refused as a duplicate - measured at up
    /// to 144s (codex review of 0c9798b).
    ///
    /// The supervisor copies it onto the answer, which is where it is read (`sessionInputOccupant`).
    /// OPTIONAL AND ADDITIVE, the rule this whole channel is under: a request from a CLI that
    /// predates the field decodes with nil, and nil means the longest wait, which is exactly the
    /// behaviour that stood before it existed.
    var waitSeconds: Int?
}

/// What became of one request, in the vocabulary both ends share.
enum SessionInputOutcome: String {
    /// Typed and sent.
    case submitted
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

    /// Whether this outcome means the text reached the session. One word, because there is one way
    /// for it to land: typed and sent.
    var delivered: Bool { self == .submitted }
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
    /// How long the caller that asked for this said it would wait, copied off the request
    /// (`SessionInputRequest.waitSeconds` states why it travels). nil when it did not say, which
    /// reads as the longest wait any caller makes.
    var waitSeconds: Int?

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

// MARK: - Kept to this user

// THE SAME DECISION THE AUDIT LOG IS UNDER, and it has to be, or the two contradict each other in
// one feature. `sessionInputLogMode` (SessionInput.swift) argues that a record of text typed into a
// live conversation is CONTENT rather than telemetry, and so is not kept at the 0644 the rest of
// `~/.tally` uses. Everything in this directory is the same content, and less redacted: the log
// keeps 40 characters with the control bytes replaced, a request file holds the whole line
// verbatim, and it can sit here for the length of the TTL waiting for a turn to end.
//
// The default modes were exactly what that argument refuses. A umask of 022 makes a `Data.write` a
// 0644 file, `~/.tally` and `$HOME` are both traversable, and the directory was 0755: measured on
// this machine by review, not deduced.
//
// WHAT THIS DOES AND DOES NOT BUY, said plainly so nobody has to rediscover it: it closes READING
// by other accounts on the machine. It does not close WRITING by this user's own processes, which
// could forge a request and have it typed into a terminal - anything running as this user can
// already edit `~/.claude/settings.json`, install a hook or change PATH, and that trade is argued
// in section 4.1 of the design document rather than being an oversight here. A same-uid bar is
// still a bar worth having over a same-machine one.

/// The mode every file in this directory is kept at: readable by its owner and by nobody else.
let sessionInputFileMode = 0o600

/// And the directory itself, which is what stops another account listing the pids that have
/// requests pending even where it cannot read them.
let sessionInputDirMode = 0o700

/// Make the request directory, at `sessionInputDirMode`, and bring an existing one in to it.
///
/// IT CONVERGES rather than only setting the mode at creation, for the reason `appendSessionInputLine`
/// gives about the log beside it: the directory that matters is the one an earlier build already
/// made, and a mode applied only at creation would never reach it. Checked before it is set, so the
/// ordinary write costs a `stat` rather than a `chmod`.
/// `log` HAS NO DEFAULT, the rule `appendHandoffLine` states about its own sink: this is the one
/// path here that writes into the user's audit history, and a default is what lets a test reach it
/// by saying nothing.
func makeSessionInputDirectory(_ dir: URL, log: URL) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: dir.path) else {
        // The leaf only: an intermediate `~/.tally` created on the way is left at its usual mode,
        // since everything else in it is the 0644 telemetry this directory is deliberately unlike.
        return try manager.createDirectory(at: dir, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: sessionInputDirMode])
    }
    guard (try? manager.attributesOfItem(atPath: dir.path))?[.posixPermissions] as? Int
        != sessionInputDirMode else { return }
    do {
        try manager.setAttributes([.posixPermissions: sessionInputDirMode], ofItemAtPath: dir.path)
    } catch {
        // NOT FATAL AND NOT SILENT. The write goes ahead: a directory that cannot be narrowed is
        // still a directory this session's requests have to pass through, and refusing to type
        // would take the feature away over a condition the caller cannot fix from where they
        // stand. But a directory left traversable is exactly what the mode is for, so it leaves a
        // line rather than nothing - a `try?` here would make the difference between "narrowed"
        // and "could not be narrowed" invisible on the one channel that records this feature.
        appendSessionInputLine(sessionInputDirectoryModeLine(dir: dir, failure: error), to: log)
    }
}

/// Write `data` to `file` atomically AND privately.
///
/// BOTH HALVES IN ONE FUNCTION because doing either the obvious way loses the other.
/// `Data.write(options: .atomic)` writes a temporary and renames it over the destination, and a
/// rename carries the TEMPORARY's mode - which is the umask's, 0644 - so pre-creating the
/// destination at 0600 buys nothing at all: the inode that ends up at that path is the one this
/// process just made under a different name. So the temporary is the thing that has to be created
/// closed, and `rename(2)` (the same primitive `.atomic` uses) puts it in place with the mode it
/// was made with.
///
/// AND IT IS `open(2)` RATHER THAN `FileManager.createFile`, which is a distinction the first
/// version of this got wrong in a way no measurement of the finished file can see. `createFile`
/// creates the file under the UMASK and applies the attributes AFTERWARDS, so under the usual 022
/// there is a real window in which a file holding the whole of somebody's line is 0644 on disk -
/// and the check that "the mode is 0600" passes anyway, because it runs after the window has
/// closed (codex review of 1615990). `open` takes the mode as an argument of the creating call, so
/// the inode has never existed at any other mode; 0600 also survives every ordinary umask, which
/// only ever clears bits this mode does not set.
///
/// `O_EXCL` because the name is ours to own: a collision (a leftover from a killed write, an
/// unlikely UUID repeat) becomes an error rather than a silent overwrite of a file somebody else is
/// in the middle of.
func writeSessionInputPrivately(_ data: Data, to file: URL, in dir: URL,
                                log: URL = sessionInputLog) throws {
    try makeSessionInputDirectory(dir, log: log)
    let temp = dir.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
    let handle = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(sessionInputFileMode))
    guard handle >= 0 else { throw sessionInputPOSIXError(errno) }
    var failure: Int32?
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = write(handle, bytes.baseAddress!.advanced(by: offset),
                                bytes.count - offset)
            // A short write is not a failure, it is the rest of the loop; only an error ends it,
            // and EINTR is not even that (a signal landing mid-write must not lose the request).
            if written < 0 {
                guard errno == EINTR else { failure = errno; return }
                continue
            }
            offset += written
        }
    }
    // CLOSING IS PART OF WRITING, and its answer is not decoration. A filesystem may defer a write
    // error until the descriptor is closed (EIO is the documented case, and a network mount is
    // where it actually happens), so bytes that every `write` accepted can still be incomplete
    // until this returns. Ignoring it publishes a truncated request through the rename below and
    // tells the caller it was typed (codex review of 80499b3).
    //
    // CLOSED EXACTLY ONCE, whatever it answers: the descriptor is deallocated even when close
    // reports an error, so a retry or a second close on the failure path would be operating on a
    // number that no longer belongs to this file.
    let closeFailure = close(handle) == 0 ? nil : errno
    // The write's own error leads: it says what went wrong first, and a close error following it is
    // the same failure seen a second time.
    if let failure = failure ?? closeFailure {
        try? FileManager.default.removeItem(at: temp)
        throw sessionInputPOSIXError(failure)
    }
    guard rename(temp.path, file.path) == 0 else {
        let code = errno
        try? FileManager.default.removeItem(at: temp)
        throw sessionInputPOSIXError(code)
    }
}

/// A failed syscall as something a caller can print. Its own function so the three sites above
/// cannot describe the same failure two ways.
func sessionInputPOSIXError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
}

/// This session's pending request, or nil when there is none (or it cannot be read).
func readSessionInputRequest(sessionKey: String, dir: URL = sessionInputDir)
    -> SessionInputRequest? {
    guard let data = try? Data(contentsOf: sessionInputFile(sessionKey: sessionKey, dir: dir))
    else { return nil }
    return parseSessionInput(data)
}

/// Stamp a request for one session. Atomic and private, on the terms `writeSessionInputPrivately`
/// states: a supervisor polling mid-write reads either the previous request or this one, never half
/// of either, and no other account on this machine reads either.
func writeSessionInputRequest(_ request: SessionInputRequest, sessionKey: String,
                              dir: URL = sessionInputDir) throws {
    guard let data = sessionInputData(request) else {
        throw CocoaError(.coderInvalidValue)
    }
    try writeSessionInputPrivately(data, to: sessionInputFile(sessionKey: sessionKey, dir: dir),
                                   in: dir)
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

/// Publish what became of a request. Best-effort, and it answers nil when it landed or WHY when it
/// did not.
///
/// THE REASON RATHER THAN A BARE `false`, because of what a lost answer costs on the other end: the
/// caller is blocked on this file, so a failure here is a caller that waits out its whole timeout
/// and then cannot tell "the supervisor never read it" from "the text was typed and the receipt was
/// lost". Those two want opposite things of it, and only the second makes a retry a duplicate line
/// in somebody's conversation. The one place that can still say which is this one, at the moment it
/// fails, so it hands the sentence up rather than a bit (codex review of 18b3174).
@discardableResult
func writeSessionInputResult(_ result: SessionInputResult, sessionKey: String,
                             dir: URL = sessionInputDir) -> String? {
    guard let data = sessionInputData(result) else { return "the answer could not be encoded" }
    do {
        try writeSessionInputPrivately(
            data, to: sessionInputResultFile(sessionKey: sessionKey, dir: dir), in: dir)
    } catch {
        return error.localizedDescription
    }
    return nil
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
