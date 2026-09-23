import Foundation

// Incremental transcript event processing, split from the watcher storage and binding.
extension TranscriptWatcher {
    /// Scan newly-appended lines; true when a genuine cap-hit event (newer than launch) appears.
    ///
    /// BOUNDED PER CALL (issue #3): a supervisor bound to a long conversation used to read
    /// everything from `offset` to the end in one go, which on a 295 MB transcript held the poll
    /// loop for minutes. It now reads in blocks up to `scanBudgetBytes` and leaves the rest for the
    /// next tick, and lines older than this child go through `consumedAsHistory`, which does only
    /// what the full scan would have done with them.
    mutating func sawCapHit() -> Bool {
        locateFile()
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else {
            caughtUp = false
            return false
        }
        defer { try? handle.close() }
        let end = handle.seekToEndOfFile()
        if end < offset {
            offset = 0
            loginSignals = TranscriptLoginSignals()
        }
        // A partial record may still contain a fallback flag, so only actual silence can settle a
        // pending model choice before the next complete event arrives.
        guard end > offset else {
            caughtUp = true
            settlePendingIfQuiet()
            return false
        }
        handle.seek(toFileOffset: offset)
        let start = offset
        let blockBytes = max(1, min(transcriptScanBlockBytes, scanBudgetBytes))
        var hit = false
        let sinceKey = transcriptSecondKey(since)
        // Bytes from `offset` not yet ended by a newline. Always rebuilt from index 0.
        var pending = Data()
        var read = 0
        var atEnd = false
        while !atEnd {
            // The budget stops the read only once a line has been consumed: a single line larger
            // than the budget is read whole, or every tick would re-read it and never move.
            if read >= scanBudgetBytes, offset > start { break }
            guard let block = try? handle.read(upToCount: blockBytes), !block.isEmpty else {
                atEnd = true
                break
            }
            if block.count < blockBytes { atEnd = true }
            read += block.count
            // Only the part just appended can hold a newline: `pending` never keeps one.
            let searchFrom = pending.count
            pending.append(block)
            guard let newline = transcriptLastNewline(in: pending, from: searchFrom) else { continue }
            let complete = pending.prefix(newline + 1)
            if scanCompleteLines(complete, sinceKey: sinceKey) { hit = true }
            offset += UInt64(complete.count)
            pending = Data(pending.suffix(from: newline + 1))
        }
        // Keep an incomplete final JSON record on disk for the next poll, including a split UTF-8
        // scalar. Complete records without a trailing newline are valid transcript fixtures too.
        if atEnd, !pending.isEmpty, (try? JSONSerialization.jsonObject(with: pending)) != nil {
            if scanCompleteLines(pending, sinceKey: sinceKey) { hit = true }
            offset += UInt64(pending.count)
        }
        // A trailing record still being written does not count as unread: it is not a line yet.
        caughtUp = atEnd || offset >= end
        return hit
    }

    /// Every non-empty line in `bytes`, each consumed by the history path or decoded and scanned.
    /// A line that is not valid UTF-8 is skipped on its own rather than taking its block with it.
    private mutating func scanCompleteLines(_ bytes: Data, sinceKey: [UInt8]) -> Bool {
        var hit = false
        bytes.withUnsafeBytes { (all: UnsafeRawBufferPointer) in
            var lineStart = 0
            while lineStart < all.count {
                let lineEnd = transcriptByteIndex(of: 0x0A, in: all, from: lineStart) ?? all.count
                defer { lineStart = lineEnd + 1 }
                guard lineEnd > lineStart else { continue }
                let line = UnsafeRawBufferPointer(rebasing: all[lineStart..<lineEnd])
                if consumedAsHistory(line, sinceKey: sinceKey) { continue }
                fullPathLines += 1
                guard let text = String(bytes: line, encoding: .utf8) else { continue }
                if scanLine(text[...]) { hit = true }
            }
        }
        return hit
    }

    /// True when `line` predates this child and was fully handled here, off the bytes.
    ///
    /// Everything the full scan does is guarded by `since` EXCEPT two readers: the conversation's
    /// size (`lastContextTokens`, deliberately unguarded so a resumed session reports its size
    /// before its first turn) and the excerpt FIFO. So an old line does exactly those two things and
    /// nothing else. Kept on the full path: lines whose readers judge time by the top-level stamp
    /// after a parse (`transcriptFullPathNeedles`), lines with no stamp, and every line while a
    /// login failure is open (`TranscriptLoginSignals.observe` parses each of them then).
    private mutating func consumedAsHistory(_ line: UnsafeRawBufferPointer,
                                            sinceKey: [UInt8]) -> Bool {
        guard skipsHistoryCheaply, loginSignals.requiredAt == nil,
              transcriptLineStampedBefore(bytes: line, since: since, sinceKey: sinceKey),
              !transcriptFullPathNeedles.contains(where: { transcriptBytesContain(line, $0) })
        else { return false }
        guard !transcriptBytesContain(line, sidechainTrueBytes) else { return true }
        if transcriptBytesContain(line, typeAssistantBytes),
           let tokens = transcriptContextTokens(bytes: line) {
            lastContextTokens = tokens
        }
        if transcriptBytesContain(line, typeUserBytes), let uuid = transcriptLineUUID(bytes: line),
           let text = transcriptUserExcerpt(bytes: line) {
            rememberExcerpt(uuid: uuid, text: text)
        }
        return true
    }

    /// One complete line through every reader, in the order the scan has always used. True when it
    /// is a genuine cap hit.
    private mutating func scanLine(_ line: Substring) -> Bool {
        loginSignals.observe(line, since: since, sessionID: transcriptSessionID)
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
            // The two clocks a standing wait is judged against: whether the conversation moved
            // at all (`lastConversationEventAt`, user and assistant records only; a `system`
            // record is Claude Code talking about the session, not the session moving) and
            // whether a PERSON moved it (`lastPersonInputAt`, `lineIsPersonInput`).
            if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
               lastConversationEventAt.map({ ts > $0 }) ?? true {
                lastConversationEventAt = ts
            }
            if lineIsPersonInput(line), lastPersonInputAt.map({ ts > $0 }) ?? true {
                lastPersonInputAt = ts
            }
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
        // WHAT THIS ACCOUNT HAS BEEN TOLD ABOUT ITS WEEKLY RESET, from any line that carries
        // one of Claude Code's own sentences: the command's answer (a `local_command` record)
        // and the wall notice (an api-error body) are the two shapes, and both go through the
        // one matcher (LimitResetSignals.swift). Post-launch and main-chain, the guards every
        // signal here carries: a resumed conversation replays its whole history, and a reset
        // spent last week is not news about this one.
        if let ts = lineTimestamp(line), ts >= since,
           !line.contains("\"isSidechain\":true"),
           let outcome = limitResetSignal(inLine: line) {
            lastLimitReset = (outcome, ts)
        }
        guard line.contains("\"isApiErrorMessage\":true") else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let message = object["message"] as? [String: Any] else { return false }
        let content = message["content"]
        let body = (content as? String)
            ?? ((content as? [[String: Any]])?.first?["text"] as? String) ?? ""
        guard body.hasPrefix("You've"), body.contains("limit") else { return false }
        // Ignore events older than this child (a forked resume carries the previous
        // conversation's history - including the very cap event that triggered the handoff).
        let when = (object["timestamp"] as? String).flatMap(parseISO)
        if let when, when < since { return false }
        // Assigned unconditionally, nil included, so a reported cap always describes THIS
        // event rather than inheriting a stamp from one the caller already acted on. The wall
        // it names travels with it on the same terms and for the same reason.
        capHitAt = when
        capHitScope = capScope(ofBody: body)
        return true
    }
}

/// Whether a main-chain transcript record is something a PERSON produced: the only kind of record
/// that may explain a standing wait as `answered` (`lastPersonInputAt`).
///
/// A `user` record, then everything Claude Code itself writes under that type is refused. The
/// census this was written from (14 days of transcripts on this machine, Claude Code 2.1.277 to
/// 2.1.280, 2026-09-23; docs/session-wait-events.md lists it) found these stamped main-chain kinds:
///   - a person: typed or queued prompts (`origin.kind == "human"`), slash commands
///     (`<command-name>`), an interrupt (`[Request interrupted`), a prompt from an SDK host, and
///     tool results, which is what a permission or question dialog writes once answered;
///   - not a person: `isMeta` records (skill bodies, Stop hook feedback, command caveats, peer
///     messages), `isCompactSummary`, `promptSource: "system"` (task notifications), and every
///     `assistant`, `system` (`informational`, `away_summary`, `turn_duration`,
///     `stop_hook_summary`, `local_command`, `model_fallback`) and `attachment` record.
///
/// UNKNOWN MEANS NOT A PERSON: an `origin.kind` other than `human`, or a `promptSource` outside the
/// three seen from people, is refused. Wrong in that direction, an answer is reported late (or as
/// `unknown` when the conversation moves on without one); wrong in the other, a wait nobody
/// answered is reported answered, which is the defect this exists for (H1 rerun O4: a stamped
/// `system`/`informational` line 0.97s after an auto mode toggle read as the answer).
///
/// On a Claude Code whose registry speaks (2.1.280), this never decides whether a dialog is open
/// (`claudeDialogOpen` does); it labels a close the older rules made, and the `idle_prompt` path.
/// Limitation 13 (a tool result of another call read as the answer) is therefore confined to the
/// registry-less path.
func lineIsPersonInput<S: StringProtocol>(_ line: S) -> Bool {
    guard line.contains("\"type\":\"user\""), !line.contains("\"isSidechain\":true"),
          !line.contains("\"isMeta\":true"), !line.contains("\"isCompactSummary\":true"),
          !line.contains("<task-notification>") else { return false }
    if line.contains("\"origin\":{\"kind\":\""), !line.contains("\"origin\":{\"kind\":\"human\"") {
        return false
    }
    if line.contains("\"promptSource\":\""),
       !["typed", "queued", "sdk"].contains(where: { line.contains("\"promptSource\":\"\($0)\"") }) {
        return false
    }
    return true
}
