import Foundation

// The session status board (SessionState.swift, SessionStateSync.swift, UserNotice.swift): what
// each supervised session is doing, decided by the one process that can decide it and published
// for the panel and `tally status --json` to read.
//
// Everything here is pure or pointed at a temp directory, like every other suite in this family:
// nothing touches `~/.tally/supervisor-state`, so a machine with live sessions on it can run this
// without one of them being disturbed.

func runSessionStateChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-sessionstate-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let t0 = Date(timeIntervalSince1970: 1_786_571_200)

    // MARK: the machine

    check("a moving transcript is working",
          supervisedSessionState(wait: nil, hasTranscript: true, quiet: false) == .working)
    check("a quiet one with nothing outstanding is idle",
          supervisedSessionState(wait: nil, hasTranscript: true, quiet: true) == .idle)
    // A child that has not bound a conversation has written nothing anywhere, so `isQuiet` answers
    // true about a file it never found. Reading that as idle would be a guess dressed as a reading.
    check("no transcript is unknown rather than idle",
          supervisedSessionState(wait: nil, hasTranscript: false, quiet: true) == .unknown)
    // A HARD WAIT LEADS, including over an unbound transcript: a session whose first act is a
    // permission request is exactly that case, and unknown would hide the one state the board
    // exists for. A dialog is open, and a subagent writing in the background is not an answer to it.
    check("a permission request is blocked whatever the transcript says",
          supervisedSessionState(wait: .hard, hasTranscript: true, quiet: false) == .blocked
              && supervisedSessionState(wait: .hard, hasTranscript: true, quiet: true) == .blocked
              && supervisedSessionState(wait: .hard, hasTranscript: false, quiet: true) == .blocked)
    // THE ASSERTION THIS REPLACES SAID `blocked: true, quiet: false` IS BLOCKED, WHATEVER ELSE WAS
    // TRUE - and that shape is the defect itself, not a contract: it is a fan-out, where the main
    // transcript stops the instant the subagents start, Claude Code's 60s timer fires an
    // `idle_prompt`, and nobody is being waited for at all. Measured 2026-08-15: two of six live
    // sessions on this machine stood red for minutes while their subagents wrote. Left as a passing
    // assertion, it would have gone on telling the next reader the behaviour was intended.
    check("a session that is merely free to speak, while work is still going on, is working",
          supervisedSessionState(wait: .soft, hasTranscript: true, quiet: false) == .working)
    check("…and is a call for somebody once the work stops",
          supervisedSessionState(wait: .soft, hasTranscript: true, quiet: true) == .blocked)
    // Not over `unknown`: with no transcript bound, quiet is true in a way that means nothing, so a
    // soft wait there is a sentence about a conversation nobody can see.
    check("…but says nothing about a session that has bound no conversation yet",
          supervisedSessionState(wait: .soft, hasTranscript: false, quiet: true) == .unknown)

    // MARK: which kind of wait an event is

    // The taxonomy that split above rests on. FAIL-OPEN TO HARD in both directions, on the same
    // rule the wait filter itself is under: an event with no type (a notice written before the
    // field existed, or a Claude Code that names none) and a type this build has never heard of
    // both keep the behaviour that stood before the distinction existed.
    check("a permission request is a hard wait", userWait(notificationType: "permission_prompt") == .hard)
    check("…as is one raised for a background worker",
          userWait(notificationType: "worker_permission_prompt") == .hard)
    check("…and an agent asking for something, and an elicitation",
          userWait(notificationType: "agent_needs_input") == .hard
              && userWait(notificationType: "elicitation_dialog") == .hard
              && userWait(notificationType: "elicitation_url_dialog") == .hard)
    check("the floor being free is the soft one, and the only one",
          userWait(notificationType: "idle_prompt") == .soft
              && softWaitNotificationTypes == ["idle_prompt"])
    check("a notice from before the type was recorded is read as hard",
          userWait(notificationType: nil) == .hard)
    check("…and so is a type this build has never heard of",
          userWait(notificationType: "some_future_type") == .hard)
    // Every waiting type is classified, so a type added to the vocabulary cannot arrive here as
    // neither one thing nor the other.
    check("every waiting type has a kind",
          waitingNotificationTypes.allSatisfy {
              userWait(notificationType: $0) == (softWaitNotificationTypes.contains($0)
                                                     ? .soft : .hard)
          })

    // MARK: the type the hook writes down

    // The hook has always READ the type to decide whether the event is a wait at all; writing it
    // down is what makes the two kinds separable a tick later. A notice from before this field
    // decodes with none, which the rule above reads as hard.
    writeUserNotice(UserNotice(message: "Claude is waiting for your input", at: t0,
                               type: "idle_prompt"), pid: "9107", dir: dir)
    check("a notice carries the kind of event it was",
          readUserNotice(pid: "9107", dir: dir)?.type == "idle_prompt")
    try? Data(#"{"message":"older build","at":"2026-08-13T09:00:00Z"}"#.utf8)
        .write(to: dir.appendingPathComponent("9108" + userNoticeSuffix))
    check("…and one written before the field existed reads with none, which fails open to hard",
          readUserNotice(pid: "9108", dir: dir)?.type == nil
              && userWait(notificationType: readUserNotice(pid: "9108", dir: dir)?.type) == .hard)
    // AND THE HOOK ACTUALLY RECORDS IT, which no value here can reach: `runHookNotify` reads its
    // event off stdin inside somebody's session, with the supervisor marker in the environment, so
    // the wiring is read off the source like the other two boundaries in this file. Everything
    // above is worth nothing if the one writer of these notices drops the field on the floor - and
    // a build that did would look exactly like a fleet of older supervisors.
    let hookSource = (try? String(contentsOfFile: "TallyCLI/HookNotify.swift", encoding: .utf8)) ?? ""
    check("the hook source is readable from the session-state checks", !hookSource.isEmpty)
    check("the type the hook filtered on is the type it writes down",
          hookSource.contains("let type = notificationTypeInEvent(event)")
              && hookSource.contains("guard notificationWaitsForUser(type) else")
              && hookSource.contains("type: type, sessionID: sessionID)"))

    // MARK: a soft event does not overwrite a hard one nobody has answered

    // THE SLOT IS ONE FILE PER SUPERVISOR AND THE HOOK IS ITS ONLY WRITER, so whatever arrives
    // second is what the next tick judges. During a fan-out both arrive: a worker's permission
    // request (hard), and then the main conversation's 60s `idle_prompt` (soft). Overwritten, the
    // request reads as soft, a soft wait yields to a session that is not quiet, and the fan-out
    // still writing keeps the card green for as much as a whole busy window with an authorisation
    // dialog open behind it (codex review of 29ea45e, 2026-08-15).
    let worker = UserNotice(message: "A worker needs your permission to use Bash", at: t0,
                            type: "worker_permission_prompt")
    let floorIsFree = UserNotice(message: "Claude is waiting for your input",
                                 at: t0.addingTimeInterval(60), type: "idle_prompt")
    check("an empty slot takes whatever arrives",
          recordUserNotice(floorIsFree, pid: "9121", dir: dir)
              && readUserNotice(pid: "9121", dir: dir)?.type == "idle_prompt")
    check("a permission request replaces the idle prompt that was standing",
          recordUserNotice(worker, pid: "9121", dir: dir)
              && readUserNotice(pid: "9121", dir: dir) == worker)
    check("…and the idle prompt that follows it leaves it exactly where it is",
          !recordUserNotice(floorIsFree, pid: "9121", dir: dir)
              && readUserNotice(pid: "9121", dir: dir) == worker)
    // Hard over hard replaces, which is the single slot's own limit rather than a rule anybody
    // wanted: the newest request is the one whose sentence names what is being asked for now.
    let agent = UserNotice(message: "An agent needs your input", at: t0.addingTimeInterval(90),
                           type: "agent_needs_input")
    check("one hard event still replaces another, which is what the single slot costs",
          recordUserNotice(agent, pid: "9121", dir: dir)
              && readUserNotice(pid: "9121", dir: dir) == agent)
    // A notice from a supervisor too old to record a type reads as hard, so it is kept on the same
    // rule: the compatibility direction stays the conservative one here as everywhere on this
    // track. Against the untyped file written above rather than a second copy of it, and a fixture
    // that went missing would fail this rather than pass it (nothing standing means the idle prompt
    // is recorded, which is the `true` this asserts against).
    check("a standing event naming no type outranks an idle prompt too",
          !recordUserNotice(floorIsFree, pid: "9108", dir: dir)
              && readUserNotice(pid: "9108", dir: dir)?.message == "older build")
    // Soft over soft replaces, which is how a standing idle prompt keeps its clock: Claude Code
    // re-raises it for as long as the floor stays free, and preserving the first would report the
    // age of an event that has been superseded a dozen times.
    check("an idle prompt replaces an idle prompt",
          recordUserNotice(floorIsFree, pid: "9123", dir: dir)
              && recordUserNotice(UserNotice(message: "still free", at: t0.addingTimeInterval(120),
                                             type: "idle_prompt"), pid: "9123", dir: dir)
              && readUserNotice(pid: "9123", dir: dir)?.message == "still free")
    // AND THE HOOK GOES THROUGH IT, which no value assertion above can see: the rule is worth
    // nothing if the one writer of these notices still replaces the slot unconditionally, and a
    // build that did would look exactly like this suite passing. The same shape as the tick's own
    // clearing guard further down, and for the same reason.
    check("the hook records through the guard rather than writing the slot directly",
          hookSource.contains("recordUserNotice(UserNotice(")
              && !hookSource.contains("writeUserNotice("))

    // MARK: when a wait is over

    let notice = UserNotice(message: "Claude needs your permission to run Bash", at: t0)
    check("no event, nothing waiting",
          !userNoticeStillOpen(nil, transcriptModified: t0.addingTimeInterval(-5),
                               keyboardBurstAt: nil))
    check("an event nobody has answered is still open",
          userNoticeStillOpen(notice, transcriptModified: t0.addingTimeInterval(-30),
                              keyboardBurstAt: nil))
    check("the conversation moving after the event answers it",
          !userNoticeStillOpen(notice, transcriptModified: t0.addingTimeInterval(1),
                               keyboardBurstAt: nil))
    // The clock matters, not the fact: a write from BEFORE the hook fired cannot be the answer to it.
    check("a transcript older than the event answers nothing",
          userNoticeStillOpen(notice, transcriptModified: t0.addingTimeInterval(-1),
                              keyboardBurstAt: nil))
    check("somebody typing in that terminal after the event answers it",
          !userNoticeStillOpen(notice, transcriptModified: nil,
                               keyboardBurstAt: t0.addingTimeInterval(2)))
    check("typing from before the event does not",
          userNoticeStillOpen(notice, transcriptModified: nil,
                              keyboardBurstAt: t0.addingTimeInterval(-2)))
    // THE CHATTER CASE, which is why the rule asks for a burst rather than a stamp: an idle terminal
    // with nobody at it is stamped by control traffic every 23-60s (KeyboardIdle.swift's measurement).
    // `keyboardBurstAt` is nil throughout such a stretch, so the wait survives it.
    check("a terminal stamped by chatter alone leaves the wait standing",
          userNoticeStillOpen(notice, transcriptModified: t0.addingTimeInterval(-90),
                              keyboardBurstAt: nil))

    // MARK: which of the nine notifications is a wait

    // FOUR OF THE NINE ARE NEWS, NOT A WAIT. `agent_completed` is the one that would have hurt
    // most: a session that dispatches subagents would go red every time one FINISHED, and stand
    // red until somebody typed in that terminal.
    check("the five waiting types are waits",
          waitingNotificationTypes.allSatisfy { notificationWaitsForUser($0) })
    check("the four settled ones are not",
          settledNotificationTypes.allSatisfy { !notificationWaitsForUser($0) })
    check("an agent finishing is never a wait", !notificationWaitsForUser("agent_completed"))
    // FAIL-OPEN IN BOTH DIRECTIONS, which is the compatibility rule: an older Claude Code whose
    // payload carries no type at all, and a TENTH type invented by a later one, are both treated
    // as possible waits. A missed wait is the state this board exists to show; a spurious one
    // clears on the next tick.
    check("an event with no type at all is treated as a wait", notificationWaitsForUser(nil))
    check("…and so is a type this build has never heard of",
          notificationWaitsForUser("some_future_type"))
    // The matcher the registration carries is built from the same list, so the two ends cannot
    // come to disagree about which types are asked for.
    check("the matcher asks for exactly the waiting types and nothing else",
          notificationHookMatcher == waitingNotificationTypes.joined(separator: "|"))
    // A TYPE ABSENT FROM THE MATCHER IS ONE THE HOOK IS NEVER FIRED FOR: Claude Code matches a
    // pattern made only of `[A-Za-z0-9_|]` by splitting on `|` and testing membership rather than
    // as a regular expression, so the fail-open belt above cannot reach a type nobody asked for.
    // `worker_permission_prompt` (2.1.233) is a permission request for a background worker, and
    // until it was named here that request stood with nothing on the board at all.
    check("a permission request raised for a worker is asked for",
          waitingNotificationTypes.contains("worker_permission_prompt")
              && notificationHookMatcher.contains("worker_permission_prompt"))
    check("…and the matcher stays a plain alternation, which is what makes it an exact list",
          notificationHookMatcher.allSatisfy {
              $0 == "|" || $0 == "_" || $0.isLetter || $0.isNumber
          })

    // The type is read out of the payload under whichever spelling it arrives in: the field name
    // is not in the documentation, so the reader tries the plausible ones rather than betting.
    check("the type is found under the snake_case spelling",
          notificationTypeInEvent(["notification_type": "agent_completed"]) == "agent_completed")
    check("…the camelCase one", notificationTypeInEvent(["notificationType": "idle_prompt"])
          == "idle_prompt")
    check("…and a bare `type`", notificationTypeInEvent(["type": "permission_prompt"])
          == "permission_prompt")
    check("a payload naming no type reads as no type, which fails open",
          notificationTypeInEvent(["message": "hello"]) == nil
              && notificationTypeInEvent(nil) == nil)
    // An empty string is not a type, and reading one as a type would be a value the settled set
    // certainly does not contain - harmless here, but it would make the next reader's life a lie.
    check("an empty value is not a type", notificationTypeInEvent(["type": ""]) == nil)
    check("a type that is not a string is not a type",
          notificationTypeInEvent(["type": 7]) == nil)

    // MARK: the sidecar

    let record = SessionStateRecord(state: "blocked", since: t0, updatedAt: t0,
                                    reason: "needs permission", accountID: "claude:.claude",
                                    directory: "/Users/u/code/tally", project: "tally",
                                    worktree: "cart", model: "opus", childPid: 4_242)
    writeSessionState(record, pid: "9001", dir: dir)
    check("a state reading round-trips whole", readSessionState(pid: "9001", dir: dir) == record)
    check("…and is read back as the state it names",
          readSessionState(pid: "9001", dir: dir)?.supervised == .blocked)
    clearSessionState(pid: "9001", dir: dir)
    check("clearing unlinks it, because absence is the signal",
          readSessionState(pid: "9001", dir: dir) == nil)

    // A WORD THIS BUILD HAS NEVER HEARD OF MUST NOT LOSE THE SESSION. The state is a String rather
    // than a Codable enum precisely so a fifth state written by a newer CLI decodes and reads as
    // unknown, instead of rejecting the whole record and dropping the row off the board.
    let futureFile = dir.appendingPathComponent("9002" + sessionStateSuffix)
    try? Data(#"{"state":"compacting","since":"2026-08-13T10:00:00Z","updatedAt":"2026-08-13T10:00:00Z"}"#.utf8)
        .write(to: futureFile)
    check("a state word from a newer build still decodes, as unknown",
          readSessionState(pid: "9002", dir: dir)?.supervised == .unknown)
    // Additive-only: everything past the first three fields has to be optional, or a record written
    // before a field existed is rejected rather than read.
    check("…and a record with only the required fields is readable",
          readSessionState(pid: "9002", dir: dir)?.accountID == nil)

    // MARK: the clock a wait is written on

    // THE DEFECT THIS PINS (codex review, 2026-08-13): `at` is compared against a transcript's
    // mtime, and the two land in the same second as a matter of course - a tool result written at
    // T.600, the permission prompt for the next call at T.900. Encoded to whole seconds, `at` came
    // back as T.000, the earlier mtime was greater, and the first tick after the prompt read a
    // write from BEFORE it as the answer to it. A permission request never reached the board.
    let atMs = Date(timeIntervalSince1970: 1_786_571_200.5)
    writeUserNotice(UserNotice(message: "needs permission", at: atMs), pid: "9101", dir: dir)
    check("an event keeps the sub-second instant it fired at",
          readUserNotice(pid: "9101", dir: dir)?.at == atMs)
    check("a transcript written EARLIER in the same second does not answer it",
          userNoticeStillOpen(readUserNotice(pid: "9101", dir: dir),
                              transcriptModified: Date(timeIntervalSince1970: 1_786_571_200.25),
                              keyboardBurstAt: nil))
    check("…and one written later in that same second does",
          !userNoticeStillOpen(readUserNotice(pid: "9101", dir: dir),
                               transcriptModified: Date(timeIntervalSince1970: 1_786_571_200.75),
                               keyboardBurstAt: nil))
    // The same second, one axis over: a keystroke burst is compared against the same instant.
    check("typing earlier in the same second does not answer it either",
          userNoticeStillOpen(readUserNotice(pid: "9101", dir: dir), transcriptModified: nil,
                              keyboardBurstAt: Date(timeIntervalSince1970: 1_786_571_200.25)))
    // A notice on disk across the upgrade that introduced the fractional form is at most one wait
    // old, but reading it as unparseable would DROP that wait, which is the failure this file is
    // for. Whole-second files therefore still decode.
    try? Data(#"{"message":"older build","at":"2026-08-13T09:00:00Z"}"#.utf8)
        .write(to: dir.appendingPathComponent("9102" + userNoticeSuffix))
    check("an event written before the fractional clock still reads",
          readUserNotice(pid: "9102", dir: dir)?.message == "older build")
    check("…and a stamp that is not an instant at all reads as no event",
          { try? Data(#"{"message":"x","at":"whenever"}"#.utf8)
              .write(to: dir.appendingPathComponent("9103" + userNoticeSuffix))
            return readUserNotice(pid: "9103", dir: dir) == nil }())

    // MARK: a wait is only cleared if it is still the one that was judged

    // Reading an event, deciding it has been answered and unlinking it are three steps with nothing
    // holding the path still between them, and the hook replaces that file atomically at any
    // moment. A prompt landing in the gap used to be deleted unread, leaving somebody waiting on a
    // session the board called idle.
    //
    // ASSERTED AGAINST THE GUARD ITSELF rather than against a tick, because a tick reads the file
    // once and cannot be interrupted from out here: driving `syncSessionState` with a replaced file
    // exercises the path where the wait is still OPEN, so a mutant that deleted unconditionally
    // walked straight through it (caught by mutation, 2026-08-13).
    let judged = UserNotice(message: "first", at: t0)
    writeUserNotice(judged, pid: "9104", dir: dir)
    // The hook fires again, in the gap, with a different instant.
    writeUserNotice(UserNotice(message: "second", at: t0.addingTimeInterval(30)), pid: "9104",
                    dir: dir)
    clearAnsweredUserNotice(judged, pid: "9104", dir: dir)
    check("an event that arrived after the judgement is not swept away with it",
          readUserNotice(pid: "9104", dir: dir)?.message == "second")
    // Two events one SECOND apart are told apart only because the instant carries milliseconds,
    // which is the same fix C1 made: on whole seconds these two would compare equal and the
    // replacement would be deleted.
    let close = UserNotice(message: "third", at: t0.addingTimeInterval(30).addingTimeInterval(0.25))
    writeUserNotice(close, pid: "9104", dir: dir)
    clearAnsweredUserNotice(UserNotice(message: "second", at: t0.addingTimeInterval(30)),
                            pid: "9104", dir: dir)
    check("…even when the replacement landed a fraction of a second later",
          readUserNotice(pid: "9104", dir: dir)?.message == "third")
    // And the ordinary case still clears: the same event, answered.
    clearAnsweredUserNotice(close, pid: "9104", dir: dir)
    check("an answered event that nothing replaced is taken away",
          readUserNotice(pid: "9104", dir: dir) == nil)
    // A file that has already gone is not an event that was replaced: nothing to remove, no throw.
    clearAnsweredUserNotice(close, pid: "9104", dir: dir)
    check("clearing an event that is already gone is a no-op",
          readUserNotice(pid: "9104", dir: dir) == nil)

    // The tick reaches it through the same door, which is what keeps the guard on the live path.
    var replaced = SessionStateWriter()
    var watcher = TranscriptWatcher(projectDir: dir, since: t0)
    writeUserNotice(UserNotice(message: "answered", at: t0), pid: "9106", dir: dir)
    syncSessionState(&replaced, pid: "9106", project: PickProject(name: "p", path: dir.path),
                     accountID: "claude:.claude", childPid: nil, model: nil, watcher: &watcher,
                     keyboardBurstAt: t0.addingTimeInterval(10),
                     dir: dir, now: t0.addingTimeInterval(20))
    check("a tick that finds the wait answered takes it away",
          readUserNotice(pid: "9106", dir: dir) == nil)
    // …and one that finds it still open leaves it exactly where it is.
    writeUserNotice(UserNotice(message: "standing", at: t0.addingTimeInterval(60)), pid: "9106",
                    dir: dir)
    syncSessionState(&replaced, pid: "9106", project: PickProject(name: "p", path: dir.path),
                     accountID: "claude:.claude", childPid: nil, model: nil, watcher: &watcher,
                     keyboardBurstAt: t0.addingTimeInterval(10),
                     dir: dir, now: t0.addingTimeInterval(70))
    check("a tick that finds it still open leaves it standing",
          readUserNotice(pid: "9106", dir: dir)?.message == "standing")
    check("…and reports the session as blocked while it stands",
          readSessionState(pid: "9106", dir: dir)?.supervised == .blocked)

    // MARK: the two readings this board was getting wrong (2026-08-15)

    // Everything below drives the WHOLE tick against a transcript on disk, because both defects
    // live in the join rather than in either half: the state rule and the notice reader were each
    // behaving as written, and the tick threw one of them away.
    //
    // Timestamps here are against the real clock: `isQuiet` compares mtimes to `Date()`, and the
    // `now` a tick is handed only moves the writer's own bookkeeping.
    let realNow = Date()
    let stamper = ISO8601DateFormatter()
    stamper.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    /// A live conversation in a directory of its own (so nothing here can be read as a fork of
    /// anything else): its last turn open on `tool` or closed, written `age` seconds ago, with or
    /// without a subagent that is writing right now.
    func conversation(open tool: String?, age: TimeInterval,
                      subagentWriting: Bool = false) -> URL {
        let home = dir.appendingPathComponent("live-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("session.jsonl")
        var body = "{\"parentUuid\":\"p0\",\"isSidechain\":false,\"type\":\"assistant\","
            + "\"uuid\":\"a1\",\"timestamp\":\"\(stamper.string(from: realNow.addingTimeInterval(-age)))\","
            + "\"message\":{\"model\":\"claude-opus-5\",\"role\":\"assistant\",\"content\":["
            + "{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"\(tool ?? "Bash")\","
            + "\"input\":{}}],\"stop_reason\":\"tool_use\"}}\n"
        if tool == nil {
            body += "{\"parentUuid\":\"a1\",\"isSidechain\":false,\"type\":\"user\",\"uuid\":\"u1\","
                + "\"timestamp\":\"\(stamper.string(from: realNow.addingTimeInterval(-age + 1)))\","
                + "\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"toolu_1\","
                + "\"type\":\"tool_result\",\"content\":\"ok\"}]}}\n"
        }
        try? body.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: realNow.addingTimeInterval(-age)],
                                               ofItemAtPath: file.path)
        if subagentWriting {
            // Where the Agent tool writes a work package: the walk `isQuiet` runs finds this and
            // holds the session busy while the main file says nothing at all.
            let subagents = file.deletingPathExtension().appendingPathComponent("subagents")
            try? FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            try? Data("{}\n".utf8)
                .write(to: subagents.appendingPathComponent("agent-a1.jsonl"))
        }
        return file
    }
    /// One tick over that conversation, with whatever notice is standing, and what it published.
    func tick(_ pid: String, file: URL, notice: UserNotice?) -> SessionStateRecord? {
        if let notice { writeUserNotice(notice, pid: pid, dir: dir) } else {
            clearUserNotice(pid: pid, dir: dir)
        }
        var writer = SessionStateWriter()
        var watcher = TranscriptWatcher(projectDir: file.deletingLastPathComponent(), file: file,
                                        since: t0)
        syncSessionState(&writer, pid: pid,
                         project: PickProject(name: "p", path: file.deletingLastPathComponent().path),
                         accountID: "claude:.claude", childPid: nil, model: nil, watcher: &watcher,
                         keyboardBurstAt: nil, dir: dir, now: realNow)
        return readSessionState(pid: pid, dir: dir)
    }
    func idlePrompt(_ ago: TimeInterval) -> UserNotice {
        UserNotice(message: "Claude is waiting for your input",
                   at: realNow.addingTimeInterval(-ago), type: "idle_prompt")
    }

    // A1: THE FAN-OUT. The main transcript stops the instant the subagents start, Claude Code's
    // 60s timer fires an `idle_prompt`, and the card went red for the whole of the work package.
    // The tick already knew better - the subagent walk had answered "not quiet" on the same pass.
    let fanout = tick("9301", file: conversation(open: nil, age: 120, subagentWriting: true),
                      notice: idlePrompt(60))
    check("a session whose subagents are writing is working, whatever the idle prompt says",
          fanout?.supervised == .working)
    check("…and says nothing about a wait, because there is none to name",
          fanout?.reason == nil)
    // A2: the same event with the work actually finished. This is what `idle_prompt` is FOR, and it
    // still lands - the fix narrows the event to the case it describes rather than dropping it.
    let free = tick("9302", file: conversation(open: nil, age: 120), notice: idlePrompt(60))
    check("a conversation with nothing outstanding IS a call for somebody",
          free?.supervised == .blocked && free?.reason == "Claude is waiting for your input")
    // NO REGRESSION ON THE PATH THAT MATTERS. A permission dialog holds an open tool call, so the
    // session is never quiet while one stands: any rule that let "busy" outrank a wait would hide
    // exactly the state the board exists for.
    let permission = tick("9303", file: conversation(open: nil, age: 120, subagentWriting: true),
                          notice: UserNotice(message: "Claude needs your permission to use Bash",
                                             at: realNow.addingTimeInterval(-10),
                                             type: "permission_prompt"))
    check("a permission request stands even while a subagent writes",
          permission?.supervised == .blocked
              && permission?.reason == "Claude needs your permission to use Bash")
    // And a notice from a supervisor that never recorded a type keeps the behaviour it had.
    let untyped = tick("9304", file: conversation(open: nil, age: 120, subagentWriting: true),
                       notice: UserNotice(message: "older build", at: realNow.addingTimeInterval(-10)))
    check("a notice naming no type is still taken as hard",
          untyped?.supervised == .blocked)

    // B1: THE OTHER DIRECTION - the one state the board exists for was the one it could not show.
    // Claude Code fires no notification for `AskUserQuestion` or a plan awaiting approval, and the
    // open tool call made the session read as working. The transcript is asked instead.
    let asked = tick("9305", file: conversation(open: "AskUserQuestion", age: 120), notice: nil)
    check("a question nobody has answered is a wait, with no notification anywhere",
          asked?.supervised == .blocked && asked?.reason == "Claude is asking you a question")
    let plan = tick("9306", file: conversation(open: "ExitPlanMode", age: 120), notice: nil)
    check("…as is a plan waiting for approval",
          plan?.supervised == .blocked && plan?.reason == "A plan is waiting for approval")
    // A question outranks a soft notice rather than merging with one: both are standing after 60s,
    // and only one of them means somebody is being waited for.
    let askedAndIdle = tick("9307", file: conversation(open: "AskUserQuestion", age: 120),
                            notice: idlePrompt(60))
    check("a question standing behind an idle prompt is still a wait",
          askedAndIdle?.supervised == .blocked)
    // An ordinary tool call is the session working, which is the whole of the distinction: only the
    // two tools a PERSON closes are read this way.
    let building = tick("9308", file: conversation(open: "Bash", age: 120), notice: nil)
    check("a session inside an ordinary tool call is working, not waiting",
          building?.supervised == .working && building?.reason == nil)

    // MARK: what the tick publishes about WHY (the diagnosis, not the decision)

    check("a wait publishes the kind of event it came from",
          free?.noticeType == "idle_prompt" && permission?.noticeType == "permission_prompt")
    check("…and the quiet reading it was judged against",
          free?.quiet == true && fanout?.quiet == false)
    // THE MOST DIAGNOSTIC COMBINATION THERE IS, and the reason this field follows the EVENT rather
    // than the decision: `working` beside `idle_prompt` and `quiet: false` says the hook fired, the
    // event is standing, and the card is not red because the conversation is not quiet - which is
    // the entire judgement that was wrong before, in one line of a command's output.
    check("a session that is working under a standing idle prompt says so",
          fanout?.supervised == .working && fanout?.noticeType == "idle_prompt"
              && fanout?.quiet == false)
    check("a session with no event standing at all names none",
          asked?.noticeType == nil && building?.noticeType == nil)

    // MARK: a publish that failed is retried rather than believed

    // The guard that suppresses an unchanged write judges against an in-memory copy, so updating
    // that copy after a write that never landed would suppress every retry for the life of the
    // session: the state decided correctly, every tick, and published never again.
    let blocked = dir.appendingPathComponent("not-a-directory")
    try? Data("".utf8).write(to: blocked)
    var stubborn = SessionStateWriter()
    stubborn.sync(.working, reason: nil, identity: SessionIdentity(accountID: "claude:.claude"),
                  pid: "9105", dir: blocked.appendingPathComponent("under-a-file"), now: t0)
    stubborn.sync(.working, reason: nil, identity: SessionIdentity(accountID: "claude:.claude"),
                  pid: "9105", dir: dir, now: t0.addingTimeInterval(2))
    check("a state whose write failed is published on the next tick, not suppressed",
          readSessionState(pid: "9105", dir: dir)?.state == "working")

    // MARK: the sweep

    // The suffix list is what keeps a dead session's files from piling up; a document added to this
    // track and forgotten there is never swept (PendingNotice.swift).
    check("the sweep recognises a state file", supervisorStatePid(ofFile: "4242.state") == 4_242)
    check("…and a user-notice event", supervisorStatePid(ofFile: "4242.usernotice") == 4_242)
    check("…and still ignores anything that is not ours",
          supervisorStatePid(ofFile: "notes.txt") == nil)
    // The presence entry is what `liveSupervisorPids` counts, and it parses names as pids: a suffixed
    // file that read as one would inflate the live-session count.
    check("a suffixed file is not a live supervisor",
          liveSupervisorPids(dir: dir).isEmpty)

    // MARK: the writer

    var writer = SessionStateWriter(pid: "9003", dir: dir)
    writer.sync(.working, reason: nil, identity: SessionIdentity(accountID: "claude:.claude"),
                pid: "9003", dir: dir, now: t0)
    check("the first tick publishes", readSessionState(pid: "9003", dir: dir)?.state == "working")
    // The age of the WAIT, not of the poll: `since` holds for as long as the word does.
    writer.sync(.working, reason: nil, identity: SessionIdentity(accountID: "claude:.claude"),
                pid: "9003", dir: dir, now: t0.addingTimeInterval(60))
    check("a state that has not changed keeps its start time",
          readSessionState(pid: "9003", dir: dir)?.since == t0)
    // Nothing to say means nothing written: 2s per session for the life of the machine, otherwise.
    clearSessionState(pid: "9003", dir: dir)
    writer.sync(.working, reason: nil, identity: SessionIdentity(accountID: "claude:.claude"),
                pid: "9003", dir: dir, now: t0.addingTimeInterval(120))
    check("an unchanged tick writes nothing at all",
          readSessionState(pid: "9003", dir: dir) == nil)
    // An identity change IS a change, even under the same state word: a handoff moves the account
    // mid-turn, and a row naming the account a session has left is the defect this track keeps closing.
    writer.sync(.working, reason: nil, identity: SessionIdentity(accountID: "claude:.claude2"),
                pid: "9003", dir: dir, now: t0.addingTimeInterval(180))
    check("a moved account is published even though the state word held",
          readSessionState(pid: "9003", dir: dir)?.accountID == "claude:.claude2")
    check("…without restarting the clock on a state that never changed",
          readSessionState(pid: "9003", dir: dir)?.since == t0)
    writer.sync(.blocked, reason: "needs permission",
                identity: SessionIdentity(accountID: "claude:.claude2"),
                pid: "9003", dir: dir, now: t0.addingTimeInterval(240))
    check("a new state starts a new clock",
          readSessionState(pid: "9003", dir: dir)?.since == t0.addingTimeInterval(240)
              && readSessionState(pid: "9003", dir: dir)?.reason == "needs permission")

    // SEEDED FROM THE FILE, which is the self-update case: `execv` keeps the pid, so a fresh image
    // starts holding nothing while the record its predecessor wrote is still on disk. Unseeded, this
    // writer would republish and lose the clock (`PendingNoticeWriter` carries the incident).
    var afterUpgrade = SessionStateWriter(pid: "9003", dir: dir)
    clearSessionState(pid: "9003", dir: dir)
    afterUpgrade.sync(.blocked, reason: "needs permission",
                      identity: SessionIdentity(accountID: "claude:.claude2"),
                      pid: "9003", dir: dir, now: t0.addingTimeInterval(300))
    check("an image that replaced its predecessor knows what already stands",
          readSessionState(pid: "9003", dir: dir) == nil)

    // MARK: the knock a session's END has to send

    // No value assertion can see a distributed notification, so the boundary lives in the source.
    // Every OTHER knock is posted by the writer as it publishes; a session that has exited
    // publishes nothing more, so without one here the board hears nothing until an unrelated
    // supervisor happens to move - and for a session that was BLOCKED that is a red dot in the
    // menu bar for a conversation that no longer exists.
    let loopSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the session-state checks", !loopSource.isEmpty)
    let teardown = loopSource.range(of: "removeSupervisorState(pid: supervisorPID)")
        .map { String(loopSource[$0.lowerBound...]) } ?? ""
    // The same kind of boundary one file over: whether the TICK routes its clear through the guard
    // cannot be seen from a value assertion, because the race the guard narrows needs another
    // process writing between two reads inside one synchronous call. The guard's own behaviour IS
    // value-asserted above; this is the half that says the live path uses it. Both are needed - a
    // mutant that swapped the call back to the unconditional clear passed every value assertion
    // there is (2026-08-13).
    let syncSource = (try? String(contentsOfFile: "TallyCLI/SessionStateSync.swift",
                                  encoding: .utf8)) ?? ""
    check("the sync source is readable from the session-state checks", !syncSource.isEmpty)
    check("the tick clears an answered wait only through the guard",
          syncSource.contains("clearAnsweredUserNotice(notice, pid: pid, dir: dir)")
              && !syncSource.contains("clearUserNotice(pid: pid, dir: dir)"))

    check("a session that has exited knocks, after clearing its files",
          teardown.range(of: "clearSessionState(pid: supervisorPID)").map { cleared in
              teardown.range(of: "postSessionStateChanged(pid: supervisorPID)")
                  .map { $0.lowerBound > cleared.lowerBound } ?? false
          } ?? false)

    // MARK: reading the board back

    // A live supervisor, using this process as one: `liveSupervisorPids` filters on the pid being
    // alive, and this one certainly is.
    let me = String(getpid())
    try? Data().write(to: dir.appendingPathComponent(me))
    check("a live session with nothing published yet is still on the board",
          liveSessionStates(dir: dir).count == 1 && liveSessionStates(dir: dir).first?.record == nil)
    writeSessionState(record, pid: me, dir: dir)
    check("…and carries its reading once there is one",
          liveSessionStates(dir: dir).first?.record?.supervised == .blocked)
    // pid 1 is launchd, which this user cannot signal: `supervisorAlive` reports EPERM as alive, so a
    // dead pid is needed instead. A pid this high is not in use on a machine that has just booted an
    // assertion harness.
    try? Data().write(to: dir.appendingPathComponent("999999"))
    check("a supervisor that has exited is not painted",
          liveSessionStates(dir: dir).map(\.supervisorPid) == [getpid()])

    // MARK: the order the panel draws

    func row(_ state: SupervisedState, _ offset: TimeInterval) -> SessionRosterStore.SessionRow {
        SessionRosterStore.SessionRow(
            id: "\(state)-\(offset)",
            record: SessionStateRecord(state: state.rawValue,
                                       since: t0.addingTimeInterval(offset), updatedAt: t0,
                                       project: "tally"))
    }
    let ordered = SessionRosterStore.sorted([row(.idle, 0), row(.unknown, 0), row(.working, 0),
                                             row(.blocked, 0)])
    check("what wants somebody leads, then what is moving, then what is not",
          ordered.map(\.state) == [.blocked, .working, .idle, .unknown])
    let aged = SessionRosterStore.sorted([row(.working, 100), row(.working, 0), row(.working, 50)])
    check("inside a state the oldest wait leads",
          aged.compactMap(\.since) == [t0, t0.addingTimeInterval(50), t0.addingTimeInterval(100)])
    // A SESSION THAT HAS PUBLISHED NOTHING SITS BELOW ALL FOUR STATES, unknown included: "running,
    // with nothing to say yet" is a reading, and this is the absence of one. It is on the board all
    // the same - a card of its own rather than a number - so the order has to place it.
    let silent = SessionRosterStore.SessionRow(id: "silent", record: nil,
                                               session: SessionSidecar(updatedAt: t0),
                                               cwd: "/Users/u/code/atlas")
    check("a session with no reading at all comes after the ones that have one",
          SessionRosterStore.sorted([silent, row(.unknown, 0), row(.blocked, 0)])
              .map(\.id) == ["blocked-0.0", "unknown-0.0", "silent"])
    check("…and is named after the directory it runs in, having published no project",
          silent.title == "atlas")
    check("…and reports itself as the one thing it knows: not reporting",
          !silent.isReporting && silent.state == .unknown)

    // MARK: the sidecars the board reads beside the state

    // THE SUFFIXES ARE SPELLED IN TWO PLACES, and this is what stops them drifting: the app cannot
    // compile the supervisor's own file (project.yml says why), so the panel carries a reader's
    // copy of these names. A rename on the writer's side with no answer here is a board that
    // silently loses every account, model and token figure it draws.
    check("the panel reads the context file the supervisor writes",
          SessionSidecar.contextSuffix == sessionContextSuffix)
    check("…the directory file", SessionSidecar.cwdSuffix == supervisorCwdSuffix)
    check("…and the child file", SessionSidecar.childSuffix == supervisorChildSuffix)

    // Round-tripped through the REAL writer, so the fields are asserted against what is actually on
    // disk rather than against a fixture written to match the reader.
    let published = SupervisedSession(accountID: "claude:.claude5", contextTokens: 229_317,
                                      updatedAt: t0, sessionPin: nil,
                                      axes: SessionAxes(pinnedModel: nil, pinnedEffort: "xhigh",
                                                        observedModel: "claude-fable-5",
                                                        runningModel: "fable",
                                                        runningEffort: "high"),
                                      transcript: "abc-123")
    writeSessionContext(published, pid: "9201", dir: dir)
    let read = SessionSidecar.read(pid: "9201", dir: dir)
    check("a context reading written by the supervisor is read back whole",
          read?.accountID == "claude:.claude5" && read?.contextTokens == 229_317
              && read?.updatedAt == t0)
    check("…with both model answers, so the card can prefer the observed one",
          read?.observedModel == "claude-fable-5" && read?.runningModel == "fable")
    check("…and both effort answers, so a pin outranks what is merely running",
          read?.sessionEffort == "xhigh" && read?.runningEffort == "high")
    let joined = SessionRosterStore.SessionRow(id: "9201", record: nil, session: read)
    // The OBSERVED id wins, and it reaches the card without the vendor's name on it: the sidecar
    // holds `claude-fable-5`, the row draws `fable-5`.
    check("the card prefers the model it was SEEN answering with", joined.model == "fable-5")
    check("…and the effort somebody pinned over the one the child was launched with",
          joined.effort == "xhigh")

    // MARK: the model as a card prints it

    // THE VENDOR IS NAMED ONCE PER LINE. The account beside it already says Claude, so an identity
    // line carrying `claude-opus-5` said it twice and spent a truncating line's width on the repeat.
    check("a card names the model without repeating the vendor the account already names",
          displayModelName("claude-opus-5") == "opus-5"
              && displayModelName("claude-fable-5") == "fable-5")
    // AND NOTHING ELSE IS DROPPED, which is the whole difference from the judgement's normalisation
    // one file over: `sol` and `terra` are what two Codex sessions are told apart by, and
    // `shortModelName` would leave both cards reading `gpt`.
    check("…and keeps every segment two models of one vendor are told apart by",
          displayModelName("gpt-5.6-sol") == "gpt-5.6-sol"
              && displayModelName("gpt-5.6-terra") == "gpt-5.6-terra")
    check("…which is exactly what the drift check's own normalisation would have thrown away",
          shortModelName("gpt-5.6-sol") == "gpt" && shortModelName("claude-opus-5") == "opus")
    check("…an id with no vendor on it answers itself",
          displayModelName("opus") == "opus" && displayModelName("") == "")
    // A prefix and nothing after it is left whole: dropping it would trade an odd id for an empty
    // field, and blank is the one answer that says less than the raw string.
    check("…and a bare prefix is left alone rather than reduced to nothing",
          displayModelName("claude-") == "claude-")
    // ONE BOARD, ONE SPELLING. The row's three sources are not spelled alike on disk - the state
    // record's model was trimmed by its writer, the sidecar's two are raw ids - so the fallback
    // card and the observed card have to arrive at the same form or the page shows both.
    check("the model a state record carried is drawn the way the observed one is",
          SessionRosterStore.SessionRow(
            id: "9213",
            record: SessionStateRecord(state: "idle", since: t0, updatedAt: t0, model: "opus"))
              .model == "opus")
    check("…and a raw id that only the launch knew arrives trimmed too",
          SessionRosterStore.SessionRow(
            id: "9214", record: nil,
            session: SessionSidecar(runningModel: "claude-sonnet-5")).model == "sonnet-5")

    // MARK: the account the card names, and the provider it marks

    func onAccount(_ accountID: String?) -> SessionRosterStore.SessionRow {
        SessionRosterStore.SessionRow(id: "9215", record: nil,
                                      session: SessionSidecar(accountID: accountID))
    }
    // The surface's own naming, as `sessionIdentityLine` builds it: the account list this build can
    // see, each member called what the user calls it.
    let renamed = ["claude:.claude5": "Work"]
    let nameOf: (String) -> String? = { renamed[$0] }
    check("a card calls the account what the user calls it",
          onAccount("claude:.claude5").accountName(nameOf) == "Work")
    // THE ACCOUNT WENT AND THE SESSION DID NOT: its config home is in the Trash and the supervisor
    // is still running. Naming it comes back empty-handed, and the answer is a missing segment -
    // NOT `claude:.claude9`, which is an address rather than a name, on a line that truncates.
    check("an account this build cannot see contributes no segment, rather than its raw id",
          onAccount("claude:.claude9").accountName(nameOf) == nil)
    check("…and neither does a session that named no account at all",
          onAccount(nil).accountName(nameOf) == nil)

    // The mark that leads the line, off the id's own head: the one thing there a rename cannot
    // reach (an account called "Work" says nothing about whose).
    check("the provider is read off the account id", onAccount("claude:.claude5").providerID == "claude")
    check("…for either provider", onAccount("codex:.codex2").providerID == "codex")
    // An id with no head to read gets no mark of its own rather than a wrong one: the card falls
    // back to the catalog's generic glyph, which keeps every identity line at the same left edge.
    check("…and an id this build cannot read the head of names no provider",
          onAccount("claude").providerID == nil && onAccount(":.claude5").providerID == nil
              && onAccount(nil).providerID == nil)
    // Additive in both directions: a document from before these axes existed, and one from after a
    // field this build has never heard of was added, both have to read rather than be rejected.
    try? Data(#"{"accountID":"claude:.claude","contextTokens":12,"updatedAt":"2026-08-13T10:00:00Z"}"#.utf8)
        .write(to: dir.appendingPathComponent("9202" + SessionSidecar.contextSuffix))
    let old = SessionSidecar.read(pid: "9202", dir: dir)
    check("a reading from before the axes existed still reads, with nothing to say about them",
          old?.contextTokens == 12 && old?.observedModel == nil && old?.runningEffort == nil)
    try? Data(#"{"contextTokens":5,"updatedAt":"2026-08-13T10:00:00.250Z","somethingNew":true}"#.utf8)
        .write(to: dir.appendingPathComponent("9203" + SessionSidecar.contextSuffix))
    check("a field this build never heard of is ignored rather than fatal",
          SessionSidecar.read(pid: "9203", dir: dir)?.contextTokens == 5)
    // And the stamp in the form the rest of this track moved to on 2026-08-13: rejecting it would
    // lose the whole reading, which is exactly the failure the state word's string type avoids.
    check("…and a stamp carrying fractional seconds is read rather than refused",
          SessionSidecar.read(pid: "9203", dir: dir)?.updatedAt
              == Date(timeIntervalSince1970: 1_786_615_200.25))
    // A file that is not a document reads as no document, like every other best-effort read here.
    try? Data("half a jso".utf8)
        .write(to: dir.appendingPathComponent("9204" + SessionSidecar.contextSuffix))
    check("a corrupt reading reads as none rather than taking the card down",
          SessionSidecar.read(pid: "9204", dir: dir) == nil)
    check("…and so does one that was never written",
          SessionSidecar.read(pid: "9205", dir: dir) == nil)
    // A zero is not a measurement: the figure comes off an assistant turn's own usage, so nothing
    // but "no turn yet" produces one, and a card drawing "0" would state a reading nobody took.
    check("a session with no turn yet has no context figure to draw",
          SessionRosterStore.SessionRow(id: "x", record: nil,
                                        session: SessionSidecar(contextTokens: 0))
              .contextTokens == nil)

    // The directory sidecar, which is where a card with no published project gets its name and the
    // jump gets its match.
    writeSupervisorCwd(dir.path, pid: "9206", dir: dir)
    // Against the writer's own resolution rather than against the path handed in: it publishes a
    // realpath, which on a temp directory is a different string from the one this harness holds.
    check("the directory a supervisor published is read back",
          SessionSidecar.readCwd(pid: "9206", dir: dir) == realpathString(dir.path))
    try? Data("  \n".utf8).write(to: dir.appendingPathComponent("9207" + SessionSidecar.cwdSuffix))
    check("a write that got as far as the file and no further says nothing",
          SessionSidecar.readCwd(pid: "9207", dir: dir) == nil)

    // The child sidecar: the fallback the terminal jump uses for a session whose state record
    // cannot name one. A DEAD pid is not an answer - it names a process that has exited, and the
    // jump would match nothing rather than falling through to the directory.
    writeSupervisorChild(getpid(), pid: "9208", dir: dir)
    check("a live child is offered to the jump",
          SessionSidecar.readChildPid(pid: "9208", dir: dir) == Int(getpid()))
    writeSupervisorChild(999_999, pid: "9209", dir: dir)
    check("a pid that has exited is not", SessionSidecar.readChildPid(pid: "9209", dir: dir) == nil)
    check("…and neither is a file holding something that is not a pid at all",
          { try? Data("not a pid".utf8)
              .write(to: dir.appendingPathComponent("9210" + SessionSidecar.childSuffix))
            return SessionSidecar.readChildPid(pid: "9210", dir: dir) == nil }())
    // The record's own child is the vetted one (the supervisor publishes it only while it can prove
    // it), so it wins wherever there is one; the sidecar is what reaches a session too old to
    // publish a state at all.
    let both = SessionRosterStore.SessionRow(
        id: "9211",
        record: SessionStateRecord(state: "idle", since: t0, updatedAt: t0, childPid: 111),
        child: 222)
    check("the published child outranks the sidecar", both.childPid == 111)
    check("…and the sidecar is what a session with no record jumps by",
          SessionRosterStore.SessionRow(id: "9212", record: nil, child: 222).childPid == 222)

    // MARK: the row's own name

    func named(project: String?, worktree: String?) -> String {
        SessionRosterStore.SessionRow(
            id: "x",
            record: SessionStateRecord(state: "idle", since: t0, updatedAt: t0,
                                       project: project, worktree: worktree)).title
    }
    check("a session on the trunk is called after its repository", named(project: "tally", worktree: nil) == "tally")
    check("a parallel line names the line beside it",
          named(project: "tally", worktree: "cart") == "tally · cart")
    check("a supervisor too old to publish either has nothing to say rather than a stray separator",
          named(project: nil, worktree: nil).isEmpty)

    try? FileManager.default.removeItem(at: dir)
}
