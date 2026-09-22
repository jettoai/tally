import Foundation

// H1 rerun B4 (Codex CLI 0.155.1, 2026-09-23): a `request_user_input` chooser stood open for two
// minutes and Tally emitted nothing. The rollout records the call when the chooser opens and its
// output when it is answered; these checks drive CodexSessionObserver and CodexWaitTracker through
// both, in the shapes that rollout wrote. Only API the pre-fix tree already had is used, so the
// file shows the gap when run against it. Helpers (`fixture`, `line`, `event`, `append`, `meta`,
// `start`, `sid`, `nextTurn`, `home`, `check`) are top-level in `main.swift`.
func runCodexWaitQuestionChecks() throws {
    let identity = SessionWaitIdentity(key: "codex:4343:1758575401000000", supervisorPid: 4343,
        supervisorStartedAt: 1758575401000000, childPid: 4344, transcriptSessionId: nil,
        launchNonce: "fresh", account: "acct", directory: nil, project: nil, worktree: nil)
    let prompt = CodexSessionActivity(nonce: "fresh", sessionID: sid, turnID: nextTurn,
        event: "UserPromptSubmit", at: start.addingTimeInterval(2))
    func call(_ id: String, name: String = "request_user_input", after: TimeInterval) throws -> Data {
        try line("response_item", ["type": "function_call", "id": "fc_\(id)", "name": name,
            "arguments": "{\"questions\":[]}", "call_id": id,
            "internal_chat_message_metadata_passthrough": ["turn_id": nextTurn]], after: after)
    }
    func output(_ id: String, after: TimeInterval) throws -> Data {
        try line("response_item", ["type": "function_call_output", "id": "fco_\(id)", "call_id": id,
            "output": "{\"answers\":{}}",
            "internal_chat_message_metadata_passthrough": ["turn_id": nextTurn]], after: after)
    }
    func tick(_ tracker: inout CodexWaitTracker, _ observer: CodexSessionObserver, at: TimeInterval) -> [SessionWaitEvent] {
        tracker.reconcile(observer: observer, directory: "/work/tally", project: "tally", worktree: nil,
                          now: start.addingTimeInterval(at))
    }

    var (file, observer) = try fixture("question-answered", contents: meta() + event("task_complete"))
    var tracker = CodexWaitTracker(identity: identity)
    observer.poll(home: home.path, activity: prompt)
    check("B4: a working turn with no question emits nothing", tick(&tracker, observer, at: 2).isEmpty)
    try append(call("call_q1", after: 3), to: file)
    observer.poll(home: home.path, activity: prompt)
    let opened = tick(&tracker, observer, at: 3)
    check("B4: an open request_user_input call opens one suspected question wait",
          opened.count == 1 && opened[0].kind == "wait.opened" && opened[0].provider == "codex"
              && opened[0].request?.kind == "question" && opened[0].request?.confidence == "suspected"
              && opened[0].request?.tool == "request_user_input"
              && opened[0].request?.since == start.addingTimeInterval(3)
              && opened[0].request?.summary == "Codex request_user_input call is open")
    check("B4: the standing question is not re-emitted", tick(&tracker, observer, at: 4).isEmpty)
    try append(output("call_other", after: 4), to: file)
    observer.poll(home: home.path, activity: prompt)
    check("B4: another call's output does not close it", tick(&tracker, observer, at: 4).isEmpty)
    try append(output("call_q1", after: 5), to: file)
    observer.poll(home: home.path, activity: prompt)
    let answered = tick(&tracker, observer, at: 5)
    check("B4: its own output resolves the question as answered",
          answered.count == 1 && answered[0].kind == "wait.resolved" && answered[0].resolution == "answered"
              && answered[0].request?.id == opened.first?.request?.id)

    var (abortFile, abortObserver) = try fixture("question-aborted", contents: meta() + event("task_complete"))
    var abortTracker = CodexWaitTracker(identity: identity)
    abortObserver.poll(home: home.path, activity: prompt)
    try append(call("call_q2", after: 3), to: abortFile)
    abortObserver.poll(home: home.path, activity: prompt)
    check("B4: a second question opens", tick(&abortTracker, abortObserver, at: 3).count == 1)
    try append(event("turn_aborted", turnID: nextTurn, after: 4), to: abortFile)
    abortObserver.poll(home: home.path, activity: prompt)
    let aborted = tick(&abortTracker, abortObserver, at: 4)
    check("B4: an interrupted turn resolves its question as unknown",
          aborted.count == 1 && aborted[0].kind == "wait.resolved" && aborted[0].resolution == "unknown")

    var (shellFile, shellObserver) = try fixture("question-shell", contents: meta() + event("task_complete"))
    var shellTracker = CodexWaitTracker(identity: identity)
    shellObserver.poll(home: home.path, activity: prompt)
    try append(call("call_s1", name: "shell", after: 3), to: shellFile)
    shellObserver.poll(home: home.path, activity: prompt)
    check("B4: any other function call opens nothing", tick(&shellTracker, shellObserver, at: 3).isEmpty)

    var (endFile, endObserver) = try fixture("question-finish", contents: meta() + event("task_complete"))
    var endTracker = CodexWaitTracker(identity: identity)
    endObserver.poll(home: home.path, activity: prompt)
    try append(call("call_q3", after: 3), to: endFile)
    endObserver.poll(home: home.path, activity: prompt)
    _ = tick(&endTracker, endObserver, at: 3)
    endObserver.invalidate()
    let ended = tick(&endTracker, endObserver, at: 4)
    check("B4: invalidating the binding resolves an open question as session-ended",
          ended.count == 1 && ended[0].resolution == "session-ended")
}
