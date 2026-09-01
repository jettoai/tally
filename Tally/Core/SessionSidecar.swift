import Foundation

/// THE FILES THE SUPERVISOR WRITES BESIDE ITS STATE, as the panel reads them.
///
/// `<pid>.session` is the context reading (`SupervisedSession`, TallyCLI/SessionContext.swift),
/// `<pid>.cwd` the directory the session runs in and `<pid>.child` the Claude Code it spawned. All
/// three predate the status board, which is exactly why the board reads them: a supervisor too old
/// to publish a state still writes these, so a session that cannot say what it is DOING can still
/// say what it is, where, and how big it has grown.
///
/// A SEPARATE DECLARATION FROM THE WRITER'S, deliberately. The app compiles the state record itself
/// (project.yml says why), but the context reading lives in a file full of supervisor machinery -
/// transcript scanning, the writer's own change gate - that the app has no business carrying. So
/// this is a reader's view of that document: every field optional, unknown fields ignored, and the
/// suffixes asserted against the writer's own constants in `tests/supervisor/sessionstatechecks.swift`
/// so the two spellings cannot drift apart in silence.
struct SessionSidecar: Equatable, Decodable {
    var accountID: String?
    var contextTokens: Int?
    var updatedAt: Date?
    var sessionPin: String?
    /// Which scope is holding this session on its account (`SessionPinScope`'s raw word), or nil
    /// when nothing is - a smart pick, or a supervisor from before the field existed. Both read as
    /// "no mark", which is deliberate: the card cannot tell them apart and neither can it lie about
    /// one, and the reading is republished within a poll of the supervisor updating.
    var pinScope: String?
    var sessionModel: String?
    var sessionEffort: String?
    var observedModel: String?
    var runningModel: String?
    var runningEffort: String?

    /// The app's spelling of the four suffixes. Held here rather than typed at each call site, and
    /// locked to the writer's in the assertions above.
    static let contextSuffix = ".session"
    static let cwdSuffix = ".cwd"
    static let childSuffix = ".child"
    static let transcriptSuffix = ".transcript"

    /// A document that cannot be read, or cannot be understood, reads as no document: the board
    /// simply draws the parts it knows. Same best-effort rule the state reading beside it follows.
    static func read(pid: String, dir: URL = supervisorStateDir) -> SessionSidecar? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(pid + contextSuffix))
        else { return nil }
        let decoder = JSONDecoder()
        // THE WRITER'S FORM AND ANYTHING NEWER. `.iso8601` alone rejects a stamp carrying fractional
        // seconds outright, and rejecting is losing the whole reading - the same failure the state
        // record's string-typed state word exists to avoid, one field over (and the fractional form
        // is not hypothetical: the user-notice file gained one on 2026-08-13).
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let forms: [ISO8601DateFormatter.Options] = [
                [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
            ]
            for options in forms {
                let parser = ISO8601DateFormatter()
                parser.formatOptions = options
                if let date = parser.date(from: text) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "not an instant: \(text)")
        }
        return try? decoder.decode(SessionSidecar.self, from: data)
    }

    /// WHICH CONVERSATION THIS SESSION IS IN, off the first line of `<pid>.transcript` (the file's
    /// own contract is `TallyCLI/TranscriptIdentity.swift`: the id, then the Claude Code that
    /// reported it, then when that process started).
    ///
    /// THE ID ALONE, AND NOT THE STAMP THE SUPERVISOR CHECKS. The supervisor reads this to decide
    /// which transcript to WATCH, so a report from the child before last would bind it to a file
    /// nobody is writing and it refuses one; this reads it to answer a different question - which
    /// session a scratchpad directory belongs to (`MachineLoadRollup.scratchpadConversation`) - and
    /// a conversation this supervisor was in one relaunch ago is still THIS supervisor's session.
    /// The cost of a stale line is therefore the right answer rather than a wrong one.
    ///
    /// Nothing when the file is absent, empty, or does not lead with an id of the right shape: a
    /// half-written line must not become a session name.
    static func readConversation(pid: String, dir: URL = supervisorStateDir) -> String? {
        guard let raw = try? String(contentsOf: dir.appendingPathComponent(pid + transcriptSuffix),
                                    encoding: .utf8) else { return nil }
        let first = raw.split(separator: "\n", omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return MachineLoadRollup.isConversationID(first) ? first : nil
    }

    /// The directory this supervisor was started in, or nil when the file is absent or empty (an
    /// empty one is a write that got as far as the file and no further, which says nothing).
    static func readCwd(pid: String, dir: URL = supervisorStateDir) -> String? {
        guard let raw = try? String(contentsOf: dir.appendingPathComponent(pid + cwdSuffix),
                                    encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// The Claude Code pid this supervisor spawned, IF IT IS STILL RUNNING. A publish that failed
    /// leaves the previous child's number behind, and a dead pid handed to the terminal jump is a
    /// click that matches nothing; liveness is what this can check cheaply and it checks exactly
    /// that. The CLI's own reader (`readSupervisorChild`) additionally proves the process is this
    /// supervisor's child, which needs the process table - the app settles for less here because
    /// the cost of being wrong is one fallback, not a wrong decision: the jump falls back to the
    /// directory match and then to a bare activate.
    static func readChildPid(pid: String, dir: URL = supervisorStateDir) -> Int? {
        guard let raw = try? String(contentsOf: dir.appendingPathComponent(pid + childSuffix),
                                    encoding: .utf8),
              let child = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let running = pid_t(exactly: child), supervisorAlive(running) else { return nil }
        return child
    }
}
