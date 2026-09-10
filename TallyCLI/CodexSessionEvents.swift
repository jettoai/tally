import Foundation

/// A hook receipt contains identity and lifecycle fields only, never conversation text.
struct CodexSessionBinding: Codable, Equatable {
    var nonce: String
    var sessionID: String
    var transcriptPath: String
    var model: String?
    var directory: String?
}

struct CodexSessionActivity: Codable {
    var nonce: String
    var sessionID: String
    var turnID: String
    var event: String
    var at: Date
}

func codexTranscriptURL(path: String, home: String) -> URL? {
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    guard file.pathExtension == "jsonl" else { return nil }
    let base = URL(fileURLWithPath: home)
    let roots = ["sessions", "archived_sessions"].map {
        base.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL.path + "/"
    }
    return roots.contains(where: { file.path.hasPrefix($0) }) ? file : nil
}

func codexRootMetadata(_ object: [String: Any], sessionID: String) -> Bool {
    guard object["type"] as? String == "session_meta",
          let meta = object["payload"] as? [String: Any],
          meta["id"] as? String == sessionID,
          meta["session_id"] as? String == sessionID,
          meta["source"] as? String == "cli",
          meta["parent_thread_id"] == nil || meta["parent_thread_id"] is NSNull else { return false }
    return true
}

/// Incremental JSONL reader. Replacement, truncation and malformed records invalidate the reading.
/// Only complete lines are reduced; content fields are discarded with each parsed line.
struct CodexSessionObserver {
    private(set) var state: SupervisedState = .unknown
    private(set) var model: String?
    private var turns: Set<String> = []
    private var terminalTurns: Set<String> = []
    private var offset: UInt64 = 0
    private var pending = Data()
    private var fileNumber: UInt64?
    private var metadataValidated = false
    private var invalidated = false
    private var lastActivity: Date?
    private let launchedAt: Date
    let binding: CodexSessionBinding

    init(binding: CodexSessionBinding, launchedAt: Date) {
        self.binding = binding
        self.launchedAt = launchedAt
        self.model = binding.model
    }

    mutating func invalidate() { state = .unknown; invalidated = true }

    mutating func poll(home: String, activity: CodexSessionActivity? = nil) {
        guard !invalidated,
              let file = codexTranscriptURL(path: binding.transcriptPath, home: home),
              let handle = try? FileHandle(forReadingFrom: file) else { invalidate(); return }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0 else { invalidate(); return }
        let inode = UInt64(info.st_ino)
        if let fileNumber, fileNumber != inode { invalidate(); return }
        fileNumber = inode
        guard UInt64(info.st_size) >= offset else { invalidate(); return }
        do {
            try handle.seek(toOffset: offset)
            // Bound each poll's allocation, including a single unsupported oversized record.
            let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data()
            offset += UInt64(bytes.count)
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { invalidate(); return }
                consume(object)
                if invalidated { return }
            }
            guard pending.count < 1024 * 1024 else { invalidate(); return }
        } catch { invalidate(); return }
        guard metadataValidated else { state = .unknown; return }
        if let activity, activity.nonce == binding.nonce, activity.sessionID == binding.sessionID,
           activity.at >= launchedAt, lastActivity == nil || activity.at > lastActivity! {
            lastActivity = activity.at
            if !terminalTurns.contains(activity.turnID) {
                if activity.event == "UserPromptSubmit" {
                    turns.insert(activity.turnID)
                    state = .working
                } else if activity.event == "PermissionRequest" {
                    // A hook can subsequently allow or deny this request; no proven blocked state.
                    state = .unknown
                }
            }
        }
    }

    private mutating func consume(_ object: [String: Any]) {
        if !metadataValidated {
            guard codexRootMetadata(object, sessionID: binding.sessionID) else { invalidate(); return }
            metadataValidated = true
            return
        }
        guard let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { invalidate(); return }
        if type == "session_meta" { invalidate(); return }
        guard let stamp = object["timestamp"] as? String, let date = codexEventDate(stamp) else {
            invalidate(); return
        }
        guard date >= launchedAt else { return }
        if type == "turn_context" { model = payload["model"] as? String ?? model; return }
        guard type == "event_msg" else { return }
        guard let event = payload["type"] as? String else { invalidate(); return }
        guard ["task_started", "task_complete", "turn_aborted"].contains(event) else { return }
        guard let turn = payload["turn_id"] as? String, UUID(uuidString: turn) != nil else {
            invalidate(); return
        }
        if event == "task_started" {
            terminalTurns.remove(turn)
            turns.insert(turn)
            state = .working
        } else {
            turns.remove(turn)
            terminalTurns.insert(turn)
            if terminalTurns.count > 1024 { terminalTurns = [turn] }
            state = turns.isEmpty ? .idle : .working
        }
    }
}

func codexEventDate(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: value)
}
