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
//
// Why a conversation moves to a new transcript, how a fork is told from a sibling session, and
// the code that follows it: TranscriptFork.swift.

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
    /// it moves the conversation into carries as its `session_id` (see TranscriptFork.swift). A
    /// per-process constant, so unlike `resumeID` it is NEVER moved by an adoption: `resumeID`
    /// tracks the live file because it feeds the next `--resume`, this one tracks the process.
    /// Resolved on first use (from `resumeID`, or from the first file bound on a fresh launch)
    /// rather than at init, so the same value is reached whichever way the watcher was built.
    var launchID: String?
    /// The model id of the newest assistant event seen so far - how the supervisor notices a
    /// server-side model fallback.
    var lastModel: String?
    /// When the user last typed Claude Code's OWN `/model` in this child, and the effort the line
    /// it printed named.
    ///
    /// Claude Code writes that command as two adjacent main-chain user events sharing one stamp: the
    /// invocation (`<command-name>/model</command-name>`) and what it printed
    /// (`<local-command-stdout>Set model to ...`). Neither asks anything of this supervisor; they
    /// are how a session says "the person changed the model themselves", which is the one signal
    /// that tells that apart from the server degrading it. What is then DONE about it, and why the
    /// answer is the opposite of a rescue, is `adoptNativeModelChoice` (SessionModel.swift).
    ///
    /// The same guards `lastModel` carries, for the same reason: a resumed session replays its whole
    /// history, and that history holds every earlier `/model` - four of them in the session this was
    /// written for. A replayed one is not somebody changing the model now.
    var lastModelCommandAt: Date?
    /// The effort named by that line, when it named one. Best effort in the literal sense: the two
    /// shapes on this machine are "... for new sessions" and "... for new sessions with <effort>
    /// effort" (78 and 92 occurrences respectively), so an absent one is ordinary rather than a
    /// parse failure, and nil means "leave the effort axis alone".
    var lastModelCommandEffort: String?
    /// The timestamp of the newest main-chain, real, post-launch assistant event. A cap recovery
    /// is cleared when this passes the cap time (a genuine turn happened after the cap, so the
    /// account came back on its own). Same three guards as `lastModel`.
    var lastMainChainEventAt: Date?
    /// The timestamp of the newest main-chain, post-launch event where THE USER SAID SOMETHING: a
    /// prompt they typed, not a tool result and not a synthetic injection.
    ///
    /// The distinction is the whole reason this exists beside `lastMainChainEventAt`. Claude Code
    /// writes a tool's return as a `"type":"user"` event, and an assistant event follows every one
    /// of them, so "an assistant event happened" is true several times INSIDE a single turn - which
    /// makes it useless as an answer to "has the person been back since". A `tally switch` is run as
    /// a tool call from inside a turn, so anything measured that way expires while the user is still
    /// reading the answer that tool call was part of (SessionSwitch.swift's cancellation notice was,
    /// caught in review 2026-08-06).
    ///
    /// FOUR refusals, and the third is the one that matters most in practice. Claude Code appends a
    /// main-chain `user` event when a background agent or task finishes - the `<task-notification>`
    /// events - and those carry no `tool_result` and are not `isMeta`, so the first two guards wave
    /// them through. On a machine running agents that is not an edge case: 4,796 of them sit in this
    /// user's transcripts against 6,455 typed prompts (counted 2026-08-06 across ~/.claude/projects,
    /// structure only), so a notice waiting for "the user came back" would be cleared by an agent
    /// finishing while nobody was there.
    ///
    /// The discriminator is structural and Claude Code's own: those events carry
    /// `"promptSource":"system"`, and no typed prompt in that corpus does (typed ones read `typed`,
    /// `queued`, `suggestion_accepted`, `sdk`, or carry no such field at all, which is what older
    /// transcripts look like). So the rule is a REFUSAL of `system` rather than a whitelist of the
    /// others: absent stays "possibly a person", which is how every transcript written before the
    /// field existed reads.
    ///
    /// The fourth guard is the content shape, and it is admittedly the fragile one - it is here only
    /// for those older transcripts, where the structural field is missing (3 such events in the same
    /// corpus). A future rename of the marker costs exactly that fallback and nothing else.
    ///
    /// Cheap substring tests rather than a JSON parse, like every other signal in this scan. Every
    /// refusal fails in the safe direction: a prompt that happens to contain one of these words is
    /// simply not counted, and the wait it would have ended lasts until the next prompt.
    var lastUserTurnAt: Date?
    /// The size of the conversation as of its newest main-chain assistant event, that turn's own
    /// answer included: how much context a resume of this conversation would reload
    /// (SessionContext.swift).
    ///
    /// Deliberately WITHOUT the post-launch guard the two signals above carry. Those answer "what is
    /// this session doing now", so a replayed history is noise. This one answers "how big is this
    /// conversation", and a resumed session's replayed history is the conversation: the guard would
    /// blank the number for exactly the sessions whose size is worth knowing, until the next turn.
    var lastContextTokens: Int?
    /// The timestamp the cap event `sawCapHit` last reported carries, or nil when that event had
    /// none. The cap's OWN instant, which is up to one poll interval earlier than the moment this
    /// process notices it: the recovery boundary is measured against the cap once and never
    /// recomputed, so a reset landing inside that gap would otherwise be read as a stale stamp and
    /// leave the session with no reset path for the rest of its life (SupervisorRuntime.swift).
    var capHitAt: Date?
    /// The newest Fable safeguard fallback event seen (`model_refusal_fallback`), post-launch and
    /// main-chain. How the supervisor notices the API forced this session onto a fallback model.
    var lastFlag: SafeguardFlag?
    /// A small rolling map from a user event's uuid to its text, so a fallback's
    /// `refusedUserMessageUuid` can be resolved to a readable trigger excerpt for the log. Bounded
    /// FIFO (a long session has thousands of turns; only recent ones can be a live trigger).
    var recentUserExcerpts: [String: String] = [:]
    /// Insertion order backing `recentUserExcerpts`' FIFO eviction.
    var excerptOrder: [String] = []
    /// How far each candidate has been read while looking for the fork marker, so a rescan resumes
    /// instead of starting over. Keyed by session id.
    var forkScanOffsets: [String: UInt64] = [:]
    /// Candidates already proven to carry the marker, so proving it costs one read, not one per
    /// scan (and so a proof can never be scanned past and lost).
    var forkMarked: Set<String> = []
    /// Candidates already proven to be another conversation, for the same reason. Deliberately NOT
    /// cleared on an adoption the way `forkMarked` is: being a sibling is a fact about the file and
    /// this child's CONSTANT launch id, not about which file the watcher is bound to, and the
    /// offsets are cleared there - so re-proving it would re-read every sibling in the directory
    /// from byte zero on every move.
    var forkSibling: Set<String> = []
    /// True while a transcript written more recently than the bound one cannot yet be told apart
    /// from the file this conversation moved to - a `/clear` with no turn typed into it yet
    /// (TranscriptFork.swift). Holds `isQuiet` false, so every non-urgent relaunch waits instead of
    /// resuming an id the conversation may have just left.
    var hasUnresolvedFork = false
    /// Where this watcher's own audit lines go (the ambiguous-fork report, TranscriptFork.swift).
    /// Injectable for the reason `appendHandoffLine` is: a suite that exercises the tie must not
    /// write invented reports into the user's history.
    var auditLog: URL = handoffLog
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
    ///
    /// A fourth condition comes from the other direction and is not about the bound file at all:
    /// while a NEWER transcript in this directory cannot yet be told apart from the file the
    /// conversation just moved to (a `/clear` that has not been typed into), the bound file's
    /// silence proves nothing, because it may be silent for having been abandoned. The answer is no
    /// until that resolves - see the hold note in TranscriptFork.swift.
    mutating func isQuiet(_ seconds: TimeInterval = 5) -> Bool {
        locateFile()
        if hasUnresolvedFork { return false }
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
    /// 2s supervisor poll.
    ///
    /// The walk is RECURSIVE because the dispatch paths land at different depths. Censused
    /// 2026-08-02 over every transcript on this machine (3,245 agent transcripts - 1,589 from the
    /// Agent tool, 1,656 under workflow directories - across 273 workflow runs): not one agent
    /// transcript lives outside a `subagents/` directory, and none nests deeper than the second
    /// shape below.
    ///
    ///   - `subagents/agent-a<hex>.jsonl` - the Agent tool, in all of its forms. A plain subagent,
    ///     an agent team member (whose dispatch name lands in the FILENAME,
    ///     `agent-a<name>-<hex>.jsonl`), and a subagent dispatched BY a subagent, which stays flat
    ///     here rather than nesting: spawnDepth reaches 4 in the corpus, the path never does.
    ///   - `subagents/workflows/wf_<id>/` - a Workflow fan-out, holding its `agent-*.jsonl`, their
    ///     `.meta.json` sidecars and the run's `journal.jsonl`. Every one of the 273 runs that
    ///     dispatched an agent has this directory; the one run without it crashed in 6ms having
    ///     dispatched none. These are the longest packages of all.
    ///
    /// Both are written as the work happens rather than flushed at the end, which is what makes an
    /// mtime mean anything here: one workflow aborted 38s in had already left 122 KB of agent
    /// transcript behind it.
    ///
    /// The sibling `<session>/workflows/` is deliberately NOT walked, and that is a measurement
    /// rather than an oversight. It holds the run's state json and generated script, and the json is
    /// written exactly once, when the run ENDS (its mtime minus the run's end time is 0.0s across
    /// all 273 runs), so it is a stale file for the whole of the run it describes. By the time it
    /// does move, the `Workflow` tool call has returned and the session's own mtime has already
    /// answered. Rooting the walk one level higher to reach it would cost a directory on every poll
    /// and detect nothing - and would read a session whose packages all finished as busy forever.
    ///
    /// Cost, since this is a per-poll walk: the largest subagents tree on this machine is 973
    /// entries and takes 3.8ms, against a 2s poll.
    ///
    /// No extension filter: the directory holds only per-agent transcripts, their metadata sidecars
    /// and the workflow journal, and a write to any of them is this session waiting on a subagent.
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
            // How big the conversation is now, off the same line the model came from. Main-chain
            // only: a subagent's context is its own, and it is not what a resume of THIS
            // conversation reloads.
            if line.contains("\"type\":\"assistant\""), !line.contains("\"isSidechain\":true"),
               let tokens = contextTokens(inLine: line) {
                lastContextTokens = tokens
            }
            // Remember recent user prompts so a later fallback's refused-uuid resolves to a
            // readable excerpt. Substring extraction (this runs on every user line), main-chain
            // only, no time guard - a replayed old prompt just ages out of the bounded FIFO.
            if line.contains("\"type\":\"user\""), !line.contains("\"isSidechain\":true"),
               let uuid = lineUUID(line), let text = userExcerpt(line) {
                rememberExcerpt(uuid: uuid, text: text)
            }
            // When the person last said something themselves (`lastUserTurnAt` explains why this is
            // not the event above, and why it is not `lastMainChainEventAt` either). Post-launch
            // only, like the model signal: a resumed conversation replays its prompts, and a
            // replayed one is not somebody coming back.
            if line.contains("\"type\":\"user\""), !line.contains("\"isSidechain\":true"),
               !line.contains("\"tool_result\""), !line.contains("\"isMeta\":true"),
               !line.contains("\"promptSource\":\"system\""),
               !line.contains("<task-notification>"),
               let ts = lineTimestamp(line), ts >= since {
                lastUserTurnAt = ts
            }
            // Claude Code's own `/model`, in the two events it writes. The invocation is what
            // marks the moment; the line it printed carries the effort, and is JSON-parsed only
            // past a substring prefilter (its text is ANSI-coded, so it cannot be read off the raw
            // line). Guarded like the model signal - post-launch, main-chain - because a resumed
            // session replays every earlier one.
            if line.contains(nativeModelCommandTag), !line.contains("\"isSidechain\":true"),
               let ts = lineTimestamp(line), ts >= since {
                lastModelCommandAt = ts
            }
            if line.contains(nativeModelStdoutPrefix),
               let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                   as? [String: Any],
               (object["isSidechain"] as? Bool) != true,
               let when = (object["timestamp"] as? String).flatMap(parseISO), when >= since,
               let content = (object["message"] as? [String: Any])?["content"] as? String {
                lastModelCommandEffort = nativeModelEffort(inStdout: content)
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
            let when = (object["timestamp"] as? String).flatMap(parseISO)
            if let when, when < since { continue }
            // Assigned unconditionally, nil included, so a reported cap always describes THIS
            // event rather than inheriting a stamp from one the caller already acted on.
            capHitAt = when
            return true
        }
        return false
    }
}
