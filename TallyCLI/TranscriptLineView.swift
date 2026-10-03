import Foundation

/// What `scanLine` (TranscriptWatcherScan.swift) asks of one live transcript line. Two readers
/// answer it: `StringLineView`, the substring readers the scan has always used, and `RustLineView`
/// (TranscriptLineRust.swift), the same answers read off the bytes by the Rust core. Every decision
/// stays in `scanLine`, written once against this protocol.
protocol TranscriptLineView {
    func has(_ needle: LineNeedle) -> Bool
    /// Any of `limitResetPrefilter`, the gate `limitResetSignal(inLine:)` opens with.
    func hasLimitResetToken() -> Bool
    var uuid: String? { get }
    /// An empty value reads as nil, as `lineParentUUID` does.
    var parentUUID: String? { get }
    var timestamp: Date? { get }
    /// The raw value after the first `"model":"`, up to its closing quote.
    var modelValue: Substring? { get }
    var contextTokens: Int? { get }
    var excerpt: String? { get }
    /// The whole line. Asked only past a needle gate (the JSON-parsed branches).
    var text: Substring { get }
}

/// The markers `scanLine` tests a line for. The raw value is the bit the Rust core reports it in,
/// and `table` is the SINGLE home of these strings: the Rust core is handed it at startup and
/// carries none of its own.
enum LineNeedle: Int, CaseIterable {
    case sidechain, typeUser, typeAssistant, toolResult, isMeta
    case promptSourceAny, promptSourceSystem, promptSourceTyped, promptSourceQueued, promptSourceSdk
    case taskNotificationTag, compactSummary, apiError, refusalFallback, authFailed
    case modelCommandTag, modelStdout, originAny, originHuman, originTaskNotification
    case contentTaskNotification, statusStopped, statusKilled

    var literal: String {
        switch self {
        case .sidechain: "\"isSidechain\":true"
        case .typeUser: "\"type\":\"user\""
        case .typeAssistant: "\"type\":\"assistant\""
        case .toolResult: "\"tool_result\""
        case .isMeta: "\"isMeta\":true"
        case .promptSourceAny: "\"promptSource\":\""
        case .promptSourceSystem: "\"promptSource\":\"system\""
        case .promptSourceTyped: "\"promptSource\":\"\(personPromptSources[0])\""
        case .promptSourceQueued: "\"promptSource\":\"\(personPromptSources[1])\""
        case .promptSourceSdk: "\"promptSource\":\"\(personPromptSources[2])\""
        case .taskNotificationTag: "<task-notification>"
        case .compactSummary: "\"isCompactSummary\":true"
        case .apiError: "\"isApiErrorMessage\":true"
        case .refusalFallback: "model_refusal_fallback"
        case .authFailed: "authentication_failed"
        case .modelCommandTag: nativeModelCommandTag
        case .modelStdout: nativeModelStdoutPrefix
        case .originAny: "\"origin\":{\"kind\":\""
        case .originHuman: "\"origin\":{\"kind\":\"human\""
        case .originTaskNotification: "\"origin\":{\"kind\":\"task-notification\"}"
        case .contentTaskNotification: "\"content\":\"<task-notification>"
        case .statusStopped: "<status>stopped</status>"
        case .statusKilled: "<status>killed</status>"
        }
    }

    /// Bits from here up are `limitResetPrefilter`, in its order.
    static let limitResetBase = allCases.count
    static let strings: [String] = allCases.map(\.literal) + limitResetPrefilter
    static let table: [[UInt8]] = {
        precondition(strings.count <= 64, "the Rust core reports needles in a 64-bit mask")
        return strings.map { Array($0.utf8) }
    }()
}

/// The `promptSource` values people produce (`lineIsPersonInput`).
let personPromptSources = ["typed", "queued", "sdk"]

/// The substring readers, unchanged: what the scan ran before the Rust core, and what it runs
/// wherever that core is not linked (the swiftc-built suites).
struct StringLineView: TranscriptLineView {
    let line: Substring

    func has(_ needle: LineNeedle) -> Bool { line.contains(LineNeedle.strings[needle.rawValue]) }
    func hasLimitResetToken() -> Bool { limitResetPrefilter.contains { line.contains($0) } }
    var uuid: String? { transcriptLineUUIDText(line) }
    var parentUUID: String? { lineParentUUID(line) }
    var timestamp: Date? { lineTimestamp(line) }
    var modelValue: Substring? { lineModelValue(line) }
    var contextTokens: Int? { lineContextTokens(line) }
    var excerpt: String? { transcriptUserExcerptText(line) }
    var text: Substring { line }
}

/// `contextTokens(inLine:)`, reached past the protocol member of the same name.
private func lineContextTokens(_ line: Substring) -> Int? { contextTokens(inLine: line) }

/// The top-level `uuid` of one transcript line, without a full parse. `"uuid":"` never appears
/// inside `"parentUuid":"` (the leading quote guards it), so the first match is the event's own.
/// Twins: TranscriptLineBytes.swift and rust/crates/core/src/line.rs; change all three.
func transcriptLineUUIDText(_ line: Substring) -> String? {
    guard let key = line.range(of: "\"uuid\":\"") else { return nil }
    let rest = line[key.upperBound...]
    guard let quote = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<quote])
}

/// A user event's visible text by substring (no full parse - every user line hits this). Reads
/// a string `content`, else the first `text` of an array `content`. Best-effort: an embedded
/// escaped quote truncates it early, fine for a snippet already capped and newline-stripped.
/// Twins: TranscriptLineBytes.swift and rust/crates/core/src/line.rs; change all three.
func transcriptUserExcerptText(_ line: Substring) -> String? {
    guard let key = line.range(of: "\"content\":") else { return nil }
    let rest = line[key.upperBound...]
    if rest.first == "\"" {
        let body = rest.dropFirst()
        guard let end = body.firstIndex(of: "\"") else { return nil }
        return String(body[..<end])
    }
    if let textKey = rest.range(of: "\"text\":\"") {
        let body = rest[textKey.upperBound...]
        guard let end = body.firstIndex(of: "\"") else { return nil }
        return String(body[..<end])
    }
    return nil
}

/// The value after the first `"model":"`, up to its closing quote; nil without one.
/// Twin: rust/crates/core/src/line.rs.
func lineModelValue(_ line: Substring) -> Substring? {
    guard let modelKey = line.range(of: "\"model\":\"") else { return nil }
    let rest = line[modelKey.upperBound...]
    guard let quote = rest.firstIndex(of: "\"") else { return nil }
    return rest[..<quote]
}

/// `lineIsPersonInput`, asked of a view. Same tests in the same order; keep the two together.
func lineIsPersonInput(view line: some TranscriptLineView) -> Bool {
    guard line.has(.typeUser), !line.has(.sidechain), !line.has(.isMeta),
          !line.has(.compactSummary), !line.has(.taskNotificationTag) else { return false }
    if line.has(.originAny), !line.has(.originHuman) { return false }
    if line.has(.promptSourceAny),
       !(line.has(.promptSourceTyped) || line.has(.promptSourceQueued)
           || line.has(.promptSourceSdk)) {
        return false
    }
    return true
}

/// `lineStartsTurn`, asked of a view.
func lineStartsTurn(view line: some TranscriptLineView) -> Bool {
    line.has(.typeUser) && !line.has(.toolResult)
}
