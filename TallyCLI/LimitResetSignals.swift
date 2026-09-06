import Foundation

// READING A TRANSCRIPT FOR THE TWO THINGS THIS FEATURE NEEDS: which wall a cap event was, and what
// this conversation has been told about its weekly session-limit reset.
//
// A file of its own rather than more of TranscriptWatcher.swift, which is already over its size cap
// and is the one file three suites compile for the tailer alone. Nothing here holds state: both
// functions are pure over one line or one sentence, which is what lets the whole matrix be asserted
// without a transcript, a supervisor or a home directory. The state machine they feed is
// Core/LimitReset.swift; the station that acts on them is CapLimitReset.swift.

/// Which limit a cap event was about.
///
/// THE MOTHER SET IS THIS MACHINE'S OWN HISTORY, counted rather than imagined: 78 `You've …`
/// api-error events across `~/.claude/projects` fall into exactly three sentences -
/// "You've hit your session limit · resets …" (the 5-hour window), "You've hit your weekly limit ·
/// resets …", and "You've reached your Fable 5 limit. Run /usage-credits …" (a model tier). The
/// first two name their window; the third names a model instead, which is why `model` is the
/// fallback rather than a phrase of its own.
enum CapScope: String, Equatable {
    case session
    case weekly
    case model
}

/// Which wall this cap sentence describes.
///
/// SUBSTRING RATHER THAN A PATTERN, because the discriminating words are the vendor's own nouns
/// and everything around them varies (the reset stamp, the timezone, the "· progress saved" tail).
/// An unrecognised sentence answers `model`, which is the conservative reading for the one consumer
/// this has: the weekly reset is spent only on a `session` wall, so anything this cannot name gets
/// no credit spent on it.
func capScope(ofBody body: String) -> CapScope {
    let text = body.lowercased()
    if text.contains("session limit") { return .session }
    if text.contains("weekly limit") { return .weekly }
    return .model
}

/// What one transcript line says about the weekly session-limit reset, or nil when it says nothing.
///
/// TWO RECORD TYPES ARE READ, AND ONLY TWO, because only two of them are Claude Code SPEAKING.
/// Everything else in a transcript is the conversation: what a person typed, what the assistant
/// wrote, what a tool returned. Those carry arbitrary text, and this feature's own sentences are
/// exactly the text a session working on this feature quotes all day (measured while writing it:
/// the transcript of the session that reviewed this file held six lines containing "Weekly reset
/// used", every one of them an ordinary assistant or user message). Reading those would let a
/// conversation ABOUT the reset settle the account's record for the week, so the record type is a
/// gate rather than a hint:
///
///  - the command's own answer, `{"type":"system","subtype":"local_command",
///    "content":"<local-command-stdout>…"}` - the shape measured 380 times on this machine for
///    `/usage`, `/model` and `/clear`, and the only place a slash command's output lands;
///  - the wall notice, which arrives in the body of an `isApiErrorMessage` event - the flag Claude
///    Code sets on the messages it writes itself when a limit is hit, and the same one
///    `TranscriptWatcher` requires before it will call anything a cap.
///
/// The api-error body is read in both its string and its array-of-parts form, because both occur.
/// An `isApiErrorMessage` line is not the conversation: the flag is set by the product, not by
/// anything a message can say about itself.
///
/// THE PREFILTER IS ON THE RAW LINE, which is a named blind spot rather than an oversight. A JSON
/// parse per line would be paid on every line of every transcript this supervisor tails, so the
/// cheap tokens below decide whether to parse at all - and a TUI escape landing INSIDE one of those
/// two-word tokens would hide the line from this. That fails toward silence: the record stays where
/// it was and ages into `unknown`, which is the direction Core/LimitReset.swift fails in
/// everywhere. The escapes that do occur are taken out after the parse (`limitResetPlainText`),
/// which is where a bolded date would land.
func limitResetSignal(inLine line: Substring) -> LimitResetOutcome? {
    guard limitResetPrefilter.contains(where: { line.contains($0) }) else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    else { return nil }
    var texts: [String] = []
    if object["type"] as? String == "system", object["subtype"] as? String == "local_command",
       let content = object["content"] as? String {
        texts.append(content)
    }
    if object["isApiErrorMessage"] as? Bool == true,
       let message = object["message"] as? [String: Any] {
        if let body = message["content"] as? String {
            texts.append(body)
        } else if let parts = message["content"] as? [[String: Any]] {
            texts.append(contentsOf: parts.compactMap { $0["text"] as? String })
        }
    }
    for text in texts {
        if let outcome = limitResetSignal(inText: text) { return outcome }
    }
    return nil
}

/// The cheap tokens that decide whether a line is worth parsing.
///
/// CASE-SENSITIVE AND THEREFORE ENUMERATED, which is the trap this list has already fallen into
/// once: "Session limit reset" opens a sentence, so the lower-case token does not cover it, and a
/// prefilter that misses the SUCCESS sentence would leave the one outcome that matters unobserved.
/// Every phrase in `LimitResetPhrase` is covered by at least one entry here, and the suite asserts
/// that pairing rather than trusting this comment (tests/limitreset).
let limitResetPrefilter = ["session limit", "Session limit", "session-limit", "limit-reset",
                           "Weekly reset", "Unknown command"]
