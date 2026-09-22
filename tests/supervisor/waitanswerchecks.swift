import Foundation

// What may resolve a Claude wait as `answered`, and what a structured question is reported as,
// driven through the whole tick (`syncSessionState`) against a transcript, a notice and Claude
// Code's session registry on disk. Only API the pre-fix tree already had is used here, so the same
// file run against that tree shows every defect it pins (H1 rerun O4 and O5, Claude Code 2.1.280).

/// One supervised session's files: `<root>/cfg/projects/p/session.jsonl` (so the registry is at
/// `<root>/cfg/sessions/<childPid>.json`, where the tick looks for it) and a state dir for notices.
private final class WaitRig {
    let pid: String
    let childPid = 70001
    let state: URL
    let file: URL
    let registry: URL
    let now = Date()
    var watcher: TranscriptWatcher
    var tracker = SessionWaitTracker()
    var writer = SessionStateWriter()

    init(_ root: URL, _ name: String, pid: String) {
        self.pid = pid
        let home = root.appendingPathComponent(name)
        let projects = home.appendingPathComponent("cfg/projects/p")
        state = home.appendingPathComponent("state")
        registry = home.appendingPathComponent("cfg/sessions/\(childPid).json")
        for dir in [projects, state, registry.deletingLastPathComponent()] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        file = projects.appendingPathComponent("session.jsonl")
        try! Data().write(to: file)
        watcher = TranscriptWatcher(projectDir: projects, file: file, since: now.addingTimeInterval(-600))
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

    func registry(pid: Int? = nil, status: String, waitingFor: String?) {
        var object: [String: Any] = ["pid": pid ?? childPid, "status": status, "version": "2.1.280"]
        if let waitingFor { object["waitingFor"] = waitingFor }
        try! JSONSerialization.data(withJSONObject: object).write(to: registry)
    }

    func tick() -> [SessionWaitEvent] {
        _ = watcher.sawCapHit()
        var emitted: [SessionWaitEvent] = []
        syncSessionState(&writer, pid: pid, project: PickProject(name: "p", path: file.path),
                         accountID: "claude:.claude", childPid: childPid, model: nil,
                         supervisorVersion: nil, watcher: &watcher, keyboardBurstAt: nil,
                         tracker: &tracker, dir: state, now: now, emit: { emitted += $0 })
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
    let askedAnswered = asked.tick()
    check("O5: its answer resolves the question as answered",
          kinds(askedAnswered) == ["wait.resolved"] && askedAnswered[0].resolution == "answered"
              && askedAnswered[0].request?.kind == "question")

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
}
