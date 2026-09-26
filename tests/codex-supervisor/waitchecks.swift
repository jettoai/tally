import Foundation

// T14/T14b (plan §12, P5/P5b): CodexSessionObserver's `pendingPermission`/`lastPermissionOutcome`
// bookkeeping around a `PermissionRequest` hook, and CodexWaitTracker turning that bookkeeping into
// `SessionWaitEvent`s for the spool. Split out of `main.swift` once that file passed the 500-line
// advisory cap (`hooks/check-long-file.sh`); everything this function references (`file`, `observer`,
// `home`, `start`, `sid`, `turn`, `nextTurn`, `fixture`, `event`, `meta`, `append`, `check`) is a
// top-level declaration in `main.swift` and stays visible here in the same compiled closure
// (`tests/run-codex-supervisor-tests.sh`'s swiftc invocation compiles both files together).
func runCodexWaitPermissionChecks() throws {
    // Restore an independent completed-turn fixture for the checks below.
    (file, observer) = try fixture("root-after-input-checks", contents: meta() + event("task_complete"))
    observer.poll(home: home.path)

    check("terminal event proves idle", observer.state == .idle)
    let prompt = CodexSessionActivity(nonce: "fresh", sessionID: sid, turnID: nextTurn,
        event: "UserPromptSubmit", at: start.addingTimeInterval(2))
    observer.poll(home: home.path, activity: prompt)
    check("next root prompt starts working before rollout flush", observer.state == .working)
    let permission = CodexSessionActivity(nonce: "fresh", sessionID: sid, turnID: nextTurn,
        event: "PermissionRequest", at: start.addingTimeInterval(3))
    observer.poll(home: home.path, activity: permission)
    check("permission hook does not claim a human is blocked", observer.state == .unknown)
    try append(event("turn_aborted", turnID: nextTurn, after: 4), to: file)
    observer.poll(home: home.path, activity: permission)
    check("abort completes the matching active turn", observer.state == .idle)
    observer.poll(home: home.path, activity: prompt)
    check("late prompt receipt cannot reopen a completed turn", observer.state == .idle)

    // A PermissionRequest opens a pending permission without ever changing the board's own state,
    // and a terminal record for the same turn is what closes it again.
    var (permFile, permObserver) = try fixture("permission-lifecycle", contents: meta() + event("task_complete"))
    let permPrompt = CodexSessionActivity(nonce: "fresh", sessionID: sid, turnID: nextTurn,
        event: "UserPromptSubmit", at: start.addingTimeInterval(2))
    permObserver.poll(home: home.path, activity: permPrompt)
    let permRequest = CodexSessionActivity(nonce: "fresh", sessionID: sid, turnID: nextTurn,
        event: "PermissionRequest", at: start.addingTimeInterval(3), tool: "shell")
    permObserver.poll(home: home.path, activity: permRequest)
    check("permission request leaves the board state unknown", permObserver.state == .unknown)
    check("permission request opens a pending permission for its own turn with the hook's tool name",
          permObserver.pendingPermission?.turnID == nextTurn && permObserver.pendingPermission?.tool == "shell")
    try append(event("task_complete", turnID: nextTurn, after: 4), to: permFile)
    permObserver.poll(home: home.path, activity: permRequest)
    check("a terminal record for the same turn clears the pending permission as turn-ended",
          permObserver.pendingPermission == nil && permObserver.lastPermissionOutcome?.turnID == nextTurn
          && permObserver.lastPermissionOutcome?.reason == "turn-ended")

    // A prompt for a different turn proves the pending permission's own turn moved on, even though
    // no terminal record for that turn ever arrived.
    var (moveFile, moveObserver) = try fixture("permission-turn-moved", contents: meta() + event("task_complete"))
    let moveFirstPrompt = CodexSessionActivity(nonce: "fresh", sessionID: sid, turnID: nextTurn,
        event: "UserPromptSubmit", at: start.addingTimeInterval(2))
    moveObserver.poll(home: home.path, activity: moveFirstPrompt)
    let movePermission = CodexSessionActivity(nonce: "fresh", sessionID: sid, turnID: nextTurn,
        event: "PermissionRequest", at: start.addingTimeInterval(3), tool: "shell")
    moveObserver.poll(home: home.path, activity: movePermission)
    check("a second fixture's permission is pending before its turn moves on",
          moveObserver.pendingPermission?.turnID == nextTurn)
    let anotherTurn = UUID().uuidString
    let movePrompt = CodexSessionActivity(nonce: "fresh", sessionID: sid, turnID: anotherTurn,
        event: "UserPromptSubmit", at: start.addingTimeInterval(4))
    moveObserver.poll(home: home.path, activity: movePrompt)
    check("a different turn's prompt clears the stale pending permission as turn-moved",
          moveObserver.pendingPermission == nil && moveObserver.lastPermissionOutcome?.turnID == nextTurn
          && moveObserver.lastPermissionOutcome?.reason == "turn-moved")
    _ = moveFile

    // T14b: the supervisor-side tracker turns the observer's pending permission into wait events and
    // never touches the spool itself (the supervisor appends what it returns).
    let waitIdentity = SessionWaitIdentity(key: "codex:4242:1758575401000000", supervisorPid: 4242,
        supervisorStartedAt: 1758575401000000, childPid: 4243, transcriptSessionId: nil,
        launchNonce: "fresh", account: "acct", directory: nil, project: nil, worktree: nil)
    func tick(_ tracker: inout CodexWaitTracker, _ observer: CodexSessionObserver?, at: TimeInterval) -> [SessionWaitEvent] {
        tracker.reconcile(observer: observer, directory: "/work/tally", project: "tally", worktree: nil,
                          now: start.addingTimeInterval(at))
    }
    var unboundTracker = CodexWaitTracker(identity: waitIdentity)
    check("no observer means no wait events", tick(&unboundTracker, nil, at: 1).isEmpty)
    var (waitFile, waitObserver) = try fixture("wait-events", contents: meta() + event("task_complete"))
    var waitTracker = CodexWaitTracker(identity: waitIdentity)
    waitObserver.poll(home: home.path, activity: CodexSessionActivity(nonce: "fresh", sessionID: sid,
        turnID: nextTurn, event: "UserPromptSubmit", at: start.addingTimeInterval(2)))
    check("a working turn without a permission emits nothing", tick(&waitTracker, waitObserver, at: 2).isEmpty)
    let waitPermission = CodexSessionActivity(nonce: "fresh", sessionID: sid, turnID: nextTurn,
        event: "PermissionRequest", at: start.addingTimeInterval(3), tool: "shell")
    waitObserver.poll(home: home.path, activity: waitPermission)
    let opened = tick(&waitTracker, waitObserver, at: 3)
    check("permission request opens exactly one suspected permission wait",
          opened.count == 1 && opened[0].kind == "wait.opened" && opened[0].provider == "codex"
          && opened[0].request?.kind == "permission" && opened[0].request?.confidence == "suspected"
          && opened[0].request?.tool == "shell" && opened[0].request?.since == start.addingTimeInterval(3))
    check("opened event carries the neutral summary and the live session identity",
          opened.first?.request?.summary == codexPermissionSummary && opened.first?.session.key == waitIdentity.key
          && opened.first?.session.transcriptSessionId == sid && opened.first?.session.project == "tally"
          && opened.first?.resolution == nil && !(opened.first?.idempotencyKey.isEmpty ?? true))
    check("the same standing permission is not re-emitted on the next tick", tick(&waitTracker, waitObserver, at: 4).isEmpty)
    try append(event("task_complete", turnID: nextTurn, after: 5), to: waitFile)
    waitObserver.poll(home: home.path, activity: waitPermission)
    let resolved = tick(&waitTracker, waitObserver, at: 5)
    check("a terminal record for the turn resolves the wait as unknown",
          resolved.count == 1 && resolved[0].kind == "wait.resolved" && resolved[0].resolution == "unknown"
          && resolved[0].request?.id == opened[0].request?.id && resolved[0].idempotencyKey != opened[0].idempotencyKey)
    check("nothing standing after the resolution emits nothing", tick(&waitTracker, waitObserver, at: 6).isEmpty)

    var (invalidFile, invalidObserver) = try fixture("wait-invalidated", contents: meta() + event("task_complete"))
    var invalidTracker = CodexWaitTracker(identity: waitIdentity)
    invalidObserver.poll(home: home.path, activity: CodexSessionActivity(nonce: "fresh", sessionID: sid,
        turnID: nextTurn, event: "UserPromptSubmit", at: start.addingTimeInterval(2)))
    invalidObserver.poll(home: home.path, activity: waitPermission)
    check("a second tracker opens its own permission wait", tick(&invalidTracker, invalidObserver, at: 3).count == 1)
    invalidObserver.invalidate()
    let invalidated = tick(&invalidTracker, invalidObserver, at: 4)
    check("invalidating the binding resolves the wait as session-ended",
          invalidated.count == 1 && invalidated[0].kind == "wait.resolved" && invalidated[0].resolution == "session-ended")
    _ = invalidFile

    var (finishFile, finishObserver) = try fixture("wait-finish", contents: meta() + event("task_complete"))
    var finishTracker = CodexWaitTracker(identity: waitIdentity)
    finishObserver.poll(home: home.path, activity: CodexSessionActivity(nonce: "fresh", sessionID: sid,
        turnID: nextTurn, event: "UserPromptSubmit", at: start.addingTimeInterval(2)))
    finishObserver.poll(home: home.path, activity: waitPermission)
    _ = tick(&finishTracker, finishObserver, at: 3)
    let finished = finishTracker.finish(now: start.addingTimeInterval(4))
    check("finishing with a standing wait resolves it as session-ended before session.ended",
          finished.map(\.kind) == ["wait.resolved", "session.ended"] && finished[0].resolution == "session-ended"
          && finished[1].request == nil && finished[1].resolution == nil && finished[1].session.key == waitIdentity.key)
    var idleTracker = CodexWaitTracker(identity: waitIdentity)
    let reason = SessionEndReason(supervisorSignal: 15, childStatus: 15)
    let idleEnd = idleTracker.finish(now: start, reason: reason)
    check("finishing with nothing standing emits only session.ended", idleEnd.map(\.kind) == ["session.ended"])
    check("session.ended carries the reason it was given", idleEnd.last?.reason == reason)
    let codexSource = (try? String(contentsOfFile: "TallyCLI/CodexSupervisor.swift", encoding: .utf8)) ?? ""
    check("the Codex supervisor builds that reason from its received signal and the child's wait status",
          codexSource.contains("SessionEndReason(supervisorSignal: codexSupervisorSignal, childStatus: status)")
              && codexSource.contains("codexWaits.finish(now: Date(), reason: endReason)"))
    _ = finishFile
}
