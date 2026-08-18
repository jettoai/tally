import Foundation

// THE TURN-END FACT CHANNEL: the record Claude Code's `Stop` hook leaves (SessionTurnEnd.swift), and
// what the input gate is allowed to conclude from it.
//
// Everything here is pure or pointed at a temporary directory, like every other suite in this
// family: nothing reads `~/.tally`, and the two ticks that run are given an input directory and a
// log of their own, so a machine with live sessions on it can run this without one of them being
// typed into.
//
// WHAT THE FEATURE HAS TO SURVIVE, and therefore what is asserted here rather than described: a
// boundary that belongs to another conversation (a `/clear`, a fork, a nested session), a boundary
// with a new turn already written after it, and a boundary left by the child before this one. Each
// of the three has a check on the pure rule and, for the first two, one through the real reading
// over a real transcript - the rule and the wiring are separate ways of being wrong.

func runTurnEndChecks() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-turnend-\(UUID().uuidString)")
    let state = root.appendingPathComponent("state")
    let project = root.appendingPathComponent("project")
    let gate = root.appendingPathComponent("input")
    for path in [state, project, gate] {
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    let gateLog = gate.appendingPathComponent("input.log")

    /// A fixed instant for everything about the RECORD, so those checks depend on no clock.
    let t0 = Date(timeIntervalSince1970: 1_786_600_000)
    /// …and the real one for everything about a transcript, whose mtime is what the board reads.
    let now = Date()
    let stamps = ISO8601DateFormatter()
    stamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func at(_ offset: TimeInterval) -> String { stamps.string(from: now.addingTimeInterval(offset)) }
    /// The transcript text a list of events makes, newline terminated as Claude Code writes it.
    func transcriptText(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    // MARK: - The record on disk

    let recorded = SessionTurnEnd(at: t0.addingTimeInterval(0.75), sessionID: "a-conversation")
    writeSessionTurnEnd(recorded, pid: "7001", dir: state)
    let stored = readSessionTurnEnd(pid: "7001", dir: state)
    check("a turn-end event survives a round trip through its file", stored == recorded)
    // THE SUB-SECOND IS THE WHOLE COMPARISON. The instant this is judged against comes out of a
    // transcript event, and the two land in the same second as a matter of course: an answer at
    // T.2 and the boundary that followed it at T.7. Truncated to the second, the boundary decodes
    // as T.0, reads as older than the answer before it, and every acceleration is refused.
    check("…with the sub-second the freshness test turns on, rather than truncated to the second",
          stored?.at.timeIntervalSince1970 == t0.timeIntervalSince1970 + 0.75)
    check("no record at all is nothing said, which is where every machine starts",
          readSessionTurnEnd(pid: "7002", dir: state) == nil)
    // Registered on the track, so a dead supervisor's copy goes with the rest of its files rather
    // than being left for a pid that comes round again.
    check("a record left by a session that exited is the sweep's to remove",
          supervisorStatePid(ofFile: "7001" + sessionTurnEndSuffix) == 7001)

    // MARK: - What the hook writes down

    check("the turn boundary is the event that is recorded",
          turnEndEvent(AgentRosterEvent(kind: .boundary, agentID: nil), sessionID: "c", now: t0)
              == SessionTurnEnd(at: t0, sessionID: "c"))
    // A SUBAGENT FINISHING IS NOT A TURN ENDING, and reading it as one would hand the gate a
    // boundary in the middle of a fan-out - the precise moment the head is still mid-turn.
    check("…and neither edge of a subagent's life is one",
          turnEndEvent(AgentRosterEvent(kind: .stopped, agentID: "a1"), sessionID: "c", now: t0)
              == nil
              && turnEndEvent(AgentRosterEvent(kind: .started, agentID: "a1"), sessionID: "c",
                              now: t0) == nil)
    check("a boundary whose payload named no conversation is recorded saying so",
          turnEndEvent(AgentRosterEvent(kind: .boundary, agentID: nil), sessionID: nil, now: t0)
              == SessionTurnEnd(at: t0, sessionID: nil))

    // MARK: - Whether a recorded boundary still stands

    let born = t0
    let ended = t0.addingTimeInterval(100)
    /// The honoured case, with one thing varied per check.
    func stands(_ event: SessionTurnEnd? = SessionTurnEnd(at: ended, sessionID: "live"),
                transcript: String? = "live", newest: Date? = ended.addingTimeInterval(-3),
                childStartedAt: Date = born, forked: Bool = false) -> Bool {
        turnEndStillStands(event, transcript: transcript, newestMessageAt: newest,
                           childStartedAt: childStartedAt, forked: forked)
    }
    check("a boundary in this conversation with nothing written since is honoured", stands())
    // (a) THE EVENT BELONGS TO A CONVERSATION THIS SESSION NO LONGER IS. A `/clear` or a fork
    // starts a new transcript with a new id, and the last thing the OLD one did was end a turn - so
    // an unchecked record would report the new conversation as between turns for as long as it
    // never fired a boundary of its own.
    check("…and one left by the conversation this session used to be is not",
          !stands(transcript: "cleared"))
    check("…nor one that names no conversation at all, which cannot be checked",
          !stands(SessionTurnEnd(at: ended, sessionID: nil)))
    check("…nor one judged against a watcher with no transcript bound",
          !stands(transcript: nil))
    // (b) SOMETHING HAPPENED AFTER IT. A turn that has begun since the boundary has written a
    // main-chain event by definition, and half a second is enough: the two are told apart by the
    // instants inside the events, not by the file's mtime.
    check("a message written after the boundary means a new turn may have begun",
          !stands(newest: ended.addingTimeInterval(0.5)))
    check("…while the boundary's own instant is not something written after it",
          stands(newest: ended))
    // AND NO MESSAGE IN VIEW IS A REFUSAL, not a clear field. A turn that ended wrote a message by
    // definition, so seeing none means the tail window is too short to hold it: a tool result
    // larger than `openTurnTailBytes` pushes the last message out of view and leaves an attachment
    // or a system line behind it, which is a live turn that would otherwise read as a finished one.
    check("…and a window with no message in it cannot be checked, so nothing is accelerated",
          !stands(newest: nil))
    // The child before this one ended its turns too, and a relaunch resumes the same transcript.
    check("a boundary from before this child started is the previous child's",
          !stands(childStartedAt: ended.addingTimeInterval(0.001)))
    check("…and one exactly at the launch instant is this child's",
          stands(childStartedAt: ended))
    // While a newer transcript cannot yet be told apart from the file the conversation moved to,
    // the id compared above is the id of a file that may already be abandoned.
    check("nothing is honoured while a fork is unresolved", !stands(forked: true))
    check("and nothing recorded is nothing to honour", !stands(nil))

    // MARK: - The tail the freshness test is read from

    /// Whether the walk lands on the event written `offset` seconds from now, which is how each
    /// check below names the one event in its tail that the walk is supposed to stop at.
    func newestIs(_ tail: String, _ offset: TimeInterval) -> Bool {
        guard let found = newestMainChainMessage(inTail: tail) else { return false }
        return abs(found.timeIntervalSince(now.addingTimeInterval(offset))) < 0.002
    }
    let turn = [
        #"{"isSidechain":false,"type":"user","timestamp":"\#(at(-40))","message":{"role":"user","content":"go"}}"#,
        #"{"isSidechain":false,"type":"assistant","uuid":"u1","timestamp":"\#(at(-6))","message":{"model":"claude-fable-5"}}"#,
        // What Claude Code writes AFTER the stop hooks return, this record's own hook among them
        // (measured on this machine 2026-08-17: `stop_hook_summary` and `turn_duration` land 0.5 to
        // 3.3 seconds behind the last assistant event, which is what makes an mtime test useless
        // here and this one necessary).
        #"{"type":"system","subtype":"stop_hook_summary","timestamp":"\#(at(-2))","hookCount":8}"#,
        #"{"type":"system","subtype":"turn_duration","timestamp":"\#(at(-2))","durationMs":41000}"#,
        #"{"type":"file-history-snapshot","messageId":"m1","snapshot":{}}"#,
    ]
    check("the newest main-chain message is the assistant event, not the records after it",
          newestIs(transcriptText(turn), -6))
    // A subagent's events live in their own file, but the guard is what keeps that a fact about
    // today's layout rather than a load-bearing assumption.
    let withSidechain = turn + [
        #"{"isSidechain":true,"type":"assistant","uuid":"s1","timestamp":"\#(at(-1))","message":{"model":"claude-sonnet-5"}}"#,
    ]
    check("…and a subagent's own events are not this conversation's",
          newestIs(transcriptText(withSidechain), -6))
    // AND THE OTHER DIRECTION, which is why the substring filter `openToolCall` opens with is not
    // here: a main-chain assistant message whose own text quotes that substring is a conversation
    // about this code, and passing over it would let the walk fall back to an older event and
    // report a live turn as a finished one.
    let quoting = turn + [
        #"{"isSidechain":false,"type":"assistant","uuid":"u2","timestamp":"\#(at(-1))","message":{"model":"claude-fable-5","content":[{"type":"text","text":"the line reads \"isSidechain\":true"}]}}"#,
    ]
    check("…while a message that merely quotes a subagent's marker is this conversation's",
          newestIs(transcriptText(quoting), -1))
    check("a line still half written is skipped rather than trusted",
          newestIs(transcriptText(turn)
              + #"{"isSidechain":false,"type":"assistant","timest"#, -6))
    // AND A META USER EVENT COUNTS, which is the one property holding the blocked-Stop hole shut: a
    // `Stop` another hook blocks is answered by Claude Code with the block reason as a main-chain
    // `isMeta` user event, and the turn then continues. Skipping it - the way the neighbouring
    // `lastUserTurnAt` does, and the way a "let us make the two walks agree" cleanup would - reports
    // that stop attempt as a finished turn and types into a live one.
    let blocked = turn + [
        #"{"isSidechain":false,"type":"user","isMeta":true,"timestamp":"\#(at(-1))","message":{"role":"user","content":"Stop hook feedback:\n- inbox gate: 1 unread"}}"#,
    ]
    check("a blocked stop's own feedback record is this conversation still talking",
          newestIs(transcriptText(blocked), -1))
    // A transcript a `/clear` has just started: modes and attachments, and not one message.
    check("a tail with no message in it says so rather than inventing one",
          newestMainChainMessage(inTail: transcriptText([
              #"{"type":"mode","mode":"default"}"#,
              #"{"type":"attachment","attachment":{"type":"file"}}"#,
          ])) == nil)

    // MARK: - The reading, over a real transcript

    /// A session written as the shape above, with its file's mtime NOW - which is the state this
    /// whole feature is about: every silent reading calls that session mid-turn for 30 more seconds.
    ///
    /// A DIRECTORY PER SESSION, because one of the readers below locates rather than reads: a
    /// publisher's tick asks the watcher to follow a fork, and several fresh transcripts side by
    /// side are candidates for one - which would answer a question about a file this fixture never
    /// meant to bind.
    func liveSession(_ id: String, lines: [String]) -> TranscriptWatcher {
        let home = project.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("\(id).jsonl")
        try? transcriptText(lines).write(to: file, atomically: true, encoding: .utf8)
        return TranscriptWatcher(projectDir: home, file: file,
                                 since: now.addingTimeInterval(-600))
    }
    let boundary = SessionTurnEnd(at: now.addingTimeInterval(-4), sessionID: "sess-live")
    writeSessionTurnEnd(boundary, pid: "7010", dir: state)
    let live = liveSession("sess-live", lines: turn)
    check("the channel says a session whose turn has just ended is between turns",
          sessionTurnEnded(pid: "7010", watcher: live, dir: state))
    // The same record read against the conversation this session has moved to: this is the fork and
    // the `/clear` case through the real reading rather than through the rule alone.
    let moved = liveSession("sess-cleared", lines: turn)
    check("…and says nothing about the conversation that session has since become",
          !sessionTurnEnded(pid: "7010", watcher: moved, dir: state))
    // A new turn has written its first event, so the boundary describes a turn that is over and a
    // session that is no longer between turns.
    let restarted = liveSession("sess-live", lines: turn + [
        #"{"isSidechain":false,"type":"user","timestamp":"\#(at(-1))","message":{"role":"user","content":"and again"}}"#,
    ])
    check("…and stops saying so the moment a new turn writes its first event",
          !sessionTurnEnded(pid: "7010", watcher: restarted, dir: state))
    check("a session whose Claude Code never reported a boundary is not accelerated at all",
          !sessionTurnEnded(pid: "7011", watcher: live, dir: state))
    // The blind window, through the real reading: what a tool result bigger than the tail leaves in
    // view is records like these, with the message that would answer the question out of sight.
    writeSessionTurnEnd(SessionTurnEnd(at: now.addingTimeInterval(-4), sessionID: "sess-blind"),
                        pid: "7012", dir: state)
    let blind = liveSession("sess-blind", lines: [
        #"{"type":"attachment","attachment":{"type":"file","path":"/tmp/a"}}"#,
        #"{"type":"system","subtype":"turn_duration","timestamp":"\#(at(-2))","durationMs":41000}"#,
    ])
    check("…nor one whose tail window holds no message to judge the boundary against",
          !sessionTurnEnded(pid: "7012", watcher: blind, dir: state))
    check("…and neither is one with no transcript bound to read a boundary against",
          !sessionTurnEnded(pid: "7010",
                            watcher: TranscriptWatcher(projectDir: project, since: t0), dir: state))

    // MARK: - What it changes at the gate, and what it does not

    check("a session the board calls working is typed into when its turn has been reported over",
          sessionInputHold(state: .working, quiet: .busy, turnEnded: true, keyboardIdle: true,
                           relaunchPlanned: false) == nil)
    check("…and is held as its own turn without that fact, exactly as before",
          sessionInputHold(state: .working, quiet: .busy, turnEnded: false, keyboardIdle: true,
                           relaunchPlanned: false) == .turn)
    // The fact reaches one row and no other, or it would be a way around the gate rather than a
    // faster route through it.
    check("…and it opens none of the other three gates",
          sessionInputHold(state: .working, quiet: .busy, turnEnded: true, keyboardIdle: false,
                           relaunchPlanned: false) == .keyboard
              && sessionInputHold(state: .working, quiet: .busy, turnEnded: true,
                                  keyboardIdle: true, relaunchPlanned: true) == .restart
              && sessionInputHold(state: .unknown, quiet: .quiet, turnEnded: true,
                                  keyboardIdle: true, relaunchPlanned: false) == .notReporting)

    // MARK: - End to end: the board's own reading, and the tick behind it

    /// The state this tick publishes for a session, through the real publisher.
    func publish(_ watcher: inout TranscriptWatcher, pid: String) -> SessionTick {
        var writer = SessionStateWriter()
        return syncSessionState(&writer, pid: pid,
                                project: PickProject(name: "p", path: project.path),
                                accountID: "claude:.claude", childPid: nil, model: nil,
                                watcher: &watcher, keyboardBurstAt: nil, dir: state)
    }
    /// One tick of the input gate with a request already waiting, answering what was typed.
    func tick(_ pid: String, board: SessionTick, turnEnded: Bool) -> [String] {
        var input = SessionInputState(sessionKey: pid, servedEpoch: 0, dir: gate)
        try? writeSessionInputRequest(
            SessionInputRequest(epoch: Int(Date().timeIntervalSince1970 * 1000), text: "/clear"),
            sessionKey: pid, dir: gate)
        var typed: [String] = []
        applySessionInput(&input, session: board.state, quiet: board.quiet,
                          turnEnded: { turnEnded }, keyboardIdle: true, relaunchPlanned: false,
                          dir: gate, log: gateLog) { text in
            typed.append(text)
            return .done
        }
        return typed
    }
    var justFinished = liveSession("sess-fresh", lines: turn)
    let board = publish(&justFinished, pid: "7020")
    // THE STATE THIS FEATURE EXISTS FOR: the turn is over, and every silent reading still says
    // mid-turn because the file was written a moment ago. The board is left exactly as it was.
    check("a session that has just finished a turn still publishes working, as the board does",
          board.state == .working && board.quiet == .busy)
    check("…and without the fact channel its pending line waits, as it did before",
          tick("7021", board: board, turnEnded: false).isEmpty)
    check("…while the fact channel gets it typed on this very tick",
          tick("7022", board: board, turnEnded: true) == ["/clear"])
    // AND THE INFERENCE BEHIND IT IS UNTOUCHED. The same session 30 seconds later reads idle from
    // silence alone and is typed into with no fact channel at all, which is every machine that has
    // not registered these hooks.
    var settled = liveSession("sess-fresh", lines: turn)
    let quietFile = project.appendingPathComponent("sess-fresh")
        .appendingPathComponent("sess-fresh.jsonl")
    try? FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-sessionStateQuietSeconds - 5)],
        ofItemAtPath: quietFile.path)
    let after = publish(&settled, pid: "7023")
    check("thirty seconds of silence still publishes idle on its own",
          after.state == .idle && after.quiet == .quiet)
    check("…and the line is typed with nothing from this channel at all",
          tick("7024", board: after, turnEnded: false) == ["/clear"])

    // MARK: - The wiring, which no fixture above can reach

    // EVERY CHECK IN THIS FILE FEEDS THE ANSWER IN, so all of them stay green with the poll loop
    // handing the gate a constant: the channel would then be a feature that silently never fires,
    // which is the failure `SessionRosterStore.install()` names about a missed registration. The
    // loop itself is a `while true` inside a process that spawns children, so the source carries it
    // - the technique the preventive station and the self-update fold already use.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the poll loop was really read", loop.contains("let typed = applySessionInput("))
    // READ OFF THIS CALL rather than off the whole file, for the reason the neighbouring suite
    // learned by mutation: a file-wide search for an argument name is satisfied by somebody else's
    // call and says nothing about this one.
    //
    // THE FACT IS ASKED THROUGH A NAME NOW, because two writers into that composer ask it (the
    // advisory knock joined the station, QuotaKnock.swift) and one spelling shared between them
    // cannot drift. So this is two assertions: the call is handed that name, and the name is this
    // session's own reading rather than a constant.
    if let start = loop.range(of: "let typed = applySessionInput("),
       let end = loop.range(of: "relaunchPlanned: replacingChild)",
                            range: start.upperBound ..< loop.endIndex) {
        let call = String(loop[start.lowerBound ..< end.upperBound])
        check("the gate is asked this session's own turn-end fact rather than a constant",
              call.contains("turnEnded: turnOver")
                  && loop.contains("let turnOver = { sessionTurnEnded(pid: supervisorPID, "
                      + "watcher: watcher) }"))
    } else {
        check("the gate is asked this session's own turn-end fact rather than a constant", false)
    }

    try? FileManager.default.removeItem(at: root)
}
