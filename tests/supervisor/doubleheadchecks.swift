import Foundation

// ONE HEAD PER CONVERSATION ACROSS AN ACCOUNT MOVE (reported 2026-09-06: a `tally account` move
// left the directory with two Claude Codes on one conversation).
//
// Three mechanisms, asserted here because none of them had a single assertion before: nothing in
// this suite tree said a handoff terminates what the old child started, that it refuses to resume a
// conversation somebody else is writing, or what an open tool call means to a move somebody typed.
//
// Everything below is driven over values and temporary directories. The one place that reads the
// real machine is the process-table pass, which is asked only about THIS process and its parent -
// two processes that certainly exist and that nothing here signals.

func runDoubleHeadChecks() {
    // MARK: - 47a. A handoff does not resume a conversation somebody else is writing

    let stateDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-doublehead-state-\(UUID().uuidString)")
    // Empty, and injected everywhere: the union `liveConversations` takes includes the register
    // unsupervised launches write, and reading the real one would make these assertions depend on
    // what else is running on this machine (`unmanagedConversations`).
    let unmanagedDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-doublehead-unmanaged-\(UUID().uuidString)")
    let projectCwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-doublehead-cwd-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: unmanagedDir, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: projectCwd, withIntermediateDirectories: true)

    // THE TWO SUPERVISORS ARE REAL LIVE PIDS, and they have to be: the registry filters on
    // `supervisorAlive`, so a fixture pid that is not running registers as nothing at all. This
    // process stands in for the one performing the handoff and its parent for the sibling session
    // in the same directory. Neither is signalled by anything in this file.
    let ours = String(getpid())
    let sibling = String(getppid())
    let ourConversation = "11111111-2222-3333-4444-555555555555"
    let siblingConversation = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    markSupervisorLive(pid: ours, dir: stateDir)
    markSupervisorLive(pid: sibling, dir: stateDir)
    writeSupervisorCwd(projectCwd.path, pid: ours, dir: stateDir)
    writeSupervisorCwd(projectCwd.path, pid: sibling, dir: stateDir)
    let ourStamp = processStamp(getpid())
    let siblingStamp = processStamp(getppid())
    check("the machine names this process and its parent, which the witnesses below are built from",
          ourStamp != nil && siblingStamp != nil)
    if let ourStamp, let siblingStamp {
        // The status line's witness rather than the supervisor's publish, because it is the one a
        // young session has: the published context does not exist until a turn with a usage reading
        // in it, and two young sessions in one directory is exactly the gap this closes.
        writeTranscriptIdentity(TranscriptIdentity(id: ourConversation, claudeCode: ourStamp),
                                pid: ours, dir: stateDir)
        writeTranscriptIdentity(TranscriptIdentity(id: siblingConversation, claudeCode: siblingStamp),
                                pid: sibling, dir: stateDir)
    }

    check("both sessions in the directory are named as live writers",
          liveConversations(in: projectCwd.path, dir: stateDir, unmanagedDir: unmanagedDir)
              == [ourConversation, siblingConversation])
    // The half a handoff needs, and the half that did not exist: asking the question WITHOUT its
    // own answer in it. Unexcluded, every supervisor reads its own publish back and would refuse
    // every resume there is.
    check("excluding one supervisor drops its own conversation and nobody else's",
          liveConversations(in: projectCwd.path, excluding: ours, dir: stateDir,
                            unmanagedDir: unmanagedDir) == [siblingConversation])
    check("a directory nobody is working in names nothing",
          liveConversations(in: FileManager.default.temporaryDirectory.path, excluding: ours,
                            dir: stateDir, unmanagedDir: unmanagedDir).isEmpty)

    let elsewhere = liveConversations(in: projectCwd.path, excluding: ours, dir: stateDir,
                                      unmanagedDir: unmanagedDir)
    check("resuming this session's own conversation forks nothing",
          !resumeForksConversation(ourConversation, liveElsewhere: elsewhere))
    // The whole point: `adoptRequestedTranscript` and a resume that forked can both leave the
    // watcher on a sibling's file, and resuming it is the second head.
    check("resuming one another session is writing would put a second head on it",
          resumeForksConversation(siblingConversation, liveElsewhere: elsewhere))
    check("a session with no transcript at all has nothing to fork",
          !resumeForksConversation(nil, liveElsewhere: elsewhere))

    let notice = secondHeadNotice(conversation: siblingConversation, target: "Claude 2")
    check("the notice names the conversation left behind, cut to the eight characters every other "
          + "surface shows",
          notice.contains(siblingConversation.prefix(8)) && !notice.contains(siblingConversation))
    check("and the account the fresh window starts on instead", notice.contains("Claude 2"))
    let holdLine = secondHeadHoldLine(conversation: siblingConversation, pid: ours,
                                      cwd: projectCwd.path)
    check("the audit line carries the fields this log is grepped by",
          holdLine.contains("pid=\(ours)") && holdLine.contains("resume=declined")
              && holdLine.contains("reason=second-head") && holdLine.contains("cwd=\(projectCwd.path)"))
    check("and is one whole line", holdLine.hasSuffix("\n")
              && !holdLine.dropLast().contains(where: { $0 == "\n" }))
    check("neither surface writes an em dash",
          !notice.contains("—") && !holdLine.contains("—"))

    // MARK: - 47b. Which processes a handoff takes down with the child

    func proc(_ pid: pid_t, under parent: pid_t, startedAt: Int64 = 1_000) -> HandoffProcess {
        HandoffProcess(pid: pid, parent: parent, startedAt: startedAt)
    }
    // A supervisor, its child, the turn's `pnpm e2e` under a shell, and two processes that are
    // nobody's business here: a sibling session's child and a daemon.
    let table = [proc(10, under: 1), proc(100, under: 10), proc(200, under: 100),
                 proc(201, under: 100), proc(300, under: 200), proc(400, under: 10),
                 proc(401, under: 1)]
    let tree = Set(childTreeDescendants(of: 100, in: table).map(\.pid))
    check("everything the ended turn started is found, grandchildren included", tree == [200, 201, 300])
    check("the child is not in its own descendants", !tree.contains(100))
    check("a sibling under the same supervisor is not touched", !tree.contains(400))
    check("nor is a daemon that merely has no parent of ours", !tree.contains(401))
    check("and the supervisor doing the killing is never in the list", !tree.contains(10))
    check("a child that started nothing sweeps nothing",
          childTreeDescendants(of: 201, in: table).isEmpty)
    check("launchd is nobody's child, whatever a table says",
          childTreeDescendants(of: 1, in: table).isEmpty)
    check("an unknown pid finds nothing rather than everything",
          childTreeDescendants(of: 999, in: table).isEmpty)
    // The fail-safe direction, and the one the supervisor's own pid rides on: an excluded process
    // takes its subtree with it rather than having its children swept up around it.
    check("an excluded pid takes its own subtree with it",
          Set(childTreeDescendants(of: 100, in: table, excluding: [200]).map(\.pid)) == [201])
    check("and excluding the child itself sweeps nothing at all",
          childTreeDescendants(of: 100, in: table, excluding: [100]).isEmpty)
    // A pid tree has no cycles, which is why the guard costs nothing - it says so rather than
    // resting on it. Without `seen` this walk does not return.
    let cyclic = [proc(100, under: 10), proc(500, under: 100), proc(501, under: 500),
                  proc(500, under: 501)]
    check("a table describing a cycle is walked once and terminates",
          childTreeDescendants(of: 100, in: cyclic).map(\.pid) == [500, 501])

    // The identity check that stands between a two-second-old snapshot and a stranger's process.
    let recorded = proc(4242, under: 100, startedAt: 111)
    check("a pid the machine no longer answers for is not signalled",
          !stillTheSameProcess(recorded, asOf: nil))
    check("nor is a different process that inherited the number",
          !stillTheSameProcess(recorded, asOf: proc(4242, under: 1, startedAt: 999)))
    // Reparented onto launchd, which is what happens to every one of these the moment claude dies:
    // the parent has changed and it is still the same process.
    check("the process that was recorded is, however it was reparented since",
          stillTheSameProcess(recorded, asOf: proc(4242, under: 1, startedAt: 111)))

    // The one reading of the real machine, over two processes that certainly exist. It is here
    // because the pure walk above cannot see the trap that made the worktree scan undercount: a
    // pid buffer walked a quarter of the way through and a tree quietly missing its deepest half.
    let live = handoffProcessTable()
    check("the process table pass sees this very process", live.contains { $0.pid == getpid() })
    check("and names its parent the way the kernel does",
          live.first { $0.pid == getpid() }?.parent == getppid())
    check("a real parent's descendants include the process asking",
          childTreeDescendants(of: getppid(), in: live).contains { $0.pid == getpid() })
    let self1 = handoffProcess(getpid())
    check("a live pid reads the same identity twice",
          self1 != nil && stillTheSameProcess(self1!, asOf: handoffProcess(getpid())))

    check("one survivor is spoken of in the singular",
          handoffSurvivorNotice(count: 1).hasPrefix("1 process ")
              && handoffSurvivorNotice(count: 1).hasSuffix("ending it too"))
    check("and several in the plural",
          handoffSurvivorNotice(count: 3).hasPrefix("3 processes ")
              && handoffSurvivorNotice(count: 3).hasSuffix("ending them too"))
    check("with no em dash in either",
          !handoffSurvivorNotice(count: 1).contains("—")
              && !handoffSurvivorNotice(count: 3).contains("—"))

    // MARK: - 47c. What an open tool call means to a move somebody typed

    let childStart = Date(timeIntervalSince1970: 1_800_000_000)
    let ownCall = childStart.addingTimeInterval(60)       // opened by the running child
    let inherited = childStart.addingTimeInterval(-5)     // left behind by the child before it
    let twentyMinutesIn = childStart.addingTimeInterval(1_200)

    check("the ceiling has lapsed on a call that has been open for twenty minutes",
          !openTurnHoldsSession(openedAt: ownCall, now: twentyMinutesIn))
    // Which is the reported failure in one line: judged by that reading, the move fires INSIDE the
    // call, the turn's builds and servers are orphaned onto the account being left, and the resumed
    // conversation does the work again.
    check("the moving reading holds it, so the move waits for the turn rather than cutting it",
          openTurnHoldsMovingSession(openedAt: ownCall, childStartedAt: childStart))
    check("a call inherited from a dead child holds nothing, since nothing is running",
          !openTurnHoldsMovingSession(openedAt: inherited, childStartedAt: childStart))
    check("though the ceiling would have held that move for ten minutes over it",
          openTurnHoldsSession(openedAt: inherited, now: childStart.addingTimeInterval(10)))
    check("and no open call at all holds nothing, either way",
          !openTurnHoldsMovingSession(openedAt: nil, childStartedAt: childStart)
              && !openTurnHoldsSession(openedAt: nil, now: twentyMinutesIn))

    /// A session whose transcript ends in an unanswered `tool_use` opened at `openedAt`, watched by
    /// a child that started at `since`. The FILE is an hour stale, so every mtime bar passes and
    /// only what is in it can hold the session busy.
    func callWatcher(_ label: String, openedAt: Date, since: Date) -> TranscriptWatcher {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-doublehead-\(label)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        let opened = ISO8601DateFormatter().string(from: openedAt)
        try! (#"{"type":"assistant","timestamp":"\#(opened)","isSidechain":false,"#
              + #""message":{"content":[{"type":"tool_use","id":"toolu_move"}]}}"#)
            .write(to: file, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: file.path)
        return TranscriptWatcher(projectDir: dir, file: file, since: since)
    }

    let now = Date()
    var running = callWatcher("running", openedAt: now.addingTimeInterval(-1_200),
                              since: now.addingTimeInterval(-1_800))
    check("the ordinary reading calls a twenty-minute tool call an idle session",
          running.isQuiet(manualMoveIdleSeconds))
    check("the moving reading calls it busy, which is what keeps the move out of the turn",
          !running.isQuiet(manualMoveIdleSeconds, moving: true))
    var stale = callWatcher("stale", openedAt: now.addingTimeInterval(-60),
                            since: now.addingTimeInterval(-30))
    check("the ordinary reading holds a move behind a call a dead child left open",
          !stale.isQuiet(manualMoveIdleSeconds))
    check("the moving reading moves now instead of waiting ten minutes for nothing",
          stale.isQuiet(manualMoveIdleSeconds, moving: true))

    // AND THE GATE ITSELF ASKS THAT WAY, which the two readings above cannot say on their own: they
    // would stay green with the flag deleted from its one call site.
    let moveDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-doublehead-switch-\(UUID().uuidString)")
    func movePlan(_ watcher: inout TranscriptWatcher) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        var record: PendingSwitchConsumption?
        var policy = LaunchPolicy()
        var state = ManualMoveState(sessionKey: "doublehead", servedEpoch: 0, dir: moveDir)
        applyManualMoves(plan: &plan, state: &state, record: &record, policy: &policy,
                         account: switchAccount("A"), providerID: "claude", watcher: &watcher,
                         childAge: 9_999, keyboardIdle: { _ in true }, dir: moveDir,
                         request: { _ in SwitchRequest(epoch: 999, accountID: "B") },
                         accounts: { [switchAccount("A"), switchAccount("B")] },
                         homeOnDisk: { _, _ in true },
                         loaded: { switchFleetReading([switchAccount("A")]) },
                         quarantineIn: switchQuarantineDir)
        return plan
    }
    check("a typed move waits out a tool call this child is really inside",
          movePlan(&running) == nil)
    check("and is served at once by a session carrying a dead child's unanswered call",
          movePlan(&stale)?.target.id == "B")
}
