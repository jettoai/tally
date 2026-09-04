import Foundation

/// WHY A CODEX READ CAME HOME WITHOUT NUMBERS, as a closed set of answers rather than as one word.
///
/// "Read failed" was three failures wearing one coat: the vendor answering the usage request with
/// an error of its own (OpenAI's endpoint answered 404 through the app-server on 2026-09-03), an
/// answer arriving in a shape this app cannot read, and no answer arriving at all. A card that
/// names only the coat sends its reader off to check a login and a network that are both fine, so
/// the card keeps the same short line and the callout beside it says which of the three it was
/// (`CodexProvider.detail`, `AccountCardView.errorRow`).
///
/// CLOSED, AND TRANSLATED AT THE SURFACE, which is the rule the redeem outcome next door already
/// follows (`CodexAppServerClient.RedeemOutcome`): no protocol token reaches a view on its own, and
/// the server's own words appear only where they are marked as the server's.
///
/// PURE, AND IN A FILE OF ITS OWN, which is what lets an assertion harness state the rule with no
/// process to spawn and no credential anywhere near it (`tests/codexemail`): everything it needs is
/// the line that came back, whether the app-server outlived it, and how long the caller had been
/// willing to wait.
enum CodexReadFailure: Equatable {
    /// The app-server answered the request for numbers with a JSON-RPC error, in its own words.
    case serverSaid(String)
    /// Something came back that this app could not read as rate limits.
    case unreadableAnswer
    /// Nothing came back before the deadline, the app-server still running.
    case silent(seconds: Int)

    /// How much of the server's own sentence a callout carries. A vendor error is written for a
    /// log rather than for a tooltip, and one that ran on would push the callout past the panel it
    /// is anchored to; what a reader needs is which system is complaining, which is at the front.
    static let messageLimit = 160

    /// WHICH OF THE THREE ONE READ MET, or nil where this is not the question to ask: an
    /// app-server that DIED before answering is a broken CLI rather than a failed read, and the
    /// caller says so in its own words (`Outcome.cliBroken`).
    ///
    /// A LINE THAT CAME BACK IS READ EVEN IF THE PROCESS THEN EXITED, because it is an answer
    /// either way: a codex that says "404" and quits has told the reader more than its exit did.
    ///
    /// ASKED ONLY ON THE FAILING PATH. Whether a line IS readable as rate limits is decided once,
    /// by the decode that the reader needs to succeed anyway (`CodexAppServerClient.read`), so
    /// nothing here re-decides it: this only tells an error the server SPELLED apart from a shape
    /// nobody could read.
    ///
    /// - Parameter timeout: how long the caller waited, so the silent case can say it. Seconds,
    ///   rounded, because it is read as a sentence rather than as a measurement.
    static func of(limitsLine: Data?, processDied: Bool,
                   timeout: TimeInterval) -> CodexReadFailure? {
        guard let limitsLine else {
            return processDied ? nil : .silent(seconds: Int(timeout.rounded()))
        }
        if let message = serverMessage(in: limitsLine) { return .serverSaid(message) }
        return .unreadableAnswer
    }

    /// The `error.message` of a JSON-RPC answer, folded onto one line and capped, or nil for
    /// anything else: a result this app could not read, an error object carrying no message, a line
    /// that is not JSON at all. An error with nothing to say is not the server's words, so it reads
    /// as a shape nobody could read rather than as an empty quotation, and a message that is
    /// nothing but whitespace has nothing to say either.
    ///
    /// AND "WHITESPACE" IS ASKED TWICE, OF TWO DEFINITIONS THAT DISAGREE. A `Character` is
    /// whitespace by Unicode's own property, which U+200B (zero width space) does not carry, while
    /// Foundation's `.whitespacesAndNewlines` does hold it: a message written in zero width spaces
    /// survived the fold as itself, non-empty and invisible, and was quoted as the empty quotation
    /// this rule exists to rule out (codex review of 9e3b89d). The fold wants the narrower
    /// definition, every run of it collapsing to one space; what is LEFT is judged by the wider
    /// one, so anything a reader cannot see counts as nothing to say.
    ///
    /// FOLDED BECAUSE THE CALLOUT SPENDS A ROW ON EVERY LINE BREAK. The server writes for a log,
    /// where a stack trace or a multi-line HTTP error is ordinary, while `tallyTooltip` renders
    /// each `\n` as a row of its own and the callout has no ceiling: 160 characters arriving as
    /// forty lines would overflow the very panel the cap is there to protect. Every run of
    /// whitespace becomes one space, which is also what trims the ends.
    ///
    /// Read with `JSONSerialization` rather than a `Decodable` shape, the same way the redeem flow
    /// reads its own outcome line: what is wanted here is one string out of an envelope whose
    /// other fields are the vendor's business.
    private static func serverMessage(in line: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        let folded = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty else { return nil }
        return folded.count > messageLimit ? String(folded.prefix(messageLimit)) + "\u{2026}"
                                           : folded
    }
}
