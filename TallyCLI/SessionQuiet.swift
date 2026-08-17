import Foundation

// HOW QUIET A CONVERSATION IS, which is the one question every gate in the poll loop asks before it
// acts on a session: a relaunch, a self-update, a handoff that can wait, and the line
// `tally session send` is holding.
//
// Split out of TranscriptWatcher.swift, which keeps the tailing itself (binding a file, following a
// fork, reading the events). The seam is the one the readers already drew: nothing here reads an
// event, and everything here is about mtimes and the walk beside them. It moved because the file it
// came from is far over the size a file in this repo may be, and because the answer grew a third
// value that has a reader of its own (below).

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

/// What a session's silence is made of, in the three shapes that are worth telling apart.
///
/// THE READERS ARE NOT ALIKE, which is the whole reason this is not a Bool. Every gate that
/// RESTARTS a child (a reload, a self-update, a pin follow, a rebalance) treats all three the same
/// way and asks `isQuiet`: a restart kills whatever is running, so a work package writing in the
/// background is exactly as fatal to it as a turn mid-stream. The gate that TYPES a line
/// (`tally session send`) kills nothing, and for it the difference is the feature: a head that has
/// finished its answer and left agents running is a head whose context may be cleared, and holding
/// its `/clear` until every subagent stops is what made a routine hand-over hang for minutes at a
/// time (Albert, 2026-08-17, after four refusals the day before).
enum SessionQuiet: Equatable {
    /// Nothing outstanding at all: the file silent for the bar asked, no tool call open, no
    /// unresolved fork, and no subagent that has written inside `subagentIdleSeconds`.
    case quiet
    /// The conversation's OWN context is as quiet as that, and the only thing still writing is work
    /// it dispatched (`<session>/subagents/`). It means no unmatched tool call of ANY age, not
    /// merely none inside the relaunch ceiling (`boundFileQuietness` argues why).
    case subagentsWriting
    /// The conversation itself is moving: its transcript is being appended to, a tool call it opened
    /// has not come back, or a fork it may have moved into cannot be told apart yet.
    case busy
}

extension TranscriptWatcher {
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
    mutating func isQuiet(_ seconds: TimeInterval = 5) -> Bool { quietness(seconds) == .quiet }

    /// The same reading with its three answers kept apart (`SessionQuiet` states who asks for
    /// which). Everything `isQuiet` promises is promised here; that one is this one flattened.
    mutating func quietness(_ seconds: TimeInterval = 5) -> SessionQuiet {
        locateFile()
        if hasUnresolvedFork { return .busy }
        return boundFileQuietness(seconds)
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
        boundFileQuietness(seconds) == .quiet
    }

    /// And that one in its three-valued form, which is where the distinction is actually made.
    ///
    /// A MISSING FILE READS AS `quiet` rather than as anything else, unchanged from the Bool this
    /// grew out of: a session on a path that no longer exists has nothing outstanding, and the
    /// callers that care whether a transcript exists at all ask that separately
    /// (`supervisedSessionState` takes `hasTranscript` for exactly this reason).
    mutating func boundFileQuietness(_ seconds: TimeInterval) -> SessionQuiet {
        // Fresh URL on purpose: resourceValues are cached per URL instance, and a cached
        // mtime would report an active turn as quiet forever.
        guard let file,
              let modified = (try? URL(fileURLWithPath: file.path)
                  .resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate else { return .quiet }
        guard Date().timeIntervalSince(modified) > seconds else { return .busy }
        // Past the mtime bar is exactly where an idle session lives, so the tail read behind this
        // is cached against the mtime already in hand (see `openScanCache`) rather than repeated
        // on every poll. The verdict itself is still computed here, against the current clock.
        let call = openTurn(of: file, modified: modified)
        if openTurnHoldsSession(openedAt: call?.startedAt) { return .busy }
        guard let subagent = newestSubagentWrite(),
              Date().timeIntervalSince(subagent) <= subagentIdleSeconds else { return .quiet }
        // DISPATCHED WORK BESIDE A TOOL CALL THAT NEVER CAME BACK IS NOT DISPATCHED WORK, and the
        // age of that call does not enter into it. `openTurnHoldsSession` stops honouring a call
        // after `openTurnMaxSeconds`, which is right for what that cap is for: a child SIGKILLed
        // mid-call leaves its `tool_use` unmatched for ever, and a relaunch gate with no ceiling
        // would wedge that session out of every restart for the rest of its life. Inheriting the
        // ceiling here would let a line be typed INTO a live turn, because the two situations are
        // told apart by exactly this pair: a killed child writes no subagent transcripts either, so
        // an unmatched call with a subagent still writing beside it is a conversation genuinely
        // inside a turn that has run long (a `Workflow` fan-out is the ordinary case, and it runs
        // well past the ceiling). The stale-call escape stays open where it was, which is the row
        // above: no subagent writing, and the reading is `quiet` exactly as it always was.
        return call == nil ? .subagentsWriting : .busy
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
}
