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
    // Only populated for a PermissionRequest event, and only ever the tool's name, never its
    // input. A sidecar written before this field existed decodes fine with this left nil.
    var tool: String? = nil
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
/// Oversized response and compaction content is opaque after its bounded header is recognized; its payload
/// syntax is not validated. Lifecycle records still require complete JSON decoding.
struct CodexSessionObserver {
    // State is deliberately left `.unknown` for a PermissionRequest (a hook can allow or deny it
    // without ever reaching a person), so this pending record is the only place that fact is
    // visible; a future supervisor tick can turn it into a suspected wait without touching state.
    private(set) var pendingPermission: (turnID: String, at: Date, tool: String?)?
    // Set whenever pendingPermission is cleared, so a consumer can tell why it went away instead
    // of only that it did.
    private(set) var lastPermissionOutcome: (turnID: String, reason: String)?
    private(set) var state: SupervisedState = .unknown
    private(set) var model: String?
    private(set) var effort: String?
    private(set) var hasTurnContext = false
    private(set) var lastUserTurnAt: Date?
    private(set) var lastInputReceiptAt: Date?
    private(set) var inputReceiptsAvailable = false
    private(set) var inputCaughtUp = false
    private var lastUserMessage: (text: String, at: Date)?
    private var turns: Set<String> = []
    private var terminalTurns: Set<String> = []
    private var offset: UInt64 = 0
    private var pending = Data()
    private var discardingOpaqueRecord = false
    private let lineLimit = 1024 * 1024
    private var fileNumber: UInt64?
    private var metadataValidated = false
    private(set) var invalidated = false
    private var lastActivity: Date?
    private let launchedAt: Date
    let binding: CodexSessionBinding

    /// Whether the native transcript has caught up to a turn Codex is not still working through,
    /// which is the only reading a direct send may be typed on.
    var canAcceptInput: Bool { state == .idle && inputCaughtUp }

    init(binding: CodexSessionBinding, launchedAt: Date) {
        self.binding = binding
        self.launchedAt = launchedAt
        self.model = binding.model
    }

    mutating func invalidate() {
        state = .unknown
        invalidated = true
        clearPendingPermission(reason: "invalidated")
    }

    /// Drops the pending permission if one is standing, and remembers why. A no-op when there is
    /// none, so every call site can call it unconditionally.
    private mutating func clearPendingPermission(reason: String) {
        guard let pending = pendingPermission else { return }
        pendingPermission = nil
        lastPermissionOutcome = (turnID: pending.turnID, reason: reason)
    }

    /// Whether Codex itself recorded the prompt that was typed, which is what turns a terminal
    /// write into a delivery. A receipt from before the write proves nothing about it.
    func receivedInput(_ text: String, after: Date) -> Bool {
        guard let message = lastUserMessage else { return false }
        return message.at >= after && message.text == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func inputSubmitted() {
        // Do not reuse the previous turn end while the TUI is accepting this submission.
        state = .unknown
        inputCaughtUp = false
    }

    mutating func poll(home: String, activity: CodexSessionActivity? = nil) {
        inputCaughtUp = false
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
        var latest = stat()
        inputCaughtUp = pending.isEmpty && !discardingOpaqueRecord
            && fstat(handle.fileDescriptor, &latest) == 0
            && latest.st_size >= 0 && offset == UInt64(latest.st_size)
        if let activity, activity.nonce == binding.nonce, activity.sessionID == binding.sessionID,
           activity.at >= launchedAt, lastActivity == nil || activity.at > lastActivity! {
            lastActivity = activity.at
            // A prompt for a different turn means the pending permission's turn moved on without
            // ever reaching a terminal record for it; the prompt itself proves that much.
            if activity.event == "UserPromptSubmit", let pending = pendingPermission,
               pending.turnID != activity.turnID {
                clearPendingPermission(reason: "turn-moved")
            }
            if !terminalTurns.contains(activity.turnID) {
                if activity.event == "UserPromptSubmit" {
                    lastUserTurnAt = max(lastUserTurnAt ?? activity.at, activity.at)
                    turns.insert(activity.turnID)
                    state = .working
                } else if activity.event == "PermissionRequest" {
                    // A hook can subsequently allow or deny this request; no proven blocked state.
                    state = .unknown
                    pendingPermission = (turnID: activity.turnID, at: activity.at, tool: activity.tool)
                }
            }
        }
    }

    private mutating func consumeSegment(_ segment: Data, complete: Bool) {
        if discardingOpaqueRecord {
            if complete { discardingOpaqueRecord = false }
            return
        }
        if pending.count + segment.count > lineLimit {
            // Probe only the envelope before payload. Never search conversation text for tags.
            let probeLimit = 16 * 1024
            var prefix = Data(pending.prefix(probeLimit))
            prefix.append(segment.prefix(probeLimit - prefix.count))
            guard metadataValidated, CodexOpaqueRecordHeader.recognizes(prefix) else { invalidate(); return }
            pending.removeAll(keepingCapacity: false)
            discardingOpaqueRecord = !complete
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
        if event == "user_message", let text = payload["message"] as? String {
            acceptInputReceipt(text, at: date)
        } else if event == "item_completed" {
            acceptPaginatedUserReceipt(payload, at: date)
        }
        guard ["task_started", "task_complete", "turn_aborted"].contains(event) else { return }
        guard let turn = payload["turn_id"] as? String, UUID(uuidString: turn) != nil else {
            invalidate(); return
        }
        if pendingPermission?.turnID == turn { clearPendingPermission(reason: "turn-ended") }
        if event == "task_started" {
            lastUserTurnAt = max(lastUserTurnAt ?? date, date)
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

    /// Current Codex rollouts record the submitted prompt in a completed `UserMessage` item.
    /// `response_item` messages are intentionally not receipts: their user role can contain
    /// environment and instruction blocks, and they have no turn binding.
    private mutating func acceptPaginatedUserReceipt(_ payload: [String: Any], at date: Date) {
        guard let turn = payload["turn_id"] as? String, UUID(uuidString: turn) != nil,
              let item = payload["item"] as? [String: Any],
              item["type"] as? String == "UserMessage",
              let content = item["content"] as? [[String: Any]], content.count == 1,
              let part = content.first,
              part["type"] as? String == "text",
              let text = part["text"] as? String,
              part["text_elements"] is [Any] else { return }
        acceptInputReceipt(text, at: date)
    }

    /// Keep just one short, normalized receipt. The input channel has the same 200-byte bound;
    /// a larger transcript prompt can prove the route exists, but is never retained as content.
    private mutating func acceptInputReceipt(_ text: String, at date: Date) {
        inputReceiptsAvailable = true
        lastInputReceiptAt = max(lastInputReceiptAt ?? date, date)
        lastUserTurnAt = max(lastUserTurnAt ?? date, date)
        guard text.utf8.count <= 200 else { lastUserMessage = nil; return }
        lastUserMessage = (text.trimmingCharacters(in: .whitespacesAndNewlines), date)
    }
}

/// Recognizes the native writer's envelope, including its optional ordinal, before payload.
/// Large payload-first envelopes and unrecognized header fields remain unsupported.
private struct CodexOpaqueRecordHeader {
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
                // Compaction snapshots carry replacement context, not live events. Never
                // interpret their nested history as a turn completion or input receipt.
                guard let type = string(), ["response_item", "compacted"].contains(type) else { return false }
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
