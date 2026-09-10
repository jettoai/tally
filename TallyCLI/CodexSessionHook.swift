import Darwin
import Foundation

/// Native telemetry is deliberately independent of the harness inbox hook and its exit contract.
func runCodexSessionHook() {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 4 * 1024 * 1024,
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    recordCodexSessionHook(payload, environment: ProcessInfo.processInfo.environment,
                           reporterPID: getpid(), dir: supervisorStateDir)
}

func recordCodexSessionHook(_ payload: [String: Any], environment: [String: String],
                            reporterPID: pid_t, dir: URL) {
    guard payload["agent_id"] == nil, payload["agent_type"] == nil,
          let pid = environment["TALLY_SUPERVISOR_PID"],
          let nonce = environment["TALLY_CODEX_LAUNCH_NONCE"],
          let start = environment["TALLY_SUPERVISOR_STARTED_AT"].flatMap(Int64.init),
          let sessionID = payload["session_id"] as? String, UUID(uuidString: sessionID) != nil,
          let event = payload["hook_event_name"] as? String,
          ["SessionStart", "UserPromptSubmit", "PermissionRequest"].contains(event) else { return }
    // SessionStart can race the spawn return. Wait briefly for the child's generation publication.
    var identity: SessionMonitoring?
    for _ in 0..<20 {
        identity = SessionMonitoring.read(pid: pid, dir: dir)
        if identity?.childPID != nil { break }
        usleep(25_000)
    }
    guard let identity, identity.provider == "codex", identity.nonce == nonce,
          identity.supervisorStart == start, let child = identity.childPID,
          codexHookBelongsToChild(reporterPID, child: child, supervisor: identity.supervisorPID),
          let path = payload["transcript_path"] as? String,
          let transcript = codexTranscriptURL(path: path, home: identity.home),
          let handle = try? FileHandle(forReadingFrom: transcript) else { return }
    defer { try? handle.close() }
    guard let bytes = try? handle.read(upToCount: 64 * 1024), let newline = bytes.firstIndex(of: 10),
          let meta = try? JSONSerialization.jsonObject(with: bytes[..<newline]) as? [String: Any],
          codexRootMetadata(meta, sessionID: sessionID) else { return }
    let file = dir.appendingPathComponent(pid + ".codex-binding")
    let directory = (payload["cwd"] as? String).map(realpathString)
    let candidate = CodexSessionBinding(nonce: nonce, sessionID: sessionID,
                                        transcriptPath: transcript.path, model: payload["model"] as? String,
                                        directory: directory)
    if let existing = try? Data(contentsOf: file) {
        guard let binding = try? JSONDecoder().decode(CodexSessionBinding.self, from: existing),
              binding.nonce == nonce, binding.sessionID == sessionID,
              binding.transcriptPath == transcript.path else { return }
    } else {
        guard event == "SessionStart", let bytes = try? JSONEncoder().encode(candidate) else { return }
        // Exclusive creation prevents concurrent nested launches from replacing a proven binding.
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
    guard event != "SessionStart", let turn = payload["turn_id"] as? String,
          UUID(uuidString: turn) != nil else { return }
    let activity = CodexSessionActivity(nonce: nonce, sessionID: sessionID, turnID: turn,
                                        event: event, at: Date())
    if let bytes = try? JSONEncoder().encode(activity) {
        try? bytes.write(to: dir.appendingPathComponent(pid + ".codex-activity"), options: .atomic)
    }
}

/// Accept the native child or the native process directly spawned by its npm Node launcher.
/// A nested Codex cannot reach either owner without crossing another provider process.
func codexHookBelongsToChild(_ reporter: pid_t, child: pid_t, supervisor: pid_t,
    identityOf: (pid_t) -> (parent: pid_t, name: String, startedAt: Int64)? = processIdentity) -> Bool {
    var pid = reporter
    var seen: Set<pid_t> = []
    while pid > 1, seen.insert(pid).inserted, let identity = identityOf(pid) {
        if pid == child { return identity.parent == supervisor }
        if pid != reporter, identity.name.lowercased().contains("codex") {
            guard identity.parent == child, let launcher = identityOf(child),
                  launcher.name.lowercased() == "node", launcher.parent == supervisor else { return false }
            return true
        }
        pid = identity.parent
    }
    return false
}
