import Foundation

// When keyboard focus last changed hands on this machine, written by Tally.app and read by every
// Claude supervisor. Compiled into both targets (project.yml), the same arrangement
// ReloadRequest.swift uses, so it must stay dependency-free.
//
// WHY IT EXISTS (2026-09-23, cortex reload held for 7 minutes): Claude Code 2.1.280 turns on the
// terminal's focus reports (`CSI ?1004h`), so every time the terminal window gains or loses key
// the child reads `ESC[I` or `ESC[O` and the tty's atime moves. Focus reports come in PAIRS, out
// then in, and a user moving between apps every few seconds produces pairs well inside
// `keyboardBurstGap`, which `KeyboardActivity` reads as typing. The supervisor cannot see focus
// changes; the app can, so it writes them down here and the tracker declines to let a stamp that
// one of them explains end a burst (KeyboardIdle.swift).
//
// Absence is the safe answer everywhere: no file, an unreadable line, or no event near a stamp all
// leave the stamp counted exactly as it was before this file existed.

let focusEventsFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/focus-events")

/// How far back the file keeps events. A supervisor classifies a stamp within a few seconds of
/// reading it, so anything older than this can no longer explain anything.
let focusEventsRetention: TimeInterval = 120
/// A hard cap on lines, whatever the rate.
let focusEventsMaxLines = 64
/// Events further in the future than this are a clock that moved, not a focus change.
let focusEventsFutureSlack: TimeInterval = 5

/// Parse the file body: one unix time in seconds (fractional) per line. Unparseable lines are skipped.
func parseFocusEvents(_ raw: String) -> [Date] {
    raw.split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        .map { Date(timeIntervalSince1970: $0) }
}

/// The recorded focus changes, or nil when the file does not exist or cannot be read. Nil means
/// "no focus source on this machine" and the caller treats every stamp as it always did.
func readFocusEvents(now: Date = Date(), from file: URL = focusEventsFile) -> [Date]? {
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return parseFocusEvents(raw).filter { $0.timeIntervalSince(now) <= focusEventsFutureSlack }
}

/// The body to write after adding `event` to what is already there: merged (a second Tally build
/// may be writing too), sorted, pruned to `focusEventsRetention` and `focusEventsMaxLines`. Pure.
func mergedFocusEvents(existing: [Date], adding event: Date) -> String {
    let kept = (existing + [event])
        .filter { event.timeIntervalSince($0) <= focusEventsRetention }
        .sorted()
        .suffix(focusEventsMaxLines)
    return kept.map { String(format: "%.3f", $0.timeIntervalSince1970) }.joined(separator: "\n") + "\n"
}

/// Record one focus change. Atomic (temp + rename): a supervisor reading mid-write sees the
/// previous list or this one. Best-effort; a lost event only means that stamp is counted as before.
func appendFocusEvent(_ event: Date = Date(), to file: URL = focusEventsFile) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let existing = (try? String(contentsOf: file, encoding: .utf8)).map(parseFocusEvents) ?? []
    try mergedFocusEvents(existing: existing, adding: event)
        .write(to: file, atomically: true, encoding: .utf8)
}
