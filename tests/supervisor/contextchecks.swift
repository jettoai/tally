import Foundation

// The session-context reading (SessionContext.swift): how much context a resume would reload,
// taken off the transcript the supervisor already tails and published on the supervisor-state
// track for `tally status --json`.
//
// The line fixtures below are the real shapes from this machine's transcripts (2026-08-04),
// trimmed: an ordinary assistant turn with its `iterations` array, a synthetic error turn with an
// all-zero usage, and a subagent's sidechain turn.

func runSessionContextChecks() {
    // MARK: - 28. Reading one line

    func assistantLine(input: Int, creation: Int, read: Int, sidechain: Bool = false,
                       iterations: Bool = true) -> String {
        let iterationsField = iterations
            ? #","iterations":[{"input_tokens":7,"cache_read_input_tokens":9,"#
                + #""cache_creation_input_tokens":11}]"#
            : ""
        return #"{"isSidechain":\#(sidechain),"type":"assistant","message":{"model":"claude-fable-5""#
            + #","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(creation)"#
            + #","cache_read_input_tokens":\#(read),"output_tokens":568"#
            + #","server_tool_use":{"web_search_requests":0},"service_tier":"standard""#
            + #","cache_creation":{"ephemeral_1h_input_tokens":\#(creation)"#
            + #","ephemeral_5m_input_tokens":0}\#(iterationsField)}}}"#
    }

    // The three input figures plus this turn's own answer: 2 + 9762 + 467306 + 568.
    check("the input figures and the turn's own answer add up",
          contextTokens(inLine: Substring(assistantLine(input: 2, creation: 9762, read: 467_306)))
              == 477_638)
    // The nested `iterations` array repeats every one of these keys per API call. Reading those
    // instead would report one call's slice as the whole conversation.
    check("the nested iterations are not counted",
          contextTokens(inLine: Substring(assistantLine(input: 2, creation: 753, read: 477_068)))
              == 478_391)
    check("and the answer is the same without an iterations array",
          contextTokens(inLine: Substring(
              assistantLine(input: 2, creation: 753, read: 477_068, iterations: false))) == 478_391)
    // Every earlier turn's output is already inside the next line's input figures. The NEWEST one's
    // is not - no later line exists to have absorbed it - and a resume reloads it all the same, so
    // leaving it out understates the reading by exactly one answer.
    check("the newest turn's own answer is in the sum",
          contextTokens(inLine: Substring(assistantLine(input: 1, creation: 0, read: 0))) == 569)

    // MARK: - 28a. A partial sum is never published

    // The window cut decides what happens when the totals are not all in front of `iterations`, and
    // the answer has to be nil rather than whatever part of them survived: a number that is quietly
    // wrong is worse than none, because the surfaces cannot tell the two apart. The reading simply
    // stops moving instead.
    let iterationsFirst = #"{"isSidechain":false,"type":"assistant","message":{"usage":{"#
        + #""iterations":[{"input_tokens":7,"cache_read_input_tokens":9,"#
        + #""cache_creation_input_tokens":11}],"input_tokens":2,"#
        + #""cache_creation_input_tokens":753,"cache_read_input_tokens":477068}}}"#
    check("iterations in front: nothing rather than one call's slice",
          contextTokens(inLine: Substring(iterationsFirst)) == nil)
    // The half-and-half order, which the first-match search alone does NOT cover: `input_tokens`
    // lands inside the window and both cache figures fall outside it, so a sum over whatever
    // happened to hit would publish 2 for a conversation of half a million (caught in review,
    // 2026-08-04).
    let iterationsBetween = #"{"isSidechain":false,"type":"assistant","message":{"usage":{"#
        + #""input_tokens":2,"iterations":[{"input_tokens":7,"cache_read_input_tokens":9,"#
        + #""cache_creation_input_tokens":11}],"cache_creation_input_tokens":753,"#
        + #""cache_read_input_tokens":477068,"output_tokens":568}}}"#
    check("iterations in the middle: nothing rather than a two-digit conversation",
          contextTokens(inLine: Substring(iterationsBetween)) == nil)
    // A missing `output_tokens` is the one absence that still answers: it costs one turn's answer,
    // where a missing cache figure costs nearly the whole conversation.
    let noOutput = #"{"isSidechain":false,"type":"assistant","message":{"usage":{"#
        + #""input_tokens":2,"cache_creation_input_tokens":753,"#
        + #""cache_read_input_tokens":477068}}}"#
    check("a usage with no output figure still answers",
          contextTokens(inLine: Substring(noOutput)) == 477_823)
    // A field that is present but not a number is a disagreement about the shape, not a zero.
    let nullField = #"{"isSidechain":false,"type":"assistant","message":{"usage":{"#
        + #""input_tokens":2,"cache_creation_input_tokens":null,"#
        + #""cache_read_input_tokens":477068,"output_tokens":568}}}"#
    check("a non-numeric input figure answers nothing",
          contextTokens(inLine: Substring(nullField)) == nil)
    // A synthetic turn (an interrupted call, an API error) is written with an all-zero usage. It
    // must read as no answer rather than as a conversation of size zero, or one API error would
    // wipe a real reading - the same trap replayed history once sprang on `lastModel`.
    let synthetic = #"{"isSidechain":false,"type":"assistant","message":{"model":"<synthetic>","#
        + #""usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"#
        + #""cache_read_input_tokens":0}}}"#
    check("an all-zero usage is no reading", contextTokens(inLine: Substring(synthetic)) == nil)
    check("a line with no usage at all is no reading",
          contextTokens(inLine: #"{"type":"user","message":{"content":"hi"}}"#) == nil)

    // MARK: - 28b. Off the watcher's own scan

    let scanned = watcherAfterScanning([
        assistantLine(input: 2, creation: 100, read: 10_000),
        assistantLine(input: 2, creation: 200, read: 50_000),
    ])
    check("the newest turn is the reading", scanned.lastContextTokens == 50_770)
    // A subagent's context is its own, and it is not what a resume of THIS conversation reloads.
    let withSubagent = watcherAfterScanning([
        assistantLine(input: 2, creation: 200, read: 50_000),
        assistantLine(input: 2, creation: 0, read: 900_000, sidechain: true),
    ])
    check("a sidechain turn does not become the reading", withSubagent.lastContextTokens == 50_770)
    // Deliberately unlike `lastModel`: a resumed session replays its history, and that history IS
    // the conversation whose size is being asked about. Every line here predates the launch.
    let replayed = watcherAfterScanning([
        #"{"timestamp":"\#(stamp(-3600))","isSidechain":false,"type":"assistant","message":"#
            + #"{"model":"claude-fable-5","usage":{"input_tokens":2,"#
            + #""cache_creation_input_tokens":98,"cache_read_input_tokens":300000}}}"#,
    ])
    check("replayed history still answers how big the conversation is",
          replayed.lastContextTokens == 300_100)
    check("while it still does not move lastModel", replayed.lastModel == nil)
    check("a transcript with no assistant turn yet has no reading",
          watcherAfterScanning([#"{"type":"user","message":{"content":"hi"}}"#])
              .lastContextTokens == nil)

    // MARK: - 28c. The state file

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-session-\(UUID().uuidString)")
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let livePid = String(getpid())
    let siblingPid = String(getppid())
    // A pid nothing on this machine is using, so a stale file can be tested for real.
    let deadPid = String((30_000 ... 99_999).first { !supervisorAlive(pid_t($0)) } ?? 99_999)

    check("nothing published reads as nothing", readSessionContext(pid: livePid, dir: dir) == nil)
    let reading = SupervisedSession(accountID: "claude:.claude", contextTokens: 477_070,
                                    updatedAt: at)
    writeSessionContext(reading, pid: livePid, dir: dir)
    check("a written reading round-trips whole",
          readSessionContext(pid: livePid, dir: dir) == reading)
    // Beside the presence entry, never instead of it: that entry's existence is what `tally reload`
    // counts, and a context reading must not be read as another live supervisor.
    markSupervisorLive(pid: livePid, dir: dir)
    check("the reading does not inflate the live-supervisor count",
          liveSupervisorPids(dir: dir) == [pid_t(livePid)!])
    check("and the presence entry is not the reading",
          readDriftState(pid: livePid, dir: dir) == nil)
    check("a malformed body reads as no number, not as a crash", {
        try? "not json".write(to: sessionContextFile(pid: "12345", dir: dir), atomically: true,
                              encoding: .utf8)
        return readSessionContext(pid: "12345", dir: dir) == nil
    }())
    try? FileManager.default.removeItem(at: sessionContextFile(pid: "12345", dir: dir))

    // MARK: - 28d. Reading it back per account

    writeSessionContext(SupervisedSession(accountID: "claude:.claude", contextTokens: 12_000,
                                          updatedAt: at), pid: siblingPid, dir: dir)
    check("two sessions on one account report the largest",
          supervisedContextTokens(dir: dir) == ["claude:.claude": 477_070])
    writeSessionContext(SupervisedSession(accountID: "claude:.claude2", contextTokens: 33_000,
                                          updatedAt: at), pid: deadPid, dir: dir)
    check("a dead supervisor's reading is ignored",
          supervisedContextTokens(dir: dir) == ["claude:.claude": 477_070])
    // And it is swept, so it cannot be repainted for whatever process inherits that pid.
    sweepDeadSupervisorState(dir: dir)
    check("the dead supervisor's file is swept",
          !FileManager.default.fileExists(atPath: sessionContextFile(pid: deadPid, dir: dir).path))
    check("the live ones survive the sweep",
          readSessionContext(pid: livePid, dir: dir) == reading)
    clearSessionContext(pid: livePid, dir: dir)
    clearSessionContext(pid: siblingPid, dir: dir)
    check("clearing removes the reading", supervisedContextTokens(dir: dir).isEmpty)
    check("and leaves the presence entry alone",
          FileManager.default.fileExists(atPath: dir.appendingPathComponent(livePid).path))

    // MARK: - 28e. Written only when it moves

    // The loop polls every 2s and a working session produces a turn every few of them; a write per
    // turn would replace the file all day for a number every surface rounds to thousands.
    var writer = SessionContextWriter()
    writer.sync(tokens: nil, accountID: "claude:.claude", pid: livePid, dir: dir, now: at)
    check("nothing read yet writes nothing", readSessionContext(pid: livePid, dir: dir) == nil)
    writer.sync(tokens: 100_000, accountID: "claude:.claude", pid: livePid, dir: dir, now: at)
    check("the first reading is written",
          readSessionContext(pid: livePid, dir: dir)?.contextTokens == 100_000)
    clearSessionContext(pid: livePid, dir: dir)
    writer.sync(tokens: 100_400, accountID: "claude:.claude", pid: livePid, dir: dir, now: at)
    check("a move under the delta is not rewritten",
          readSessionContext(pid: livePid, dir: dir) == nil)
    writer.sync(tokens: 101_000, accountID: "claude:.claude", pid: livePid, dir: dir, now: at)
    check("a move past the delta is written, and exact",
          readSessionContext(pid: livePid, dir: dir)?.contextTokens == 101_000)
    clearSessionContext(pid: livePid, dir: dir)
    // A handoff moves the same conversation to another account: the reading has not changed, but
    // who it belongs to has, so the file must say so immediately.
    writer.sync(tokens: 101_000, accountID: "claude:.claude2", pid: livePid, dir: dir, now: at)
    check("a handoff rewrites it even at the same size",
          readSessionContext(pid: livePid, dir: dir)?.accountID == "claude:.claude2")
    try? FileManager.default.removeItem(at: dir)
}
