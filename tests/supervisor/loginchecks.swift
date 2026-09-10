import Foundation

func runLoginSignalChecks() {
    let error = #"{"type":"assistant","isSidechain":false,"isApiErrorMessage":true,"error":"authentication_failed","timestamp":"\#(stamp(60))","message":{"model":"<synthetic>","content":[{"type":"text","text":"Not logged in · Please run /login"}]}}"#
    var watcher = watcherAfterScanning([error])
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-login-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var writer = SessionStateWriter()
    let tick = syncSessionState(&writer, pid: "9219", project: PickProject(name: "test", path: "/test"),
                                accountID: "claude:test", childPid: nil, model: nil,
                                supervisorVersion: "test", watcher: &watcher,
                                keyboardBurstAt: nil, dir: dir)
    check("authentication_failed blocks the live session", tick.state == .blocked && tick.waitingOnPerson)
    check("authentication_failed publishes the session login instruction",
          readSessionState(pid: "9219", dir: dir)?.reason == "Sign in again in this session (/login).")
    check("authentication_failed exposes its timestamp", watcher.loginRequiredAt == launch.addingTimeInterval(60))
    check("authentication_failed is not a cap", !watcher.sawCapHit() && watcher.capHitAt == nil)
    check("login state round-trips through the sidecar",
          readSessionState(pid: "9219", dir: dir)?.loginRequiredAt == watcher.loginRequiredAt)

    func event(_ fields: [String: Any], at offset: TimeInterval = 90) -> String {
        var object = fields
        object["timestamp"] = stamp(offset)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    let service: [String: Any] = ["type": "assistant", "isSidechain": false,
                                  "message": ["model": "claude-fable-5", "content": []]]
    check("a real main-chain assistant response clears login",
          watcherAfterScanning([error, event(service)]).loginRequiredAt == nil)
    let rejected: [[String: Any]] = [
        ["type": "user", "message": ["content": "Not logged in · Please run /login"]],
        ["type": "user", "message": ["model": "claude-fable-5", "content": "quoted response"]],
        ["type": "assistant", "isSidechain": true, "message": ["model": "claude-fable-5"]],
        ["type": "assistant", "message": ["model": "<synthetic>"]],
        ["type": "assistant", "isApiErrorMessage": true, "message": ["model": "claude-fable-5"]],
        ["type": "assistant", "error": "server_error", "message": ["model": "claude-fable-5"]],
        ["type": "system", "subtype": "model_refusal_fallback", "message": ["model": "claude-fable-5"]],
        ["type": "assistant", "sessionId": "another-session", "message": ["model": "claude-fable-5"]],
        ["type": "user", "message": ["content": [["type": "tool_result", "content": "Login successful"]]]]
    ]
    for (index, fields) in rejected.enumerated() {
        check("non-service event \(index) preserves login failure",
              watcherAfterScanning([error, event(fields)]).loginRequiredAt != nil)
    }
    var auth = try! JSONSerialization.jsonObject(with: Data(error.utf8)) as! [String: Any]
    check("repeated authentication errors preserve the unresolved episode timestamp",
          watcherAfterScanning([error, event(auth, at: 120)]).loginRequiredAt == launch.addingTimeInterval(60))
    auth["isSidechain"] = true
    check("a sidechain authentication error does not block the session",
          watcherAfterScanning([event(auth)]).loginRequiredAt == nil)
    auth["isSidechain"] = false
    check("a pre-launch authentication error does not block the session",
          watcherAfterScanning([event(auth, at: -60)]).loginRequiredAt == nil)
    auth["sessionId"] = "another-session"
    check("another explicit session id cannot set login failure",
          watcherAfterScanning([event(auth)]).loginRequiredAt == nil)
    auth.removeValue(forKey: "sessionId")
    auth["error"] = "api_error"
    auth["message"] = ["model": "<synthetic>", "content": "API Error: 401 MCP unauthorized"]
    check("a generic 401 does not imply session login failure",
          watcherAfterScanning([event(auth)]).loginRequiredAt == nil)
    check("quoting the structured error in a user prompt does not set login failure",
          watcherAfterScanning([event(["type": "user", "message": ["content": error]])]).loginRequiredAt == nil)
    check("a historical assistant success cannot clear a live failure",
          watcherAfterScanning([error, event(service, at: -20)]).loginRequiredAt != nil)

    let command = event(["type": "user", "message": ["content":
        "<command-message>login</command-message><command-name>/login</command-name>"]])
    let success = event(["type": "user", "message": ["content":
        "<local-command-stdout>Login successful</local-command-stdout>"]], at: 100)
    check("unverified native login output does not clear the failure",
          watcherAfterScanning([error, command, success]).loginRequiredAt != nil)
    check("native login invocation alone does not clear the failure",
          watcherAfterScanning([error, command]).loginRequiredAt != nil)
    check("a success stdout without a login invocation cannot clear the failure",
          watcherAfterScanning([error, success]).loginRequiredAt != nil)

    let cap = #"{"isApiErrorMessage":true,"timestamp":"\#(stamp(30))","message":{"content":"You've hit your session limit"}}"#
    let capThenLogin = watcherAfterScanning([cap, error])
    check("a cap earlier in the same chunk does not swallow the login error",
          capThenLogin.capHitAt != nil && capThenLogin.loginRequiredAt != nil)

    let chunkDir = dir.appendingPathComponent("chunks")
    try! FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
    let chunkFile = chunkDir.appendingPathComponent("chunks.jsonl")
    let bytes = Data(error.utf8)
    let cut = bytes.count / 2
    try! bytes.prefix(cut).write(to: chunkFile)
    var partial = TranscriptWatcher(projectDir: chunkDir, file: chunkFile, since: launch)
    check("partial JSON neither signals nor consumes the record", !partial.sawCapHit()
          && partial.loginRequiredAt == nil && partial.offset == 0)
    let handle = try! FileHandle(forWritingTo: chunkFile)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: bytes.suffix(bytes.count - cut))
    check("the completed partial record reports login without a cap", !partial.sawCapHit()
          && partial.loginRequiredAt != nil)
    try! handle.write(contentsOf: Data(("\n" + event(service) + "\n").utf8))
    try! handle.close()
    _ = partial.sawCapHit()
    check("an appended service record clears the same watcher", partial.loginRequiredAt == nil)

    var moved = watcherAfterScanning([error])
    let other = moved.projectDir.appendingPathComponent("next.jsonl")
    try! "{}".write(to: other, atomically: true, encoding: .utf8)
    moved.moveTo(other)
    check("adopting another transcript drops the old login failure", moved.loginRequiredAt == nil)
    var truncated = watcherAfterScanning([error])
    try! "{}".write(to: truncated.file!, atomically: true, encoding: .utf8)
    _ = truncated.sawCapHit()
    check("a truncated transcript drops its previous login failure", truncated.loginRequiredAt == nil)
    var restarted = TranscriptWatcher(projectDir: watcher.projectDir, file: watcher.file,
                                       since: launch.addingTimeInterval(120))
    _ = restarted.sawCapHit()
    check("a relaunched child cannot inherit the earlier login failure", restarted.loginRequiredAt == nil)

    var notifications: [String] = []
    var notificationWriter = SessionStateWriter()
    func publish(_ at: Date?, now: Date) {
        notificationWriter.sync(.blocked, reason: "waiting", loginRequiredAt: at,
                                identity: SessionIdentity(accountID: "claude:test"),
                                pid: "notification", dir: dir, now: now,
                                notify: { notifications.append($0) })
    }
    publish(nil, now: launch)
    publish(launch, now: launch.addingTimeInterval(1))
    publish(launch, now: launch.addingTimeInterval(2))
    publish(nil, now: launch.addingTimeInterval(3))
    check("auth changes notify while the state stays blocked and identical ticks do not",
          notifications == ["notification", "notification", "notification"])
    check("auth changes preserve the blocked state's since",
          readSessionState(pid: "notification", dir: dir)?.since == launch)
    let older = #"{"state":"idle","since":"2026-08-13T10:00:00Z","updatedAt":"2026-08-13T10:00:00Z"}"#
    try! Data(older.utf8).write(to: dir.appendingPathComponent("older.state"))
    check("older records decode with no login signal", readSessionState(pid: "older", dir: dir) != nil
          && readSessionState(pid: "older", dir: dir)?.loginRequiredAt == nil)

}
