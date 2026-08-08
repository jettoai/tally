import Foundation

// Which CONVERSATION a `tally account` / `tally model` request was typed into, and what a supervisor
// does with that. The request files themselves are SwitchRequest.swift and ModelRequest.swift; the
// rebinding this performs is the fork adoption's own (TranscriptFork.swift). What is here is the one
// thing neither of those could answer: a request that names the transcript it came from, so a
// supervisor watching a file the conversation has already left can catch up without waiting for a
// turn.
//
// THE DEADLOCK THIS CLOSES. `/clear` starts a new transcript immediately, and Claude Code stamps
// `session_id` on the first real API turn and not before, so between the clear and the next turn the
// new file can be proved neither a fork nor a sibling. That is the third state TranscriptFork.swift
// describes, and while such a candidate exists `isQuiet` answers false so no non-urgent relaunch
// resumes an id the conversation may have just left. The hold is right and it stays.
//
// What it had no way out of is the one command that arrives inside that very window. `/tally-account`
// and `/tally-model` are answered by a prompt hook and cost no model turn BY DESIGN (SwitchHook.swift
// states why an escape hatch may not depend on the thing it exists to escape), so a session that is
// cleared and then only asked to move never writes another assistant event: the candidate stays
// unresolved, the hold never lifts, and the request sits in `~/.tally/switch/<pid>` until the session
// exits and the sweep removes it. Measured on a live session (2026-08-08): the request was written at
// 16:09, the conversation never moved, and the handoff log holds no `manual-switch` line for it. It
// is not a race - a `/clear` followed only by hook-answered commands reproduces it every time.
//
// THE EVIDENCE IS ALREADY IN HAND, and it is decisive rather than circumstantial. Claude Code hands a
// prompt hook its own id for the conversation the prompt came from, and that id IS the stem of the
// transcript being written (measured 2026-08-07; `SessionMarkerTrust.corroborated` already resolves
// sessions with it). So the request carries it, and a supervisor reading one may rebind to the file
// it names instead of waiting for a turn this command exists to avoid.
//
// A SCAN IS A GUESS; A REPORT IS NOT. Everything in TranscriptFork.swift INFERS where a conversation
// went from what the files in the directory contain, because nothing tells it. Here Claude Code has
// said so outright, about this very prompt. That is why this may act while the scan still cannot say
// anything, and why nothing else about the hold changes: rebalance, self-update, follow and reload
// have no such witness and wait exactly as they did.
//
// COMPATIBILITY IS THE OTHER HALF OF THE DESIGN. Both request files are a cross-process contract, and
// the two builds run side by side: a supervisor replaces itself at the next idle moment, so until it
// does, an OLD supervisor is reading files a NEW CLI wrote. The field is therefore APPENDED and never
// positional-shifted, so an older reader takes the lines it knows and ignores the rest, and a newer
// reader given a file without the field behaves exactly as it always has.

/// Whether `id` can be used to name a transcript inside a project directory.
///
/// A REQUEST FILE IS UNTRUSTED INPUT even though the user owns it: this value is turned into a path,
/// so anything carrying a separator or a dot segment could name a file outside the directory the
/// watcher is allowed to bind. Claude Code's ids are UUIDs, so letters, digits, dash and underscore
/// is a bound that fits every real one and admits no traversal at all. Refusing here is not a parse
/// failure: an unusable id simply reads as ABSENT, and the request it rides on is still a perfectly
/// good instruction about an account or a model.
func isTranscriptSessionID(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= 128 else { return false }
    return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
}

/// The line a request file carries for the conversation it came from: the id where there is a usable
/// one, and an empty line where there is not.
///
/// THE VALUE IS UNTRUSTED WHERE IT IS WRITTEN as well as where it is read, and for a sharper reason
/// than the path traversal above: an id carrying a newline would not be a bad value in a field, it
/// would be an extra LINE, and every field a reader takes positionally after it would shift by one.
/// One helper for both axes, so neither can be the one that forgot.
func transcriptRequestLine(_ id: String?) -> String {
    id.flatMap { isTranscriptSessionID($0) ? $0 : nil } ?? ""
}

/// The transcript id a request should carry, given how the command that writes it knows which session
/// it is talking about.
///
/// ONLY THE SECOND-HAND SURFACES HAVE ONE, and that is the whole distinction `SessionMarkerTrust`
/// draws. A `.corroborated` marker came from a prompt hook or the MCP server behind the native
/// picker, both of which are handed Claude Code's own id for the conversation the prompt came from. A
/// `.trusted` marker is a person's shell, which descends from the session and carries no such
/// payload: nil there means "this command cannot say", and the supervisor is left with the same fork
/// scan it has always had.
extension SessionMarkerTrust {
    var promptTranscriptID: String? {
        switch self {
        case .trusted: return nil
        case .corroborated(let origin):
            return origin.promptSession.flatMap { isTranscriptSessionID($0) ? $0 : nil }
        }
    }
}

/// Whether some OTHER live supervisor publishes `id` as the conversation it is watching.
///
/// The one witness that can contradict a request outright. Each supervisor publishes the transcript
/// it is tailing (`SupervisedSession.transcriptSessionID`, SessionContext.swift), so a candidate
/// another session is demonstrably in the middle of is not somewhere THIS conversation moved to, and
/// rebinding to it would point every later reading - quiet, cap detection, and above all the id the
/// next relaunch resumes - at somebody else's live conversation.
///
/// `sessionKey` is this supervisor's own pid and is excluded, because its published reading is the
/// STALE one by construction: it names the file this conversation has left, which is precisely the
/// situation being repaired.
func transcriptWatchedElsewhere(_ id: String, excluding sessionKey: String,
                                dir: URL = supervisorStateDir) -> Bool {
    liveSupervisorPids(dir: dir).contains { pid in
        let key = String(pid)
        return key != sessionKey
            && readSessionContext(pid: key, dir: dir)?.transcriptSessionID == id
    }
}

/// Re-point the watcher at the transcript a request named, when everything about that name checks
/// out. True when it moved, which is only ever news to a test: the callers act on the watcher.
///
/// FOUR REFUSALS, and each closes a way this could be worse than the hold it releases:
///
///   - A name this build cannot use as a filename, or the one already bound. The second is the
///     ordinary case by a wide margin: nothing has moved, so there is nothing to do.
///   - No such file in THIS session's project directory, or one born before this child launched. The
///     directory is the watcher's own, so a request cannot send it wandering; the birth gate is the
///     fork scan's (`scanCandidates`) and answers the same question - a transcript that predates the
///     launch cannot be where this child moved to, and resuming it would replace the conversation.
///   - A file another live supervisor says it is watching (above).
///   - A file the fork scan can already PROVE belongs to another conversation. `.sibling` means an
///     assistant turn this child never took, or somebody else's launch id: evidence in the file
///     itself, and it outranks a report about which prompt was typed where. `.unresolved` (the
///     `/clear` this exists for) and `.fork` (the move the scan would have adopted anyway) both pass.
///
/// The hold is dropped here rather than left for the next scan, because the next scan will not run:
/// the file just bound was written seconds ago, so `followFork`'s cost gate returns before it
/// recomputes anything, and the request would wait another turn for an answer already in hand. It is
/// re-derived from scratch by the first scan that does run, exactly as before.
@discardableResult
func adoptRequestedTranscript(_ id: String?, watcher: inout TranscriptWatcher, sessionKey: String,
                              dir: URL = supervisorStateDir) -> Bool {
    guard let id, isTranscriptSessionID(id) else { return false }
    // Bound first if nothing is: a request can land on the very first tick, and refusing here would
    // put this fix a poll behind for no reason. Already-bound is the normal path and costs nothing.
    if watcher.file == nil { watcher.locateFile() }
    guard let bound = watcher.file,
          bound.deletingPathExtension().lastPathComponent != id else { return false }
    let url = watcher.projectDir.appendingPathComponent("\(id).jsonl")
    // Fresh URL for the same reason every other stat here builds one: resource values are cached per
    // instance, and this path is read once per tick while a request is pending.
    guard let created = (try? URL(fileURLWithPath: url.path)
        .resourceValues(forKeys: [.creationDateKey]))?.creationDate,
        created >= watcher.since.addingTimeInterval(-5) else { return false }
    guard !transcriptWatchedElsewhere(id, excluding: sessionKey, dir: dir) else { return false }
    // The join key is resolved against the file being LEFT, before anything moves (TranscriptFork
    // .swift: it names the id this child was LAUNCHED with, and every file the conversation moves
    // into carries that one forever).
    let marker = watcher.launchKey(boundTo: bound.deletingPathExtension().lastPathComponent)
    guard watcher.forkEvidence(url, id: id, launchedWith: marker) != .sibling else { return false }
    watcher.moveTo(url)
    watcher.hasUnresolvedFork = false
    return true
}
