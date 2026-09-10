import Darwin
import Foundation

func runCodexMonitoringChecks() {
    typealias Identity = (parent: pid_t, name: String, startedAt: Int64)
    var ancestry: [pid_t: Identity] = [
        100: (99, "tally", 1), 200: (100, "node", 2), 300: (200, "codex", 3),
        400: (300, "sh", 4), 500: (400, "tally", 5)]
    check("official npm launcher directly owns the native root Codex",
          codexHookBelongsToChild(500, child: 200, supervisor: 100, identityOf: { ancestry[$0] }))
    check("direct native Codex retains its hook ownership",
          codexHookBelongsToChild(500, child: 300, supervisor: 200, identityOf: { ancestry[$0] }))
    check("a launcher under a different supervisor is rejected",
          !codexHookBelongsToChild(500, child: 200, supervisor: 99, identityOf: { ancestry[$0] }))
    ancestry[600] = (400, "codex", 6)
    ancestry[700] = (600, "tally", 7)
    check("nested native Codex cannot claim the outer npm launcher",
          !codexHookBelongsToChild(700, child: 200, supervisor: 100, identityOf: { ancestry[$0] }))
    ancestry[600] = (400, "node", 6)
    ancestry[700] = (600, "codex", 7)
    ancestry[800] = (700, "tally", 8)
    check("nested npm launcher cannot claim the outer root",
          !codexHookBelongsToChild(800, child: 200, supervisor: 100, identityOf: { ancestry[$0] }))
    ancestry[200] = (100, "python", 2)
    check("an unrecognized launcher does not widen hook ownership",
          !codexHookBelongsToChild(500, child: 200, supervisor: 100, identityOf: { ancestry[$0] }))

    for args in [[], ["hello"], ["resume", "--last"], ["-m", "exec", "hello"],
                 ["--", "exec"], ["--config", "model=\"review\"", "resume", "--last"]] {
        check("Codex monitors interactive argv \(args)", shouldMonitorCodex(args: args, stdoutIsTTY: true))
    }
    for args in [["exec", "hello"], ["e", "hello"], ["review"], ["app-server"],
                 ["login"], ["logout"], ["mcp-server"], ["--help"], ["--version"],
                 ["--no-handoff"], ["fork"], ["-m", "gpt-test", "exec", "hello"]] {
        check("Codex leaves non-monitored argv plain \(args)", !shouldMonitorCodex(args: args, stdoutIsTTY: true))
    }
    check("Codex pipe stays one-shot", !shouldMonitorCodex(args: [], stdoutIsTTY: false))
    let environment = supervisedChildEnvironment(provider: providers[1], home: "/tmp/codex-new",
        supervisorVersion: nil, supervisorPID: "100", supervisorStartedAt: "200",
        base: ["CODEX_HOME": "/tmp/codex-old", "TALLY_SUPERVISED": "0",
               "TALLY_SUPERVISOR_VERSION": "stale", "TALLY_CODEX_LAUNCH_NONCE": "old"])
    check("nested monitoring replaces the selected Codex home", environment["CODEX_HOME"] == "/tmp/codex-new")
    check("nested monitoring clears stale build identity", environment["TALLY_SUPERVISOR_VERSION"] == nil)
    check("nested monitoring replaces plain-exec marker", environment["TALLY_SUPERVISED"] == "1")
    check("nested monitoring does not inherit launch nonce", environment["TALLY_CODEX_LAUNCH_NONCE"] == nil)
    check("Codex does not receive Claude resume suppression", environment[resumeTokenThresholdEnvKey] == nil)

    let base = FileManager.default.temporaryDirectory.appendingPathComponent("tally-codex-hook-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("codex")
    let dir = base.appendingPathComponent("state")
    let transcript = home.appendingPathComponent("sessions/root.jsonl")
    do {
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sid = UUID().uuidString
        let turn = UUID().uuidString
        let meta: [String: Any] = ["type": "session_meta", "payload": ["id": sid, "session_id": sid, "source": "cli"]]
        var data = try JSONSerialization.data(withJSONObject: meta)
        data.append(10)
        try data.write(to: transcript)
        let supervisor = getppid()
        let pid = String(supervisor)
        let generation = SessionMonitoring.generation(supervisor)!
        let identity = SessionMonitoring(provider: "codex", supervisorPID: supervisor,
            supervisorStart: generation, childPID: getpid(), childStart: SessionMonitoring.generation(getpid()),
            nonce: "fresh-launch", home: home.path)
        try identity.write(dir: dir)
        let env = ["TALLY_SUPERVISOR_PID": pid, "TALLY_SUPERVISOR_STARTED_AT": String(generation),
                   "TALLY_CODEX_LAUNCH_NONCE": "fresh-launch"]
        let payload: [String: Any] = ["hook_event_name": "SessionStart", "session_id": sid,
                                     "transcript_path": transcript.path, "model": "native-model"]
        let bindingFile = dir.appendingPathComponent(pid + ".codex-binding")
        let activityFile = dir.appendingPathComponent(pid + ".codex-activity")
        var childPayload = payload
        childPayload["agent_id"] = UUID().uuidString
        recordCodexSessionHook(childPayload, environment: env, reporterPID: getpid(), dir: dir)
        check("subagent sharing the root session ID cannot bind", !FileManager.default.fileExists(atPath: bindingFile.path))
        var staleEnv = env
        staleEnv["TALLY_CODEX_LAUNCH_NONCE"] = "old"
        recordCodexSessionHook(payload, environment: staleEnv, reporterPID: getpid(), dir: dir)
        check("old nonce cannot create a binding", !FileManager.default.fileExists(atPath: bindingFile.path))
        staleEnv = env
        staleEnv["TALLY_SUPERVISOR_STARTED_AT"] = String(generation - 1)
        recordCodexSessionHook(payload, environment: staleEnv, reporterPID: getpid(), dir: dir)
        check("old supervisor generation cannot create a binding", !FileManager.default.fileExists(atPath: bindingFile.path))
        recordCodexSessionHook(payload, environment: env, reporterPID: getpid(), dir: dir)
        let binding = try JSONDecoder().decode(CodexSessionBinding.self, from: Data(contentsOf: bindingFile))
        check("root hook binds the actual ancestor generation", binding.sessionID == sid && binding.nonce == "fresh-launch")
        check("root hook publishes observed model", binding.model == "native-model")
        check("Codex automatic resume sees a live bound generation", liveCodexConversations(dir: dir) == [sid])
        var staleIdentity = identity
        staleIdentity.nonce = "different-launch"
        try staleIdentity.write(dir: dir)
        check("Codex automatic resume ignores a stale binding nonce", liveCodexConversations(dir: dir).isEmpty)
        staleIdentity = identity
        staleIdentity.supervisorStart -= 1
        try staleIdentity.write(dir: dir)
        check("Codex automatic resume ignores a stale supervisor generation", liveCodexConversations(dir: dir).isEmpty)
        try identity.write(dir: dir)
        var prompt = payload
        prompt["hook_event_name"] = "UserPromptSubmit"
        prompt["turn_id"] = turn
        prompt["prompt"] = "PRIVATE-FIXTURE-CONTENT"
        recordCodexSessionHook(prompt, environment: env, reporterPID: getpid(), dir: dir)
        let activityBytes = try Data(contentsOf: activityFile)
        let activity = try JSONDecoder().decode(CodexSessionActivity.self, from: activityBytes)
        check("root prompt publishes only its structural turn", activity.turnID == turn && activity.event == "UserPromptSubmit")
        check("hook receipt does not persist prompt content", !String(decoding: activityBytes, as: UTF8.self).contains("PRIVATE-FIXTURE-CONTENT"))
        var stop = prompt
        stop["hook_event_name"] = "Stop"
        recordCodexSessionHook(stop, environment: env, reporterPID: getpid(), dir: dir)
        check("Stop hook cannot overwrite activity", try Data(contentsOf: activityFile) == activityBytes)
        childPayload = prompt
        childPayload["agent_id"] = "child-agent"
        childPayload["turn_id"] = UUID().uuidString
        recordCodexSessionHook(childPayload, environment: env, reporterPID: getpid(), dir: dir)
        check("subagent prompt cannot overwrite root activity", try Data(contentsOf: activityFile) == activityBytes)
        var stranger = payload
        stranger["session_id"] = UUID().uuidString
        recordCodexSessionHook(stranger, environment: env, reporterPID: getpid(), dir: dir)
        let preserved = try JSONDecoder().decode(CodexSessionBinding.self, from: Data(contentsOf: bindingFile))
        check("another session cannot replace a proven root binding", preserved.sessionID == sid)

        try (SessionMonitoring.presencePrefix + String(generation)).write(
            to: dir.appendingPathComponent(pid), atomically: true, encoding: .utf8)
        let legacyPID = String(getpid())
        try "".write(to: dir.appendingPathComponent(legacyPID), atomically: true, encoding: .utf8)
        check("mixed reload counts only the supported Claude resident", currentReloadReadiness(dir: dir) == .ready(1))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(legacyPID))
        check("Codex-only roster is not counted as legacy reload",
              currentReloadReadiness(dir: dir, processes: { [] }) == .nothingRunning)
        writeSupervisorCwd("/fixture/shared", pid: pid, dir: dir)
        writeSupervisorAccount("codex:fixture", pid: pid, dir: dir)
        writeSupervisorChild(getpid(), pid: pid, dir: dir)
        writeSessionState(SessionStateRecord(state: "unknown", since: Date(), updatedAt: Date(), accountID: "codex:fixture"), pid: pid, dir: dir)
        let reading = sessionReadings(dir: dir, socketDir: base.appendingPathComponent("sockets").path,
                                     identity: { _ in (nil, nil) })
        check("Codex JSON advertises monitoring-only capabilities", reading.sessions.first?.provider == "codex" && reading.sessions.first?.supportedActions == [])
        check("Codex JSON never invents context usage", reading.accountSessions["codex:fixture"] == nil)
        check("Codex JSON does not publish a Claude socket", reading.sessions.first?.messagingSocket == nil)
        clearCodexSupervisorState(pid: pid, dir: dir)
        check("cleanup removes this resident and its event sidecars", try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)

        // A separate live process prevents the caller's ancestor exclusion from making this pass.
        let monitor = Process()
        monitor.executableURL = URL(fileURLWithPath: "/bin/sleep")
        monitor.arguments = ["30"]
        try monitor.run()
        defer { monitor.terminate(); monitor.waitUntilExit() }
        let monitoredPID = monitor.processIdentifier
        let monitorKey = String(monitoredPID)
        var metadata = SessionMonitoring(provider: "codex", supervisorPID: monitoredPID,
            supervisorStart: SessionMonitoring.generation(monitoredPID)!, nonce: "other", home: home.path)
        try metadata.write(dir: dir)
        try (SessionMonitoring.presencePrefix + String(metadata.supervisorStart)).write(
            to: dir.appendingPathComponent(monitorKey), atomically: true, encoding: .utf8)
        let processProjection = [RunningProcess(pid: monitoredPID, ppid: getpid(), name: "tally",
            startedAt: Date(timeIntervalSince1970: 1)),
            RunningProcess(pid: 987_654, ppid: monitoredPID, name: "codex", startedAt: Date())]
        check("monitoring-only process is excluded from the legacy probe",
              currentReloadReadiness(dir: dir, processes: { processProjection }) == .nothingRunning)
        try Data("broken".utf8).write(to: dir.appendingPathComponent(monitorKey + SessionMonitoring.suffix))
        check("damaged Codex registration is not relabeled a legacy Claude session",
              currentReloadReadiness(dir: dir, processes: { processProjection }) == .nothingRunning)
        metadata.supervisorStart -= 1
        try metadata.write(dir: dir)
        sweepDeadSupervisorState(dir: dir)
        check("damaged metadata leaves the live owner's refusal marker intact",
              sessionControlRefusal(pid: monitorKey, dir: dir) != nil)
        try (SessionMonitoring.presencePrefix + String(metadata.supervisorStart)).write(
            to: dir.appendingPathComponent(monitorKey), atomically: true, encoding: .utf8)
        try "stale".write(to: dir.appendingPathComponent(monitorKey + ".codex-binding"), atomically: true, encoding: .utf8)
        sweepDeadSupervisorState(dir: dir)
        check("PID generation reuse sweeps the old owner sidecars together",
              try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    } catch { check("Codex native hook fixture completed: \(error)", false) }
}
