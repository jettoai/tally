import Darwin
import Foundation

// The session-transcript tailer the supervisor uses to notice a cap hit and a model degradation.
//
// Detection is grounded in real transcript data (this machine's history, 2026-07-16): genuine cap
// hits are `isApiErrorMessage:true` events whose text starts with "You've" ("You've hit your
// session limit…", "You've reached your Fable 5 limit…"). Server-side trouble ("API Error: …",
// "Server is temporarily limiting requests (not your usage limit)", 529/500, login expiry) never
// starts with "You've" and must never trigger a handoff.
//
// HOW QUIET A SESSION IS lives next door in SessionQuiet.swift (`isQuiet` and the walk behind it),
// which is an extension of this same watcher: nothing there reads an event, and everything there is
// about mtimes, which is the seam the two are split on.

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
    /// Which turn each event belongs to (TranscriptSignals.swift), which is what makes the answer to
    /// a `/model` identifiable without guessing anything about the user's side.
    var turnRoots = TurnRoots()
    /// The turn that ANSWERED the newest `/model`: the first main-chain event carrying a real model
    /// id whose TURN began at or after the command.
    ///
    /// ANCHORED ON THE ASSISTANT SIDE, which is the fourth and last shape this rule has had. The
    /// three before it all asked the user side which record would produce a model request - the last
    /// of them, "the first prompt typed after the command", was refuted by `/effort`: its invocation
    /// is indistinguishable from a prompt, so the tail of the turn already in flight cleared the bar
    /// and was read as the answer (codex probe, 2026-08-07). A served model event is not a guess
    /// about what will happen; asking which turn it belongs to is not a guess either.
    ///
    /// An in-flight tail is excluded by construction rather than by timing: its turn began before
    /// the command, so no arrival time can make it eligible. The command's own two events need no
    /// special case for the same reason - nothing is served from them, so they never root anything.
    ///
    /// Cleared by a newer `/model`, which asks the question again.
    var modelConfirmation: (model: String, at: Date)?
    /// The turn that LOOKS like the answer, held until the transcript has finished saying what
    /// happened in it.
    ///
    /// A confirmation cannot be settled when it arrives, and the reason is an ordering fact rather
    /// than a preference: when the API falls a request onto another model, Claude Code writes the
    /// assistant records FIRST and the `model_refusal_fallback` system record after them. Deciding
    /// at arrival therefore reads the fallback before the evidence that it was one, pins it as the
    /// user's choice, and blinds the degradation rescue for the rest of the session - the very hole
    /// the fallback check was added to close, reached one record earlier (gate review, 2026-08-07).
    ///
    /// So the candidate waits for its turn to be OVER. The signal is structural rather than timed:
    /// the next turn's root appearing means the previous turn has stopped writing, and by then any
    /// flag belonging to it has landed. THE COST, stated plainly: a `/model` answered by one turn
    /// and then silence is adopted late - at the user's next turn rather than at that answer. Late
    /// is the direction this whole feature fails in on purpose; the pin is what a session is
    /// expected to run, and a wrong one cannot be noticed by anything downstream.
    var pendingConfirmation: (model: String, at: Date, root: TurnRoot)?
    /// How many events this watcher has placed in a turn, which is the file position everything
    /// about "after the command" is judged by (`TurnRoot.seq`). Monotonic by construction, unlike
    /// the timestamps in the file.
    var scanSeq = 0
    /// Where the newest `/model` sits in that order. nil until one is seen.
    var commandSeq: Int?
    /// Flags seen since that command, not just the newest: two fallbacks inside one command's window
    /// are possible, and comparing a candidate against only the last one lets the earlier turn
    /// through (gate review, 2026-08-07). Bounded by the reset on every new command.
    var flagsSinceCommand: [SafeguardFlag] = []
    /// Whether an unresolved turn is EXPECTED right now rather than a symptom: the events at the top
    /// of a file this conversation has just moved to have parents that were never in this map.
    var anchorGraceAfterMove = false
    /// Real model events served since the newest `/model` whose turn could not be resolved at all,
    /// and whether the canary has already been written for this command
    /// (`unanchoredConfirmationLimit`).
    var unanchoredServed = 0
    var anchorLossReported = false
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
    var openScanCache: (path: String, modified: Date, call: OpenToolCall?)?
    private var excerptCapacity: Int { 64 }

    /// The user prompt that triggered the current drift, resolved from the flag's refused uuid, or
    /// nil when unknown (no flag, no uuid, or the message aged out of the FIFO).
    var driftTriggerExcerpt: String? {
        guard let uuid = lastFlag?.refusedUUID else { return nil }
        return recentUserExcerpts[uuid]
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
    /// Decide the held candidate now that its turn is over: it becomes the answer, or it is dropped
    /// and the wait goes on.
    ///
    /// DROPPED when the API says it served that turn on a model of its own choosing. A `/model`
    /// naming a model whose window is spent gets its first fresh turn served by the fallback, and
    /// adopting that makes the fallback what this session is EXPECTED to run - which is the one
    /// thing that stops the degradation rescue from ever seeing a difference again. Two conditions,
    /// not three: the API said so itself (`model_refusal_fallback`) at some point since the command,
    /// and the model it named is the one this candidate carries.
    ///
    /// The upper bound the arrival-time version had - the flag must predate the answer - is exactly
    /// what made it useless: the flag is written AFTER the records it explains. Judging at the end
    /// of the turn is what lets both orders work, and the remaining looseness (a flag from a later
    /// turn naming the same model) errs toward waiting, which is the safe direction.
    ///
    /// EVERY flag since the command is considered, not the newest one: a window holding two
    /// fallbacks would otherwise clear a candidate the earlier one disqualifies.
    /// Settle a held candidate because the transcript has gone quiet: the user chose a model, read
    /// the answer, and stopped. Without this the candidate is held until they type again, and in the
    /// meantime the session's expected model is still the old one - which the degradation rescue
    /// reads as a session that has drifted and moves to another account to "fix"
    /// (`pendingSettleQuietSeconds` states the argument and how to refute it).
    mutating func settlePendingIfQuiet() {
        // `isQuiet` rather than the bound file's mtime alone, and that is the whole fix: silence
        // means "this turn is finished" only while it is still THIS conversation's silence. A
        // `/clear` right after the answer leaves a new transcript with no turn in it yet, so the
        // watcher is still bound to the old file and that file is, of course, quiet - and settling
        // there pins a choice from a conversation the user has left, walking straight past the drop
        // the move itself performs (`followFork`, TranscriptFork.swift; review, 2026-08-07).
        //
        // The hold already exists and already means this: an unresolved fork keeps `isQuiet` false
        // so that every non-urgent relaunch waits. Asking through it is what stops this settlement
        // from being a second, weaker definition of the same idea.
        guard pendingConfirmation != nil,
              isQuiet(pendingSettleQuietSeconds) else { return }
        settlePendingConfirmation()
    }

    mutating func settlePendingConfirmation() {
        guard let pending = pendingConfirmation, modelConfirmation == nil else { return }
        pendingConfirmation = nil
        if flagsSinceCommand.contains(where: { modelsAgree(pending.model, $0.to) }) { return }
        modelConfirmation = (pending.model, pending.at)
    }

    /// A request was served while a `/model` was still waiting for its answer. Counted, and said out
    /// loud once when there have been too many.
    ///
    /// THE CANARY the design asked for. This feature now rests on `parentUuid` chains, which are
    /// Claude Code's own private format: if their shape changes, roots stop resolving, the fail-safe
    /// holds, nothing is adopted - and nothing is heard either. That is the failure mode this design
    /// chose on purpose, and a silent one is exactly what a canary is for. To the audit log rather
    /// than the terminal, because no relaunch follows it (PendingNotice.swift's rule).
    mutating func noteUnanchoredService(commandAt: Date) {
        unanchoredServed += 1
        guard unanchoredServed > unanchoredConfirmationLimit, !anchorLossReported else { return }
        anchorLossReported = true
        appendHandoffLine(
            modelAnchorLostLine(sessionID: file?.deletingPathExtension().lastPathComponent,
                                served: unanchoredServed, commandAt: commandAt),
            to: auditLog)
    }

    mutating func rememberExcerpt(uuid: String, text: String) {
        guard recentUserExcerpts[uuid] == nil else { return }
        recentUserExcerpts[uuid] = String(text.prefix(160))
        excerptOrder.append(uuid)
        if excerptOrder.count > excerptCapacity {
            let evicted = excerptOrder.removeFirst()
            recentUserExcerpts.removeValue(forKey: evicted)
        }
    }

    /// The still-unanswered tool call, reading the tail only when the file has moved.
    ///
    /// `modified` is the mtime the caller already stat'd, both as the cache key and to keep this to
    /// one stat per ask.
    mutating func openTurn(of file: URL, modified: Date) -> OpenToolCall? {
        if let cache = openScanCache, cache.path == file.path, cache.modified == modified {
            return cache.call
        }
        let call = openToolCall(inTail: transcriptTail(of: file) ?? "")
        openScanCache = (path: file.path, modified: modified, call: call)
        return call
    }

    /// The tool this conversation is holding open that only a PERSON can answer, or nil when it is
    /// not holding one (SessionStateSync.swift is the caller, and OpenTurn.swift says which tools
    /// and why the transcript is asked at all).
    ///
    /// FROM THE SCAN THIS TICK ALREADY TOOK AND FROM NOTHING ELSE: it reads the cache under the
    /// mtime the caller stat'd, and answers nil rather than reading a tail of its own. That is what
    /// keeps it free on the common path, and it is why it says nothing about a MOVING transcript -
    /// `isQuiet` returns at the mtime bar without scanning, so there is nothing cached for the file
    /// as it now stands. Which is the right answer anyway: a conversation being written to is
    /// working by every reading here, and a question nobody has answered does not write. The cost
    /// of that honesty is that a question asked less than `sessionStateQuietSeconds` ago is not on
    /// the board yet.
    ///
    /// NOT AGED AGAINST `openTurnMaxSeconds`, unlike the veto beside it, and the difference is the
    /// question being asked. That cap exists so a call left unmatched by a killed child cannot wedge
    /// a session out of every relaunch for ever; this decides what a card SAYS, where the fact is
    /// self-clearing - the moment somebody answers, Claude Code writes the `tool_result` and the
    /// next scan finds the turn closed. Capping it would take the red dot away from a question
    /// standing over lunch, which is precisely the wait the board exists to show.
    func openUserQuestion(asOf modified: Date?) -> String? {
        guard let file, let modified, let cache = openScanCache, cache.path == file.path,
              cache.modified == modified else { return nil }
        return cache.call?.names.first { userQuestionTools[$0] != nil }
    }

    /// Claude Code's own id for the conversation being tailed, which is the transcript's basename
    /// (measured 2026-08-07: a hook's `session_id` equals the stem of its `transcript_path`).
    ///
    /// Published by the supervisor so a prompt hook can tell THIS session from another one running
    /// in the same directory - the case neither the environment marker nor the working directory
    /// can separate (SessionContext.swift, SwitchRequest.swift). Derived rather than stored, so a
    /// `/clear` or a fork that rebinds `file` changes this with it.
    var transcriptSessionID: String? {
        file.map { $0.deletingPathExtension().lastPathComponent }
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
        // No prefetch, for the reason `scanCandidates` states (TranscriptFork.swift): the mtime is
        // asked for below, over the files that survive the extension filter, and this pass runs on
        // every tick of a session whose transcript does not exist yet.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil)) ?? []
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
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            // NOTHING NEW, so this is the moment a held candidate may be settled on silence rather
            // than on the next turn opening (`pendingSettleQuietSeconds`). Only on this path: a
            // chunk that HAS arrived may carry the very flag that disqualifies the candidate, and
            // settling before reading it would decide on evidence still in the buffer.
            settlePendingIfQuiet()
            return false
        }

        for line in text.split(separator: "\n") {
            // WHICH TURN THIS LINE BELONGS TO, before anything asks. Main-chain and post-launch
            // only: a replayed history would fill the map with turns that ended before this session
            // started, evicting the live ones, and an event whose root is missing is treated as
            // unresolvable anyway - which is the correct answer for a turn that began before the
            // watcher did (TranscriptSignals.swift states the model).
            var turnRoot: TurnRoot?
            /// The parent this line hangs off, kept so the canary can ask whether THAT is one the
            /// cap dropped rather than whether anything ever was.
            var lineParent: String?
            if !line.contains("\"isSidechain\":true"), let uuid = lineUUID(line),
               let ts = lineTimestamp(line), ts >= since {
                let startsTurn = lineStartsTurn(line)
                scanSeq += 1
                lineParent = lineParentUUID(line)
                turnRoot = turnRoots.record(uuid: uuid, parent: lineParent,
                                            startsTurn: startsTurn, at: ts, seq: scanSeq)
                // The first turn placed in the new file ends the post-move grace: from here on an
                // unresolved chain is a symptom rather than an expected consequence of the move.
                if turnRoot != nil { anchorGraceAfterMove = false }
                // A NEW turn starting is the transcript saying the previous one is finished, which
                // is when a held candidate can be judged: anything the API had to say about that
                // turn has been written by now (`pendingConfirmation`).
                if startsTurn, let root = turnRoot, pendingConfirmation?.root.seq != root.seq {
                    settlePendingConfirmation()
                }
            }
            // Track the ACTUAL serving model, with three guards learned from a live misfire
            // (2026-07-19: a continued session replays its whole history, whose old lines and
            // "<synthetic>" error turns poisoned lastModel and ping-ponged the rescue):
            // real model ids only, main-chain events only, and only events newer than launch.
            if let modelKey = line.range(of: "\"model\":\""),
               !line.contains("\"isSidechain\":true") {
                let rest = line[modelKey.upperBound...]
                if let quote = rest.firstIndex(of: "\""), rest[..<quote].hasPrefix("claude"),
                   let ts = lineTimestamp(line), ts >= since {
                    let model = String(rest[..<quote])
                    lastModel = model
                    lastMainChainEventAt = ts
                    // The answer to the newest `/model`: this request was served, so the only
                    // question left is whether the turn it belongs to began after the command
                    // (`modelConfirmation` states the whole rule). A root that will not resolve is
                    // not an answer: the wait continues, because a late adoption costs a badge and a
                    // wrong one costs the degradation rescue for the rest of the session.
                    if let commandSeq, modelConfirmation == nil, pendingConfirmation == nil {
                        // POSITION, not time: a transcript's stamps are not monotonic, and a
                        // command stamped earlier than a turn already running would otherwise hand
                        // that turn's tail back as the answer (`TurnRoot.seq`).
                        if let turnRoot, turnRoot.seq > commandSeq {
                            // HELD, not decided: what the API did to this turn may still be a
                            // record or two away (`pendingConfirmation`).
                            pendingConfirmation = (model, ts, turnRoot)
                        } else if turnRoot == nil, !anchorGraceAfterMove,
                                  !turnRoots.wasEvicted(lineParent) {
                            // THE ONLY THING THE CANARY IS ABOUT: a chain that will not resolve
                            // when it should, which is what a format drift looks like. Three ways
                            // to fail to resolve are EXPECTED and excluded by the guard above, all
                            // of them found by review: THIS parent is one the cap dropped
                            // (`wasEvicted` - asked of the parent rather than of the session, so a
                            // single eviction no longer silences the canary for the rest of it),
                            // the first events after a move have parents from a file this map no
                            // longer describes (`anchorGraceAfterMove`), and a candidate
                            // deliberately held is not unresolved at all (it never reaches here).
                            // What remains is a chain that should have resolved and did not.
                            noteUnanchoredService(commandAt: lastModelCommandAt ?? .distantPast)
                        }
                    }
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
               // An auto-compact writes its summary as a user event carrying no promptSource, so it
               // read as somebody coming back and took down a badge nobody had seen. Nobody is in
               // the room when a compaction happens; it is the session folding itself up.
               !line.contains("\"isCompactSummary\":true"),
               let ts = lineTimestamp(line), ts >= since {
                lastUserTurnAt = ts
            }
            // Claude Code's own `/model`, in the two events it writes. The invocation is what
            // marks the moment; the line it printed carries the effort, and is JSON-parsed only
            // past a substring prefilter (its text is ANSI-coded, so it cannot be read off the raw
            // line). Guarded like the model signal - post-launch, main-chain - because a resumed
            // session replays every earlier one.
            if line.contains(nativeModelCommandTag), !line.contains("\"isSidechain\":true"),
               // …and IS the command rather than merely mentioning it. The tag is a substring, and
               // a transcript carries it innocently more often than one would think: a tool_result
               // holding this repo's own source, a prompt quoting a transcript. Read as a command,
               // any of them resets a live anchor and spends the served stamp
               // (`lineIsCommandRecord`, TranscriptSignals.swift).
               lineIsCommandRecord(line, opening: nativeModelCommandOpening),
               let ts = lineTimestamp(line), ts >= since {
                lastModelCommandAt = ts
                // WHERE it sits, which is what every later "after the command" test compares
                // against: the stamp above is for display and for the badge, and a transcript's
                // stamps do not run in order (`TurnRoot.seq`).
                commandSeq = scanSeq
                // A new question: what answered the PREVIOUS one says nothing about this one, a
                // candidate held for it is not held for this, the flags that explained it belong to
                // it, and the canary starts counting again.
                modelConfirmation = nil
                pendingConfirmation = nil
                flagsSinceCommand.removeAll()
                unanchoredServed = 0
                anchorLossReported = false
            }
            if line.contains(nativeModelStdoutPrefix),
               lineIsCommandRecord(line, opening: nativeModelStdoutOpening),
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
                let flag = SafeguardFlag(at: when, from: from, to: to, category: category,
                                         refusedUUID: object["refusedUserMessageUuid"] as? String,
                                         uuid: object["uuid"] as? String)
                lastFlag = flag
                // ALL of them since the command, not just the newest: two fallbacks inside one
                // command's window are possible, and a candidate compared against only the last one
                // walks through the earlier one (gate review, 2026-08-07). Bounded by the reset a new
                // command performs, and by the handful of refusals a session can produce between
                // two turns.
                if lastModelCommandAt != nil { flagsSinceCommand.append(flag) }
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
