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
        openTurnHoldsSession(openedAt: openToolCallStart(inTail: lines.joined(separator: "\n")),
                             now: now)
    }

    // The case the whole thing exists for: an 8-minute build, 300s in. The file has said nothing
    // for 300s, so every mtime bar in the supervisor calls this session idle, and it is not.
    check("a tool call still running blocks a non-urgent relaunch",
          busy([prose(600), toolUse(["toolu_a"], secondsAgo: 300)]))
    check("and the open call's own start time is what is reported",
          openToolCallStart(inTail: toolUse(["toolu_a"], secondsAgo: 300))
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
          openTurnHoldsSession(openedAt: openToolCallStart(inTail: transcriptTail(of: openFile) ?? ""),
                               now: now))
    let closedFile = dir.appendingPathComponent("closed.jsonl")
    try! (padding + toolUse(["toolu_a"], secondsAgo: 200) + "\n"
          + toolResult(["toolu_a"], secondsAgo: 190) + "\n")
        .write(to: closedFile, atomically: true, encoding: .utf8)
    check("a real file whose call came back reads as closed",
          !openTurnHoldsSession(openedAt: openToolCallStart(inTail: transcriptTail(of: closedFile) ?? ""),
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
          openTurnHoldsSession(openedAt: openToolCallStart(inTail: hugeTail), now: now))
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
    func watcherWithTurn(open: Bool, callAge: TimeInterval) -> TranscriptWatcher {
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
        return TranscriptWatcher(projectDir: dir, file: file, since: launch)
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

    // MARK: - 25h. The wiring: the quiet gate consults it, the cap path never does

    // `isQuiet` is the one gate every non-urgent path shares (pin, follow, reload, self-update,
    // degradation rescue, fallback), and the cap handoff deliberately does not consult it at all.
    // A pure rule cannot hold either half, so the source carries them.
    let watcherSource = (try? String(contentsOfFile: "TallyCLI/TranscriptWatcher.swift",
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
       let end = supervisorSource.range(of: "// Follow the launch default:",
                                        range: start.upperBound ..< supervisorSource.endIndex) {
        let cap = String(supervisorSource[start.upperBound ..< end.lowerBound])
        check("the cap handoff consults neither the quiet gate nor the open-turn check",
              !cap.contains("isQuiet") && !cap.contains("openTurn"))
    } else {
        check("the cap block was found by the open-turn checks", false)
    }
}
