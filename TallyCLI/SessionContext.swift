import Foundation

// How big a supervised conversation has grown, published for the surfaces outside the terminal.
//
// The number the user actually wants before deciding anything about a session (restart it, hand it
// to another account, start a fresh one) is how much context a resume would have to reload. It is
// in the transcript already: every assistant event carries the usage of the call that produced it,
// and the figures of the newest one add up to how big the conversation is once that turn is in it.
//
// It rides the track the drift badge and the pending notice already use: one file per supervisor
// pid in `supervisorStateDir`, read only while that pid is alive, swept when it is not, best-effort
// at every step. A `.session` suffix keeps it beside the presence entry rather than replacing it,
// so `liveSupervisorPids` (which parses names as pids) still counts one live session per supervisor
// and a context reading can never be read as another one.

// MARK: - Reading the transcript

/// The context a resume would reload, from one transcript line, or nil when the line carries none.
///
/// `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the event: the three
/// halves of that call's input, whether they were sent fresh, written into the cache, or read back
/// out of it. Plus its own `output_tokens`, which is what the model then wrote INTO the
/// conversation. Every earlier turn's output is already inside these input figures, but the newest
/// one's is not: there is no later line to have absorbed it yet, and a resume reloads it all the
/// same, so leaving it out understates the newest reading by exactly one answer.
///
/// Substring extraction rather than a JSON parse, because this runs over every assistant line the
/// poll reads, including the whole replayed history the first scan of a resumed session walks.
///
/// Three shapes in the real data decide the details (sampled from this machine's transcripts,
/// 2026-08-04). `usage` holds an `iterations` array repeating every one of these keys per API call,
/// so the window stops before it: the totals read are the top-level ones. All THREE input figures
/// must be inside that window or the answer is nil, because a partial sum is the failure worth
/// avoiding above all others here - a writer that emitted `iterations` between them would otherwise
/// publish `input_tokens` alone, a two-digit number where the conversation is half a million
/// (caught in review, 2026-08-04). The reading simply stops moving instead. `output_tokens` is the
/// one field taken when present and skipped when not: missing it costs one turn's answer, which is
/// bounded and small, where missing a cache figure costs nearly everything.
///
/// And a zero total is never a real context: synthetic assistant turns (an interrupted call, an API
/// error) are written with an all-zero usage, and reporting one would wipe a genuine reading with a
/// 0 the way replayed history once poisoned `lastModel` (TranscriptWatcher.swift).
func contextTokens(inLine line: Substring) -> Int? {
    guard let usage = line.range(of: "\"usage\":{") else { return nil }
    var window = line[usage.upperBound...]
    if let iterations = window.range(of: "\"iterations\":") {
        window = window[..<iterations.lowerBound]
    }
    var total = 0
    for key in contextTokenFields {
        guard let value = tokenField(key, in: window) else { return nil }
        total += value
    }
    // The newest turn's own answer, when it is in the window (see above).
    total += tokenField("\"output_tokens\":", in: window) ?? 0
    return total > 0 ? total : nil
}

/// One `"<key>":<digits>` reading out of a usage window, or nil when the key is not in it (or
/// carries something that is not a number, e.g. `null`, which is a disagreement about the shape and
/// not a zero).
func tokenField(_ key: String, in window: Substring) -> Int? {
    guard let field = window.range(of: key) else { return nil }
    return Int(window[field.upperBound...].prefix { $0.isNumber })
}

/// The three input figures `contextTokens` requires, hoisted out of it because it runs on every
/// assistant line the poll reads. The leading quote is what keeps `"input_tokens":` off
/// `cache_creation_input_tokens`, whose own key carries an underscore in that position, so the
/// three stay independent whatever order a future writer emits them in.
let contextTokenFields = ["\"input_tokens\":", "\"cache_creation_input_tokens\":",
                          "\"cache_read_input_tokens\":"]

// MARK: - The state file

/// The suffix separating a context reading from the presence/drift file of the same pid.
let sessionContextSuffix = ".session"

/// One supervised session's published context reading.
struct SupervisedSession: Equatable, Codable {
    /// The account this session is running on right now, so a reader can attribute the number
    /// without knowing anything about supervisor pids. Rewritten by a handoff, like the reading.
    let accountID: String
    /// How big the conversation is as of its newest assistant turn, that turn's own answer
    /// included: what a resume of it costs before it does anything at all.
    let contextTokens: Int
    /// When this reading was taken. An idle session keeps a true number with an old stamp, so this
    /// is the age of the last turn rather than a freshness warning.
    let updatedAt: Date
    /// The account a `tally switch` pinned this session to, or nil when it follows automatic
    /// selection (SessionSwitch.swift). Published so a surface outside this terminal can say why a
    /// session is sitting on a dying account instead of being rebalanced off it.
    ///
    /// Additive, like every other field on this track: it has a default, so a document written
    /// before it existed decodes with nil rather than being rejected, and a reader that has never
    /// heard of it is unaffected.
    var sessionPin: String?
    /// The model and effort a `tally model` pinned this session to, or nil for an axis it follows
    /// the project profile and the fleet default on (SessionModel.swift). Additive on the same
    /// terms as `sessionPin`.
    var sessionModel: String?
    var sessionEffort: String?
    /// The model actually SEEN serving this session's most recent turn: the newest assistant
    /// event's model id, with the three guards `TranscriptWatcher.lastModel` applies (a real model
    /// id, on the main chain, later than this child's launch). nil until one has been read.
    ///
    /// AN OBSERVATION, WHERE THE PAIR BELOW IS A REQUEST, and the difference is the whole reason
    /// both are published. The command line is what was ASKED FOR, and it does not move when the
    /// answer does: a safeguard fallback, a quota degradation, or the user typing Claude Code's own
    /// `/model` all change which model serves the next turn without touching a single argv word. A
    /// reader with only the argv reports the model the session was launched on, confidently, at the
    /// exact moment it has stopped being true (raised in review of f17fb2c - whose own commit
    /// message called that the case that mattered most, while reading argv).
    ///
    /// The rule this file failed to apply is older than this feature and lives outside this repo:
    /// read the actual runtime result rather than predicting behaviour from a setting, whenever
    /// there is an actual result to read. There was.
    var observedModel: String?
    /// What the session ASKED FOR: the `--model` and `--effort` on the command line its child was
    /// spawned with.
    ///
    /// A SEPARATE PAIR FROM THE ONE ABOVE, and the distinction is the whole reason these exist. The
    /// pin is what the user asked for; this is what is on screen. They come apart routinely and
    /// none of the ways are exotic: a `--model` typed at launch, a session that started before its
    /// project declared a profile, and - the one that matters most - a quota fallback or a safeguard
    /// restore having moved the session onto another model already (ModelDegradation.swift,
    /// SafeguardDrift.swift). A reader with only the layers can compute what SHOULD be running and
    /// has no way at all to learn what is, which is exactly the question `tally model` is asked at
    /// the moment those paths have fired (found by smoke-testing the real binary, 2026-08-07).
    ///
    /// Additive like everything else on this track: a document written before these existed decodes
    /// with nil, which reads as "cannot say" rather than as "running nothing".
    var runningModel: String?
    var runningEffort: String?
    /// Claude Code's own id for the conversation this supervisor is watching: the stem of the
    /// transcript file it is tailing, which IS that id (measured 2026-08-07: a hook's `session_id`
    /// and the basename of its `transcript_path` are the same string).
    ///
    /// THE ONLY WITNESS THAT BINDS A PROMPT TO A SESSION. Everything else a second-hand caller
    /// holds is circumstantial: the environment marker is inherited by every descendant, and the
    /// working directory is shared by every session opened in a project. Neither separates a
    /// `claude` launched from INSIDE another supervised session in the same directory, where the
    /// inner session's prompts were resolved onto the outer conversation (codex review of 512303b).
    /// This does: the hook says which conversation its prompt came from, and this says which one
    /// each candidate supervisor is actually watching.
    ///
    /// Additive on the same terms as the pair above: nil from a supervisor too old to publish it,
    /// which the resolution reads as "no witness" rather than as "not this one"
    /// (SwitchRequest.swift). It follows a `/clear` and a fork, because it is republished from the
    /// watcher's CURRENT file whenever anything here moves.
    var transcriptSessionID: String?
}

/// The four axis readings one publish carries. Grouped so the writer's two entry points take one
/// argument rather than four, and so a caller cannot fill the pinned pair while forgetting the
/// running one - which is the mistake the running pair was added to fix.
struct SessionAxes: Equatable {
    var pinnedModel: String?
    var pinnedEffort: String?
    /// The model seen serving the last turn, when one has been. Kept apart from the pair below
    /// rather than folded into it, so neither reader has to guess which kind of answer it holds.
    var observedModel: String?
    var runningModel: String?
    var runningEffort: String?
}

extension SupervisedSession {
    /// This reading already describes those axes and that conversation, so nothing has to be
    /// rewritten. The transcript id JOINS the comparison rather than riding along: a `/clear`
    /// starts a new conversation inside the same session, and a reading that kept the old id would
    /// name a transcript this supervisor is no longer watching - which is exactly the witness
    /// another session's prompt would then be matched against.
    func matches(_ axes: SessionAxes, transcript: String?) -> Bool {
        sessionModel == axes.pinnedModel && sessionEffort == axes.pinnedEffort
            && observedModel == axes.observedModel
            && runningModel == axes.runningModel && runningEffort == axes.runningEffort
            && transcriptSessionID == transcript
    }

    /// The axis fields and the conversation id, spelled once, so a new publish cannot fill three of
    /// them.
    init(accountID: String, contextTokens: Int, updatedAt: Date, sessionPin: String?,
         axes: SessionAxes, transcript: String?) {
        self.init(accountID: accountID, contextTokens: contextTokens, updatedAt: updatedAt,
                  sessionPin: sessionPin, sessionModel: axes.pinnedModel,
                  sessionEffort: axes.pinnedEffort, observedModel: axes.observedModel,
                  runningModel: axes.runningModel, runningEffort: axes.runningEffort,
                  transcriptSessionID: transcript)
    }
}

/// The file a supervisor's context reading lives in.
func sessionContextFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + sessionContextSuffix)
}

/// Write the reading. Best-effort and atomic, like every other file on this track.
func writeSessionContext(_ session: SupervisedSession, pid: String,
                         dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(session) else { return }
    try? data.write(to: sessionContextFile(pid: pid, dir: dir), options: .atomic)
}

/// Read a supervisor's context reading, or nil when there is none (or the file is from a format
/// this build does not know, which reads the same way: no number).
func readSessionContext(pid: String, dir: URL = supervisorStateDir) -> SupervisedSession? {
    guard let data = try? Data(contentsOf: sessionContextFile(pid: pid, dir: dir)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SupervisedSession.self, from: data)
}

/// This session is over. Unlinked rather than emptied: absence is the whole signal, and the
/// presence entry beside it is the one that has to keep existing until the supervisor exits.
func clearSessionContext(pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.removeItem(at: sessionContextFile(pid: pid, dir: dir))
}

/// How far the reading has to move before it is worth replacing the file. The supervisor polls
/// every 2 seconds and a working session produces an assistant event every few of them, so writing
/// on any change at all would be a file replace per tool call for the whole of a long turn, while
/// every surface that renders this rounds to thousands anyway.
let sessionContextWriteDelta = 1_000

/// Keeps the file in step with the session, writing only when the number has actually moved (or the
/// account under it has). The value published is always an exact reading, never a rounded one; what
/// the delta buys is that a reading lags by less than a thousand tokens instead of costing a write
/// every few seconds.
struct SessionContextWriter {
    private var current: SupervisedSession?

    /// Republish the same conversation under the account a relaunch has just moved it to, without
    /// waiting for the next poll to read a token figure.
    ///
    /// The reading itself is unchanged (the conversation is the same one; a handoff moves where it
    /// runs, not how big it is), so this is only about the account attribution, and about a reader
    /// that has no other way to ask: `tally switch` run from a shell OUTSIDE the session it moves
    /// has nothing but this file to say which account that session is on (SwitchRequest.swift), and
    /// between a handoff and the next published tick it would name the account the session just
    /// left. The new child has no transcript yet, so `sync` below cannot answer for it at all until
    /// it writes a turn.
    ///
    /// Nothing to move before the first reading is published: a session that has never had a turn
    /// has no file, and inventing one with a token count nobody measured would be worse than the
    /// silence the reader already handles.
    mutating func accountChanged(to accountID: String, pin: String?,
                                 axes: SessionAxes = SessionAxes(), transcript: String? = nil,
                                 pid: String,
                                 dir: URL = supervisorStateDir, now: Date = Date()) {
        guard let current, current.accountID != accountID || current.sessionPin != pin
            || !current.matches(axes, transcript: transcript) else { return }
        publish(SupervisedSession(accountID: accountID, contextTokens: current.contextTokens,
                                  updatedAt: now, sessionPin: pin, axes: axes,
                                  transcript: transcript), pid: pid, dir: dir)
    }

    /// The pin joins the account as a reason to write even when the number has not moved: it
    /// changes on a tick of its own (a `tally switch --auto` moves nothing at all), and a reading
    /// that waited for the next thousand tokens would describe a session that is no longer pinned.
    /// The axes join it on identical terms - `tally model --auto` also moves nothing, and a quota
    /// fallback changes what is RUNNING without changing anything the user asked for.
    mutating func sync(tokens: Int?, accountID: String, pin: String?,
                       axes: SessionAxes = SessionAxes(), transcript: String? = nil, pid: String,
                       dir: URL = supervisorStateDir, now: Date = Date()) {
        guard let tokens else { return }   // nothing read yet: leave whatever stands
        if let current, current.accountID == accountID, current.sessionPin == pin,
           current.matches(axes, transcript: transcript),
           abs(current.contextTokens - tokens) < sessionContextWriteDelta { return }
        publish(SupervisedSession(accountID: accountID, contextTokens: tokens, updatedAt: now,
                                  sessionPin: pin, axes: axes, transcript: transcript),
                pid: pid, dir: dir)
    }

    /// The one way either of the above reaches the file, so the in-memory copy both of them judge
    /// the next write against can never be left describing an older one.
    private mutating func publish(_ session: SupervisedSession, pid: String, dir: URL) {
        writeSessionContext(session, pid: pid, dir: dir)
        current = session
    }
}

// MARK: - Reading it back

/// One live session as anything outside its supervisor sees it: WHICH supervisor it is, and the
/// reading that supervisor has published about it so far.
///
/// The pid is the file's name rather than a field inside it, so a reader that wants to ask anything
/// else about the same session (which Claude Code it is running, which directory it is in, which
/// account it was launched on, all of them documents keyed by that pid) has no way to get there from
/// the reading alone. Carried together for the reason the reading is one value type: a caller
/// holding a pid and a session it paired up itself could ask about one session while reporting
/// another's numbers.
///
/// THE READING IS OPTIONAL BECAUSE THE SESSION IS NOT. A conversation that has not had a turn with
/// usage in it publishes nothing here (`SessionContextWriter.sync` returns on a nil token count,
/// deliberately), and it is running all the same - so a roster keyed on the reading loses exactly
/// the sessions somebody has just started (codex review of d2d620e). nil is "nothing measured yet",
/// never "no session".
struct LiveSupervisor: Equatable {
    let supervisorPid: String
    let session: SupervisedSession?
}

/// Every live session on this machine, oldest supervisor first so the answer is stable.
///
/// FROM THE PRESENCE ENTRY, which is what a supervisor writes before it spawns anything
/// (`markSupervisorLive`) and keeps until it exits, so this roster is complete from the first
/// instant of a session rather than from its first answer. A supervisor that is gone is ignored
/// rather than trusted, the same rule the drift badge follows: the startup sweep unlinks its files,
/// but a reader running in between must not paint a session that has already exited.
func liveSupervisors(dir: URL = supervisorStateDir) -> [LiveSupervisor] {
    // On the pid as a NUMBER: the directory listing has no order worth relying on, and sorting the
    // names as text would put 9000 after 10000 in a report people read.
    liveSupervisorPids(dir: dir).sorted().map {
        LiveSupervisor(supervisorPid: String($0),
                       session: readSessionContext(pid: String($0), dir: dir))
    }
}

/// The live published reading per account: every supervisor still running, keyed by the account it
/// is on, carrying both the context a resume would reload and the pair a `tally model` pinned that
/// session to.
///
/// Several sessions can share an account, and the LARGEST conversation wins, because every question
/// asked of this map ("how much would a resume here cost", "what is that session pinned to") is
/// about the session a person would be thinking of. One value type per account rather than a field
/// at a time, so a caller cannot pair one session's token count with another's pinned model.
///
/// A FOLD OF THE LIST ABOVE, not a second scan: it takes the roster rather than reading the
/// directory again, because this map answers "what is on this account" and therefore drops every
/// session but one - so a reader asking "which sessions are running" has to start from the list or
/// it will be told about two of the ten, and the two answers have to describe the same moment.
/// A session with nothing published yet is not on any account here: this is the READING per account,
/// and there is no reading to attribute.
func supervisedSessionsByAccount(_ live: [LiveSupervisor]) -> [String: SupervisedSession] {
    var byAccount: [String: SupervisedSession] = [:]
    for entry in live {
        guard let session = entry.session else { continue }
        if let seen = byAccount[session.accountID], seen.contextTokens >= session.contextTokens {
            continue
        }
        byAccount[session.accountID] = session
    }
    return byAccount
}
