import CryptoKit
import Foundation

// THE ONE EVENT SHAPE THIS FEATURE EMITS, published one line at a time to `~/.tally/events/spool.jsonl`
// (SessionWaitSpool.swift) and, from there, to whatever external watcher subscribes (EventDelivery.swift).
// Everything here is data and pure encoding: what DECIDES a request is standing or resolved lives in
// SessionWaitLogic.swift, and this file only says how that decision is spelled on the wire.
//
// Field names and shapes are the plan's own schema (`docs/plans/[WIP] feature-session-wait-events.md`
// §3), not invented here: a consumer outside this repo reads this JSON, so drifting a name from the
// plan without updating the plan and the docs it promises (§5.7) breaks a contract nobody in this
// process would notice breaking.

/// One thing that changed about a session's wait: a request opened, changed, resolved, or the
/// session itself ended. Optional stored properties encode as an ABSENT key rather than `null`
/// (Swift's synthesised `Encodable` calls `encodeIfPresent`), which is the repo's own convention
/// for this kind of record (see `tests/statusjson/main.swift`'s "nil fields are omitted, not null").
struct SessionWaitEvent: Codable, Equatable {
    /// The contract version. Bumped only when a field's MEANING changes, not when one is added.
    var v: Int = 1
    /// Filled by `appendSessionWaitEvent` at write time: the spool's own monotonic counter, not
    /// something this struct can know about itself.
    var seq: Int = 0
    /// When this event was decided, not when the wait it describes began (`request.since` is that).
    var at: Date
    /// One of `SessionWaitEventKind`'s raw values, held as a string for the same reason
    /// `SessionStateRecord.state` is (SessionState.swift): a consumer one version behind a build
    /// that grows a fifth kind should still decode the event rather than lose the whole record.
    var kind: String
    /// `"claude"` or `"codex"`.
    var provider: String
    var session: SessionWaitIdentity
    /// nil only when `kind == "session.ended"` (§3.5): every other kind carries the request it is
    /// about.
    var request: SessionWaitRequest?
    /// One of `SessionWaitResolution`'s raw values, or nil when `kind != "wait.resolved"`.
    var resolution: String?
    /// Filled by `sessionWaitIdempotencyKey` before the event is handed to the spool: a consumer
    /// that acts on this event and sees the same key again knows it already acted.
    var idempotencyKey: String = ""
}

enum SessionWaitEventKind: String {
    case opened = "wait.opened"
    case updated = "wait.updated"
    case resolved = "wait.resolved"
    case ended = "session.ended"
}

enum SessionWaitConfidence: String {
    case confirmed, suspected, unknown
}

enum SessionWaitKind: String {
    case permission, question, unknown
}

enum SessionWaitResolution: String {
    case answered, denied, superseded
    case sessionEnded = "session-ended"
    case unknown
}

/// Everything a consumer needs to NAME the session a wait belongs to, and to tell one supervisor
/// generation from the next one that reused its pid (`key` folds in `supervisorStartedAt` for
/// exactly that reason, §3.3).
struct SessionWaitIdentity: Codable, Equatable {
    var key: String
    var supervisorPid: Int
    var supervisorStartedAt: Int
    /// nil when nothing has proven a child process is alive yet.
    var childPid: Int?
    /// nil before the session has bound a transcript.
    var transcriptSessionId: String?
    /// Codex's `TALLY_CODEX_LAUNCH_NONCE`; always nil for Claude, which is not an error.
    var launchNonce: String?
    var account: String?
    var directory: String?
    var project: String?
    var worktree: String?
}

/// What is being waited for. Absent fields have their own meanings (§3.2 of the plan), not "unknown
/// by omission": `noticeType` nil means the event that opened this request named no type, `tool` nil
/// means no tool name could be attached, `summary` nil means the wait had nothing to say about
/// itself.
struct SessionWaitRequest: Codable, Equatable {
    /// `sessionWaitRequestID`'s output. Stable for the SAME underlying wait, which is what makes
    /// `reconcileWaitRequests` able to tell "this request changed" from "this is a different one".
    var id: String
    /// One of `SessionWaitKind`'s raw values.
    var kind: String
    /// One of `SessionWaitConfidence`'s raw values.
    var confidence: String
    /// When the wait itself began, which `resolvedWaitOutcome` measures an answer against, NOT
    /// this event's own timestamp (`SessionWaitEvent.at` is that).
    var since: Date
    var noticeType: String?
    var tool: String?
    var summary: String?
}

// MARK: - The clock this contract hashes and hangs `since`/`at` on
//
// THE SAME MILLISECOND-PRECISE, FRACTIONAL ISO 8601 SPELLING `UserNotice.swift` uses, built again
// here rather than imported: `fractionalInstantFormatter()` there is deliberately file-scoped
// (UserNotice.swift:77-84 states why a formatter is not shared the way its two encode/decode
// functions are), and a request id's hash needs the exact string a consumer would see the instant
// spelled as on the wire, which only this formatter's own format options guarantee.
//
// `.iso8601` MUST NOT be used for `at`/`since` (memory `tally-iso8601-subsecond-trap`, and
// UserNotice.swift's clock section spells out why in full): two events one second apart would
// decode to the same whole second, and a consumer measuring "did the transcript move after this
// wait began" would read a write that happened before the wait as its answer.
private func sessionWaitClockString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// The one encoder every writer of this event uses: fractional-second, UTC, matching
/// `UserNotice.swift:91`'s strategy exactly so `at`/`since` compare correctly against a transcript
/// mtime and against each other.
func sessionWaitEventEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom(encodeFractionalInstant)
    return encoder
}

/// The matching decoder (`UserNotice.swift:99`'s strategy): the fractional form first, falling back
/// to the plain one, so an event spooled before this feature existed (there is none, but the rule is
/// shared) would still decode rather than be dropped.
func sessionWaitEventDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(decodeFractionalInstant)
    return decoder
}

// MARK: - Identity and idempotency

/// The first 16 hex characters (8 bytes) of a SHA-256 digest, the same shape `AppRelaunch.swift:313`
/// and `ClaudeLoginExpiry.swift:67` already produce for a short, stable, collision-resistant key.
private func sha256Hex16(_ input: String) -> String {
    SHA256.hash(data: Data(input.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// §3.2a. Stable for the SAME dialog (same session, same kind, same notice type, same instant it
/// started) and different the moment any of those change: `since` alone is enough to distinguish
/// two waits of the same kind and type that happen not to overlap, because `UserNotice.at` is
/// millisecond-precise and a new dialog always gets a new `at`.
func sessionWaitRequestID(sessionKey: String, kind: String, noticeType: String?, since: Date) -> String {
    sha256Hex16("\(sessionKey)|\(kind)|\(noticeType ?? "-")|\(sessionWaitClockString(since))")
}

/// §3.2b. Keyed off the RESULT of an event (which request, which kind of event, which resolution)
/// rather than off anything that varies between retries, so the same event computed twice (a
/// spool re-append, a webhook retry) always lands on the same key and a consumer that already acted
/// on it can tell.
func sessionWaitIdempotencyKey(requestID: String?, sessionKey: String, kind: String,
                               resolution: String?) -> String {
    sha256Hex16("\(requestID ?? sessionKey)|\(kind)|\(resolution ?? "-")")
}

/// §3.2's cap on `request.summary`: at most `byteLimit` UTF-8 bytes, and an ellipsis appended when
/// something was cut. nil stays nil (a wait with nothing to say about itself is not the same as a
/// wait whose sentence was truncated to nothing), and text at or under the cap is returned as-is
/// with no trailing mark.
///
/// `byteLimit` defaults to the plan's 200 but is exposed so `SessionWaitSpool.swift` can ask for a
/// SHORTER cut when a spool line is still over its own 4096-byte ceiling after the first truncation
/// (§5.2 step 4): the same function, asked a smaller question, rather than a second one.
func sessionWaitSummary(_ text: String?, byteLimit: Int = 200) -> String? {
    guard let text, !text.isEmpty else { return text }
    let bytes = Array(text.utf8)
    guard bytes.count > byteLimit, byteLimit > 0 else { return bytes.count > byteLimit ? nil : text }
    // Walk the cap backwards to a UTF-8 sequence boundary: a byte whose top two bits are `10` is a
    // continuation byte, meaning the character that started before it is not finished, and cutting
    // there would hand `String(decoding:as:)` a broken sequence.
    var cut = byteLimit
    while cut > 0, (bytes[cut] & 0b1100_0000) == 0b1000_0000 {
        cut -= 1
    }
    guard cut > 0 else { return nil }
    return String(decoding: bytes[0..<cut], as: UTF8.self) + "…"
}
