import Darwin
import Foundation

// The session-transcript tailer the supervisor uses to notice a cap hit and a model degradation.
//
// Detection is grounded in real transcript data (this machine's history, 2026-07-16): genuine cap
// hits are `isApiErrorMessage:true` events whose text starts with "You've" ("You've hit your
// session limit…", "You've reached your Fable 5 limit…"). Server-side trouble ("API Error: …",
// "Server is temporarily limiting requests (not your usage limit)", 529/500, login expiry) never
// starts with "You've" and must never trigger a handoff.

/// How long a subagent must be silent before its session counts as idle. Deliberately NOT the
/// caller's bar: a healthy subagent writes nothing for the whole of any single long tool call, so
/// the caller's window measures the wrong thing entirely. Measured here 2026-07-25 across three
/// healthy packages: 61s, 52s and 109s of silence, each inside an xcodebuild or a run of the eleven
/// suites. 109s against the 120s follow bar leaves 11 seconds of margin, so a slightly slower build
/// crosses it and the child is relaunched mid-package.
///
/// 600s because that sample of three cannot be the ceiling (a package running two xcodebuilds plus
/// the eleven suites goes past it), because the owner's stop hook already uses 600s for this exact
/// question ("has this subagent stopped writing"), so the product and the harness agree, and
/// because there is no process to fall back on: subagents run inside the claude process rather than
/// as separate PIDs, leaving file mtime as the only signal. The window therefore has to absorb the
/// longest tool call, not the typical one.
///
/// The cost, accepted knowingly: for up to 600s after a subagent genuinely finishes, its session
/// still reads busy, so a reload or self-update waiting on that session is delayed by that much.
/// Every relaunch behind this bar is non-urgent by definition (a cap handoff never waits for
/// quiet), and a late restart costs the user a wait while an early one destroys a work package.
let subagentIdleSeconds: TimeInterval = 600

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

/// The shortest gap between two directory scans while the bound file stays quiet, so an idle session
/// does not re-read candidates on every 2s poll.
let forkScanInterval: TimeInterval = 10

/// How much of one candidate a single scan reads before leaving the rest to the next one. The marker
/// sits on the candidate's first assistant event, which the SessionStart hook context pushes 56 to
/// 77 KB in (measured across six real forks here), so a megabyte is generous; transcripts are
/// append-only, so a scan that stops short resumes exactly where it stopped.
let forkScanBytes = 1 << 20

/// Watches one session transcript for a cap-hit event newer than `since`.
struct TranscriptWatcher {
    let projectDir: URL
    var file: URL?
    var offset: UInt64 = 0
    let since: Date
    /// The session id this child was launched to resume, when known (set after a handoff, which
    /// relaunches with `--resume <id>`). Lets `locateFile` pin `<id>.jsonl` directly instead of
    /// guessing by mtime - two sessions in one directory otherwise cross-bind to whichever file
    /// was touched last. nil on a fresh launch, where the heuristic still applies.
    var resumeID: String?
    /// The fork-discovery join key: the id THIS child process was launched with, which every file
    /// it moves the conversation into carries as its `session_id` (see the fork notes above). A
    /// per-process constant, so unlike `resumeID` it is NEVER moved by an adoption: `resumeID`
    /// tracks the live file because it feeds the next `--resume`, this one tracks the process.
    /// Resolved on first use (from `resumeID`, or from the first file bound on a fresh launch)
    /// rather than at init, so the same value is reached whichever way the watcher was built.
    var launchID: String?
    /// The model id of the newest assistant event seen so far - how the supervisor notices a
    /// server-side model fallback.
    var lastModel: String?
    /// The timestamp of the newest main-chain, real, post-launch assistant event. A cap recovery
    /// is cleared when this passes the cap time (a genuine turn happened after the cap, so the
    /// account came back on its own). Same three guards as `lastModel`.
    var lastMainChainEventAt: Date?
    /// The newest Fable safeguard fallback event seen (`model_refusal_fallback`), post-launch and
    /// main-chain. How the supervisor notices the API forced this session onto a fallback model.
    var lastFlag: SafeguardFlag?
    /// A small rolling map from a user event's uuid to its text, so a fallback's
    /// `refusedUserMessageUuid` can be resolved to a readable trigger excerpt for the log. Bounded
    /// FIFO (a long session has thousands of turns; only recent ones can be a live trigger).
    var recentUserExcerpts: [String: String] = [:]
    /// Insertion order backing `recentUserExcerpts`' FIFO eviction.
    var excerptOrder: [String] = []
    /// Earliest time the next fork scan may read the directory (see `forkScanInterval`).
    var nextForkScan: Date = .distantPast
    /// How far each candidate has been read while looking for the fork marker, so a rescan resumes
    /// instead of starting over. Keyed by session id.
    var forkScanOffsets: [String: UInt64] = [:]
    /// Candidates already proven to carry the marker, so proving it costs one read, not one per
    /// scan (and so a proof can never be scanned past and lost).
    var forkMarked: Set<String> = []
    /// True once the ambiguity warning has been said, so it is said once rather than every scan.
    var forkAmbiguityWarned = false
    /// The last open-turn scan, keyed by the file it read and the mtime it read it at.
    ///
    /// The supervisor asks its quiet question every 2s poll (`Supervisor.swift`), and on an idle
    /// session two or three of those asks reach the open-turn check on every single tick, because
    /// the arguments are evaluated whether or not a relaunch is being planned. Quiet is the common
    /// state, not the rare one, so re-reading a 256 KB tail and re-parsing every line in it to
    /// re-derive an answer that cannot have changed is pure waste all night long.
    ///
    /// The SCAN is cached, never the verdict: `openTurnHoldsSession` expires the evidence at
    /// `openTurnMaxSeconds` while the mtime stands still, so a cached verdict would wedge a session
    /// whose child was killed mid-call as busy forever, the one thing OpenTurn.swift exists to
    /// prevent. Invalidation needs no bookkeeping either: a fork changes the path and a write
    /// changes the mtime, so the key stops matching exactly when the answer could differ.
    var openScanCache: (path: String, modified: Date, openedAt: Date?)?
    private var excerptCapacity: Int { 64 }

    /// The user prompt that triggered the current drift, resolved from the flag's refused uuid, or
    /// nil when unknown (no flag, no uuid, or the message aged out of the FIFO).
    var driftTriggerExcerpt: String? {
        guard let uuid = lastFlag?.refusedUUID else { return nil }
        return recentUserExcerpts[uuid]
    }

    /// The event timestamp of one transcript line, without a full JSON parse.
    func lineTimestamp(_ line: Substring) -> Date? {
        guard let key = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[key.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        return parseISO(String(rest[..<quote]))
    }

    /// The top-level `uuid` of one transcript line, without a full parse. `"uuid":"` never appears
    /// inside `"parentUuid":"` (the leading quote guards it), so the first match is the event's own.
    func lineUUID(_ line: Substring) -> String? {
        guard let key = line.range(of: "\"uuid\":\"") else { return nil }
        let rest = line[key.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<quote])
    }

    /// A user event's visible text by substring (no full parse - every user line hits this). Reads
    /// a string `content`, else the first `text` of an array `content`. Best-effort: an embedded
    /// escaped quote truncates it early, fine for a snippet already capped and newline-stripped.
    func userExcerpt(_ line: Substring) -> String? {
        guard let key = line.range(of: "\"content\":") else { return nil }
        let rest = line[key.upperBound...]
        if rest.first == "\"" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<end])
        }
        if let textKey = rest.range(of: "\"text\":\"") {
            let body = rest[textKey.upperBound...]
            guard let end = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<end])
        }
        return nil
    }

    /// Store a user prompt under its uuid, evicting the oldest past the capacity. Re-seen uuids keep
    /// their place (the text does not change), so the FIFO tracks distinct recent messages.
    mutating func rememberExcerpt(uuid: String, text: String) {
        guard recentUserExcerpts[uuid] == nil else { return }
        recentUserExcerpts[uuid] = String(text.prefix(160))
        excerptOrder.append(uuid)
        if excerptOrder.count > excerptCapacity {
            let evicted = excerptOrder.removeFirst()
            recentUserExcerpts.removeValue(forKey: evicted)
        }
    }

    /// True when the transcript has been silent for `seconds` - the between-turns proxy. An
    /// active turn appends events (tool calls, messages) every few seconds, so a quiet file
    /// means no response is being cut mid-stream. Non-urgent handoffs (pin follow, degradation
    /// rescue, fallback profile) wait for this; a cap hit does not (that turn is already dead).
    ///
    /// The session file alone is not enough, in TWO ways, and silence looks identical in both.
    ///
    /// A turn blocked on a subagent appends NOTHING while it waits, so the stat below reads a live
    /// work package as idle. Measured in this repo 2026-07-25: packages run 5 to 15 minutes against
    /// the 120s follow bar, so the child was relaunched mid-package and the subagent died with it,
    /// its work gone with no error anywhere.
    ///
    /// A turn inside a long TOOL CALL is the same trap one level in, and the subagent window cannot
    /// see it: an 8-minute xcodebuild runs in the MAIN context with no subagent directory involved,
    /// writing nothing between its `tool_use` and its `tool_result` (measured 2026-07-26: 153.7s of
    /// silence inside one live turn, past the 120s bar). OpenTurn.swift reads that pair directly.
    ///
    /// Quiet therefore means all three: the file silent for `seconds`, no tool call still waiting,
    /// and the newest subagent silent for `subagentIdleSeconds`.
    mutating func isQuiet(_ seconds: TimeInterval = 5) -> Bool {
        locateFile()
        return isBoundFileQuiet(seconds)
    }

    /// The quiet test itself, over the file already bound, with no fork discovery in front of it.
    ///
    /// Split out for a caller that has ALREADY enumerated the transcripts it means to judge (the
    /// teardown gate, which asks about every session in a worktree at once). Going through
    /// `isQuiet` there made each file re-scan its directory for fork markers and read up to a
    /// megabyte of every sibling, turning one directory's worth of work into one per file: a
    /// project with a hundred large transcripts read gigabytes and looked like a hang. The
    /// supervisor keeps calling `isQuiet`, which is unchanged: it tails ONE live conversation and
    /// must follow that conversation when it moves.
    mutating func isBoundFileQuiet(_ seconds: TimeInterval) -> Bool {
        // Fresh URL on purpose: resourceValues are cached per URL instance, and a cached
        // mtime would report an active turn as quiet forever.
        guard let file,
              let modified = (try? URL(fileURLWithPath: file.path)
                  .resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate else { return true }
        guard Date().timeIntervalSince(modified) > seconds else { return false }
        // Past the mtime bar is exactly where an idle session lives, so the tail read behind this
        // is cached against the mtime already in hand (see `openScanCache`) rather than repeated
        // on every poll. The verdict itself is still computed here, against the current clock.
        if openTurnHoldsSession(openedAt: openTurnStart(of: file, modified: modified)) {
            return false
        }
        guard let subagent = newestSubagentWrite() else { return true }
        return Date().timeIntervalSince(subagent) > subagentIdleSeconds
    }

    /// When the still-unanswered tool call started, reading the tail only when the file has moved.
    ///
    /// `modified` is the mtime the caller already stat'd, both as the cache key and to keep this to
    /// one stat per ask.
    mutating func openTurnStart(of file: URL, modified: Date) -> Date? {
        if let cache = openScanCache, cache.path == file.path, cache.modified == modified {
            return cache.openedAt
        }
        let openedAt = openToolCallStart(inTail: transcriptTail(of: file) ?? "")
        openScanCache = (path: file.path, modified: modified, openedAt: openedAt)
        return openedAt
    }

    /// The newest write under this session's subagent transcripts, nil when it never dispatched one
    /// (`<projectDir>/<session>.jsonl` pairs with `<projectDir>/<session>/subagents/`).
    ///
    /// Derived from the watched file, so it follows a fork for free: the subagents of a moved
    /// conversation are written under the id actually running (`341bd05d/subagents/` filled up
    /// while the pinned `3ee0aca7` sat still, 2026-07-26), and reading the old session's directory
    /// answered a question about a session that no longer existed.
    ///
    /// Rescanned per call rather than bound to one file: a session runs several subagents and which
    /// one is newest changes, and the directory only appears once the first one is dispatched. Most
    /// sessions dispatch none, so that case costs one stat instead of a walk - this runs on every
    /// 2s supervisor poll. The walk is recursive because a workflow fan-out nests its agents one
    /// level deeper (`subagents/workflows/wf_*/agent-*.jsonl`), and those are the longest packages
    /// of all. No extension filter: the directory holds only per-agent transcripts and their
    /// metadata sidecars, and a write to either is this session waiting on a subagent.
    func newestSubagentWrite() -> Date? {
        guard let file else { return nil }
        let dir = file.deletingPathExtension().appendingPathComponent("subagents")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        // Safe against the cached-mtime trap above for the same reason: every poll walks the
        // directory afresh, so these URLs (and their prefetched values) are built from scratch and
        // never held across polls.
        guard let walk = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return nil }
        var newest: Date?
        for case let entry as URL in walk {
            guard let modified = (try? entry.resourceValues(forKeys: Set(keys)))?
                .contentModificationDate else { continue }
            if modified > newest ?? .distantPast { newest = modified }
        }
        return newest
    }

    /// The transcript this child is writing: bound once, then kept pointing at the live file.
    ///
    /// `forceForkCheck` skips the cost gates below. The relaunch path uses it: the id it resumes
    /// has to be the live one, and there the check runs once rather than every 2s.
    mutating func locateFile(forceForkCheck: Bool = false) {
        if file == nil { bindFile() }
        followFork(force: forceForkCheck)
    }

    /// The first binding: a pin when the launch resumed a known id, else the mtime heuristic.
    private mutating func bindFile() {
        // A resumed handoff knows its session id, so bind `<id>.jsonl` directly: mtime guessing
        // would otherwise pick the wrong file when the directory holds a second session (a
        // sibling tab, an unrelated older conversation). Only a first launch (no known id, or
        // the file not yet copied into this account's tree) falls back to the heuristic below.
        if let resumeID {
            let pinned = projectDir.appendingPathComponent("\(resumeID).jsonl")
            if FileManager.default.fileExists(atPath: pinned.path) { file = pinned; return }
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidate = files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { return nil }
                return modified >= since.addingTimeInterval(-5) ? (url, modified) : nil
            }
            .max { $0.1 < $1.1 }
        file = candidate?.0
    }

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
            // not moved anywhere, so nothing below needs to run.
            guard let modified = boundModified,
                  now.timeIntervalSince(modified) > forkScanQuietSeconds,
                  now >= nextForkScan else { return }
            nextForkScan = now.addingTimeInterval(forkScanInterval)
        }
        // Only a file written more recently than the bound one can be where the conversation went:
        // the process writes to exactly one transcript, so everything it left behind stopped
        // growing. Without this the constant join key would adopt an already dead fork of this same
        // child straight back, because it carries the very same marker as the live one.
        let forks = markedForks(marker: launchKey(boundTo: boundID), excluding: boundID)
            .filter { $0.modified > boundModified ?? .distantPast }
        guard let newest = forks.first else { return }
        // Two candidates written since the bound file mean the child moved twice, and the newest is
        // the live one - the process writes to one transcript, so the other stopped growing. Only a
        // tie leaves nothing to order them by, and guessing there is what lost the turns in the
        // first place: keep the pin and say so.
        if forks.count > 1, forks[1].modified >= newest.modified {
            if !forkAmbiguityWarned {
                warn("two session files continue this conversation - staying on " +
                     "\(boundID.prefix(8)); resume the right one by hand if a restart loses turns")
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
        nextForkScan = .distantPast
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

    /// Files in this directory that carry `marker` as their `session_id`, newest first: born after
    /// this child launched (a transcript that predates the launch cannot be where it moved to) and
    /// carrying the marker, which no sibling session ever does. `boundID` is excluded because the
    /// file already bound is not somewhere to move to, and under a constant marker it can be one of
    /// the matches itself.
    mutating func markedForks(marker: String,
                              excluding boundID: String) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: keys)) ?? []
        var found: [(url: URL, modified: Date)] = []
        for url in files where url.pathExtension == "jsonl" {
            let id = url.deletingPathExtension().lastPathComponent
            guard id != boundID,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let created = values.creationDate,
                  let modified = values.contentModificationDate,
                  created >= since.addingTimeInterval(-5) else { continue }
            if carriesForkMarker(url, id: id, launchedWith: marker) {
                found.append((url, modified))
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }

    /// Whether `url` holds a line written by a process launched as `launchedWith` but into `id` -
    /// the fork marker. The substring is only a prefilter; the decision is a top-level parse, so an
    /// id merely QUOTED inside a tool result (this repo's own transcripts are full of them) proves
    /// nothing.
    mutating func carriesForkMarker(_ url: URL, id: String, launchedWith parent: String) -> Bool {
        if forkMarked.contains(id) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let start = forkScanOffsets[id] ?? 0
        handle.seek(toFileOffset: start)
        guard let raw = try? handle.read(upToCount: forkScanBytes), !raw.isEmpty else { return false }
        // Stop at the last complete line: decoding may not split a multi-byte character (these
        // transcripts are full of CJK), and the next scan then resumes on a line boundary.
        let complete: Data
        if let newline = raw.lastIndex(of: 0x0A) {
            complete = raw[raw.startIndex...newline]
        } else if raw.count == forkScanBytes {
            forkScanOffsets[id] = start + UInt64(raw.count)   // one line past a whole block: step over it
            return false
        } else {
            return false   // the last line is still being written; read it whole next time
        }
        forkScanOffsets[id] = start + UInt64(complete.count)
        guard let text = String(data: complete, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n") {
            guard line.contains("\"session_id\":\"\(parent)\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                      as? [String: Any],
                  object["session_id"] as? String == parent,
                  object["sessionId"] as? String == id else { continue }
            forkMarked.insert(id)
            return true
        }
        return false
    }

    /// Scan newly-appended lines; true when a genuine cap-hit event (newer than launch) appears.
    mutating func sawCapHit() -> Bool {
        locateFile()
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return false }

        for line in text.split(separator: "\n") {
            // Track the ACTUAL serving model, with three guards learned from a live misfire
            // (2026-07-19: a continued session replays its whole history, whose old lines and
            // "<synthetic>" error turns poisoned lastModel and ping-ponged the rescue):
            // real model ids only, main-chain events only, and only events newer than launch.
            if let modelKey = line.range(of: "\"model\":\""),
               !line.contains("\"isSidechain\":true") {
                let rest = line[modelKey.upperBound...]
                if let quote = rest.firstIndex(of: "\""), rest[..<quote].hasPrefix("claude"),
                   let ts = lineTimestamp(line), ts >= since {
                    lastModel = String(rest[..<quote])
                    lastMainChainEventAt = ts
                }
            }
            // Remember recent user prompts so a later fallback's refused-uuid resolves to a
            // readable excerpt. Substring extraction (this runs on every user line), main-chain
            // only, no time guard - a replayed old prompt just ages out of the bounded FIFO.
            if line.contains("\"type\":\"user\""), !line.contains("\"isSidechain\":true"),
               let uuid = lineUUID(line), let text = userExcerpt(line) {
                rememberExcerpt(uuid: uuid, text: text)
            }
            // A Fable safeguard fallback: a structured system event, parsed only past a cheap
            // substring prefilter. Guarded like the model signal (post-launch, main-chain) so a
            // resumed session's replayed history never re-raises a stale flag.
            if line.contains("model_refusal_fallback"),
               let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               (object["isSidechain"] as? Bool) != true,
               let from = object["originalModel"] as? String,
               let to = object["fallbackModel"] as? String,
               let category = object["apiRefusalCategory"] as? String,
               let when = (object["timestamp"] as? String).flatMap(parseISO), when >= since {
                lastFlag = SafeguardFlag(at: when, from: from, to: to, category: category,
                                         refusedUUID: object["refusedUserMessageUuid"] as? String,
                                         uuid: object["uuid"] as? String)
            }
            guard line.contains("\"isApiErrorMessage\":true") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any] else { continue }
            let content = message["content"]
            let body = (content as? String)
                ?? ((content as? [[String: Any]])?.first?["text"] as? String) ?? ""
            guard body.hasPrefix("You've"), body.contains("limit") else { continue }
            // Ignore events older than this child (a forked resume carries the previous
            // conversation's history - including the very cap event that triggered the handoff).
            if let stamp = object["timestamp"] as? String,
               let when = parseISO(stamp), when < since { continue }
            return true
        }
        return false
    }
}
