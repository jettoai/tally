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

    // MARK: the AppleScript the jump sends

    // Both interpolated values are read off disk (a checkout path, a repository name), so neither may
    // end the literal early and turn the rest of the line into script.
    check("a quote in a path cannot close the literal",
          TerminalJump.literal("/Users/u/co\"de") == "\"/Users/u/co\\\"de\"")
    check("…nor can a backslash escape the closing one",
          TerminalJump.literal("/Users/u/code\\") == "\"/Users/u/code\\\\\"")
    let script = TerminalJump.script(directory: "/Users/u/code/tally", hint: "tally · cart",
                                     tty: nil)
    check("the script matches on the working directory and breaks ties on the name",
          script.contains("working directory of t) is equal to \"/Users/u/code/tally\"")
              && script.contains("(name of t) contains \"tally · cart\""))
    // A Ghostty without `terminals`, or without `working directory` on one, RAISES rather than
    // returning nothing, and an unhandled raise is a row that visibly does nothing.
    check("every lookup against another app's dictionary is guarded",
          script.components(separatedBy: "try").count - 1 >= 3)
    // A session with no live child to ask about must not have the older dictionary asked for a
    // property it does not have, so the pass is absent rather than merely guarded.
    check("a session with no device to match on never asks about one",
          !script.contains("tty of t"))

    // MARK: matching the surface rather than the repository

    // The bug this answers: one checkout open in several tabs or splits matches the directory in
    // all of them, the titles rarely carry the repository's name, and the tie-break therefore falls
    // through to whichever surface the enumeration happened to reach first.
    let exact = TerminalJump.script(directory: "/Users/u/code/tally", hint: "tally · cart",
                                    tty: "/dev/ttys001")
    guard let ttyHit = exact.range(of: "(tty of t) is equal to \"/dev/ttys001\""),
          let dirHit = exact.range(of: "(working directory of t) is equal to") else {
        check("the script asks about the device and the directory", false)
        return
    }
    let deviceFirst = ttyHit.upperBound < dirHit.lowerBound
    check("the device is asked about before the directory", deviceFirst)
    // Order alone would not settle it: without the guard, a later directory match overwrites the
    // exact one and the click lands on the wrong tab again. Short-circuited, so an inverted script
    // reports the line above rather than tearing the harness down on a backwards range.
    check("a directory match stands down for a device match already found",
          deviceFirst && String(exact[ttyHit.upperBound ..< dirHit.lowerBound])
              .contains("if matched is missing value then"))
    // A device path comes off the process table, so it gets the same treatment as the two values
    // read off disk rather than being trusted to be free of quotes.
    check("a device path cannot close the literal either",
          TerminalJump.script(directory: "", hint: "", tty: "/dev/tty\"s\\1")
              .contains("is equal to \"/dev/tty\\\"s\\\\1\""))
    // A Ghostty too old to have `tty` RAISES on the lookup, and the whole point of the fallback is
    // that such a version still reaches the directory pass instead of exiting non-zero.
    let beforeTTY = String(exact[..<ttyHit.lowerBound])
    check("the device lookup is inside a guard the older dictionary's raise cannot escape",
          beforeTTY.components(separatedBy: "try").count
              - 2 * (beforeTTY.components(separatedBy: "end try").count - 1) - 1 >= 2)

    // MARK: the device the kernel reports

    // The oracle is `ps`, which reads the same field by another path. Both answers are nil when
    // this harness runs with no controlling terminal (a CI runner, or a spawn from the app), which
    // is itself the case the directory pass exists for.
    func psTTY(_ pid: pid_t) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = Pipe()
        guard (try? ps.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let name = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty || name == "??" ? nil : "/dev/" + name
    }
    check("the kernel names this process's own terminal the way ps does",
          TerminalJump.controllingTTY(of: getpid()) == psTTY(getpid()))
    // pid 1 is launchd: owned by root and attached to nothing, so both refusals answer nil rather
    // than a device somebody would then be sent to.
    check("a process with no terminal of its own reports none", TerminalJump.controllingTTY(of: 1) == nil)
    try? FileManager.default.removeItem(at: dir)
}
