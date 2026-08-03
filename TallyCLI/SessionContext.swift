import Foundation

// How big a supervised conversation has grown, published for the surfaces outside the terminal.
//
// The number the user actually wants before deciding anything about a session (restart it, hand it
// to another account, start a fresh one) is how much context a resume would have to reload. It is
// in the transcript already: every assistant event carries the usage of the call that produced it,
// and the three input figures of the newest one add up to what the next call re-sends.
//
// It rides the track the drift badge and the pending notice already use: one file per supervisor
// pid in `supervisorStateDir`, read only while that pid is alive, swept when it is not, best-effort
// at every step. A `.session` suffix keeps it beside the presence entry rather than replacing it,
// so `liveSupervisorPids` (which parses names as pids) still counts one live session per supervisor
// and a context reading can never be read as another one.

// MARK: - Reading the transcript

/// The context a resume would reload, from one transcript line, or nil when the line carries none.
///
/// `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the same event: the
/// three halves of one call's input, whether they were sent fresh, written into the cache, or read
/// back out of it. `output_tokens` is deliberately not in the sum; it is what the model wrote, and
/// it is already inside the next call's input figures.
///
/// Substring extraction rather than a JSON parse, because this runs over every assistant line the
/// poll reads, including the whole replayed history the first scan of a resumed session walks.
///
/// Two shapes in the real data decide the details (sampled from this machine's transcripts,
/// 2026-08-04). `usage` holds an `iterations` array repeating every one of these keys per API call,
/// so the window stops before it and the totals read are the top-level ones. And a zero total is
/// never a real context: synthetic assistant turns (an interrupted call, an API error) are written
/// with an all-zero usage, and reporting one would wipe a genuine reading with a 0 the way replayed
/// history once poisoned `lastModel` (TranscriptWatcher.swift).
func contextTokens(inLine line: Substring) -> Int? {
    guard let usage = line.range(of: "\"usage\":{") else { return nil }
    var window = line[usage.upperBound...]
    if let iterations = window.range(of: "\"iterations\":") {
        window = window[..<iterations.lowerBound]
    }
    var total = 0
    for key in contextTokenFields {
        guard let field = window.range(of: key) else { continue }
        total += Int(window[field.upperBound...].prefix { $0.isNumber }) ?? 0
    }
    return total > 0 ? total : nil
}

/// The three keys `contextTokens` adds up, hoisted out of it because it runs on every assistant
/// line the poll reads. The leading quote is what keeps `"input_tokens":` off
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
    /// Total input tokens of the newest assistant event: what a resume of this conversation costs
    /// before it does anything at all.
    let contextTokens: Int
    /// When this reading was taken. An idle session keeps a true number with an old stamp, so this
    /// is the age of the last turn rather than a freshness warning.
    let updatedAt: Date
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

    mutating func sync(tokens: Int?, accountID: String, pid: String,
                       dir: URL = supervisorStateDir, now: Date = Date()) {
        guard let tokens else { return }   // nothing read yet: leave whatever stands
        if let current, current.accountID == accountID,
           abs(current.contextTokens - tokens) < sessionContextWriteDelta { return }
        let session = SupervisedSession(accountID: accountID, contextTokens: tokens, updatedAt: now)
        writeSessionContext(session, pid: pid, dir: dir)
        current = session
    }
}

// MARK: - Reading it back

/// The live context reading per account: every supervisor still running, keyed by the account it is
/// on. Several sessions can share an account, and the LARGEST wins, because the number answers "how
/// much would a resume here cost" and the biggest conversation is the one that answer is about.
///
/// A file whose supervisor is gone is ignored rather than trusted, the same rule the drift badge
/// follows: the startup sweep unlinks it, but a reader running in between must not paint a session
/// that has already exited.
func supervisedContextTokens(dir: URL = supervisorStateDir) -> [String: Int] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    var byAccount: [String: Int] = [:]
    for file in files {
        // Through the shared name reader (PendingNotice.swift), so one place knows how a document
        // on this track maps back to the supervisor that wrote it.
        let name = file.lastPathComponent
        guard name.hasSuffix(sessionContextSuffix), let pid = supervisorStatePid(ofFile: name),
              supervisorAlive(pid),
              let session = readSessionContext(pid: String(pid), dir: dir) else { continue }
        byAccount[session.accountID] = max(byAccount[session.accountID] ?? 0, session.contextTokens)
    }
    return byAccount
}
