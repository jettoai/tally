import Foundation

// MARK: - Following a fork

// A running claude process can move the conversation to a NEW transcript without exiting: `/clear`
// (and a resume that forks) starts `<newID>.jsonl` while the old file stops growing. The pin below
// then watched a dead file, so `isQuiet` measured nothing, cap detection read nothing, and the next
// relaunch resumed the id from BEFORE the move - every turn written since was orphaned in a file
// nothing pointed at. That happened twice in one afternoon (2026-07-26, ~2000 turns lost), which is
// why the watcher follows the move instead of trusting the pin forever.
//
// A fork is told from a sibling session INSIDE the file, never by timestamps: each line carries both
// `"session_id"` (the id the writing process was launched with) and `"sessionId"` (the file it is
// writing now), and they differ exactly when the conversation has moved. A real orphaned line from
// that afternoon, trimmed to the fields that matter:
//
//   {"type":"assistant","timestamp":"2026-07-26T04:51:24.333Z",
//    "session_id":"3ee0aca7-ffac-4c79-b24b-3ab66a9cbe68",   <- the id the supervisor still resumed
//    "sessionId":"31705403-4fc5-43ea-9be3-de52034b08be"}    <- the file the turns were going to
//
// Checked against every transcript on this machine (207 files, 2026-07-26): 19 carry a foreign
// `session_id`, each naming exactly one earlier session in the same directory, and every sibling
// session stamps its own id or none. A sibling can therefore never be adopted.
//
// The marker names the id the writing process was LAUNCHED with, and that id is a per-process
// CONSTANT: one child that moves the conversation three times stamps all three new files with the
// same launch id. It is not a chain of parent ids. Proven 2026-07-29 by three sibling files in one
// directory, born 7/23, 13:16 and 14:34, every one of them carrying `session_id=2e61b02c`; the
// 14:34 file does not carry the id of the 13:16 file it followed.
//
// Joining on the BOUND file's id therefore only ever followed the first move. Once fork1 was
// adopted the watcher went looking for markers naming fork1, while claude kept stamping the launch
// id, so the second move was invisible for the rest of the child's life: every idle gate that goes
// through the bound file (transcript quiet, open turn, subagent) measured a file nothing was
// writing and so read quiet whatever the user was doing, and the next relaunch resumed it. On
// 2026-07-29 that cut a turn mid-flight during a self-update and orphaned about three hours of
// conversation in the file nothing pointed at.
//
// So the join key is `launchID`, fixed for the life of the watcher, while `resumeID` keeps moving
// with each adoption because it is what the next relaunch has to resume.
//
// MARK: - The third state: a candidate nothing can be said about yet
//
// A file is a fork or a sibling only ONCE IT HAS WRITTEN A TURN. `/clear` creates the new transcript
// immediately, but claude stamps `session_id` on the first real API turn and not before, so a
// conversation cleared and not yet typed into leaves a file holding `mode`,
// `file-history-snapshot`, `attachment`, the `/clear` user record, `system subtype=local_command`,
// `last-prompt` and `queue-operation` - no assistant event and no `session_id` anywhere (10 lines,
// 17 KB, read off the 2026-08-04 incident). There is nothing to adopt it on and nothing to rule it
// out on either, so the watcher stayed on the file the conversation had already left, every idle
// gate read that dead file as quiet, and the queued non-urgent relaunch resumed the id from before
// the clear: the conversation snapped back and the new file was orphaned along with the prompt just
// typed into it.
//
// So an unclassifiable candidate written MORE RECENTLY than the bound file holds: `isQuiet` answers
// false while one exists, which defers every non-urgent relaunch (follow, self-update, reload,
// rebalance, pin, degradation rescue, fallback profile all go through that one gate) and touches
// nothing else. The cap handoff deliberately does not consult it and must not: a session with no
// turn in it cannot have hit a cap, and the bound file is the right thing to resume there.
//
// "Carries no marker" is NOT the test, and this is the part that had to be measured: of the 367
// recent transcripts on this machine (2026-08-04), 49 hold real assistant turns and no `session_id`
// at all, so a missing marker alone would hold on every one of them forever. The test is that the
// file shows NEITHER an assistant event NOR any `session_id` - only true of a session before its
// first turn. That makes the ambiguity self-resolving: the first turn either stamps our launch id
// (adopted, `.fork`) or it does not (`.sibling`), and either way the hold ends.
//
// The cost, accepted knowingly: a brand-new session opened in this cwd and then left untouched
// defers non-urgent relaunches until somebody uses it. Deferral is already their default posture -
// each one waits for a quiet transcript, a quiet keyboard and a finished tool call as it is.
//
// The flag behind that hold is set by the fork scan, which is why the scan is NOT rate-limited. It
// used to skip a directory pass for 10s after each one, and that window was a hole straight through
// the hold: a `/clear` landing inside it left the flag false while the 5s bar (the pin switch, the
// degradation rescue, the fallback profile) was already satisfied, so the tick restarted on the id
// from before the clear and the conversation snapped back exactly as it had before the hold existed.
//
// Unthrottled, the answer every planner reads is current, and THAT is what makes their bookkeeping
// safe: a planner that decides on its own writes its state (the reload's served epoch, the
// fallback's one-shot flag, the rebalance's cross-supervisor cycle claim) only AFTER its own
// `isQuiet` said yes, so a live hold stops it before there is anything to undo. Held back at the
// execution point instead, it would have committed already and a stood-down tick would lose the
// work - a `tally reload` swallowed for the life of the session (2026-08-04). The follow adoption
// is the one that still needs catching, because folding onto a plan somebody else made asks no gate
// of its own; StandDown.swift gives that baseline back.
//
// The cost is one directory pass per ask, and the ask is per planner rather than per tick: up to
// eight on a tick where every gate runs. Measured here 2026-08-04 on the largest project directory
// on this machine (240 transcripts): 0.83 ms mean, 1.03 ms worst, so a fully-gated tick spends
// under 7 ms of its 2s. The pass itself never reads file CONTENTS (the `created >= since` filter
// runs first and leaves 0 to 2 candidates on a normal session), a candidate already proven is O(1)
// through `forkMarked` / `forkSibling`, and one still unresolved reads only bytes no scan has read
// before - usually none. The one gate kept is the 5s silence of the bound file, which is a semantic
// gate rather than a budget: a conversation still being written to has not moved anywhere.
//
// A constant key opens one failure mode the chained key could not have: once the newest fork is
// bound, the earlier and now dead fork still carries the same marker and would be adopted straight
// back, bouncing the watcher onto a file that stopped growing. Hence a candidate is adopted only
// when it was written MORE RECENTLY than the bound file - the live transcript is by definition the
// one still growing. The "born after this child launched" gate stays as well, and answers a
// different question: it excludes a PREVIOUS child's forks, which are older than this launch and
// carry a different launch id.

/// How long the bound transcript must have been silent before the fork check does more than one
/// stat. A live conversation appends every few seconds, so an active session never pays more.
let forkScanQuietSeconds: TimeInterval = 5

/// How much of one candidate a single scan reads before leaving the rest to the next one. The marker
/// sits on the candidate's first assistant event, which the SessionStart hook context pushes 56 to
/// 77 KB in (measured across six real forks here), so a megabyte is generous; transcripts are
/// append-only, so a scan that stops short resumes exactly where it stopped.
let forkScanBytes = 1 << 20

/// What one candidate transcript in this directory can be proven to be, so far.
enum ForkEvidence {
    /// Carries this child's launch id as its `session_id` while writing its own file: the
    /// conversation moved here.
    case fork
    /// Another conversation entirely. Proven by an assistant event (a turn this child never took)
    /// or by a `session_id` that is not ours, and never by the absence of a marker.
    case sibling
    /// Neither yet: no assistant event and no `session_id` anywhere in it. What a `/clear` leaves
    /// behind until its first real turn lands.
    case unresolved
}

// What the execution point does with this flag, and what a tick that stands down has to give back
// to the planners it is cancelling: StandDown.swift.

extension TranscriptWatcher {
    /// Re-point at the transcript the conversation moved to, when it moved (see the fork notes at
    /// the top of this file). Everything the watcher does from then on - quiet, cap detection, the
    /// subagent directory, and above all the id the next relaunch resumes - follows the live file.
    mutating func followFork(force: Bool = false, now: Date = Date()) {
        guard let current = file else { return }
        let boundID = current.deletingPathExtension().lastPathComponent
        // Fresh URL on purpose: resourceValues are cached per URL instance, and a stale mtime here
        // would either hide the file the conversation just moved to or let a dead one back in.
        let boundModified = (try? URL(fileURLWithPath: current.path)
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if !force {
            // The common case costs one stat: a conversation still appending to the bound file has
            // not moved anywhere, so nothing below needs to run. The ONLY gate, deliberately: a
            // rate limit here used to skip the directory for 10s at a time, and every planner that
            // asked inside that window got a stale answer to the one question the hold above rests
            // on (see the note at the top of this file, and the 0.83 ms it costs instead).
            guard let modified = boundModified,
                  now.timeIntervalSince(modified) > forkScanQuietSeconds else { return }
        }
        // Only a file written more recently than the bound one can be where the conversation went:
        // the process writes to exactly one transcript, so everything it left behind stopped
        // growing. Without this the constant join key would adopt an already dead fork of this same
        // child straight back, because it carries the very same marker as the live one.
        let live = boundModified ?? .distantPast
        let scan = scanCandidates(marker: launchKey(boundTo: boundID), excluding: boundID)
        // Recomputed on every scan rather than latched, so a candidate that resolves (either way)
        // releases the hold on the next pass without any bookkeeping of its own.
        hasUnresolvedFork = scan.unresolved.contains { $0 > live }
        let forks = scan.forks.filter { $0.modified > live }
        guard let newest = forks.first else { return }
        // Two candidates written since the bound file mean the child moved twice, and the newest is
        // the live one - the process writes to one transcript, so the other stopped growing. Only a
        // tie leaves nothing to order them by, and guessing there is what lost the turns in the
        // first place: keep the pin and say so.
        if forks.count > 1, forks[1].modified >= newest.modified {
            if !forkAmbiguityWarned {
                // To the log, not the terminal: this is a scan result in the middle of a tick that
                // relaunches nothing, and the child is drawing (PendingNotice.swift's rule).
                appendHandoffLine(forkAmbiguityLine(boundID: boundID), to: auditLog)
                forkAmbiguityWarned = true
            }
            return
        }
        file = newest.url
        resumeID = newest.url.deletingPathExtension().lastPathComponent
        // Cap detection restarts at the top of the new file (its events are all post-launch, and
        // the `since` guards in `sawCapHit` still filter anything replayed from before it).
        offset = 0
        forkScanOffsets.removeAll()
        forkMarked.removeAll()
        // AND THE TURN MAP GOES WITH THE FILE. A uuid identifies an event inside ONE transcript, so
        // carrying the map across a move leaves every new event's parent pointing at nothing (the
        // fail-safe holds and the wait never ends) or, worse, at a collision. `lastModelCommandAt`
        // deliberately survives - a `/model` chosen before a `/clear` still applies to the
        // conversation that follows - and `modelConfirmation` is dropped with the map for the same
        // fail-safe reason: an answer proved by events in a file this conversation has left is not
        // proof about the one it is in now, and re-waiting costs a badge while re-using it risks
        // pinning a model nobody chose here.
        turnRoots = TurnRoots()
        modelConfirmation = nil
        pendingConfirmation = nil
        // The first events in the new file hang off parents this map has never seen, so they cannot
        // resolve - which is expected here and must not read as the format drift the canary watches
        // for (`anchorGraceAfterMove`, TranscriptWatcher.swift).
        anchorGraceAfterMove = true
        unanchoredServed = 0
        anchorLossReported = false
    }

    /// The join key, resolved once and then held: the id this child was launched with, or, on a
    /// fresh launch that resumed nothing, the id of the first file the watcher bound to. Resolving
    /// it here rather than at init keeps every construction path (with a resume id, with a file
    /// handed straight in, or neither) on the same value, and reads `resumeID` before any adoption
    /// can move it.
    private mutating func launchKey(boundTo boundID: String) -> String {
        if let launchID { return launchID }
        let key = resumeID ?? boundID
        launchID = key
        return key
    }

    /// The candidates in this directory, split by what they can be proven to be: the files carrying
    /// `marker` (newest first - what adoption chooses between) and the mtimes of the files nothing
    /// can be said about yet, which is all the hold needs from them.
    ///
    /// One enumeration feeds both: born after this child launched (a transcript that predates the
    /// launch cannot be where it moved to, and cannot be a session this one has to wait for), and
    /// not the bound file, which is not somewhere to move to and, under a constant marker, can be
    /// one of the matches itself.
    mutating func scanCandidates(marker: String, excluding boundID: String)
        -> (forks: [(url: URL, modified: Date)], unresolved: [Date]) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: keys)) ?? []
        var found: [(url: URL, modified: Date)] = []
        var unresolved: [Date] = []
        for url in files where url.pathExtension == "jsonl" {
            let id = url.deletingPathExtension().lastPathComponent
            guard id != boundID,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let created = values.creationDate,
                  let modified = values.contentModificationDate,
                  created >= since.addingTimeInterval(-5) else { continue }
            switch forkEvidence(url, id: id, launchedWith: marker) {
            case .fork: found.append((url, modified))
            case .unresolved: unresolved.append(modified)
            case .sibling: continue
            }
        }
        return (found.sorted { $0.modified > $1.modified }, unresolved)
    }

    /// What `url` can be proven to be, reading only the bytes no earlier scan has read.
    ///
    /// The substrings are prefilters only; every decision is made on a top-level parse, so an id or
    /// an event type merely QUOTED inside a tool result or an attachment (this repo's own
    /// transcripts are full of both) proves nothing in either direction - it neither adopts a
    /// sibling nor releases a hold that a real turn has not yet released.
    mutating func forkEvidence(_ url: URL, id: String, launchedWith parent: String) -> ForkEvidence {
        if forkMarked.contains(id) { return .fork }
        if forkSibling.contains(id) { return .sibling }
        // A file that cannot be opened is called a sibling, not unresolved: unresolved holds every
        // non-urgent relaunch, and a permanently unreadable file would hold them forever.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .sibling }
        defer { try? handle.close() }
        let start = forkScanOffsets[id] ?? 0
        handle.seek(toFileOffset: start)
        // Nothing new since the last scan: whatever this file was, it still is, and a file that has
        // been read to its end with no turn in it is exactly the case the hold exists for.
        guard let raw = try? handle.read(upToCount: forkScanBytes), !raw.isEmpty else {
            return .unresolved
        }
        // Stop at the last complete line: decoding may not split a multi-byte character (these
        // transcripts are full of CJK), and the next scan then resumes on a line boundary.
        let complete: Data
        if let newline = raw.lastIndex(of: 0x0A) {
            complete = raw[raw.startIndex...newline]
        } else if raw.count == forkScanBytes {
            forkScanOffsets[id] = start + UInt64(raw.count)   // one line past a whole block: step over it
            return .unresolved
        } else {
            return .unresolved   // the last line is still being written; read it whole next time
        }
        forkScanOffsets[id] = start + UInt64(complete.count)
        // Decoded line by line, never as one block. A candidate can OPEN with a single line larger
        // than a whole block (a big attachment, a tool result), and the step-over above then leaves
        // the offset inside a multi-byte character; the next block starts on a truncated scalar, and
        // decoding it whole fails - taking every complete line behind it down with it, permanently,
        // because the offset has already moved past them. That is a hold nothing can ever release:
        // the file's real turn sits in bytes the scan will not read again. A transcript is valid
        // UTF-8, so only the straddling fragment fails to decode; skip it and read the rest.
        for chunk in complete.split(separator: 0x0A) {
            let bytes = Data(chunk)
            guard let line = String(data: bytes, encoding: .utf8) else { continue }
            guard line.contains("\"session_id\"") || line.contains("\"type\":\"assistant\""),
                  let object = try? JSONSerialization.jsonObject(with: bytes)
                      as? [String: Any] else { continue }
            let launchedWith = object["session_id"] as? String
            if launchedWith == parent, object["sessionId"] as? String == id {
                forkMarked.insert(id)
                return .fork
            }
            // Anything else this line can carry was written by another conversation: a launch id
            // (somebody else's, or ours stamped into a file that is not this one) or a turn, which
            // cannot be ours before the conversation has moved here. Either ends the ambiguity.
            if launchedWith != nil || object["type"] as? String == "assistant" {
                forkSibling.insert(id)
                return .sibling
            }
        }
        return .unresolved
    }
}
