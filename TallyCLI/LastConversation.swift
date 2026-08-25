import Foundation

// WHAT THIS MACHINE LAST WATCHED IN A DIRECTORY, kept so the next launch there does not have to
// guess.
//
// THE CHANNEL, and why it is already trustworthy. Claude Code hands its status-line command a JSON
// object carrying the conversation it is drawing for, so the process doing the writing says which
// file it is writing; Tally's status line IS that command, and every supervisor already reads that
// report and publishes the id it settles on (TranscriptIdentity.swift, SessionContext.swift). What
// was missing is only that the answer died with the session: it lives under the supervisor's pid and
// is swept when that pid goes. This lands the same value per DIRECTORY instead, where the next
// launch can find it.
//
// WHY PER DIRECTORY AND NOT PER ACCOUNT. The whole defect this belongs to is a per-account pointer
// standing in for a per-directory question (LaunchResume.swift). A record keyed by account would be
// the same mistake in Tally's own handwriting; a conversation belongs to the directory it was had
// in, and any account can resume it by id.
//
// WHAT IT CANNOT SEE, and why that is the right blindness. Only supervised sessions report, and
// `shouldSupervise` (LaunchFlags.swift) already refuses one-shot runs, so a `claude -p` can never
// land here. Background agents are not supervised either. Those are exactly the sessions Claude
// Code's own `--continue` skips, so the exclusion arrives for free rather than as a filter that
// could drift out of step with theirs.
//
// STALENESS IS SELF-CORRECTING and never silent: a record naming a conversation whose transcript is
// gone simply does not match anything in the directory, and the launch falls back to reading it
// (`conversationStart`). Nothing here deletes; "the last conversation in this directory" stays true
// after the session ends, which is the entire point.

/// Where the per-directory records live, beside the per-supervisor state rather than inside it: that
/// directory is swept by supervisor pid (PendingNotice.swift), and these have to outlive the
/// supervisor that wrote them.
let lastConversationDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/last-conversation")

/// The record for one working directory, named by the same slug the transcripts themselves are
/// filed under (`projectSlug`) - one key for one directory, so the record and the directory it
/// describes cannot come to be named differently.
func lastConversationFile(cwd: String, dir: URL = lastConversationDir) -> URL {
    dir.appendingPathComponent(projectSlug(forCwd: cwd))
}

/// The conversation this machine last watched in `cwd`, or nil when there is no usable record.
///
/// An unreadable, empty or malformed file reads as no record rather than as a partial one: the
/// caller's fallback is reading the directory, which is the behaviour every build before this had.
/// The id is validated on the way out as well as on the way in, because a file in a state directory
/// is only ever as trustworthy as the last thing that wrote it.
func readLastConversation(cwd: String, dir: URL = lastConversationDir) -> String? {
    guard let raw = try? String(contentsOf: lastConversationFile(cwd: cwd, dir: dir),
                                encoding: .utf8) else { return nil }
    let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return isTranscriptSessionID(id) ? id : nil
}

/// Publish one. Atomic, so a launch reading mid-write gets the previous record or this one and never
/// half of either, and best-effort like every other file on this track: failing to write it costs
/// the next launch its shortcut, never the session.
func writeLastConversation(_ id: String, cwd: String, dir: URL = lastConversationDir) {
    guard isTranscriptSessionID(id) else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? (id + "\n").write(to: lastConversationFile(cwd: cwd, dir: dir), atomically: true,
                           encoding: .utf8)
}

/// Keeps the record in step with the conversation a supervisor is watching, writing only when it has
/// actually changed.
///
/// The same discipline as `SessionContextWriter` next door and for the same reason: this is fed from
/// a 2-second poll, the value changes only when the conversation does (a `/clear`, a fork, the first
/// binding), and replacing a file every tick to write the same twelve bytes is a write per tick for
/// the life of a session.
///
/// A nil id is NOT a change to record. A session whose transcript is not located yet has not left
/// this directory - the last conversation had here is still the last conversation had here - and
/// blanking the record on that would take the answer away for exactly as long as the new session
/// has nothing to say.
struct LastConversationWriter {
    private var current: String?

    mutating func sync(_ id: String?, cwd: String, dir: URL = lastConversationDir) {
        guard let id, id != current else { return }
        current = id
        writeLastConversation(id, cwd: cwd, dir: dir)
    }
}
