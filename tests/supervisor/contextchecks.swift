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

    /// The token figure alone, which is what these assertions are about; the rest of the reading is
    /// asserted where it is published (statusjson).
    ///
    /// THROUGH THE ROSTER, because the fold is a fold of it rather than a scan of its own: a session
    /// whose supervisor is not in the presence registry is not a session at all, and reading the
    /// files directly would fold a reading nobody is running.
    func tokens() -> [String: Int] {
        supervisedSessionsByAccount(liveSupervisors(dir: dir)).mapValues(\.contextTokens)
    }
    // The presence entries the roster is built from. Every one of these supervisors registered
    // before it published anything, which is the order a real one does it in (Supervisor.swift).
    markSupervisorLive(pid: siblingPid, dir: dir)
    markSupervisorLive(pid: deadPid, dir: dir)
    writeSessionContext(SupervisedSession(accountID: "claude:.claude", contextTokens: 12_000,
                                          updatedAt: at), pid: siblingPid, dir: dir)
    check("two sessions on one account report the largest", tokens() == ["claude:.claude": 477_070])
    writeSessionContext(SupervisedSession(accountID: "claude:.claude2", contextTokens: 33_000,
                                          updatedAt: at), pid: deadPid, dir: dir)
    check("a dead supervisor's reading is ignored", tokens() == ["claude:.claude": 477_070])
    // And it is swept, so it cannot be repainted for whatever process inherits that pid.
    sweepDeadSupervisorState(dir: dir)
    check("the dead supervisor's file is swept",
          !FileManager.default.fileExists(atPath: sessionContextFile(pid: deadPid, dir: dir).path))
    check("the live ones survive the sweep",
          readSessionContext(pid: livePid, dir: dir) == reading)
    clearSessionContext(pid: livePid, dir: dir)
    clearSessionContext(pid: siblingPid, dir: dir)
    check("clearing removes the reading", tokens().isEmpty)
    check("and leaves the presence entry alone",
          FileManager.default.fileExists(atPath: dir.appendingPathComponent(livePid).path))

    // MARK: - 28e. Written only when it moves

    // The loop polls every 2s and a working session produces a turn every few of them; a write per
    // turn would replace the file all day for a number every surface rounds to thousands.
    var writer = SessionContextWriter()
    writer.sync(tokens: nil, accountID: "claude:.claude", pin: nil, pid: livePid, dir: dir, now: at)
    check("nothing read yet writes nothing", readSessionContext(pid: livePid, dir: dir) == nil)
    writer.sync(tokens: 100_000, accountID: "claude:.claude", pin: nil, pid: livePid, dir: dir, now: at)
    check("the first reading is written",
          readSessionContext(pid: livePid, dir: dir)?.contextTokens == 100_000)
    clearSessionContext(pid: livePid, dir: dir)
    writer.sync(tokens: 100_400, accountID: "claude:.claude", pin: nil, pid: livePid, dir: dir, now: at)
    check("a move under the delta is not rewritten",
          readSessionContext(pid: livePid, dir: dir) == nil)
    writer.sync(tokens: 101_000, accountID: "claude:.claude", pin: nil, pid: livePid, dir: dir, now: at)
    check("a move past the delta is written, and exact",
          readSessionContext(pid: livePid, dir: dir)?.contextTokens == 101_000)
    clearSessionContext(pid: livePid, dir: dir)
    // A handoff moves the same conversation to another account: the reading has not changed, but
    // who it belongs to has, so the file must say so immediately.
    writer.sync(tokens: 101_000, accountID: "claude:.claude2", pin: nil, pid: livePid, dir: dir, now: at)
    check("a handoff rewrites it even at the same size",
          readSessionContext(pid: livePid, dir: dir)?.accountID == "claude:.claude2")

    // MARK: - 28f. What a session is RUNNING, beside what it was PINNED to

    // Two pairs, not one. The pin is what the user asked for; the running pair is what is on screen,
    // and they come apart whenever anything else moves the session (a quota fallback, a safeguard
    // restore, a flag typed at launch). A reader with only the pin can compute what SHOULD be
    // running and has no way at all to learn what is.
    let moved = SessionAxes(pinnedModel: "opus", pinnedEffort: nil,
                            observedModel: "claude-sonnet-4-5-20260101",
                            runningModel: "sonnet", runningEffort: "low")
    writer.sync(tokens: 200_000, accountID: "claude:.claude2", pin: nil, axes: moved,
                pid: livePid, dir: dir, now: at)
    let readBack = readSessionContext(pid: livePid, dir: dir)
    check("all three readings round-trip through the published file",
          readBack?.sessionModel == "opus" && readBack?.sessionEffort == nil
              && readBack?.runningModel == "sonnet" && readBack?.runningEffort == "low"
              && readBack?.observedModel == "claude-sonnet-4-5-20260101")
    // The observation is a reason to write on its own, and the sharpest one: a server-side fallback
    // changes what is answering without touching the token count, the account, or a single argv
    // word - which is exactly the state a reader is asking about when it does.
    writer.sync(tokens: 200_000, accountID: "claude:.claude2", pin: nil,
                axes: SessionAxes(pinnedModel: "opus", observedModel: "claude-haiku-4-5",
                                  runningModel: "sonnet", runningEffort: "low"),
                pid: livePid, dir: dir, now: at)
    check("a changed observation is published even when nothing else moved",
          readSessionContext(pid: livePid, dir: dir)?.observedModel == "claude-haiku-4-5")
    // The running pair is a reason to write on its own: a quota fallback changes what is running
    // without changing the token count or anything the user asked for, and a reading that waited for
    // the next thousand tokens would name a model the session had already left.
    let onHaiku = SessionAxes(pinnedModel: "opus", runningModel: "haiku")
    writer.sync(tokens: 200_100, accountID: "claude:.claude2", pin: nil, axes: onHaiku,
                pid: livePid, dir: dir, now: at)
    check("a changed running pair is published even when the number has barely moved",
          readSessionContext(pid: livePid, dir: dir)?.runningModel == "haiku")
    // The SAME pair, so "unchanged" is a fact of the fixture rather than an eyeball diff.
    writer.sync(tokens: 200_200, accountID: "claude:.claude2", pin: nil, axes: onHaiku,
                pid: livePid, dir: dir, now: at)
    check("…and an unchanged one, under the delta, is not rewritten",
          readSessionContext(pid: livePid, dir: dir)?.contextTokens == 200_100)
    // THE PROCESS WITNESS LIVES IN ITS OWN FILE, and that is the point of it: a reading needs a
    // turn with usage in it before it exists at all, while which Claude Code this session is
    // running is known at the spawn. Riding it on the reading made it arrive late, and the
    // commonest way to reach the pickers is a bare `/tally-model` typed before the first turn
    // (codex review of 49dcdcd).
    let fresh = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-child-witness-\(UUID().uuidString)")
    // A REAL PARENT AND CHILD, because the reading checks both that the process is alive and that it
    // is that supervisor's OWN child: this process and the one that started it are exactly such a
    // pair, and they are both running for as long as this suite is.
    let liveChild = getpid()
    let itsSupervisor = String(getppid())
    writeSupervisorChild(liveChild, pid: itsSupervisor, dir: fresh)
    check("the Claude Code a supervisor spawned is readable with no reading published at all",
          readSupervisorChild(pid: itsSupervisor, dir: fresh) == Int(liveChild)
              && readSessionContext(pid: itsSupervisor, dir: fresh) == nil)
    // A relaunch spawns a new child, and the witness has to follow it or every later prompt is
    // matched against a process that has exited. Asserted on the FILE, because the second value has
    // no relationship to this supervisor and the reading is right to refuse it - which is the next
    // check.
    writeSupervisorChild(4242, pid: itsSupervisor, dir: fresh)
    check("…and a relaunch replaces what is published",
          (try? String(contentsOf: supervisorChildFile(pid: itsSupervisor, dir: fresh),
                       encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "4242")
    check("a supervisor that never published one answers nothing, not zero",
          readSupervisorChild(pid: "9999", dir: fresh) == nil)

    // A LIVE PID THAT IS SOMEBODY ELSE'S CHILD IS NOT AN ANSWER. Pids are reused, and liveness alone
    // would let a stale value name whatever now holds that number - which reads as a confident
    // "provably not it" and takes the real candidate down with it. Nothing sweeps this residue
    // either: the sweep is keyed on the SUPERVISOR's pid, and this supervisor is alive.
    writeSupervisorChild(liveChild, pid: "5153", dir: fresh)
    check("a live process that is not that supervisor's child reads as no witness",
          supervisorAlive(liveChild) && readSupervisorChild(pid: "5153", dir: fresh) == nil)
    check("…so it too is carried on as silent rather than ruling the candidate out",
          sessionsRunning(liveChild, among: ["5153"],
                          published: { readSupervisorChild(pid: $0, dir: fresh) })
              == WitnessReading(identified: false, candidates: ["5153"]))
    check("the parent lookup answers for a real pair and refuses a pid nothing is running",
          parentProcessID(getpid()) == getppid() && parentProcessID(999_999) == nil)

    // A PID NOTHING IS RUNNING IS NO ANSWER. A relaunch terminates the old child before spawning
    // the new one, so a value left behind by a publish that failed names a process that has
    // exited - and reading it as a fact makes the one real candidate look "provably not it",
    // which removes it AND skips the fallbacks behind it (codex review of bc606c4).
    let reaped = Process()
    reaped.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! reaped.run()
    reaped.waitUntilExit()
    writeSupervisorChild(reaped.processIdentifier, pid: "5151", dir: fresh)
    check("a witness naming a process that has exited reads as no witness at all",
          readSupervisorChild(pid: "5151", dir: fresh) == nil)
    // …which is what lets the fallbacks behind it run: the candidate is SILENT rather than denied.
    check("…so that candidate is carried on rather than ruled out",
          sessionsRunning(9_999_999, among: ["5151"],
                          published: { readSupervisorChild(pid: $0, dir: fresh) })
              == WitnessReading(identified: false, candidates: ["5151"]))

    // A RELAUNCH WHOSE PUBLISH CANNOT LAND, which is the case the whole guard is for. The directory
    // is made unwritable, so neither half of the publish can happen and the previous child's pid
    // stays on disk - and the session still has to keep working.
    let jammed = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-child-jammed-\(UUID().uuidString)")
    writeSupervisorChild(reaped.processIdentifier, pid: "5152", dir: jammed)
    try! FileManager.default.setAttributes([.posixPermissions: 0o500],
                                           ofItemAtPath: jammed.path)
    writeSupervisorChild(liveChild, pid: "5152", dir: jammed)
    check("a publish that cannot land leaves the old value on disk",
          (try? String(contentsOf: supervisorChildFile(pid: "5152", dir: jammed), encoding: .utf8))?
              .trimmingCharacters(in: .whitespacesAndNewlines)
              == String(reaped.processIdentifier))
    check("…which the reading refuses, because that child is gone",
          readSupervisorChild(pid: "5152", dir: jammed) == nil)
    check("…so the session is SILENT to this witness rather than denied by it",
          sessionsRunning(liveChild, among: ["5152"],
                          published: { readSupervisorChild(pid: $0, dir: jammed) })
              == WitnessReading(identified: false, candidates: ["5152"]))
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jammed.path)
    try? FileManager.default.removeItem(at: jammed)

    // AND THE ORDER OF THE TWO HALVES, pinned by shape because it cannot be observed from here.
    // `write(atomically:)` renames a temporary over the destination, so ANY failure of the write
    // leaves the old file exactly where it was; removing first turns that into an absent file. The
    // failures that reach it (a full disk, a quota, an I/O error) are not ones this suite can
    // produce, and the reading's liveness check above covers the same ground for every stale value
    // whose child has exited - so this is the belt rather than the braces, and it is locked here
    // rather than claimed in a comment.
    let requestSource = (try? String(contentsOfFile: "TallyCLI/SwitchRequest.swift",
                                     encoding: .utf8)) ?? ""
    // The whole function, comment block included, so the window cannot fall short of the two lines
    // being compared.
    let publishBody = requestSource.range(of: "func writeSupervisorChild").map {
        String(requestSource[$0.lowerBound...].prefix(1_400))
    } ?? ""
    check("the publish removes the previous value before it writes the new one",
          publishBody.range(of: "removeItem").map { removal in
              publishBody.range(of: "atomically", range: removal.upperBound ..< publishBody.endIndex)
                  != nil
          } == true)
    // THE ACCOUNT SIDECAR IS HELD TO THE SAME RULE, and it needs it more than this one does: the
    // child pid has a liveness check that refuses any stale value, and the account has no such
    // second witness - a session with no reading yet would be reported on the account it has left
    // for as long as it runs (codex review of 005b5f2). Same shape, same window, pinned the same way
    // because the failures that reach it are ones this suite cannot produce.
    let accountBody = requestSource.range(of: "func writeSupervisorAccount").map {
        String(requestSource[$0.lowerBound...].prefix(400))
    } ?? ""
    check("…and so does the account published beside it",
          accountBody.range(of: "removeItem").map { removal in
              accountBody.range(of: "atomically", range: removal.upperBound ..< accountBody.endIndex)
                  != nil
          } == true)
    // The half that IS observable: on the ordinary path the new value replaces the old whole, and a
    // handoff to another account leaves nothing of the first behind.
    writeSupervisorAccount("claude:.claudeA", pid: "5154", dir: fresh)
    writeSupervisorAccount("claude:.claudeB", pid: "5154", dir: fresh)
    check("a republished account replaces the old one rather than joining it",
          readSupervisorAccount(pid: "5154", dir: fresh) == "claude:.claudeB")
    // AND THE RESIDUAL LIMIT, stated rather than left to be discovered: a directory that has become
    // unwritable defeats both halves, exactly as it does for the child pid above. What removing
    // first buys is the failure that reaches the WRITE alone (a full disk, a quota, an I/O error).
    let jammedAccount = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-account-jammed-\(UUID().uuidString)")
    writeSupervisorAccount("claude:.claudeA", pid: "5155", dir: jammedAccount)
    try! FileManager.default.setAttributes([.posixPermissions: 0o500],
                                           ofItemAtPath: jammedAccount.path)
    writeSupervisorAccount("claude:.claudeB", pid: "5155", dir: jammedAccount)
    check("a publish that cannot even remove leaves the old account, which no reader can refuse",
          readSupervisorAccount(pid: "5155", dir: jammedAccount) == "claude:.claudeA")
    try! FileManager.default.setAttributes([.posixPermissions: 0o700],
                                           ofItemAtPath: jammedAccount.path)
    try? FileManager.default.removeItem(at: jammedAccount)
    // On the swept track like every other document beside a supervisor, or a dead session's copy
    // outlives it and answers for a pid the OS has since handed to somebody else.
    check("the witness is swept with the rest of a dead supervisor's state",
          supervisorStatePid(ofFile: "5150" + supervisorChildSuffix) == 5150)
    try? FileManager.default.removeItem(at: fresh)

    // THE CONVERSATION WITNESS, which is a reason to write on its own: a `/clear` starts a new
    // conversation in the same session, and a published id that stayed behind would name a
    // transcript this supervisor is no longer watching - which is the very witness another
    // session's prompt gets matched against (SwitchRequest.swift).
    writer.sync(tokens: 200_200, accountID: "claude:.claude2", pin: nil, axes: onHaiku,
                transcript: "conv-FIRST", pid: livePid, dir: dir, now: at)
    check("the conversation being watched is published",
          readSessionContext(pid: livePid, dir: dir)?.transcriptSessionID == "conv-FIRST")
    writer.sync(tokens: 200_300, accountID: "claude:.claude2", pin: nil, axes: onHaiku,
                transcript: "conv-SECOND", pid: livePid, dir: dir, now: at)
    check("…and a /clear that rebinds the transcript is published though nothing else moved",
          readSessionContext(pid: livePid, dir: dir)?.transcriptSessionID == "conv-SECOND")
    writer.sync(tokens: 200_400, accountID: "claude:.claude2", pin: nil, axes: onHaiku,
                transcript: "conv-SECOND", pid: livePid, dir: dir, now: at)
    check("…while the same conversation under the delta is not rewritten",
          readSessionContext(pid: livePid, dir: dir)?.contextTokens == 200_300)
    // THE SUPERVISOR ACTUALLY PASSES IT, which no assertion above can see: the reading is derived
    // from the watcher's current file, and a tick that published nil would leave every session
    // witnessless while every unit here still passed.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the poll tick publishes the transcript it is tailing",
          loop.contains("transcript: watcher.transcriptSessionID, pid: supervisorPID"))
    check("…and so does the republish a handoff makes",
          loop.contains("transcript: watcher.transcriptSessionID,\n"
              + "                                              pid: supervisorPID"))
    // AND THE ACCOUNT SIDECAR MOVES IN THE SAME BREATH AS THAT REPUBLISH. Written only at the spawn,
    // it named the account the session had just left for the whole of a child tear-down, and the two
    // documents about one account described different moments (codex review of 005b5f2). Both
    // moments write it now: this one, and the spawn that follows.
    check("a handoff republishes the account beside the reading, not a tear-down later",
          loop.range(of: "sessionContext.accountChanged").map { moved in
              loop.range(of: "writeSupervisorAccount(account.id, pid: supervisorPID)",
                         range: moved.upperBound ..< loop.endIndex) != nil
          } == true)
    check("…and the spawn writes it again for the child that actually starts",
          loop.range(of: "spawnChild").map { spawned in
              loop.range(of: "writeSupervisorAccount", range: spawned.upperBound ..< loop.endIndex)
                  != nil } == true)
    // AND THE CHILD IS PUBLISHED AT THE SPAWN, not with a reading. A unit test can assert the
    // writer stores what it is handed while the loop publishes it too late to be any use, which is
    // exactly the defect this round fixes.
    check("the loop publishes the child the moment it has one",
          loop.contains("writeSupervisorChild(childPID, pid: supervisorPID)"))
    check("…from inside the block that spawns each child, so a relaunch replaces it",
          loop.range(of: "spawnChild")
              .map { loop.range(of: "writeSupervisorChild", range: $0.upperBound ..< loop.endIndex)
                  != nil } == true)

    // Additive: a document written before these fields existed still decodes, with nil for both -
    // which every reader has to treat as "cannot say" rather than as "running nothing".
    try! #"{"accountID":"claude:.claude","contextTokens":1234,"updatedAt":"2026-08-06T00:00:00Z"}"#
        .write(to: sessionContextFile(pid: "4242", dir: dir), atomically: true, encoding: .utf8)
    let legacy = readSessionContext(pid: "4242", dir: dir)
    check("a document from a build before these fields still decodes", legacy?.contextTokens == 1234)
    check("…with no running pair and no observation, rather than made-up ones",
          legacy?.runningModel == nil && legacy?.runningEffort == nil
              && legacy?.observedModel == nil)
    check("…and no conversation id, which the resolution reads as \"cannot say\"",
          legacy?.transcriptSessionID == nil)

    try? FileManager.default.removeItem(at: dir)
}
