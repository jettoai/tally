import Foundation

// What may resolve a Claude wait as `answered`, and what a structured question is reported as,
// driven through the whole tick (`syncSessionState`) against a transcript, a notice and Claude
// Code's session registry on disk. Only API the pre-fix tree already had is used here, so the same
// file run against that tree shows every defect it pins (H1 rerun O4 and O5, Claude Code 2.1.280).

/// One supervised session's files: `<root>/cfg/projects/p/session.jsonl` (so the registry is at
/// `<root>/cfg/sessions/<childPid>.json`, where the tick looks for it) and a state dir for notices.
private final class WaitRig {
    let pid: String
    /// A var so a check can replace the child the way a cap handoff does (the registry follows it).
    var childPid = 70001
    let home: URL
    let state: URL
    let file: URL
    /// Where the tick's audit lines land, never the user's own `~/.tally/handoff.log`.
    let audit: URL
    var registry: URL { home.appendingPathComponent("cfg/sessions/\(childPid).json") }
    let now = Date()
    var watcher: TranscriptWatcher
    var tracker = SessionWaitTracker()
    var writer = SessionStateWriter()

    init(_ root: URL, _ name: String, pid: String) {
        self.pid = pid
        home = root.appendingPathComponent(name)
        let projects = home.appendingPathComponent("cfg/projects/p")
        state = home.appendingPathComponent("state")
        audit = home.appendingPathComponent("audit.log")
        for dir in [projects, state, home.appendingPathComponent("cfg/sessions")] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        file = projects.appendingPathComponent("session.jsonl")
        try! Data().write(to: file)
        watcher = TranscriptWatcher(projectDir: projects, file: file, since: now.addingTimeInterval(-600))
        watcher.auditLog = audit
    }

    /// A tracker that keeps its seed on disk, rebuilt from it: what a supervisor `execv` self-update
    /// does to a live one (same pid, fresh image).
    func reseed() {
        tracker = SessionWaitTracker(pid: pid, dir: state)
    }

    /// Everything the ticks have written to `audit` so far, empty when nothing has.
    var auditText: String {
        (try? String(contentsOf: audit, encoding: .utf8)) ?? ""
    }

    func stamp(_ ago: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(-ago))
    }

    func append(_ line: String, mtimeAgo: TimeInterval) {
        let handle = try! FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-mtimeAgo)],
                                               ofItemAtPath: file.path)
    }

    func notice(_ type: String, ago: TimeInterval, message: String) {
        writeUserNotice(UserNotice(message: message, at: now.addingTimeInterval(-ago), type: type),
                        pid: pid, dir: state)
    }

    /// `updatedAgo` writes `statusUpdatedAt` (epoch milliseconds, as Claude Code does); nil omits it.
    func registry(pid: Int? = nil, status: String, waitingFor: String?, updatedAgo: TimeInterval? = nil) {
        var object: [String: Any] = ["pid": pid ?? childPid, "status": status, "version": "2.1.280"]
        if let waitingFor { object["waitingFor"] = waitingFor }
        if let updatedAgo {
            object["statusUpdatedAt"] = Int((now.addingTimeInterval(-updatedAgo).timeIntervalSince1970 * 1000).rounded())
        }
        try! JSONSerialization.data(withJSONObject: object).write(to: registry)
    }

    /// `offset` moves the tick's own clock (the fixtures' stamps stay relative to `now`), so a
    /// check can put one tick before a notice and the next after it.
    func tick(burstAt: Date? = nil, at offset: TimeInterval = 0) -> [SessionWaitEvent] {
        _ = watcher.sawCapHit()
        var emitted: [SessionWaitEvent] = []
        syncSessionState(&writer, pid: pid, project: PickProject(name: "p", path: file.path),
                         accountID: "claude:.claude", childPid: childPid, model: nil,
                         supervisorVersion: nil, watcher: &watcher, keyboardBurstAt: burstAt,
                         tracker: &tracker, dir: state, now: now.addingTimeInterval(offset),
                         emit: { emitted += $0 })
        return emitted
    }

    /// A turn that ended with a plain text question two minutes ago: quiet, nothing open.
    func endedTurn() {
        append(#"{"parentUuid":"p0","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"\#(stamp(120))","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"Which one?"}],"stop_reason":"end_turn"}}"#,
               mtimeAgo: 120)
    }

    /// A turn holding a tool call open, the shape a permission or question dialog stands over.
    func openCall(_ name: String) {
        append(#"{"parentUuid":"p0","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"\#(stamp(30))","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":{}}],"stop_reason":"tool_use"}}"#,
               mtimeAgo: 30)
    }

    /// The stamped line Claude Code 2.1.280 wrote when auto mode was entered (H1 rerun A4b).
    func autoModeNotice(ago: TimeInterval) {
        append(#"{"parentUuid":"a1","isSidechain":false,"type":"system","subtype":"informational","level":"notice","content":"Auto mode lets Claude handle permission prompts automatically","uuid":"s1","timestamp":"\#(stamp(ago))"}"#,
               mtimeAgo: 0)
    }

    func typed(ago: TimeInterval) {
        append(#"{"parentUuid":"a1","isSidechain":false,"type":"user","promptSource":"typed","origin":{"kind":"human"},"uuid":"u1","timestamp":"\#(stamp(ago))","message":{"role":"user","content":"red"}}"#,
               mtimeAgo: 0)
    }

    /// A background task finishing: stamped and main-chain, but nobody typed it.
    func taskNotification(ago: TimeInterval) {
        append(#"{"parentUuid":"a1","isSidechain":false,"type":"user","promptSource":"system","origin":{"kind":"task-notification"},"uuid":"u2","timestamp":"\#(stamp(ago))","message":{"role":"user","content":"<task-notification>done</task-notification>"}}"#,
               mtimeAgo: 0)
    }

    /// A permission notice fired 20s ago over a dialog Claude Code's registry opened 6s before it
    /// (the lead measured in H1e O6), standing over an open call to `tool`.
    func heldDialog(_ tool: String, waitingFor: String = "permission prompt") -> [SessionWaitEvent] {
        openCall(tool)
        registry(status: "waiting", waitingFor: waitingFor, updatedAgo: 26)
        notice("permission_prompt", ago: 20, message: "Claude needs your permission")
        return tick()
    }

    /// The main turn running a tool of its own (no dialog) while another dialog stands: its call and
    /// its result, both main-chain, the result a `user` record with no origin (H1f B5t).
    func otherToolResult(ago: TimeInterval) {
        append(#"{"parentUuid":"a1","isSidechain":false,"type":"assistant","uuid":"a9","timestamp":"\#(stamp(ago + 0.5))","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"Read","input":{}}],"stop_reason":"tool_use"}}"#,
               mtimeAgo: 0)
        append(#"{"parentUuid":"a9","isSidechain":false,"type":"user","uuid":"u9","timestamp":"\#(stamp(ago))","message":{"role":"user","content":[{"tool_use_id":"toolu_9","type":"tool_result","content":"ok"}]}}"#,
               mtimeAgo: 0)
    }

    func assistantText(ago: TimeInterval) {
        append(#"{"parentUuid":"a1","isSidechain":false,"type":"assistant","uuid":"a8","timestamp":"\#(stamp(ago))","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"Still waiting on the agents."}],"stop_reason":"end_turn"}}"#,
               mtimeAgo: 0)
    }

    /// A refused agent carrying on: its own records, none of them main-chain.
    func sidechainWork(ago: TimeInterval) {
        append(#"{"parentUuid":"s0","isSidechain":true,"type":"assistant","uuid":"s7","timestamp":"\#(stamp(ago))","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"Trying another way."}],"stop_reason":"end_turn"}}"#,
               mtimeAgo: 0)
    }

    func toolResult(ago: TimeInterval) {
        append(#"{"parentUuid":"a1","isSidechain":false,"type":"user","uuid":"u1","timestamp":"\#(stamp(ago))","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]}}"#,
               mtimeAgo: 0)
    }
}

private func kinds(_ events: [SessionWaitEvent]) -> [String] { events.map(\.kind) }

func runWaitAnswerChecks() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-waitanswer-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    // MARK: - O4: a stamped `system` line is not an answer

    let idle = WaitRig(root, "idle", pid: "88901")
    idle.endedTurn()
    idle.notice("idle_prompt", ago: 60, message: "Claude is waiting for your input")
    let idleOpened = idle.tick()
    check("O4: an idle_prompt over a quiet transcript opens one unknown/suspected wait",
          kinds(idleOpened) == ["wait.opened"] && idleOpened[0].request?.kind == "unknown")
    idle.autoModeNotice(ago: 1)
    check("O4: a stamped system/informational line resolves nothing, and the fresh mtime does not either",
          idle.tick().isEmpty)
    check("O4: ...nor on the tick after", idle.tick().isEmpty)
    idle.typed(ago: 0.5)
    let idleAnswered = idle.tick()
    check("O4: the person typing resolves the same wait as answered",
          kinds(idleAnswered) == ["wait.resolved"] && idleAnswered[0].resolution == "answered"
              && idleAnswered[0].request?.id == idleOpened.first?.request?.id)

    let permission = WaitRig(root, "permission", pid: "88902")
    permission.openCall("Bash")
    permission.notice("permission_prompt", ago: 20, message: "Claude needs your permission")
    check("O4: a permission notice opens a wait", kinds(permission.tick()) == ["wait.opened"])
    permission.autoModeNotice(ago: 1)
    check("O4: a stamped system line newer than a permission notice resolves nothing",
          permission.tick().isEmpty)
    permission.toolResult(ago: 0.5)
    let permissionAnswered = permission.tick()
    check("O4: the dialog's tool result resolves it as answered",
          kinds(permissionAnswered) == ["wait.resolved"] && permissionAnswered[0].resolution == "answered")

    // The conversation moving without a person: a background task finishing wakes the session.
    let woken = WaitRig(root, "woken", pid: "88903")
    woken.endedTurn()
    woken.notice("idle_prompt", ago: 60, message: "Claude is waiting for your input")
    _ = woken.tick()
    woken.append(#"{"parentUuid":"a1","isSidechain":false,"type":"user","promptSource":"system","origin":{"kind":"task-notification"},"uuid":"u2","timestamp":"\#(woken.stamp(1))","message":{"role":"user","content":"<task-notification>done</task-notification>"}}"#,
                 mtimeAgo: 0)
    let wokenResolved = woken.tick()
    check("O4: a task notification ends the wait, as unknown rather than answered",
          kinds(wokenResolved) == ["wait.resolved"] && wokenResolved[0].resolution == "unknown")

    // MARK: - O5: a structured question behind a permission_prompt

    let asked = WaitRig(root, "asked", pid: "88904")
    asked.append(#"{"parentUuid":"p0","isSidechain":false,"type":"user","promptSource":"typed","origin":{"kind":"human"},"uuid":"u0","timestamp":"\#(asked.stamp(40))","message":{"role":"user","content":"ask me"}}"#,
                 mtimeAgo: 40)
    asked.registry(status: "waiting", waitingFor: "input needed")
    asked.notice("permission_prompt", ago: 20, message: "Claude needs your permission")
    let askedOpened = asked.tick()
    check("O5: a permission_prompt over the registry's structured question dialog opens a question",
          kinds(askedOpened) == ["wait.opened"] && askedOpened[0].request?.kind == "question"
              && askedOpened[0].request?.confidence == "confirmed"
              && askedOpened[0].request?.tool == "AskUserQuestion"
              && askedOpened[0].request?.noticeType == "permission_prompt")
    asked.toolResult(ago: 0.5)
    asked.registry(status: "busy", waitingFor: nil)
    let askedAnswered = asked.tick()
    check("O5: its answer resolves the question as answered",
          kinds(askedAnswered) == ["wait.resolved"] && askedAnswered[0].resolution == "answered"
              && askedAnswered[0].request?.kind == "question")

    // The same question answered while the registry still says its dialog is up: not the answer.
    let unanswered = WaitRig(root, "asked-guard", pid: "88908")
    unanswered.registry(status: "waiting", waitingFor: "input needed")
    unanswered.notice("permission_prompt", ago: 20, message: "Claude needs your permission")
    _ = unanswered.tick()
    unanswered.toolResult(ago: 0.5)
    check("O5 guard: a question's tool result while the registry still says waiting resolves nothing",
          unanswered.tick().isEmpty)

    let late = WaitRig(root, "late", pid: "88905")
    late.openCall("Bash")
    late.notice("permission_prompt", ago: 20, message: "Claude needs your permission")
    let lateOpened = late.tick()
    check("O5: with no registry reading the notice opens as a permission",
          kinds(lateOpened) == ["wait.opened"] && lateOpened[0].request?.kind == "permission")
    late.registry(status: "waiting", waitingFor: "input needed")
    let lateUpdated = late.tick()
    check("O5: a registry reading a tick late updates the same wait to a question",
          kinds(lateUpdated) == ["wait.updated"] && lateUpdated[0].request?.kind == "question"
              && lateUpdated[0].request?.id == lateOpened.first?.request?.id)
    try? FileManager.default.removeItem(at: late.registry)
    check("O5: a registry read that fails later does not flap it back to a permission",
          late.tick().isEmpty)

    let bash = WaitRig(root, "bash", pid: "88906")
    bash.openCall("Bash")
    bash.registry(status: "waiting", waitingFor: "permission prompt")
    bash.notice("permission_prompt", ago: 20, message: "Claude needs your permission")
    let bashOpened = bash.tick()
    check("O5: the registry's permission dialog stays a permission",
          kinds(bashOpened) == ["wait.opened"] && bashOpened[0].request?.kind == "permission")

    let stranger = WaitRig(root, "stranger", pid: "88907")
    stranger.openCall("Bash")
    stranger.registry(pid: 1, status: "waiting", waitingFor: "input needed")
    stranger.notice("permission_prompt", ago: 20, message: "Claude needs your permission")
    let strangerOpened = stranger.tick()
    check("O5: a registry record naming another pid is not read",
          kinds(strangerOpened) == ["wait.opened"] && strangerOpened[0].request?.kind == "permission")

    runDialogHoldChecks(root)
}

/// H1e O6: a dialog Claude Code's registry says is still open is not closed by conversation
/// activity nobody typed. Rows are the O6 brief's state table.
private func runDialogHoldChecks(_ root: URL) {
    // Row 1: main-turn permission, a task notification lands while it stands.
    let main = WaitRig(root, "hold-main", pid: "88910")
    check("O6 row 1: a permission over a fresh registry dialog opens",
          kinds(main.heldDialog("Bash")) == ["wait.opened"])
    main.taskNotification(ago: 1)
    check("O6 row 1: a task notification does not resolve it", main.tick().isEmpty)
    check("O6 row 1: ...and its notice is still on disk", readUserNotice(pid: main.pid, dir: main.state) != nil)

    // Row 2: the O6 original, a background subagent's dialog under a main turn waiting on agents.
    let agent = WaitRig(root, "hold-agent", pid: "88911")
    let agentOpened = agent.heldDialog("Agent")
    agent.taskNotification(ago: 1)
    check("O6 row 2: the sibling agent's task notification does not resolve it", agent.tick().isEmpty)
    check("O6 row 2: ...nor on the tick after", agent.tick().isEmpty)
    agent.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
    let agentResolved = agent.tick()
    check("O6 row 2: the registry leaving waiting resolves the same wait, as answered",
          kinds(agentResolved) == ["wait.resolved"] && agentResolved[0].resolution == "answered"
              && agentResolved[0].request?.id == agentOpened.first?.request?.id)

    // Row 3: a typed record while the registry still says waiting: the dialog is still on top, so
    // the person still has to answer it, and only the registry saying it closed ends the wait.
    let typed = WaitRig(root, "hold-typed", pid: "88912")
    _ = typed.heldDialog("Bash")
    typed.taskNotification(ago: 2)
    typed.typed(ago: 0.5)
    check("O6 row 3: a typed record while the registry still says waiting resolves nothing",
          typed.tick().isEmpty)
    typed.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
    let typedResolved = typed.tick()
    check("O6 row 3: it resolves answered once the registry leaves waiting",
          kinds(typedResolved) == ["wait.resolved"] && typedResolved[0].resolution == "answered")

    // Row 5: the structured question kind of dialog is held the same way.
    let question = WaitRig(root, "hold-question", pid: "88913")
    let questionOpened = question.heldDialog("Agent", waitingFor: "input needed")
    question.taskNotification(ago: 1)
    check("O6 row 5: a held question survives a task notification",
          questionOpened.first?.request?.kind == "question" && question.tick().isEmpty)

    // Row 10: keys pressed while the dialog stays open (moving its selection) do not answer it.
    let keys = WaitRig(root, "hold-keys", pid: "88914")
    _ = keys.heldDialog("Bash")
    check("O6 row 10: a keyboard burst over a held dialog resolves nothing",
          keys.tick(burstAt: keys.now.addingTimeInterval(-1)).isEmpty)
    keys.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
    let keysResolved = keys.tick(burstAt: keys.now.addingTimeInterval(-1))
    check("O6 row 10: once the registry leaves waiting the burst-era wait resolves as answered",
          kinds(keysResolved) == ["wait.resolved"] && keysResolved[0].resolution == "answered")

    // Row 8: a record naming another pid is no reading at all, so the rule before O6 decides. The
    // stamp is not an input: whatever `statusUpdatedAt` says, this child's `waiting` holds.
    let fallbacks: [(String, Int?, TimeInterval?)] = [
        ("another pid", 1, 26), ("no statusUpdatedAt", nil, nil),
        ("a waiting stretch begun 61s before the notice", nil, 81),
        ("a status changed after the notice", nil, 10),
    ]
    for (index, (label, otherPid, updatedAgo)) in fallbacks.enumerated() {
        let rig = WaitRig(root, "hold-fallback-\(index)", pid: "8892\(index)")
        rig.openCall("Bash")
        rig.registry(pid: otherPid, status: "waiting", waitingFor: "permission prompt", updatedAgo: updatedAgo)
        rig.notice("permission_prompt", ago: 20, message: "Claude needs your permission")
        _ = rig.tick()
        rig.taskNotification(ago: 1)
        let resolved = rig.tick()
        if otherPid != nil {
            check("O6 row 8: with \(label) a task notification still resolves the wait as unknown",
                  kinds(resolved) == ["wait.resolved"] && resolved[0].resolution == "unknown")
        } else {
            check("O6 row 8: with \(label) the registry's waiting still holds", resolved.isEmpty)
        }
    }

    runRegistryCloserChecks(root)
}

/// H1f B5t and B1x: while Claude Code's registry can speak it alone decides whether the dialog is
/// open, both ways. Only the registry leaving `waiting` after having said it for this wait closes it.
private func runRegistryCloserChecks(_ root: URL) {
    // B5t: a background agent's dialog up, the main turn runs a Read of its own.
    let b5t = WaitRig(root, "b5t", pid: "88930")
    let b5tOpened = b5t.heldDialog("Agent")
    b5t.otherToolResult(ago: 0.5)
    check("B5t: a main-chain tool result of ANOTHER call while the registry still says waiting "
            + "resolves nothing, and the notice stays on disk",
          b5t.tick().isEmpty && readUserNotice(pid: b5t.pid, dir: b5t.state) != nil)
    b5t.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
    let b5tResolved = b5t.tick()
    check("B5t: ...and the registry leaving waiting then resolves it as answered",
          kinds(b5tResolved) == ["wait.resolved"] && b5tResolved[0].resolution == "answered"
              && b5tResolved[0].request?.id == b5tOpened.first?.request?.id)

    // B1x: a lone agent's dialog refused with Esc; the agent keeps running and never finishes, the
    // main chain is not written and nobody presses a second key.
    let b1x = WaitRig(root, "b1x", pid: "88931")
    check("B1x: the agent's dialog opens", kinds(b1x.heldDialog("Agent")) == ["wait.opened"])
    check("B1x: ...and stands while the registry says waiting", b1x.tick().isEmpty)
    b1x.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
    b1x.sidechainWork(ago: 0.2)
    let b1xResolved = b1x.tick()
    check("B1x: with nothing written to the main chain, no burst and the refused agent still running, "
            + "the registry leaving waiting resolves the wait on the next tick, as answered",
          kinds(b1xResolved) == ["wait.resolved"] && b1xResolved[0].resolution == "answered")
    check("B1x: ...once, with the notice taken off disk",
          b1x.tick().isEmpty && readUserNotice(pid: b1x.pid, dir: b1x.state) == nil)

    // Restart: a supervisor self-update (execv, same pid) mid-dialog, then the Esc.
    let restart = WaitRig(root, "restart", pid: "88932")
    restart.reseed()
    let restartOpened = restart.heldDialog("Agent")
    restart.reseed()
    check("restart: a re-seeded tracker still holds the dialog", restart.tick().isEmpty)
    restart.reseed()
    restart.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
    let restartResolved = restart.tick()
    check("restart: a tracker re-seeded from disk mid-dialog still closes on the registry leaving "
            + "waiting, as answered",
          kinds(restartResolved) == ["wait.resolved"] && restartResolved[0].resolution == "answered"
              && restartResolved[0].request?.id == restartOpened.first?.request?.id)

    // Replaced child: the witness names the old child; the new one's registry knows nothing of it.
    let replaced = WaitRig(root, "replaced", pid: "88933")
    _ = replaced.heldDialog("Agent")
    replaced.childPid = 70002
    replaced.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
    check("replaced child: a witness bound to pid 70001 does not let pid 70002's non-waiting registry "
            + "close the wait", replaced.tick().isEmpty)

    // Never waiting: a readable registry that never said `waiting` for this notice.
    let drift = WaitRig(root, "never-waiting", pid: "88934")
    drift.openCall("Bash")
    drift.registry(status: "busy", waitingFor: nil, updatedAgo: 30)
    drift.notice("permission_prompt", ago: 20, message: "Claude needs your permission")
    check("never waiting: the notice still opens a wait", kinds(drift.tick()) == ["wait.opened"])
    drift.taskNotification(ago: 1)
    let driftResolved = drift.tick()
    check("never waiting: a registry that is readable but never said waiting leaves the older rules "
            + "in charge (a task notification resolves it as unknown)",
          kinds(driftResolved) == ["wait.resolved"] && driftResolved[0].resolution == "unknown")
    let driftLines = drift.auditText.split(separator: "\n").filter { $0.contains("closed by legacy rules; registry v2.1.280 never said waiting") }
    check("never waiting: the fallback leaves exactly one drift line in the audit log",
          driftLines.count == 1 && driftLines[0].contains(driftResolved.first?.request?.id ?? "?"))
    check("never waiting: a witnessed close leaves no drift line", !b1x.auditText.contains("never said waiting"))

    // idle_prompt: a soft notice is not a dialog, whatever the registry says.
    let soft = WaitRig(root, "soft-registry", pid: "88935")
    soft.endedTurn()
    soft.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 70)
    soft.notice("idle_prompt", ago: 60, message: "Claude is waiting for your input")
    check("idle_prompt: a soft notice opens its unknown wait", kinds(soft.tick()) == ["wait.opened"])
    soft.taskNotification(ago: 1)
    let softResolved = soft.tick()
    check("idle_prompt: a soft notice is judged by the older rules even when a registry says waiting",
          kinds(softResolved) == ["wait.resolved"] && softResolved[0].resolution == "unknown")

    // B5: the main turn's own reply while an agent's dialog stands.
    let reply = WaitRig(root, "b5-reply", pid: "88936")
    _ = reply.heldDialog("Agent")
    reply.assistantText(ago: 0.5)
    check("B5 guard: a main-chain assistant text while the registry says waiting resolves nothing",
          reply.tick().isEmpty)

    // A5: no notice, so the registry alone never opens anything.
    let quiet = WaitRig(root, "a5", pid: "88937")
    quiet.endedTurn()
    quiet.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 5)
    check("A5: with no notice standing a registry saying waiting opens nothing", quiet.tick().isEmpty)

    // WITNESS SWAP (codex line review of 4d015c9): A was witnessed, then B took the notice slot
    // (hard over hard replaces) while the registry had already left `waiting` BEFORE B's notice
    // fired (so nothing proves B's dialog was ever up and answered): B must not borrow A's
    // handshake, it is judged by the older rules.
    let swap = WaitRig(root, "witness-swap", pid: "88938")
    let swapA = swap.heldDialog("Agent")
    swap.notice("permission_prompt", ago: 10, message: "Claude needs your permission")
    swap.registry(status: "busy", waitingFor: nil, updatedAgo: 15)
    let swapped = swap.tick()
    let swapB = readUserNotice(pid: swap.pid, dir: swap.state)
    check("witness swap: B replacing a witnessed A under a busy registry supersedes A and opens B",
          kinds(swapped) == ["wait.resolved", "wait.opened"] && swapped[0].resolution == "superseded"
              && swapped[0].request?.id == swapA.first?.request?.id
              && swapped.count == 2 && swapped[1].request?.since == swapB?.at)
    check("witness swap: ...and B's notice stays on disk", swapB != nil)
    swap.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 0)
    check("witness swap: B stands once the registry says waiting", swap.tick().isEmpty)
    swap.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
    let swapClosed = swap.tick()
    check("witness swap: B, witnessed on its own, closes on the registry as answered",
          kinds(swapClosed) == ["wait.resolved"] && swapClosed[0].resolution == "answered"
              && swapped.count == 2 && swapClosed[0].request?.id == swapped[1].request?.id)
    // The registry-blind kind (plan §5 row 22): an elicitation replacing a witnessed permission.
    let blind = WaitRig(root, "witness-swap-blind", pid: "88939")
    _ = blind.heldDialog("Agent")
    blind.notice("elicitation_dialog", ago: 1, message: "An MCP server needs your input")
    blind.registry(status: "idle", waitingFor: nil, updatedAgo: 0)
    let blindTick = blind.tick()
    check("witness swap: an elicitation replacing a witnessed permission under an idle registry opens",
          kinds(blindTick) == ["wait.resolved", "wait.opened"] && blindTick.count == 2
              && blindTick[1].request?.kind == "question"
              && readUserNotice(pid: blind.pid, dir: blind.state) != nil)

    // The wider path (plan §5 row 22): a registry-blind kind takes the slot while A's dialog is
    // STILL up, so the registry's `waiting` that tick is A's. B must not bank it as its own witness
    // and close as answered once A goes; it stays with the older rules.
    for (index, kind) in ["worker_permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
                          "agent_needs_input"].enumerated() {
        let rig = WaitRig(root, "witness-blind-\(kind)", pid: "8895\(index)")
        _ = rig.heldDialog("Agent")
        rig.notice(kind, ago: 1, message: "Claude needs your input")
        let swapTick = rig.tick()
        check("witness blind \(kind): replacing a witnessed permission while the registry says waiting opens it",
              kinds(swapTick).last == "wait.opened" && swapTick.last?.request?.since
                  == readUserNotice(pid: rig.pid, dir: rig.state)?.at)
        rig.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
        check("witness blind \(kind): A's dialog closing (registry busy) does not resolve it as answered, "
                + "and its notice stays on disk",
              rig.tick().isEmpty && readUserNotice(pid: rig.pid, dir: rig.state)?.type == kind)
    }

    // An older build's seed could bank a witness for an unmeasured kind. It is void on read, so the
    // registry leaving `waiting` cannot close that kind as answered after a self-update.
    let legacy = WaitRig(root, "witness-legacy-seed", pid: "88954")
    legacy.reseed()
    _ = legacy.heldDialog("Agent")
    let seedFile = legacy.state.appendingPathComponent("\(legacy.pid).waitopen")
    let held = readUserNotice(pid: legacy.pid, dir: legacy.state)!
    var seed = try! JSONSerialization.jsonObject(with: Data(contentsOf: seedFile)) as! [String: Any]
    var seededRequest = seed["request"] as! [String: Any]
    var seededWitness = seed["witness"] as! [String: Any]
    let blindID = sessionWaitRequestID(sessionKey: "claude:0:0", kind: "question",
                                       noticeType: "elicitation_dialog", since: held.at)
    seededRequest["kind"] = "question"
    seededRequest["noticeType"] = "elicitation_dialog"
    seededRequest["id"] = blindID
    seededWitness["requestID"] = blindID
    seed["request"] = seededRequest
    seed["witness"] = seededWitness
    try! JSONSerialization.data(withJSONObject: seed).write(to: seedFile)
    writeUserNotice(UserNotice(message: "An MCP server needs your input", at: held.at, type: "elicitation_dialog"),
                    pid: legacy.pid, dir: legacy.state)
    legacy.reseed()
    legacy.registry(status: "busy", waitingFor: nil, updatedAgo: 0)
    let legacyTick = legacy.tick()
    check("witness legacy seed: a seeded witness for an elicitation does not close it as answered when "
            + "the registry leaves waiting, and its notice stays on disk",
          !legacyTick.contains { $0.resolution == "answered" }
              && readUserNotice(pid: legacy.pid, dir: legacy.state)?.type == "elicitation_dialog")

    // The drift tripwire is for measured kinds only: an unmeasured kind never earns a witness, so
    // the older rules closing it is expected rather than a registry whose vocabulary moved.
    let blindDrift = WaitRig(root, "blind-drift", pid: "88955")
    blindDrift.openCall("Bash")
    blindDrift.registry(status: "busy", waitingFor: nil, updatedAgo: 30)
    blindDrift.notice("elicitation_dialog", ago: 20, message: "An MCP server needs your input")
    check("blind drift: an elicitation under a readable registry opens", kinds(blindDrift.tick()) == ["wait.opened"])
    blindDrift.taskNotification(ago: 1)
    check("blind drift: the older rules close it and leave no drift line in the audit log",
          kinds(blindDrift.tick()) == ["wait.resolved"] && !blindDrift.auditText.contains("never said waiting"))

    runFastAnswerChecks(root)
}

/// O15: a dialog answered after its notice fired but before the next tick read the registry. The
/// tick before the notice saw `waiting`; the tick after sees the registry already past it.
private func runFastAnswerChecks(_ root: URL) {
    func driftLines(_ rig: WaitRig) -> Int {
        rig.auditText.split(separator: "\n").filter { $0.contains("never said waiting") }.count
    }
    let asked = "Claude needs your permission"

    // L form (O15 L1, L2): a lone background agent's first notice, Esc 35 ms later, main chain silent.
    let lone = WaitRig(root, "fast-lone", pid: "88960")
    lone.openCall("Agent")
    lone.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 8)
    check("fast L: the tick before the notice opens nothing", lone.tick(at: -2).isEmpty)
    lone.notice("permission_prompt", ago: 1.5, message: asked)
    let loneNotice = readUserNotice(pid: lone.pid, dir: lone.state)
    lone.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4)
    lone.sidechainWork(ago: 1)
    let loneTick = lone.tick()
    check("fast L: the next tick opens the notice's wait and resolves it as answered in the same tick",
          kinds(loneTick) == ["wait.opened", "wait.resolved"] && loneTick.count == 2
              && loneTick[0].request?.since == loneNotice?.at && loneTick[0].request?.kind == "permission"
              && loneTick[1].resolution == "answered" && loneTick[1].request?.id == loneTick[0].request?.id)
    check("fast L: ...its notice is off disk and the session is not blocked",
          readUserNotice(pid: lone.pid, dir: lone.state) == nil
              && readSessionState(pid: lone.pid, dir: lone.state)?.state != "blocked")
    lone.taskNotification(ago: 0.5)
    check("fast L: the agent's own task notification later resolves nothing more", lone.tick().isEmpty)
    check("fast L: ...and no drift line was written", driftLines(lone) == 0)

    // R form (O15 R2): A then B queued in one stretch, A stopped, B re-announced, Esc on B at once.
    let renotice = WaitRig(root, "fast-renotice", pid: "88961")
    renotice.openCall("Agent")
    renotice.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 29)
    renotice.notice("permission_prompt", ago: 23, message: asked)
    check("fast R: A's notice opens", kinds(renotice.tick(at: -22)) == ["wait.opened"])
    renotice.notice("permission_prompt", ago: 13, message: asked)
    let bOpened = renotice.tick(at: -12)
    check("fast R: B's queued notice supersedes A and opens B while the registry says waiting",
          kinds(bOpened) == ["wait.resolved", "wait.opened"] && bOpened[0].resolution == "superseded")
    check("fast R: ...and B stands on the tick before its re-notice", renotice.tick(at: -3).isEmpty)
    renotice.notice("permission_prompt", ago: 1.5, message: asked)
    renotice.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4)
    renotice.sidechainWork(ago: 1)
    let rTick = renotice.tick()
    check("fast R: Esc on B's re-notice before the next tick resolves B's own request as answered and "
            + "opens nothing",
          kinds(rTick) == ["wait.resolved"] && rTick[0].resolution == "answered"
              && rTick[0].request?.id == bOpened.last?.request?.id)
    check("fast R: ...its notice is off disk and the session is not blocked",
          readUserNotice(pid: renotice.pid, dir: renotice.state) == nil
              && readSessionState(pid: renotice.pid, dir: renotice.state)?.state != "blocked")
    renotice.taskNotification(ago: 0.5)
    check("fast R: B's task notification later resolves nothing more, and no drift line was written",
          renotice.tick().isEmpty && driftLines(renotice) == 0)

    // A new stretch no tick saw begin: the standing request's dialog may be gone, but this notice is
    // not provably its re-announcement, so the standing one is superseded and the notice's own wait
    // opens and is answered.
    let restretch = WaitRig(root, "fast-new-stretch", pid: "88962")
    restretch.openCall("Agent")
    restretch.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 29)
    restretch.notice("permission_prompt", ago: 23, message: asked)
    let xOpened = restretch.tick(at: -22)
    restretch.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 9)
    _ = restretch.tick(at: -3)
    restretch.notice("permission_prompt", ago: 1.5, message: asked)
    restretch.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4)
    let restretchTick = restretch.tick()
    check("fast new stretch: supersedes the standing request, then opens and answers the notice's own",
          kinds(restretchTick) == ["wait.resolved", "wait.opened", "wait.resolved"]
              && restretchTick[0].resolution == "superseded"
              && restretchTick[0].request?.id == xOpened.first?.request?.id
              && restretchTick[2].resolution == "answered"
              && restretchTick[2].request?.id == restretchTick[1].request?.id)

    // The structured question kind, answered before the next tick: its call and result land at once.
    let question = WaitRig(root, "fast-question", pid: "88963")
    question.openCall("Agent")
    question.registry(status: "waiting", waitingFor: "input needed", updatedAgo: 8)
    _ = question.tick(at: -2)
    question.notice("permission_prompt", ago: 1.5, message: asked)
    question.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4)
    question.toolResult(ago: 1.2)
    let questionTick = question.tick()
    check("fast question: opens as the structured question and resolves answered in the same tick",
          kinds(questionTick) == ["wait.opened", "wait.resolved"] && questionTick[0].request?.kind == "question"
              && questionTick[0].request?.tool == "AskUserQuestion" && questionTick[1].resolution == "answered")

    // The main turn's own dialog refused at once: the turn is interrupted and the main chain moves,
    // which the older rules alone read as closed without the wait ever being published.
    let main = WaitRig(root, "fast-main", pid: "88964")
    main.openCall("Bash")
    main.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 8)
    _ = main.tick(at: -2)
    main.notice("permission_prompt", ago: 1.5, message: asked)
    main.registry(status: "idle", waitingFor: nil, updatedAgo: 1.4)
    main.toolResult(ago: 1.2)
    let mainTick = main.tick()
    check("fast main: a main-turn dialog refused before the next tick is still published, opened and answered",
          kinds(mainTick) == ["wait.opened", "wait.resolved"] && mainTick[1].resolution == "answered")

    // The late answer (O15 C1): a tick saw the dialog up, so the handshake closes it as before.
    let late = WaitRig(root, "fast-control", pid: "88965")
    late.openCall("Agent")
    late.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 10)
    _ = late.tick(at: -6)
    late.notice("permission_prompt", ago: 4, message: asked)
    let lateOpened = late.tick(at: -3.5)
    late.registry(status: "busy", waitingFor: nil, updatedAgo: 0.5)
    let lateClosed = late.tick()
    check("fast control: a dialog a tick saw open opens once, then resolves answered on the registry",
          kinds(lateOpened) == ["wait.opened"] && kinds(lateClosed) == ["wait.resolved"]
              && lateClosed[0].resolution == "answered"
              && lateClosed[0].request?.id == lateOpened.first?.request?.id)

    // STILL OPEN: stamped after the notice but still `waiting` is a dialog on screen.
    let still = WaitRig(root, "fast-still-open", pid: "88966")
    still.openCall("Agent")
    still.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 8)
    _ = still.tick(at: -2)
    still.notice("permission_prompt", ago: 1.5, message: asked)
    still.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 1)
    let stillTick = still.tick()
    still.sidechainWork(ago: 0.5)
    check("fast guard: a registry still saying waiting, even stamped after the notice, opens the wait and "
            + "closes nothing",
          kinds(stillTick) == ["wait.opened"] && still.tick().isEmpty
              && readUserNotice(pid: still.pid, dir: still.state) != nil)

    // EVERY SHAPE THAT MUST NOT PROVE IT: each leaves the older rules in charge, so the notice opens
    // a wait that stands (exactly the pre-O15 behaviour; in these fixtures that is late).
    let unproved: [(String, (WaitRig) -> Void)] = [
        ("the registry left waiting before the notice fired", { rig in
            rig.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 8)
            _ = rig.tick(at: -2)
            rig.notice("permission_prompt", ago: 1.5, message: asked)
            rig.registry(status: "busy", waitingFor: nil, updatedAgo: 1.6) }),
        ("the reading after carries no statusUpdatedAt", { rig in
            rig.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 8)
            _ = rig.tick(at: -2)
            rig.notice("permission_prompt", ago: 1.5, message: asked)
            rig.registry(status: "busy", waitingFor: nil) }),
        ("the tick before could not read the registry", { rig in
            _ = rig.tick(at: -2)
            rig.notice("permission_prompt", ago: 1.5, message: asked)
            rig.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4) }),
        ("the tick before saw a registry that was not waiting", { rig in
            rig.registry(status: "busy", waitingFor: nil, updatedAgo: 30)
            _ = rig.tick(at: -2)
            rig.notice("permission_prompt", ago: 1.5, message: asked)
            rig.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4) }),
        ("the tick before saw another child's waiting", { rig in
            rig.childPid = 70002
            rig.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 8)
            _ = rig.tick(at: -2)
            rig.childPid = 70001
            rig.notice("permission_prompt", ago: 1.5, message: asked)
            rig.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4) }),
        ("the waiting stretch began less than 5 s before the notice", { rig in
            rig.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 4)
            _ = rig.tick(at: -2)
            rig.notice("permission_prompt", ago: 1.5, message: asked)
            rig.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4) }),
        ("the tick that saw waiting ran 5 s or more before the notice", { rig in
            rig.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 14)
            _ = rig.tick(at: -8)
            rig.notice("permission_prompt", ago: 1.5, message: asked)
            rig.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4) }),
        ("a supervisor self-update between the two ticks", { rig in
            rig.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 8)
            _ = rig.tick(at: -2)
            rig.reseed()
            rig.notice("permission_prompt", ago: 1.5, message: asked)
            rig.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4) }),
    ]
    for (index, (label, setUp)) in unproved.enumerated() {
        let rig = WaitRig(root, "fast-unproved-\(index)", pid: "8897\(index)")
        rig.openCall("Agent")
        setUp(rig)
        let opened = rig.tick()
        check("fast unproved (\(label)): the notice opens a wait that stands",
              kinds(opened) == ["wait.opened"] && rig.tick().isEmpty
                  && readUserNotice(pid: rig.pid, dir: rig.state) != nil)
    }
    // Unmeasured kinds never ride the proof, whatever the registry said around them.
    for (index, kind) in ["worker_permission_prompt", "elicitation_dialog", "agent_needs_input"].enumerated() {
        let rig = WaitRig(root, "fast-unmeasured-\(kind)", pid: "8898\(index)")
        rig.openCall("Agent")
        rig.registry(status: "waiting", waitingFor: "permission prompt", updatedAgo: 8)
        _ = rig.tick(at: -2)
        rig.notice(kind, ago: 1.5, message: asked)
        rig.registry(status: "busy", waitingFor: nil, updatedAgo: 1.4)
        check("fast unmeasured \(kind): the notice opens a wait that stands",
              kinds(rig.tick()) == ["wait.opened"] && rig.tick().isEmpty)
    }

    // O16: a witnessed request whose notice was replaced, closed by the older rules because the fast
    // answer cannot be proved (no stamp), heard `waiting`; that is not drift.
    let o16 = WaitRig(root, "fast-o16", pid: "88990")
    let o16A = o16.heldDialog("Agent")
    o16.notice("permission_prompt", ago: 10, message: asked)
    o16.registry(status: "busy", waitingFor: nil)
    o16.taskNotification(ago: 1)
    let o16Tick = o16.tick()
    check("O16: the older rules closing a witnessed request after its notice was replaced write no drift line",
          o16Tick.first?.kind == "wait.resolved" && o16Tick.first?.request?.id == o16A.first?.request?.id
              && driftLines(o16) == 0)
}
