import Foundation

// Open-turn detection (OpenTurn.swift): a session sitting inside a long tool call is BUSY, however
// long its transcript has been silent. Split out of main.swift for file size; the harness (`check`,
// `failures`) is shared from there.
//
// Every fixture below is built to the shapes read off this machine's real transcripts on
// 2026-07-26, not to what the format looks like it should be: the call is a `tool_use` block with
// an `id` inside an assistant event's `message.content`, the return is a `tool_result` block whose
// `tool_use_id` names it inside a user event's, and `isSidechain` sits at the top level.

func runOpenTurnChecks() {
    // MARK: - 25. A silent transcript is not an idle session

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func iso(_ secondsAgo: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(-secondsAgo))
    }
    /// An assistant event opening `calls`, `secondsAgo` before `now`.
    func toolUse(_ calls: [String], secondsAgo: TimeInterval, sidechain: Bool = false) -> String {
        let blocks = calls.map {
            "{\"type\":\"tool_use\",\"id\":\"\($0)\",\"name\":\"Bash\",\"input\":{}}"
        }.joined(separator: ",")
        return "{\"parentUuid\":\"p0\",\"isSidechain\":\(sidechain),\"type\":\"assistant\","
            + "\"uuid\":\"a-\(calls.joined())\",\"timestamp\":\"\(iso(secondsAgo))\","
            + "\"message\":{\"model\":\"claude-opus-5\",\"role\":\"assistant\",\"content\":[\(blocks)],"
            + "\"stop_reason\":\"tool_use\"}}"
    }
    /// A user event returning `calls`.
    func toolResult(_ calls: [String], secondsAgo: TimeInterval, sidechain: Bool = false) -> String {
        let blocks = calls.map {
            "{\"tool_use_id\":\"\($0)\",\"type\":\"tool_result\",\"content\":\"ok\"}"
        }.joined(separator: ",")
        return "{\"parentUuid\":\"p0\",\"isSidechain\":\(sidechain),\"type\":\"user\","
            + "\"uuid\":\"u-\(calls.joined())\",\"timestamp\":\"\(iso(secondsAgo))\","
            + "\"message\":{\"role\":\"user\",\"content\":[\(blocks)]}}"
    }
    /// An assistant event that answered in prose: the turn ended without opening anything.
    func prose(_ secondsAgo: TimeInterval) -> String {
        "{\"parentUuid\":\"p0\",\"isSidechain\":false,\"type\":\"assistant\",\"uuid\":\"a-text\","
            + "\"timestamp\":\"\(iso(secondsAgo))\",\"message\":{\"model\":\"claude-opus-5\","
            + "\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}"
    }
    func busy(_ lines: [String]) -> Bool {
        openTurnHoldsSession(openedAt: openToolCall(inTail: lines.joined(separator: "\n"))?.startedAt,
                             now: now)
    }

    // The case the whole thing exists for: an 8-minute build, 300s in. The file has said nothing
    // for 300s, so every mtime bar in the supervisor calls this session idle, and it is not.
    check("a tool call still running blocks a non-urgent relaunch",
          busy([prose(600), toolUse(["toolu_a"], secondsAgo: 300)]))
    check("and the open call's own start time is what is reported",
          openToolCall(inTail: toolUse(["toolu_a"], secondsAgo: 300))?.startedAt
            == now.addingTimeInterval(-300))
    // The same silence with the result already back is a genuinely idle session, which must stay
    // takeable: this is the case that keeps reload and self-update working at all.
    check("a closed pair does not block anything",
          !busy([toolUse(["toolu_a"], secondsAgo: 300), toolResult(["toolu_a"], secondsAgo: 298)]))
    check("an assistant that answered in prose is closed",
          !busy([toolUse(["toolu_a"], secondsAgo: 400), toolResult(["toolu_a"], secondsAgo: 398),
                 prose(300)]))
    check("an empty tail decides nothing and blocks nothing", !busy([]))
    check("a tail with no assistant event at all blocks nothing",
          !busy([toolResult(["toolu_x"], secondsAgo: 30)]))

    // MARK: - 25b. The veto expires, so a crashed child cannot wedge its session

    // A child SIGKILLed mid-call leaves its `tool_use` unmatched for good. Without a ceiling that
    // session would refuse every reload and self-update for the rest of its life, so the evidence
    // stops counting at the same 600s the subagent window uses.
    check("an open call just under the cap still holds the session",
          busy([toolUse(["toolu_a"], secondsAgo: openTurnMaxSeconds - 1)]))
    check("an open call past the cap has stopped counting",
          !busy([toolUse(["toolu_a"], secondsAgo: openTurnMaxSeconds + 1)]))
    check("a call open for an hour never wedges the session",
          !busy([toolUse(["toolu_a"], secondsAgo: 3600)]))
    check("the open-turn cap is the subagent window, deliberately the same number",
          openTurnMaxSeconds == subagentIdleSeconds)
    // The longest real tool call measured across the 207 transcripts on this machine was 153.7s,
    // so the cap sits far above anything normal use produces rather than trimming it.
    check("the cap clears the longest tool call actually measured here",
          openTurnMaxSeconds > 153.7 * 3)

    // MARK: - 25c. Sidechains belong to another conversation

    // A subagent's events must neither open a turn on the main chain nor close one. They cannot
    // reach this file today (all 269,050 events across the 207 main transcripts are
    // `isSidechain:false`, and the 31,208 subagent events live in their own files), so these keep
    // that a property of the code rather than of the current on-disk layout.
    check("a sidechain tool call does not make the main chain busy",
          !busy([prose(600), toolUse(["toolu_sub"], secondsAgo: 30, sidechain: true)]))
    check("a sidechain result does not close the main chain's open call",
          busy([toolUse(["toolu_a"], secondsAgo: 200),
                toolResult(["toolu_a"], secondsAgo: 100, sidechain: true)]))
    check("a sidechain event does not hide a closed turn either",
          !busy([toolUse(["toolu_a"], secondsAgo: 300), toolResult(["toolu_a"], secondsAgo: 298),
                 toolUse(["toolu_sub"], secondsAgo: 10, sidechain: true)]))

    // MARK: - 25d. Several calls opened at once

    // Rare but real: 66,684 assistant messages on this machine open one call, two open two, and one
    // opens seven. A turn is finished only when every call it opened has come back, so a partial
    // answer is still a live turn.
    check("two calls with only one answered is still open",
          busy([toolUse(["toolu_a", "toolu_b"], secondsAgo: 200),
                toolResult(["toolu_a"], secondsAgo: 190)]))
    check("two calls both answered is closed",
          !busy([toolUse(["toolu_a", "toolu_b"], secondsAgo: 200),
                 toolResult(["toolu_a"], secondsAgo: 190), toolResult(["toolu_b"], secondsAgo: 185)]))
    check("answers arriving in one event close it too",
          !busy([toolUse(["toolu_a", "toolu_b"], secondsAgo: 200),
                 toolResult(["toolu_a", "toolu_b"], secondsAgo: 190)]))
    check("an answer to a DIFFERENT call does not close this one",
          busy([toolUse(["toolu_a"], secondsAgo: 200), toolResult(["toolu_zzz"], secondsAgo: 190)]))

    // MARK: - 25d2. WHICH tool is open, out of the same walk

    // The second question this scan answers (SessionStateSync.swift is the caller): a session
    // holding `AskUserQuestion` open is waiting on a PERSON, and Claude Code fires no notification
    // for that at all - so the transcript is the only witness there is.
    /// An assistant event opening `calls` as (id, tool name) pairs.
    func namedToolUse(_ calls: [(String, String)], secondsAgo: TimeInterval) -> String {
        let blocks = calls.map {
            "{\"type\":\"tool_use\",\"id\":\"\($0.0)\",\"name\":\"\($0.1)\",\"input\":{}}"
        }.joined(separator: ",")
        return "{\"parentUuid\":\"p0\",\"isSidechain\":false,\"type\":\"assistant\","
            + "\"uuid\":\"a-\(calls.map(\.0).joined())\",\"timestamp\":\"\(iso(secondsAgo))\","
            + "\"message\":{\"model\":\"claude-opus-5\",\"role\":\"assistant\",\"content\":[\(blocks)],"
            + "\"stop_reason\":\"tool_use\"}}"
    }
    check("the open call names the tool it is inside",
          openToolCall(inTail: namedToolUse([("toolu_q", "AskUserQuestion")], secondsAgo: 30))?
              .names == ["AskUserQuestion"])
    // ONLY THE UNANSWERED ONES. An event that opened a question and a Bash call has closed the Bash
    // one by the time the question is still standing, and naming a tool that already came back
    // would report a wait that ended.
    check("a tool whose result is already back is not among them",
          openToolCall(inTail: [namedToolUse([("toolu_b", "Bash"), ("toolu_q", "AskUserQuestion")],
                                             secondsAgo: 60),
                                toolResult(["toolu_b"], secondsAgo: 50)].joined(separator: "\n"))?
              .names == ["AskUserQuestion"])
    check("a closed turn names nothing, because there is no open call to name",
          openToolCall(inTail: [namedToolUse([("toolu_q", "AskUserQuestion")], secondsAgo: 60),
                                toolResult(["toolu_q"], secondsAgo: 50)].joined(separator: "\n"))
              == nil)
    // A block with no `name` is skipped rather than reported as an empty tool: the id is what pairs
    // a call with its result, and the name is what this second question reads.
    check("a call carrying no tool name contributes none",
          openToolCall(inTail: "{\"parentUuid\":\"p0\",\"isSidechain\":false,"
                       + "\"type\":\"assistant\",\"uuid\":\"a-x\",\"timestamp\":\"\(iso(30))\","
                       + "\"message\":{\"role\":\"assistant\",\"content\":["
                       + "{\"type\":\"tool_use\",\"id\":\"toolu_n\",\"input\":{}}]}}")?
              .names.isEmpty == true)
    // The two tools only a person can close, and nothing else: every other tool open on the main
    // chain is the session working.
    // ONE MAP, so a tool cannot be recognised as a wait and then have nothing to say about
    // itself: recognition and the sentence are the same lookup.
    check("the tools that mean a person is being waited for are named, and only those",
          Set(userQuestionTools.keys) == ["AskUserQuestion", "ExitPlanMode"])
    check("…and each says what it is waiting for, in the sentence a card prints",
          userQuestionTools["AskUserQuestion"] == "Claude is asking you a question"
              && userQuestionTools["ExitPlanMode"] == "A plan is waiting for approval")
    check("…while a tool that is not one of them has nothing to say",
          userQuestionTools["Bash"] == nil)

    // MARK: - 25e. Noise between the call and its result

    // Real turns put other events in that gap (hook records, mode changes, file-history snapshots:
    // four such lines sat inside two of the measured pairs), and none of them ends the wait.
    let hook = "{\"type\":\"system\",\"subtype\":\"hook\",\"isSidechain\":false,"
        + "\"timestamp\":\"\(iso(150))\",\"hookCount\":1}"
    check("a system event between the call and its result does not close it",
          busy([toolUse(["toolu_a"], secondsAgo: 200), hook]))
    check("a half-written final line is skipped rather than believed",
          busy([toolUse(["toolu_a"], secondsAgo: 200), "{\"type\":\"user\",\"message\":{\"conte"]))
    check("a closed turn stays closed behind the same half-written line",
          !busy([toolUse(["toolu_a"], secondsAgo: 200), toolResult(["toolu_a"], secondsAgo: 190),
                 "{\"type\":\"user\",\"message\":{\"conte"]))

    // MARK: - 25f. The tail reader, against real files on disk

    // The pure rule above runs on a string; this is the glue that produces it. Bounded read from
    // the END, so the answer must not change when the same lines sit behind a large history.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-openturn-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let openFile = dir.appendingPathComponent("open.jsonl")
    let padding = String(repeating: prose(9999) + "\n", count: 400)
    try! (padding + toolUse(["toolu_a"], secondsAgo: 200) + "\n")
        .write(to: openFile, atomically: true, encoding: .utf8)
    check("a real file whose last event is an unanswered call reads as open",
          openTurnHoldsSession(openedAt: openToolCall(inTail: transcriptTail(of: openFile) ?? "")?.startedAt,
                               now: now))
    let closedFile = dir.appendingPathComponent("closed.jsonl")
    try! (padding + toolUse(["toolu_a"], secondsAgo: 200) + "\n"
          + toolResult(["toolu_a"], secondsAgo: 190) + "\n")
        .write(to: closedFile, atomically: true, encoding: .utf8)
    check("a real file whose call came back reads as closed",
          !openTurnHoldsSession(openedAt: openToolCall(inTail: transcriptTail(of: closedFile) ?? "")?.startedAt,
                                now: now))
    // The window opens mid-line on any file bigger than it, and half a JSON object must never be
    // parsed: a huge result ahead of the open call is exactly the shape that would do it.
    let hugeFile = dir.appendingPathComponent("huge.jsonl")
    let huge = "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"\(iso(500))\","
        + "\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"toolu_old\","
        + "\"type\":\"tool_result\",\"content\":\"\(String(repeating: "x", count: 400_000))\"}]}}"
    try! (huge + "\n" + toolUse(["toolu_a"], secondsAgo: 200) + "\n")
        .write(to: hugeFile, atomically: true, encoding: .utf8)
    let hugeTail = transcriptTail(of: hugeFile) ?? ""
    check("a tail that opens inside a huge line still finds the open call",
          openTurnHoldsSession(openedAt: openToolCall(inTail: hugeTail)?.startedAt, now: now))
    check("and drops the partial line it opened on rather than parsing it",
          !hugeTail.contains("xxxx"))
    check("a file that cannot be read decides nothing",
          transcriptTail(of: dir.appendingPathComponent("absent.jsonl")) == nil)
    try? FileManager.default.removeItem(at: dir)

    // MARK: - 25g. End to end, through the real quiet gate

    // The assertions above run on the rule; this runs the whole chain the supervisor runs: a real
    // transcript on disk, its mtime pushed back so every existing bar calls it idle, read through
    // `isQuiet` itself. Timestamps here are relative to the REAL clock, because that is what
    // `isQuiet` compares against.
    /// `childLaunchedAt` is the watcher's `since`: when the child WRITING this transcript started.
    /// It defaults to the distant past, which is what every check below except the residue pair
    /// wants (the subagent window ignores writes from before the current child, so a fixture that
    /// dated them out would read as residue and prove nothing about the walk).
    func watcherWithTurn(open: Bool, callAge: TimeInterval,
                         childLaunchedAt: Date = .distantPast) -> TranscriptWatcher {
        let realNow = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func stamp(_ ago: TimeInterval) -> String {
            formatter.string(from: realNow.addingTimeInterval(-ago))
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-openturn-e2e-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        var body = "{\"parentUuid\":\"p0\",\"isSidechain\":false,\"type\":\"assistant\","
            + "\"uuid\":\"a1\",\"timestamp\":\"\(stamp(callAge))\",\"message\":{"
            + "\"model\":\"claude-opus-5\",\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\","
            + "\"id\":\"toolu_e2e\",\"name\":\"Bash\",\"input\":{}}],\"stop_reason\":\"tool_use\"}}\n"
        if !open {
            body += "{\"parentUuid\":\"a1\",\"isSidechain\":false,\"type\":\"user\",\"uuid\":\"u1\","
                + "\"timestamp\":\"\(stamp(callAge - 1))\",\"message\":{\"role\":\"user\","
                + "\"content\":[{\"tool_use_id\":\"toolu_e2e\",\"type\":\"tool_result\","
                + "\"content\":\"ok\"}]}}\n"
        }
        try! body.write(to: file, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.modificationDate: realNow.addingTimeInterval(-callAge)], ofItemAtPath: file.path)
        return TranscriptWatcher(projectDir: dir, file: file, since: childLaunchedAt)
    }
    /// A subagent transcript beside a session file, written `age` seconds ago. The WORKFLOW shape
    /// (`<session>/subagents/workflows/wf_<id>/agent-*.jsonl`) rather than the flat one, because
    /// that is the dispatch whose parent tool call really does outlive the relaunch ceiling: a
    /// fan-out holds one `Workflow` call open for the whole run.
    func dropSubagentWrite(beside file: URL, age: TimeInterval) {
        let subDir = file.deletingPathExtension().appendingPathComponent("subagents")
            .appendingPathComponent("workflows").appendingPathComponent("wf_live")
        try! FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let url = subDir.appendingPathComponent("agent-a3b273b656da7c735.jsonl")
        try! "{}".write(to: url, atomically: true, encoding: .utf8)
        // The DIRECTORIES are dated too, not just the file. The walk takes the newest mtime of
        // everything it enumerates, so a freshly created parent would answer "written just now"
        // whatever the file says - which is fine while the only question is "is anything writing",
        // and wrong the moment the question becomes "did the child running now write it".
        var path = url
        for _ in 0...3 {
            try! FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path.path)
            path = path.deletingLastPathComponent()
        }
    }
    // 300s of total silence: past the 120s follow bar, so before this the supervisor relaunched
    // here and killed the build that was running.
    var midBuild = watcherWithTurn(open: true, callAge: 300)
    check("a session 300s into a tool call is NOT quiet at the follow bar",
          !midBuild.isQuiet(followIdleSeconds))
    check("nor at the urgent bar, which is what pin and rescue use",
          !midBuild.isQuiet(5))
    var finished = watcherWithTurn(open: false, callAge: 300)
    check("the same 300s of silence with the result back IS quiet",
          finished.isQuiet(followIdleSeconds))
    var abandoned = watcherWithTurn(open: true, callAge: openTurnMaxSeconds + 120)
    check("a call abandoned past the cap stops holding the session quiet",
          abandoned.isQuiet(followIdleSeconds))
    var stillStreaming = watcherWithTurn(open: false, callAge: 2)
    check("a file written 2s ago is busy on the mtime bar as it always was",
          !stillStreaming.isQuiet(followIdleSeconds))

    // THE CAP IS THE RELAUNCH GATE'S, AND THE TYPING GATE DOES NOT INHERIT IT. Past
    // `openTurnMaxSeconds` an unmatched call stops holding, which is right for a restart: a child
    // killed mid-call leaves that call unmatched for ever, and a veto with no ceiling would wedge
    // the session out of every reload for the rest of its life. But a call that old with a subagent
    // still WRITING beside it is not that case at all - a dead child writes no subagent transcripts
    // - so it is a conversation genuinely inside a long turn (a `Workflow` fan-out is the ordinary
    // one), and `tally session send` must not type into it. The reading says `busy` rather than
    // `subagentsWriting`, which is what makes the input gate hold (codex review of 0c9798b).
    //
    // WHICH CHILD WROTE THEM IS PART OF THE QUESTION, and this pair is what that costs. As first
    // written this check said "a subagent still writing" and meant "a file with a recent mtime",
    // and those are the same sentence for a live fan-out and for the wreckage a cap handoff leaves:
    // the killed child's agents wrote seconds before it died, and the relaunch resumes the same
    // transcript, so the new and completely idle child inherited both halves of the shape below.
    // The dimension that separates them is when the child running NOW started (`since`), so both
    // sides of it are asserted here rather than one (codex review of fa9533b; the same pair end to
    // end, through the board and the input gate, is in windowrepickchecks section 34).
    var oldTurnWithAgents = watcherWithTurn(open: true, callAge: openTurnMaxSeconds + 120,
                                            childLaunchedAt: Date().addingTimeInterval(-7200))
    dropSubagentWrite(beside: oldTurnWithAgents.file!, age: 5)
    check("an over-age tool call with a subagent still writing reads as the turn, not as dispatch",
          oldTurnWithAgents.quietness(followIdleSeconds) == .busy)
    check("…and the input gate holds it as that session's own turn",
          sessionInputHold(state: .working, quiet: oldTurnWithAgents.quietness(followIdleSeconds),
                           keyboardIdle: true, relaunchPlanned: false) == .turn)
    var handedOff = watcherWithTurn(open: true, callAge: openTurnMaxSeconds + 120,
                                    childLaunchedAt: Date())
    dropSubagentWrite(beside: handedOff.file!, age: 5)
    check("the identical shape under a child that started after it is the dead child's wreckage",
          handedOff.quietness(followIdleSeconds) == .quiet)
    // The escape the cap exists for is untouched: the same over-age call with nothing dispatched
    // beside it still reads quiet, so a session whose child was killed mid-call is not locked out.
    var oldTurnAlone = watcherWithTurn(open: true, callAge: openTurnMaxSeconds + 120)
    check("…while the same call with nothing writing beside it is quiet, as the cap intends",
          oldTurnAlone.quietness(followIdleSeconds) == .quiet && oldTurnAlone.isQuiet(5))
    // And the relaunch reading of BOTH is exactly what it was before the three-valued reading
    // existed: an over-age call alone is quiet, one with a live package is not.
    check("…and neither answer moved what the relaunch gates see",
          !oldTurnWithAgents.isQuiet(followIdleSeconds))

    // MARK: - 25h. The wiring: the quiet gate consults it, the cap path never does

    // `isQuiet` is the one gate every non-urgent path shares (pin, follow, reload, self-update,
    // degradation rescue, fallback), and the cap handoff deliberately does not consult it at all.
    // A pure rule cannot hold either half, so the source carries them.
    // Read off SessionQuiet.swift, which is where that gate lives since the watcher was split: it
    // is an extension of the same type, and the reading it now returns is asserted for its three
    // values in the dispatch layout suite.
    let watcherSource = (try? String(contentsOfFile: "TallyCLI/SessionQuiet.swift",
                                     encoding: .utf8)) ?? ""
    check("the transcript watcher source is readable from the suite", !watcherSource.isEmpty)
    if let start = watcherSource.range(of: "mutating func isQuiet("),
       let end = watcherSource.range(of: "func newestSubagentWrite",
                                     range: start.upperBound ..< watcherSource.endIndex) {
        let body = String(watcherSource[start.upperBound ..< end.lowerBound])
        check("the quiet gate consults the open-turn check", body.contains("openTurnHoldsSession"))
        check("and still consults the subagent window", body.contains("subagentIdleSeconds"))
    } else {
        check("the isQuiet body was found", false)
    }
    let supervisorSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift",
                                        encoding: .utf8)) ?? ""
    if let start = supervisorSource.range(of: "// Cap handoff / wait:"),
       let end = supervisorSource.range(of: "// The session's ACTUAL model",
                                        range: start.upperBound ..< supervisorSource.endIndex) {
        let cap = String(supervisorSource[start.upperBound ..< end.lowerBound])
        check("the cap handoff consults neither the quiet gate nor the open-turn check",
              !cap.contains("isQuiet") && !cap.contains("openTurn"))
    } else {
        check("the cap block was found by the open-turn checks", false)
    }

    // MARK: - 25i. The scan is cached against the mtime; the verdict never is

    // The supervisor asks this question on every 2s poll, and a quiet session is the common state
    // rather than the rare one, so re-reading a 256 KB tail and re-parsing every line in it to
    // re-derive an answer nothing could have changed is waste that runs all night. The cache is
    // keyed on the file and the mtime it was read at.
    let cacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-openturn-cache-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    /// The mtime of a file on disk: what the quiet gate has already stat'd and hands to the scan.
    /// Built from a fresh URL for the reason the gate itself does it, one line above the call:
    /// `resourceValues` are cached per URL instance, so re-asking the same one never sees a write.
    func mtime(_ url: URL) -> Date {
        let fresh = URL(fileURLWithPath: url.path)
        return ((try? fresh.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate) ?? .distantPast
    }
    let cachedFile = cacheDir.appendingPathComponent("cached.jsonl")
    try! (toolUse(["toolu_a"], secondsAgo: 200) + "\n")
        .write(to: cachedFile, atomically: true, encoding: .utf8)
    var cachedWatcher = TranscriptWatcher(projectDir: cacheDir, file: cachedFile, since: launch)
    let cachedStamp = mtime(cachedFile)
    let firstScan = cachedWatcher.openTurn(of: cachedFile, modified: cachedStamp)
    check("the first ask reads the open call out of the file",
          firstScan?.startedAt == now.addingTimeInterval(-200))
    // Deleting the file is what makes the next assertion a proof rather than a coincidence: a
    // second read would find nothing and answer nil, so the same answer can only be the cached one.
    try! FileManager.default.removeItem(at: cachedFile)
    check("the same file at the same mtime is answered without reading it again",
          cachedWatcher.openTurn(of: cachedFile, modified: cachedStamp) == firstScan)

    // A file that MOVED must be re-read, or a session would stay busy long after its call came
    // back (and a call opened after the last scan would go unseen).
    let movingFile = cacheDir.appendingPathComponent("moving.jsonl")
    let openBody = toolUse(["toolu_b"], secondsAgo: 200) + "\n"
    try! openBody.write(to: movingFile, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-200)], ofItemAtPath: movingFile.path)
    var movingWatcher = TranscriptWatcher(projectDir: cacheDir, file: movingFile, since: launch)
    let openStamp = mtime(movingFile)
    check("an unanswered call reads as busy on the first ask",
          openTurnHoldsSession(
            openedAt: movingWatcher.openTurn(of: movingFile, modified: openStamp)?.startedAt,
            now: now))
    // The result comes back, which in the real thing appends a line and stamps the file with a new
    // mtime; the stamp is set by hand here because an atomic write carries the old one over.
    try! (openBody + toolResult(["toolu_b"], secondsAgo: 190) + "\n")
        .write(to: movingFile, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-190)], ofItemAtPath: movingFile.path)
    let closedStamp = mtime(movingFile)
    check("a written transcript comes back with a new mtime, so the key stops matching",
          closedStamp != openStamp)
    check("and the next ask rescans and sees the turn closed",
          !openTurnHoldsSession(
            openedAt: movingWatcher.openTurn(of: movingFile, modified: closedStamp)?.startedAt,
            now: now))

    // What must NEVER be cached is the VERDICT. It expires at `openTurnMaxSeconds` while the mtime
    // stands perfectly still, which is exactly the state a child SIGKILLed mid-call leaves behind,
    // so a cached verdict would wedge that session busy for the rest of its life.
    if let opened = cachedWatcher.openTurn(of: cachedFile, modified: cachedStamp)?.startedAt {
        check("a cached scan still holds the session inside the cap",
              openTurnHoldsSession(openedAt: opened,
                                   now: opened.addingTimeInterval(openTurnMaxSeconds - 1)))
        check("and stops holding it past the cap, on the same unchanged mtime",
              !openTurnHoldsSession(openedAt: opened,
                                    now: opened.addingTimeInterval(openTurnMaxSeconds + 1)))
    } else {
        check("the cached scan still reported the open call", false)
    }
    try? FileManager.default.removeItem(at: cacheDir)
}
