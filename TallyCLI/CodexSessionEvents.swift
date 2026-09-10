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

/// Incremental JSONL reader. Replacement, truncation and malformed parsed records invalidate it.
/// Oversized response content is opaque after its bounded header is recognized; its payload
/// syntax is not validated. Lifecycle records still require complete JSON decoding.
struct CodexSessionObserver {
    private(set) var state: SupervisedState = .unknown
    private(set) var model: String?
    private(set) var effort: String?
    private(set) var hasTurnContext = false
    private var turns: Set<String> = []
    private var terminalTurns: Set<String> = []
    private var offset: UInt64 = 0
    private var pending = Data()
    private var discardingResponse = false
    private let lineLimit = 1024 * 1024
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
            let bytes = try handle.read(upToCount: lineLimit) ?? Data()
            offset += UInt64(bytes.count)
            var start = bytes.startIndex
            for newline in bytes.indices where bytes[newline] == 10 {
                consumeSegment(bytes[start..<newline], complete: true)
                if invalidated { return }
                start = bytes.index(after: newline)
            }
            consumeSegment(bytes[start...], complete: false)
            if invalidated { return }
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

    private mutating func consumeSegment(_ segment: Data, complete: Bool) {
        if discardingResponse {
            if complete { discardingResponse = false }
            return
        }
        if pending.count + segment.count > lineLimit {
            // Probe only the envelope before payload. Never search conversation text for tags.
            let probeLimit = 16 * 1024
            var prefix = Data(pending.prefix(probeLimit))
            prefix.append(segment.prefix(probeLimit - prefix.count))
            guard metadataValidated, CodexResponseHeader.recognizes(prefix) else { invalidate(); return }
            pending.removeAll(keepingCapacity: false)
            discardingResponse = !complete
            return
        }
        pending.append(segment)
        guard complete else { return }
        guard let object = try? JSONSerialization.jsonObject(with: pending) as? [String: Any]
        else { invalidate(); return }
        pending.removeAll(keepingCapacity: false)
        consume(object)
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
        if type == "turn_context" {
            model = payload["model"] as? String ?? model
            // Each turn supplies its own effort. A missing value must not inherit another
            // turn's effort, especially after a model change.
            effort = (payload["effort"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            hasTurnContext = true
            return
        }
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

/// Recognizes the native writer's envelope, including its optional ordinal, before payload.
/// Large payload-first envelopes and unrecognized header fields remain unsupported.
private struct CodexResponseHeader {
    var bytes: [UInt8]
    var index = 0

    static func recognizes(_ data: Data) -> Bool {
        var parser = Self(bytes: Array(data))
        return parser.read()
    }

    mutating func read() -> Bool {
        guard take(123) else { return false }
        var seen: Set<String> = []
        while let key = string(), seen.insert(key).inserted, take(58) {
            switch key {
            case "timestamp":
                guard let stamp = string(), codexEventDate(stamp) != nil else { return false }
            case "ordinal":
                whitespace()
                let start = index
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > start, (index - start == 1 || bytes[start] != 48),
                      UInt64(String(decoding: bytes[start..<index], as: UTF8.self)) != nil else { return false }
            case "type":
                guard string() == "response_item" else { return false }
            case "payload":
                return seen.contains("timestamp") && seen.contains("type") && take(123)
            default:
                return false
            }
            guard take(44) else { return false }
        }
        return false
    }

    mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func string() -> String? {
        whitespace()
        let start = index
        guard take(34) else { return nil }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 92 {
                guard index < bytes.count else { return nil }
                index += 1
            } else if byte == 34 {
                return (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]),
                    options: [.fragmentsAllowed])) as? String
            }
        }
        return nil
    }
}

func codexEventDate(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime]
    return parser.date(from: value)
}
