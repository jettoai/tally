import Foundation

// SessionWaitTracker's §4.3 restart path (SessionStateSync.swift): a seed file whose
// `identity.key` does not match this generation's own is a STALE leftover from a previous
// supervisor generation for the same pid, and the tracker's first `reconcile` must resolve it
// `session-ended` under its OWN (stale) identity - never silently adopted as this generation's
// `open`. Regression for the mutation this file's own header used to prove (§4.3, flipping
// `seed.identity.key == identity.key` to `!=`): the flipped comparison wrongly adopts the stale
// seed as `open`, so the first tick resolves it through the ORDINARY path (`resolvedWaitOutcome`
// -> `.unknown`, stamped under the NEW identity) instead of the forced stale-restart path. This was
// P3's own scratch probe (`p3-findings.md`'s "Variant self-proof"); this file is that probe made
// permanent, per the follow-up brief's own instruction.
//
// The second half (seed file's key MATCHES this generation's own) is the ordinary seed-recovery
// path: a self-update `execv` keeps the pid, so the new process image has to recover a standing
// wait from disk rather than start blind (`SessionWaitTracker`'s own header states why).

func runWaitTrackerChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-waittracker-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_800_000_500)

    /// The private `SessionWaitTracker.SessionWaitSeed` shape, reproduced field-for-field (that
    /// type is private to `SessionStateSync.swift`): `{identity: SessionWaitIdentity, request:
    /// SessionWaitRequest}`, encoded with the same `sessionWaitEventEncoder()` every writer on this
    /// track uses.
    struct SeedProbe: Codable {
        var identity: SessionWaitIdentity
        var request: SessionWaitRequest
    }

    func writeSeed(pid: String, identity: SessionWaitIdentity, request: SessionWaitRequest) {
        let file = dir.appendingPathComponent("\(pid).waitopen")
        let data = try! sessionWaitEventEncoder().encode(SeedProbe(identity: identity, request: request))
        try! data.write(to: file, options: .atomic)
    }

    /// A tick with nothing standing at all: no notice, no open question, quiet. The one shape every
    /// assertion below drives `reconcile` with, because what is under test is what a tracker DOES
    /// with a seed it read at construction, not any particular live signal.
    func reconcileNoWait(_ tracker: inout SessionWaitTracker) -> [SessionWaitEvent] {
        tracker.reconcile(childPid: nil, transcriptSessionId: nil, accountID: nil, directory: nil,
                          project: nil, worktree: nil, notice: nil, waiting: false, question: nil,
                          questionSince: nil, quiet: true, wait: nil, conversationMovedAt: nil, now: now)
    }

    // MARK: - A seed for a DIFFERENT generation of the same pid (the stale-restart path)

    let stalePid = "88881"
    let staleIdentity = SessionWaitIdentity(key: "claude:1:111", supervisorPid: 1, supervisorStartedAt: 111,
                                            childPid: nil, transcriptSessionId: nil, launchNonce: nil,
                                            account: nil, directory: nil, project: nil, worktree: nil)
    let staleRequest = SessionWaitRequest(id: sessionWaitRequestID(sessionKey: staleIdentity.key,
                                                                    kind: "permission", noticeType: "permission_prompt",
                                                                    since: now.addingTimeInterval(-30)),
                                          kind: "permission", confidence: "suspected",
                                          since: now.addingTimeInterval(-30), noticeType: "permission_prompt",
                                          tool: "Bash", summary: "test permission")
    writeSeed(pid: stalePid, identity: staleIdentity, request: staleRequest)

    // A fresh generation (pid 88881, but a NEW supervisorPid/supervisorStartedAt) constructing over
    // that file: its own identity.key ("claude:2:222") does not match the seed's ("claude:1:111"),
    // so the seed is read as `staleSeed`, not adopted as `open`.
    var staleTracker = SessionWaitTracker(pid: stalePid, supervisorPid: 2, supervisorStartedAt: 222, dir: dir)
    let firstTick = reconcileNoWait(&staleTracker)
    check("a stale seed resolves as exactly one session-ended event on the first tick",
          firstTick.count == 1 && firstTick[0].kind == "wait.resolved" && firstTick[0].resolution == "session-ended")
    check("...stamped under the STALE seed's own key, not the new generation's",
          firstTick[0].session.key == "claude:1:111")
    check("...and carries no wait.updated alongside it",
          !firstTick.contains { $0.kind == "wait.updated" })

    let secondTick = reconcileNoWait(&staleTracker)
    check("the same tracker's next tick, with nothing standing, emits nothing",
          secondTick.isEmpty)

    // MARK: - A seed for THIS generation of a different pid (the ordinary seed-recovery path)

    let recoverPid = "88882"
    let recoverIdentity = SessionWaitIdentity(key: "claude:2:222", supervisorPid: 2, supervisorStartedAt: 222,
                                              childPid: nil, transcriptSessionId: nil, launchNonce: nil,
                                              account: nil, directory: nil, project: nil, worktree: nil)
    let recoverRequest = SessionWaitRequest(id: sessionWaitRequestID(sessionKey: recoverIdentity.key,
                                                                      kind: "permission", noticeType: "permission_prompt",
                                                                      since: now.addingTimeInterval(-10)),
                                            kind: "permission", confidence: "suspected",
                                            since: now.addingTimeInterval(-10), noticeType: "permission_prompt",
                                            tool: "Read", summary: "another permission")
    writeSeed(pid: recoverPid, identity: recoverIdentity, request: recoverRequest)

    // Constructed with the SAME supervisorPid/supervisorStartedAt the seed itself carries, so
    // `identity.key` matches and the seed is adopted as `open` rather than treated as stale.
    var recoverTracker = SessionWaitTracker(pid: recoverPid, supervisorPid: 2, supervisorStartedAt: 222, dir: dir)
    let recoverTick = reconcileNoWait(&recoverTracker)
    check("a same-generation seed with nothing standing now resolves as exactly one event",
          recoverTick.count == 1 && recoverTick[0].kind == "wait.resolved")
    check("...under this generation's own key, not a stale one",
          recoverTick[0].session.key == "claude:2:222")
    check("...with the resolution `resolvedWaitOutcome` gives a nil transcript and no closed question",
          recoverTick[0].resolution == resolvedWaitOutcome(request: recoverRequest, conversationMovedAt: nil,
                                                            questionClosed: false).rawValue)

    // MARK: - What answers a wait: a stamped conversation event, not the file's mtime

    // THE DEFECT THIS PINS (H1 sandbox, Claude Code 2.1.280): an idle Claude Code appends an
    // unstamped `cost-state` record with nobody at the keyboard, the file's mtime passes the notice,
    // and the tick read that as the answer (`wait.resolved` answered, 16s later, nobody there).
    // Driven through the whole tick in the supervisor's own order (scan, then publish) against a
    // transcript on disk, so it is the clock the tick READS that is under test, not a value fed in.
    let clockHome = dir.appendingPathComponent("clock-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: clockHome, withIntermediateDirectories: true)
    let clockFile = clockHome.appendingPathComponent("session.jsonl")
    let realNow = Date()
    let stamper = ISO8601DateFormatter()
    stamper.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func stamp(_ ago: TimeInterval) -> String { stamper.string(from: realNow.addingTimeInterval(-ago)) }
    func append(_ line: String, mtimeAgo: TimeInterval) {
        let handle = try! FileHandle(forWritingTo: clockFile)
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
        try? FileManager.default.setAttributes([.modificationDate: realNow.addingTimeInterval(-mtimeAgo)],
                                               ofItemAtPath: clockFile.path)
    }
    // The turn that asked: a Bash call still open, written before the permission notice fired.
    try! Data().write(to: clockFile)
    append(#"{"parentUuid":"p0","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"\#(stamp(30))","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}],"stop_reason":"tool_use"}}"#,
           mtimeAgo: 30)
    let clockPid = "88890"
    let clockNotice = UserNotice(message: "Claude needs your permission to use Bash",
                                 at: realNow.addingTimeInterval(-20), type: "permission_prompt")
    writeUserNotice(clockNotice, pid: clockPid, dir: dir)
    var clockWatcher = TranscriptWatcher(projectDir: clockHome, file: clockFile,
                                         since: realNow.addingTimeInterval(-600))
    var clockTracker = SessionWaitTracker()
    var clockWriter = SessionStateWriter()
    func clockTick() -> [SessionWaitEvent] {
        _ = clockWatcher.sawCapHit()
        var emitted: [SessionWaitEvent] = []
        syncSessionState(&clockWriter, pid: clockPid,
                         project: PickProject(name: "p", path: clockHome.path),
                         accountID: "claude:.claude", childPid: nil, model: nil,
                         supervisorVersion: nil, watcher: &clockWatcher, keyboardBurstAt: nil,
                         tracker: &clockTracker, dir: dir, now: realNow, emit: { emitted += $0 })
        return emitted
    }
    let opened = clockTick()
    check("a permission notice nobody has answered opens exactly one wait",
          opened.filter { $0.kind == "wait.opened" }.count == 1
              && !opened.contains { $0.kind == "wait.resolved" })

    // (a) Bookkeeping only: the mtime passes the notice, no stamped event does.
    append(#"{"type":"cost-state","sessionId":"s1","totalCostUSD":0.4,"totalDuration":128853}"#, mtimeAgo: 5)
    let afterBookkeeping = clockTick()
    check("an unstamped cost-state record newer than the notice resolves nothing",
          !afterBookkeeping.contains { $0.kind == "wait.resolved" })
    check("...the notice is left standing, because the wait is still open",
          readUserNotice(pid: clockPid, dir: dir) != nil)
    check("...and the session still publishes blocked",
          readSessionState(pid: clockPid, dir: dir)?.supervised == .blocked)
    check("...and the clock the tick reads says the conversation has not moved past the notice",
          userNoticeStillOpen(clockNotice, conversationMovedAt: clockWatcher.lastConversationEventAt,
                              keyboardBurstAt: nil))

    // (b) The person answers: a stamped main-chain tool result newer than the notice.
    append(#"{"parentUuid":"a1","isSidechain":false,"type":"user","uuid":"u1","timestamp":"\#(stamp(2))","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]}}"#,
           mtimeAgo: 1)
    let afterAnswer = clockTick()
    check("a stamped tool result newer than the notice resolves the wait as answered",
          afterAnswer.filter { $0.kind == "wait.resolved" }.map(\.resolution) == ["answered"])
    check("...and the answered notice is taken away",
          readUserNotice(pid: clockPid, dir: dir) == nil)

    // MARK: - SIGHUP/SIGTERM end a Claude supervisor through its exit path (SupervisorTermination.swift)

    // The handler and the forward, against a real child: the whole supervisor loop spawns a real
    // Claude Code and cannot be driven here, so the loop's use of them is locked on the source below.
    var sleeperPid: pid_t = 0
    var sleeperArgv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
    let spawnResult = posix_spawn(&sleeperPid, "/bin/sleep", nil, nil, &sleeperArgv, environ)
    var sleeper = ChildReaper(pid: sleeperPid)
    check("with no termination signal, nothing is forwarded",
          spawnResult == 0 && !forwardSupervisorTermination(to: sleeper))
    installSupervisorTerminationHandlers()
    raise(SIGTERM)
    check("a SIGTERM is recorded rather than killing the supervisor",
          supervisorTerminationSignal == SIGTERM)
    check("...and is forwarded to the child still running",
          forwardSupervisorTermination(to: sleeper))
    let sleeperStatus = sleeper.wait()
    check("...which the child dies of", (sleeperStatus & 0x7f) == SIGTERM)
    signal(SIGTERM, SIG_DFL)
    signal(SIGHUP, SIG_DFL)
    let loopSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let forwardAt = loopSource.range(of: "if forwardSupervisorTermination(to: child) { break }")
    let tickAt = loopSource.range(of: "if autoreleasepool(invoking: tick) == .childReplaced { break }")
    check("the Claude loop installs the handlers and checks the flag before every tick",
          loopSource.contains("installSupervisorTerminationHandlers()")
              && forwardAt != nil && tickAt != nil && forwardAt!.lowerBound < tickAt!.lowerBound)
    check("...and a signalled supervisor does not relaunch, it takes the exit path",
          loopSource.contains("if handoff, supervisorTerminationSignal == 0 { continue }"))

    try? FileManager.default.removeItem(at: dir)
}
