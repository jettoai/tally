import Foundation

// An OPEN turn: the session is mid tool call, and the transcript proves it while saying nothing.
//
// The transcript's mtime is the supervisor's only "is this session busy" signal, and it lies in one
// specific way. A turn writes the assistant's `tool_use` event when a call STARTS and the matching
// `tool_result` when it returns, and nothing at all in between. An 8-minute xcodebuild, or a run of
// the eleven suites, is therefore a single silent stretch in the middle of a live turn, and after
// 120s of it the follow bar calls the session idle and a non-urgent relaunch kills the turn.
//
// This is NOT the subagent case that `subagentIdleSeconds` covers. That one is a work package
// running in its own transcript under `<session>/subagents/`; this one runs in the MAIN context,
// with no subagent directory involved at all, so nothing in the subagent window ever sees it.
//
// MEASURED against this machine's own history 2026-07-26, 207 transcripts, 385,873 events:
//
//   - real tool calls do go silent past the bar: the longest matched pair ran 153.7s with ZERO
//     lines written in between, and four pairs in the 25 newest transcripts passed the 120s bar.
//   - no matched pair anywhere reached 600s, which is what makes the cap below a ceiling on
//     wreckage rather than a bar that fires in normal use.
//   - the event shapes are read from the data, not guessed: the call is a block
//     `{"type":"tool_use","id":"toolu_..."}` inside an assistant event's `message.content`, and the
//     return is `{"type":"tool_result","tool_use_id":"toolu_..."}` inside a user event's. The two
//     ids are what pair them; the `parentUuid` chain agrees but is not needed.
//   - one assistant event can open SEVERAL calls at once (66,684 messages carry one block, two
//     carry two, one carries seven), so a turn is closed only when every call it opened came back.

/// How long an open tool call may hold a session busy before the veto lapses.
///
/// Deliberately the same 600s as `subagentIdleSeconds`, for the same reason stated there: both
/// windows have to absorb the LONGEST tool call rather than the typical one, because both are
/// measuring "is work still happening" through a file that stays silent while it does. The corpus
/// above puts the longest real pair at 153.7s, so 600s is roughly four times the worst case seen.
///
/// It is a cap and not a promise because a child that is SIGKILLed mid-call leaves its `tool_use`
/// unmatched forever, and a veto with no ceiling would wedge that session out of every reload and
/// self-update for the rest of its life. After 600s the evidence is stale, so it stops counting.
let openTurnMaxSeconds: TimeInterval = 600

/// How much of the transcript's tail one check reads.
///
/// Only the last turn matters, so this reads backwards from the end and stops at the first assistant
/// event it can decide on: normally one to three lines. 256 KB because the line that MUST fit is the
/// assistant's `tool_use`, and across all 66,687 of them on this machine the largest is 47 KB with
/// none above 64 KB. Tool RESULTS are the big ones (up to 7 MB, 1,567 above 256 KB), and those only
/// matter for recognising a turn that already closed: failing to reach one answers "not open", which
/// is exactly the behaviour that stood before this existed.
let openTurnTailBytes = 1 << 18

/// When the still-unanswered tool call started, or nil when the last turn is not waiting on one.
///
/// Walks the tail backwards, gathering the calls that have come back until it meets the assistant
/// event that made them. That event decides: no calls in it means the assistant answered in prose
/// and the turn is closed; every call answered means closed; anything left unanswered means the
/// session is still inside that call and its timestamp is when the wait began.
///
/// Sidechain events are skipped whichever way they lean, so a subagent can neither open a turn on
/// the main chain nor close one. On this machine they cannot appear here at all (every one of the
/// 269,050 events across the 207 main transcripts carries `isSidechain:false`, while all 31,208
/// subagent events live in their own files), but the guard is what keeps that a fact about today's
/// layout rather than a load-bearing assumption, and it matches how `sawCapHit` reads every other
/// signal in this watcher.
///
/// A line that will not parse is skipped rather than trusted: the last line may still be half
/// written, and half a JSON object is not evidence of anything.
func openToolCallStart(inTail tail: String) -> Date? {
    var answered: Set<String> = []
    for line in tail.split(separator: "\n").reversed() {
        guard !line.contains("\"isSidechain\":true"),
              line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                  as? [String: Any],
              (object["isSidechain"] as? Bool) != true,
              let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { continue }
        if object["type"] as? String == "user" {
            for block in blocks where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { answered.insert(id) }
            }
            continue
        }
        guard object["type"] as? String == "assistant" else { continue }
        let calls = blocks.compactMap { block -> String? in
            block["type"] as? String == "tool_use" ? block["id"] as? String : nil
        }
        if calls.isEmpty || calls.allSatisfy(answered.contains) { return nil }
        // An event with no readable timestamp cannot be aged against the cap, and a veto that
        // cannot expire is the one thing this must never become, so it declines to hold.
        return (object["timestamp"] as? String).flatMap(parseISO)
    }
    return nil
}

/// Whether an open call still holds the session busy: it does until the cap, and never after it.
func openTurnHoldsSession(openedAt: Date?, now: Date = Date()) -> Bool {
    guard let openedAt else { return false }
    return now.timeIntervalSince(openedAt) <= openTurnMaxSeconds
}

/// The tail of `url` as complete lines, or nil when it cannot be read.
///
/// Thin on purpose, so everything that decides anything above is testable without a transcript. The
/// partial line the window opens on is dropped (a read that starts mid-file starts mid-line), and a
/// tail that will not decode is retried at the last newline, which is where a multi-byte character
/// can be cut when the final line is still being written.
func transcriptTail(of url: URL, bytes: Int = openTurnTailBytes) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? handle.seek(toOffset: start)
    guard let raw = try? handle.read(upToCount: bytes), !raw.isEmpty else { return nil }
    var slice = raw[...]
    if start > 0 {
        guard let first = slice.firstIndex(of: 0x0A) else { return nil }   // one line fills it all
        slice = slice[slice.index(after: first)...]
    }
    if let text = String(data: Data(slice), encoding: .utf8) { return text }
    guard let last = slice.lastIndex(of: 0x0A) else { return nil }
    return String(data: Data(slice[..<last]), encoding: .utf8)
}
