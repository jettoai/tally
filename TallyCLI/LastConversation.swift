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
// WHAT IT CANNOT SEE, said plainly rather than justified. ONLY SUPERVISED SESSIONS REPORT, so this
// record is blind to every session that has no supervisor: one launched with an `--account` pin or
// `--no-handoff`, one started through the PATH shim, one from a `claude` typed by hand. An earlier
// version of this note called that blindness "the right blindness" on the grounds that the excluded
// set was "exactly the sessions Claude Code's own `--continue` skips" - which is true of a `claude
// -p` run and of a background agent (`shouldSupervise`, LaunchFlags.swift, refuses both) and false
// of all the rest, which are ordinary interactive conversations `--continue` would happily pick up
// (codex review of fc26083).
//
// WHAT THAT COSTS, exactly: a directory whose most recent conversation was had in an unsupervised
// session has no record naming it, so the launch after it falls through to channel 2 and RANKS the
// directory. That is the behaviour every build before this record had, and the ranking is filtered
// hard - so the cost is a good answer instead of a certain one, never a wrong one. It is not a
// safety question either: whether a live conversation may be resumed is asked of the live set, which
// does see those sessions (UnmanagedLaunch.swift).
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
///
/// A SELF-UPDATE HANDS THIS WRITER'S MEMORY OVER, because the session outlives the image. `execv`
/// keeps the pid, the child and the conversation; it does not keep this struct, so the new image
/// used to start with nothing in hand and re-announce an unchanged conversation on its first tick -
/// over whatever a SIBLING session in the same directory had published in the meantime. The first
/// version of this guard read the FILE instead and only skipped the write when the file still said
/// what we would say, which is precisely the case where the sibling had NOT written: the one it was
/// added to fix went straight through it (codex review of fc26083, with a unit-level reproduction).
/// So the memory rides the exec, in the argv beside the fuse and the pinned account
/// (`resuperviseLastConversationFlag`), and the new image knows on tick one that nothing changed.
///
/// THE FILE IS STILL READ, for a different case the memory cannot answer: a FRESH process whose
/// first conversation is the one the record already names - a launch that just resumed by id off
/// this very record. Announcing it back would be a write that says nothing.
///
/// WHAT NEITHER FIXES, stated rather than implied: two live sessions in one directory genuinely
/// disagree about which conversation was watched here last, and this record has one slot. Whichever
/// of them actually CHANGES conversation most recently wins it, which is the right answer to the
/// question the slot asks. What is removed is the write that carries no news.
struct LastConversationWriter {
    private var current: String?

    /// `current` is seeded across a self-update, and only there: `runSupervised` hands over what the
    /// supervisor this process replaced had published (SelfUpdate.swift). A fresh session seeds
    /// nothing, which is what makes its first binding news.
    init(current: String? = nil) {
        self.current = current
    }

    /// What this writer has published, for the exec that hands this session to a new image.
    var published: String? { current }

    mutating func sync(_ id: String?, cwd: String, dir: URL = lastConversationDir) {
        guard let id, id != current else { return }
        if current == nil, readLastConversation(cwd: cwd, dir: dir) == id {
            current = id
            return
        }
        current = id
        writeLastConversation(id, cwd: cwd, dir: dir)
    }
}
