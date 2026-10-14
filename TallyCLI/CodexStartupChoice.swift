import Foundation

// One answer to a codex startup screen, asked from outside the window (a Baton button) and carried
// out by the supervisor that owns the window's PTY. Deliberately narrow: three screens, one answer
// each (CodexStartupScreen.answerKeys): Skip on the update menu (Esc, so the selected row does not
// matter), "Use existing model" on the new-model announcement and "Trust and continue" on the
// first-run folder trust screen (arrows from the selected row, then Enter; Esc there is Quit); and
// only while the drawing the asker saw is still up (`screenID`).
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
    guard let record, let title = record.title, CodexStartupScreen.answerable.contains(title),
          let lines = record.lines else { return ("no-menu", nil) }
    guard record.screenID == request.screenID else { return ("stale-screen", nil) }
    if let humanInputAt, now.timeIntervalSince(humanInputAt) < 2 { return ("typing", nil) }
    guard let keys = CodexStartupScreen.answerKeys(title: title, lines: lines) else { return ("unreadable", nil) }
    return ("sent", keys)
}

/// What one read of the session state says after an answer was typed into `title`'s screen. A
/// session whose state file is gone ended (#442: it used to read as "reached its prompt").
enum StartupAnswerOutcome: Equatable {
    case sessionEnded, stillUp, prompt
    case next(CodexStartupScreenRecord)
}

func startupAnswerOutcome(stateFound: Bool, screen: CodexStartupScreenRecord?,
                         answered title: String?) -> StartupAnswerOutcome {
    guard stateFound else { return .sessionEnded }
    guard let screen else { return .prompt }
    return screen.title == title ? .stillUp : .next(screen)
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
