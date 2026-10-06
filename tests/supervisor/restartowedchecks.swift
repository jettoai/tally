import Foundation

// B-5730: whether a handoff owes the next child a line (`restartOwed`, RestartWake.swift) and what
// the child's own transcript says it still had running (RestartLiveWork.swift). The literals are
// Claude Code 2.1.28x tool results and notices as they appear in real transcripts; prose replaced.

private let owedIso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private func owedAt(_ s: String) -> Date { owedIso.date(from: s)! }

private let owedConversation = "a00788bd-c439-42a6-912c-19955ed5c1ab"
private let owedLaunch = owedAt("2026-10-02T01:30:00.000Z")
private var owedSerial = 0

private func owedToolResult(_ content: String, at ts: String) -> String {
    owedSerial += 1
    return #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"\#(content)"}]},"uuid":"00000000-0000-4000-8000-\#(String(format: "%012d", owedSerial))","timestamp":"\#(ts)","sessionId":"\#(owedConversation)"}"#
}

/// A notice as 2.1.287 writes it: origin with a producer, content opening with the tag.
private func owedNotice(_ body: String, at ts: String) -> String {
    owedSerial += 1
    return #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"<task-notification>\n\#(body)\n</task-notification>"},"uuid":"00000000-0000-4000-8000-\#(String(format: "%012d", owedSerial))","timestamp":"\#(ts)","permissionMode":"bypassPermissions","origin":{"kind":"task-notification","producer":"session-task"},"promptSource":"system","sessionId":"\#(owedConversation)"}"#
}

private func owedReplay(_ lines: [String], since: Date = owedLaunch) -> TranscriptWatcher {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-restartowed-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! (lines.joined(separator: "\n") + "\n")
        .write(to: dir.appendingPathComponent("\(owedConversation).jsonl"), atomically: true,
               encoding: .utf8)
    var w = TranscriptWatcher(projectDir: dir, since: since, resumeID: owedConversation)
    for _ in 0..<20 where !w.caughtUp { _ = w.sawCapHit() }
    try? FileManager.default.removeItem(at: dir)
    return w
}

private func owedFor(_ w: TranscriptWatcher, roster: SessionAgentsRecord?) -> RestartOwedReading {
    restartOwed(roster: roster, ranTurn: w.lastMainChainEventAt != nil, caughtUp: w.caughtUp,
                live: w.liveWork, now: owedLaunch.addingTimeInterval(600))
}

func runRestartOwedChecks() {
    let zero = SessionAgentsRecord(live: [], trusted: true, updatedAt: owedLaunch, background: 0)
    let busy = SessionAgentsRecord(live: [], trusted: true, updatedAt: owedLaunch, background: 2)
    let reply = #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"},"type":"assistant","uuid":"b0a1c2d3-0000-4000-8000-00000000b001","timestamp":"2026-10-02T01:31:00.000Z","sessionId":"a00788bd-c439-42a6-912c-19955ed5c1ab"}"#
    let idleLine = "[tally] Tally restarted Claude Code (self-update). Re-arm any monitors you had running and pick up pending work; if nothing was running, no action is needed."
    func offer(_ note: RestartNote?, _ w: TranscriptWatcher) -> CapResumeState.Offer? {
        restartWakeOffer(state: RestartWakeState(), spawnedByTally: true, resumesConversation: true,
                         note: note, launchedAt: owedLaunch, notice: nil, answeredAt: nil,
                         userTurnAt: nil, conversation: owedConversation, caughtUp: true,
                         capOwnsChild: false, now: owedLaunch.addingTimeInterval(16))
    }

    // R13: the failure sample (2026-10-07). An idle session that ran a turn and started nothing.
    let idle = owedReplay([reply])
    let r13 = owedFor(idle, roster: zero)
    check("R13 an idle child that ran a turn and started nothing is not owed",
          idle.caughtUp && idle.lastMainChainEventAt != nil && r13 == RestartOwedReading(owed: false, why: "none"))
    check("R13 …so its handoff note types nothing after the settle",
          offer(restartNoteForHandoff(reason: "self-update", fresh: false, roster: zero,
                                      owed: r13.owed), idle) == nil)
    check("R13b a child that never ran a turn is not owed, even with no roster",
          restartOwed(roster: nil, ranTurn: false, caughtUp: true, live: RestartLiveWork(),
                      now: owedLaunch) == RestartOwedReading(owed: false, why: "no-turn"))

    // R14: 2026-10-02 01:35, replayed. Monitor b7r9ppr2r armed before a /clear delivered an event
    // after this child started; the roster said zero. fedcfad's case stays owed.
    let event = owedNotice(#"<task-id>b7r9ppr2r</task-id>\n<summary>Monitor event: \"fleet-watch\"</summary>\n<event>BOARD_ACTION create #new /tmp/inbox.md</event>\nIf this event is something the user would act on now, send a PushNotification. Routine or benign output doesn't need one."#,
                           at: "2026-10-02T01:33:44.253Z")
    let monitored = owedReplay([event, reply])
    let r14 = owedFor(monitored, roster: zero)
    check("R14 a post-launch Monitor event with no terminal status is live work, roster zero or not",
          monitored.liveWork.tasks == ["b7r9ppr2r"]
              && r14 == RestartOwedReading(owed: true, why: "live-task"))
    check("R14 …and the restart wake still types the idle line",
          offer(restartNoteForHandoff(reason: "self-update", fresh: false, roster: zero,
                                      owed: r14.owed), monitored)?.line == idleLine)

    // R15: cannot say, so send.
    check("R15 a child that ran a turn with no readable roster is owed",
          owedFor(idle, roster: nil) == RestartOwedReading(owed: true, why: "unknown-roster"))
    check("R15b a transcript not read to the end is owed",
          restartOwed(roster: zero, ranTurn: true, caughtUp: false, live: RestartLiveWork(),
                      now: owedLaunch) == RestartOwedReading(owed: true, why: "catching-up"))
    check("R15c a roster that counts background work is owed",
          owedFor(idle, roster: busy) == RestartOwedReading(owed: true, why: "roster"))

    // R16: each kind of task, started and ended.
    let bash = owedToolResult("Command running in background with ID: bagfdch3z. Output is being written to: /tmp/tasks/bagfdch3z.output",
                              at: "2026-10-02T01:30:10.000Z")
    let bashDone = owedNotice(#"<task-id>bagfdch3z</task-id>\n<tool-use-id>toolu_01</tool-use-id>\n<status>completed</status>\n<summary>Background command \"build\" completed (exit code 0)</summary>"#,
                              at: "2026-10-02T01:31:10.000Z")
    check("R16 a background shell is live until its completed notice",
          owedReplay([bash]).liveWork.tasks == ["bagfdch3z"]
              && owedReplay([bash, bashDone]).liveWork.tasks.isEmpty)
    let monitor = owedToolResult("Monitor started (task by07sjuxy, expires in 30m unless the source ends first). You will be notified on each event.",
                                 at: "2026-10-02T01:30:10.000Z")
    let expired = owedNotice(#"<task-id>by07sjuxy</task-id>\n<summary>Monitor event: \"tick\"</summary>\n<event>[Monitor expired after 30m with 3 events delivered. Re-arm it if you still need the watch.]</event>"#,
                             at: "2026-10-02T02:00:10.000Z")
    let stopped = owedToolResult(#"{\"message\":\"Successfully stopped task: by07sjuxy (while true; do sleep 50; done)\",\"task_id\":\"by07sjuxy\"}"#,
                                 at: "2026-10-02T01:40:00.000Z")
    check("R16b a Monitor is live until it expires or a TaskStop stops it",
          owedReplay([monitor]).liveWork.tasks == ["by07sjuxy"]
              && owedReplay([monitor, expired]).liveWork.tasks.isEmpty
              && owedReplay([monitor, stopped]).liveWork.tasks.isEmpty)
    let asyncAgent = owedToolResult(#"Async agent launched successfully. (internal metadata)\nagentId: a167d6a843df856d0 (internal ID)"#,
                                    at: "2026-10-02T01:30:10.000Z")
    let syncAgent = owedToolResult(#"Done.\nagentId: a1111111111111111 (for resuming)"#,
                                   at: "2026-10-02T01:30:10.000Z")
    check("R16c a background subagent is live; a finished foreground one is not",
          owedReplay([asyncAgent]).liveWork.tasks == ["a167d6a843df856d0"]
              && owedReplay([syncAgent]).liveWork.tasks.isEmpty)
    let beforeLaunch = owedToolResult("Monitor started (task bold0000x, expires in 30m).",
                                      at: "2026-10-02T01:29:00.000Z")
    check("R16d a start written before this child launched died with the old process",
          owedReplay([beforeLaunch]).liveWork.tasks.isEmpty)
    let quoted = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"why did <task-notification><task-id>bquote001</task-id><summary>Monitor event: x</summary> fire?"},"uuid":"00000000-0000-4000-8000-0000000000ff","timestamp":"2026-10-02T01:30:30.000Z","promptSource":"typed","sessionId":"a00788bd-c439-42a6-912c-19955ed5c1ab"}"#
    check("R16e a prompt that merely quotes a notice changes nothing",
          owedReplay([quoted]).liveWork.tasks.isEmpty)

    // R17: session-only crons, one-shot in local time.
    var taipei = Calendar(identifier: .gregorian)
    taipei.timeZone = TimeZone(identifier: "Asia/Taipei")!
    let created = owedAt("2026-10-04T15:14:53.170Z")
    var cron = RestartLiveWork()
    cron.fold("Scheduled one-shot task 8e584121 (2 9 5 10 *). Session-only (not written to disk, dies when Claude exits). It will fire once then auto-delete.",
              at: created, notice: false, toolResult: true, calendar: taipei)
    check("R17 a one-shot cron is live until its fire minute has passed",
          cron.liveCron(now: owedAt("2026-10-05T01:02:30.000Z"))
              && !cron.liveCron(now: owedAt("2026-10-05T01:03:01.000Z")))
    var deleted = cron
    deleted.fold(#"{"type":"assistant","message":{"id":"msg_01","content":[{"type":"tool_use","id":"toolu_02","name":"CronDelete","input":{"id":"8e584121"}}]}}"#,
                 at: created, notice: false, toolResult: false, calendar: taipei)
    check("R17 …and dead once CronDelete names it (not the message or call id ahead of it)",
          deleted.crons.isEmpty)
    var durable = RestartLiveWork()
    durable.fold("Scheduled recurring task 00f080fe (*/5 * * * *). Persisted to .claude/scheduled_tasks.json",
                 at: created, notice: false, toolResult: true, calendar: taipei)
    var odd = RestartLiveWork()
    odd.fold("Scheduled one-shot task 77aa77aa (0 9 L * *). Session-only (not written to disk, dies when Claude exits).",
             at: created, notice: false, toolResult: true, calendar: taipei)
    check("R17 a cron written to disk is not live work; a schedule this cannot read stays live",
          !durable.liveCron(now: created) && odd.liveCron(now: created.addingTimeInterval(86400 * 400)))
    check("R17 a live cron makes the handoff owed",
          restartOwed(roster: zero, ranTurn: true, caughtUp: true, live: cron,
                      now: owedAt("2026-10-05T00:00:00.000Z"))
              == RestartOwedReading(owed: true, why: "live-cron"))

    // R18: the stopped notice path never asks `owed`.
    check("R18 a stopped notice still wakes a session whose note is not owed",
          restartWakeOffer(state: RestartWakeState(), spawnedByTally: true, resumesConversation: true,
                           note: RestartNote(reason: "self-update", background: 0, owed: false),
                           launchedAt: owedLaunch,
                           notice: StoppedTaskNotice(at: owedLaunch.addingTimeInterval(2), uuid: "u",
                                                     ids: ["bzsyqpoyk"]),
                           answeredAt: nil, userTurnAt: nil, conversation: owedConversation,
                           caughtUp: true, capOwnsChild: false,
                           now: owedLaunch.addingTimeInterval(40)) != nil)

    // R19: the note across a self-update exec.
    func trip(_ note: RestartNote?) -> ResuperviseArgs {
        parseResuperviseArgs(Array(selfUpdateArgv(
            binary: "/usr/local/bin/tally", id: "acct-1", label: "Claude 5",
            home: "/Users/x/.claude5", follow: true, restartNote: note,
            args: ["--resume", "abc"]).dropFirst(2)))
    }
    let quietNote = RestartNote(reason: "self-update", background: 0, owed: false)
    let busyNote = RestartNote(reason: "self-update", background: 3, owed: true)
    check("R19 the restart note survives the argv round trip, child args intact",
          trip(quietNote).restartNote == quietNote && trip(busyNote).restartNote == busyNote
              && trip(quietNote).childArgs == ["--resume", "abc"])
    check("R19 no note, no flag; a malformed value reads as none",
          trip(nil).restartNote == nil
              && ["a,b", "x,-1,1", "x,1,2", ",0,1", "x,0"].allSatisfy {
                  parseResuperviseArgs([resuperviseRestartNoteFlag, $0]).restartNote == nil
              })
    check("R19 the carried note is the exec child's; none carried is the old owed note",
          firstLaunchRestartNote(launchArgs: [], exec: true, carried: quietNote) == quietNote
              && firstLaunchRestartNote(launchArgs: [], exec: true, carried: nil) == execRestartNote)
    check("R19b an exec from a build that carried nothing still types the idle line",
          execRestartNote.owed && offer(execRestartNote, idle)?.line == idleLine)
    check("R19 the handoff line names the reading",
          restartOwedLine(pid: "42", reason: "turn-boundary", reading: r13,
                          now: owedAt("2026-10-02T01:35:03.000Z"))
              == "2026-10-02T01:35:03Z pid=42 restart-owed=0 why=none reason=turn-boundary\n")

    // R20: the cap resume asks the same rule.
    func account(_ id: String) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/h/\(id)",
                         sessionRemaining: nil, weeklyRemaining: nil, modelRemaining: nil,
                         sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                         modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                         error: nil)
    }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-restartowed-cap-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let wall = owedLaunch
    func capArm(owed: Bool, gate: Bool, log: URL) -> CapResumeState {
        var state = CapResumeState()
        armCapResume(&state, pid: "42", log: log, now: wall.addingTimeInterval(4), reason: "cap",
                     fresh: false, cappedAt: wall, answeredAt: nil,
                     conversation: "0123456789abcdef", from: account("A"), to: account("B"),
                     userTurnAt: nil, caughtUp: true, owed: owed, requiresLiveWork: gate)
        return state
    }
    let skipLog = dir.appendingPathComponent("skip.log")
    let skipped = capArm(owed: false, gate: true, log: skipLog)
    let skipText = (try? String(contentsOf: skipLog, encoding: .utf8)) ?? ""
    check("R20 gate on: a capped child with nothing running is not armed, and says why",
          !skipped.isArmed && skipText.contains("input=cap-resume-skipped reason=no-live-work")
              && !skipText.contains("cap-resume-armed"))
    let armLog = dir.appendingPathComponent("arm.log")
    let armed = capArm(owed: true, gate: true, log: armLog)
    let armText = (try? String(contentsOf: armLog, encoding: .utf8)) ?? ""
    check("R20 gate on: one with work running is armed as before",
          armed.isArmed && armText.contains("input=cap-resume-armed") && !armText.contains("skipped"))
    let offLog = dir.appendingPathComponent("off.log")
    let offArmed = capArm(owed: false, gate: false, log: offLog)
    let offText = (try? String(contentsOf: offLog, encoding: .utf8)) ?? ""
    check("R20 gate off: a capped child with nothing running is armed anyway, nothing skipped",
          offArmed.isArmed && offText.contains("input=cap-resume-armed") && !offText.contains("skipped"))
}
