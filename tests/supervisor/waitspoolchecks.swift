import Foundation

// W1: the tick's DEFAULT event wiring, end to end. Every other check in this suite hands
// `syncSessionState` an `emit` closure and reads what it was given, so the default one (append to
// `~/.tally/events/spool.jsonl`, SessionStateSync.swift) was only ever exercised by a live session.
// Here a child process (this binary re-executed, see the top of `main.swift`) runs under
// `CFFIXED_USER_HOME=<tmp>`, ticks three rigs WITHOUT an `emit` argument, finishes the last one the
// way the supervisor's exit path does, and the parent reads the spool that landed in `<tmp>`.
// Only API that predates 68e8049 is used, so this file compiled into that commit's parent shows the
// structured question read as a permission (H1c A3).

let waitSpoolChildEnvKey = "TALLY_SUPERVISOR_WAITSPOOL_CHILD"

/// One supervised session's files, the same layout `waitanswerchecks.swift`'s rig uses: the
/// transcript at `<home>/cfg/projects/p/session.jsonl`, Claude Code's registry at
/// `<home>/cfg/sessions/<childPid>.json`, notices in `<home>/state`.
private final class SpoolRig {
    let pid: String
    let childPid = 70001
    let home: URL
    let state: URL
    let file: URL
    let now = Date()
    var watcher: TranscriptWatcher
    var tracker = SessionWaitTracker()
    var writer = SessionStateWriter()

    init(_ root: URL, _ name: String, pid: String) {
        self.pid = pid
        home = root.appendingPathComponent(name)
        let projects = home.appendingPathComponent("cfg/projects/p")
        state = home.appendingPathComponent("state")
        for dir in [projects, state, home.appendingPathComponent("cfg/sessions")] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        file = projects.appendingPathComponent("session.jsonl")
        try! Data().write(to: file)
        watcher = TranscriptWatcher(projectDir: projects, file: file, since: now.addingTimeInterval(-600))
        watcher.auditLog = home.appendingPathComponent("audit.log")
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

    func notice(_ type: String, ago: TimeInterval) {
        writeUserNotice(UserNotice(message: "Claude needs your attention", at: now.addingTimeInterval(-ago),
                                   type: type), pid: pid, dir: state)
    }

    func registry(waitingFor: String) {
        let object: [String: Any] = ["pid": childPid, "status": "waiting", "waitingFor": waitingFor,
                                     "version": "2.1.280"]
        try! JSONSerialization.data(withJSONObject: object)
            .write(to: home.appendingPathComponent("cfg/sessions/\(childPid).json"))
    }

    /// One tick with NO `emit` argument: whatever it decides goes through the default wiring.
    func tick() {
        _ = watcher.sawCapHit()
        syncSessionState(&writer, pid: pid, project: PickProject(name: "p", path: file.path),
                         accountID: "claude:.claude", childPid: childPid, model: nil,
                         supervisorVersion: nil, watcher: &watcher, keyboardBurstAt: nil,
                         tracker: &tracker, dir: state, now: now)
    }
}

/// Child side: three waits opened through the default wiring, then the supervisor's exit loop.
func runWaitSpoolChild(root: URL) -> Never {
    let permission = SpoolRig(root, "permission", pid: "88961")
    permission.append(#"{"parentUuid":"p0","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"\#(permission.stamp(30))","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}],"stop_reason":"tool_use"}}"#,
                      mtimeAgo: 30)
    permission.registry(waitingFor: "permission prompt")
    permission.notice("permission_prompt", ago: 20)
    permission.tick()

    let question = SpoolRig(root, "question", pid: "88962")
    question.append(#"{"parentUuid":"p0","isSidechain":false,"type":"user","promptSource":"typed","origin":{"kind":"human"},"uuid":"u0","timestamp":"\#(question.stamp(40))","message":{"role":"user","content":"ask me"}}"#,
                    mtimeAgo: 40)
    question.registry(waitingFor: "input needed")
    question.notice("permission_prompt", ago: 20)
    question.tick()

    let idle = SpoolRig(root, "idle", pid: "88963")
    idle.append(#"{"parentUuid":"p0","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"\#(idle.stamp(120))","message":{"model":"claude-opus-5","role":"assistant","content":[{"type":"text","text":"Which one?"}],"stop_reason":"end_turn"}}"#,
                mtimeAgo: 120)
    idle.notice("idle_prompt", ago: 60)
    idle.tick()

    // The supervisor's own exit path (Supervisor.swift): the tracker's closing events, appended.
    let reason = SessionEndReason(supervisorSignal: SIGHUP, childStatus: SIGHUP)
    for event in idle.tracker.finish(now: Date(), reason: reason) { appendSessionWaitEvent(event) }
    exit(0)
}

func runWaitSpoolChecks() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-waitspool-\(UUID().uuidString)")
    let home = root.appendingPathComponent("home")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var env = ProcessInfo.processInfo.environment
    env[waitSpoolChildEnvKey] = root.appendingPathComponent("rigs").path
    env["CFFIXED_USER_HOME"] = home.path
    child.environment = env
    child.standardOutput = FileHandle.nullDevice
    try? child.run()
    child.waitUntilExit()

    let events = readSessionWaitEvents(since: 0, dir: home.appendingPathComponent(".tally/events"))
    let summary = events.map { "\($0.seq):\($0.kind):\($0.request?.kind ?? "-")/\($0.request?.confidence ?? "-")" }
    check("W1: the child ticking with the default emit exits 0", child.terminationStatus == 0)
    check("W1: the default emit lands opened x3, resolved, ended in the child's own ~/.tally/events spool (\(summary))",
          events.map(\.kind) == ["wait.opened", "wait.opened", "wait.opened", "wait.resolved", "session.ended"])
    let opened = events.filter { $0.kind == "wait.opened" }.compactMap(\.request)
    check("W1: permission_prompt over the registry's permission dialog lands as permission/confirmed",
          opened.count == 3 && opened[0].kind == "permission" && opened[0].confidence == "confirmed")
    check("W1: permission_prompt over the registry's \"input needed\" lands as question/confirmed/AskUserQuestion",
          opened.count == 3 && opened[1].kind == "question" && opened[1].confidence == "confirmed"
              && opened[1].tool == "AskUserQuestion")
    check("W1: idle_prompt over a quiet transcript lands as unknown/suspected",
          opened.count == 3 && opened[2].kind == "unknown" && opened[2].confidence == "suspected")
    check("W1: finish lands the standing wait as session-ended, then session.ended last",
          events.count == 5 && events[3].resolution == "session-ended"
              && events[3].request?.id == opened.last?.id && events[4].kind == "session.ended")
    check("W1: the spooled seqs are contiguous from 1 (\(events.map(\.seq)))", events.map(\.seq) == [1, 2, 3, 4, 5])
    check("W1: session.ended carries its reason through the spool, and no other kind carries one",
          events.last?.reason == SessionEndReason(supervisorSignal: SIGHUP, childStatus: SIGHUP)
              && events.dropLast().allSatisfy { $0.reason == nil })
    let endedLine = events.last.flatMap { try? sessionWaitEventEncoder().encode($0) }
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check("W1: the line `tally events` prints spells the reason out (\(endedLine))",
          endedLine.contains(#""reason":{"#) && endedLine.contains(#""supervisorSignal":1"#)
              && endedLine.contains(#""childSignal":1"#))
}
