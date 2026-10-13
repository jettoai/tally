import Foundation

// One answer to codex's startup update menu, asked from outside the window (a Baton button) and
// carried out by the supervisor that owns the window's PTY. Deliberately narrow: one screen (the
// update menu), one answer (Skip, sent as Esc so the selected row does not matter), and only while
// the drawing the asker saw is still up (`screenID`).
// Whether a person asked is not decidable here; the caller gates that. The request and receipt
// files sit in the supervisor state directory (`startupChoiceSuffix`, PendingNotice.swift).

let startupChoiceLife: TimeInterval = 15

struct StartupChoiceRequest: Codable, Equatable {
    var screenID: String
    var nonce: String
    var at: Date
}

struct StartupChoiceReceipt: Codable, Equatable {
    var nonce: String
    /// "sent" | "stale-screen" | "no-menu" | "typing" | "unreadable" | "expired" | "write-failed"
    var result: String
}

/// The supervisor's decision for one request, pure so the suite can drive every branch.
func decideStartupChoice(_ request: StartupChoiceRequest, record: CodexStartupScreenRecord?,
                         humanInputAt: Date?, now: Date) -> (result: String, keys: [UInt8]?) {
    guard now.timeIntervalSince(request.at) <= startupChoiceLife else { return ("expired", nil) }
    guard let record, record.title == "Update available", let lines = record.lines else { return ("no-menu", nil) }
    guard record.screenID == request.screenID else { return ("stale-screen", nil) }
    if let humanInputAt, now.timeIntervalSince(humanInputAt) < 2 { return ("typing", nil) }
    guard let keys = CodexStartupScreen.skipKeys(lines) else { return ("unreadable", nil) }
    return ("sent", keys)
}

/// The one coder pair both ends of the request and receipt use. Whole seconds are enough: `at`
/// only ages a request against `startupChoiceLife`.
func startupChoiceEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

func startupChoiceDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
