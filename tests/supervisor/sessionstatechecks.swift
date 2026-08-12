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
          supervisedSessionState(blocked: false, hasTranscript: true, quiet: false) == .working)
    check("a quiet one with nothing outstanding is idle",
          supervisedSessionState(blocked: false, hasTranscript: true, quiet: true) == .idle)
    // A child that has not bound a conversation has written nothing anywhere, so `isQuiet` answers
    // true about a file it never found. Reading that as idle would be a guess dressed as a reading.
    check("no transcript is unknown rather than idle",
          supervisedSessionState(blocked: false, hasTranscript: false, quiet: true) == .unknown)
    // BLOCKED LEADS, including over an unbound transcript: a session whose first act is a permission
    // request is exactly that case, and unknown would hide the one state the board exists for.
    check("a session waiting on the user is blocked whatever the transcript says",
          supervisedSessionState(blocked: true, hasTranscript: true, quiet: false) == .blocked
              && supervisedSessionState(blocked: true, hasTranscript: true, quiet: true) == .blocked
              && supervisedSessionState(blocked: true, hasTranscript: false, quiet: true) == .blocked)

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
    check("the matcher asks for exactly the waiting five",
          notificationHookMatcher == waitingNotificationTypes.joined(separator: "|"))

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
          aged.map(\.since) == [t0, t0.addingTimeInterval(50), t0.addingTimeInterval(100)])

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

    // MARK: the AppleScript the jump sends

    // Both interpolated values are read off disk (a checkout path, a repository name), so neither may
    // end the literal early and turn the rest of the line into script.
    check("a quote in a path cannot close the literal",
          TerminalJump.literal("/Users/u/co\"de") == "\"/Users/u/co\\\"de\"")
    check("…nor can a backslash escape the closing one",
          TerminalJump.literal("/Users/u/code\\") == "\"/Users/u/code\\\\\"")
    let script = TerminalJump.script(directory: "/Users/u/code/tally", hint: "tally · cart")
    check("the script matches on the working directory and breaks ties on the name",
          script.contains("working directory of t) is equal to \"/Users/u/code/tally\"")
              && script.contains("(name of t) contains \"tally · cart\""))
    // A Ghostty without `terminals`, or without `working directory` on one, RAISES rather than
    // returning nothing, and an unhandled raise is a row that visibly does nothing.
    check("every lookup against another app's dictionary is guarded",
          script.components(separatedBy: "try").count - 1 >= 3)
    try? FileManager.default.removeItem(at: dir)
}
