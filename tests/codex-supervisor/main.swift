import Darwin
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("tally-codex-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let home = root.appendingPathComponent("home")
let sessions = home.appendingPathComponent("sessions")
try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
let start = Date(timeIntervalSince1970: 1_800_000_000)
let sid = UUID().uuidString
let turn = UUID().uuidString
let nextTurn = UUID().uuidString
let iso = ISO8601DateFormatter()

func line(_ type: String, _ payload: [String: Any], after: TimeInterval = 1) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload,
        "timestamp": iso.string(from: start.addingTimeInterval(after))])
    data.append(10)
    return data
}
func meta(id: String = sid, source: String = "cli", parent: String? = nil) throws -> Data {
    var payload: [String: Any] = ["id": id, "session_id": id, "source": source, "originator": "codex-tui"]
    if let parent { payload["parent_thread_id"] = parent }
    return try line("session_meta", payload, after: -1)
}
func event(_ type: String, turnID: String = turn, after: TimeInterval = 1) throws -> Data {
    try line("event_msg", ["type": type, "turn_id": turnID], after: after)
}
func append(_ data: Data, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}
func fixture(_ name: String, contents: Data? = nil) throws -> (URL, CodexSessionObserver) {
    let file = sessions.appendingPathComponent(name + ".jsonl")
    try (contents ?? meta()).write(to: file)
    return (file, CodexSessionObserver(binding: CodexSessionBinding(nonce: "fresh", sessionID: sid,
        transcriptPath: file.path, model: "requested"), launchedAt: start))
}

var (file, observer) = try fixture("root")
observer.poll(home: home.path)
check("metadata alone does not invent idle", observer.state == .unknown)
try append(event("task_started"), to: file)
observer.poll(home: home.path)
check("root task started proves working", observer.state == .working)
try append(line("turn_context", ["model": "observed-model"]), to: file)
observer.poll(home: home.path)
check("native turn model overrides requested model", observer.model == "observed-model")
try append(line("event_msg", ["type": "agent_message", "message": "Stop hook continued"]), to: file)
observer.poll(home: home.path)
check("assistant message alone does not imply idle", observer.state == .working)
try append(event("task_complete"), to: file)
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

var (historyFile, historical) = try fixture("history", contents: meta() + event("task_complete", after: -1))
historical.poll(home: home.path)
check("resume history cannot publish historical idle", historical.state == .unknown)
try append(event("task_started"), to: historyFile)
try append(event("task_started", turnID: nextTurn), to: historyFile)
try append(event("task_complete"), to: historyFile)
historical.poll(home: home.path)
check("completion of one turn cannot clear a second active turn", historical.state == .working)
try append(event("turn_aborted", turnID: nextTurn), to: historyFile)
historical.poll(home: home.path)
check("both active turns have to settle", historical.state == .idle)

var (partialFile, partial) = try fixture("partial")
let full = try event("task_started")
try append(full.prefix(full.count - 4), to: partialFile)
partial.poll(home: home.path)
check("partial JSON line cannot invent working", partial.state == .unknown)
try append(full.suffix(4), to: partialFile)
partial.poll(home: home.path)
check("partial JSON line is completed on a later poll", partial.state == .working)
try append(Data("{bad}\n".utf8), to: partialFile)
partial.poll(home: home.path)
check("malformed record invalidates a prior working reading", partial.state == .unknown)
try append(event("task_complete"), to: partialFile)
partial.poll(home: home.path)
check("malformed stream does not regain unsupported confidence", partial.state == .unknown)

var (replaceFile, replaced) = try fixture("replace", contents: meta() + event("task_started"))
replaced.poll(home: home.path)
try (meta() + event("task_complete")).write(to: replaceFile, options: .atomic)
replaced.poll(home: home.path)
check("replacement inode invalidates the binding", replaced.state == .unknown)
var (truncateFile, truncated) = try fixture("truncate", contents: meta() + event("task_started"))
truncated.poll(home: home.path)
let truncateHandle = try FileHandle(forWritingTo: truncateFile)
try truncateHandle.truncate(atOffset: 0)
try truncateHandle.close()
truncated.poll(home: home.path)
check("truncation invalidates the binding", truncated.state == .unknown)

for (name, contents) in [("wrong-id", try meta(id: UUID().uuidString)),
                          ("exec-source", try meta(source: "exec")),
                          ("child", try meta(parent: UUID().uuidString))] {
    var (_, candidate) = try fixture(name, contents: contents + event("task_started"))
    candidate.poll(home: home.path)
    check("root binding rejects \(name)", candidate.state == .unknown)
}
let otherHome = root.appendingPathComponent("other-home")
try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: true)
check("same session name outside selected home is rejected", codexTranscriptURL(path: file.path, home: otherHome.path) == nil)
try FileManager.default.createSymbolicLink(at: otherHome.appendingPathComponent("sessions"), withDestinationURL: sessions)
check("shared canonical sessions symlink is accepted", codexTranscriptURL(path: file.path, home: otherHome.path) != nil)
var (_, stale) = try fixture("stale")
stale.poll(home: home.path, activity: CodexSessionActivity(nonce: "old", sessionID: sid,
    turnID: turn, event: "UserPromptSubmit", at: start.addingTimeInterval(10)))
check("old launch nonce cannot start this session", stale.state == .unknown)
stale.poll(home: home.path, activity: CodexSessionActivity(nonce: "fresh", sessionID: UUID().uuidString,
    turnID: turn, event: "UserPromptSubmit", at: start.addingTimeInterval(11)))
check("another root session cannot start this session", stale.state == .unknown)

let stateDir = root.appendingPathComponent("state")
let currentPID = String(getpid())
var identity = SessionMonitoring(provider: "codex", supervisorPID: getpid(),
    supervisorStart: SessionMonitoring.generation(getpid())!, nonce: "identity", home: home.path)
try identity.write(dir: stateDir)
try (SessionMonitoring.presencePrefix + String(identity.supervisorStart)).write(
    to: stateDir.appendingPathComponent(currentPID), atomically: true, encoding: .utf8)
check("live monitoring generation is enumerated", liveSupervisorPids(dir: stateDir) == [getpid()])
check("monitoring resident refuses mutations", sessionControlRefusal(pid: currentPID, dir: stateDir) != nil)
identity.supervisorStart -= 1
try identity.write(dir: stateDir)
check("mismatched metadata generation is absent from roster", liveSupervisorPids(dir: stateDir).isEmpty)
check("damaged metadata cannot revoke a live presence generation", !SessionMonitoring.staleGeneration(pid: currentPID, dir: stateDir))
check("stale generation still cannot fall back to Claude control", sessionControlRefusal(pid: currentPID, dir: stateDir) != nil)
try Data("broken".utf8).write(to: stateDir.appendingPathComponent(currentPID + SessionMonitoring.suffix))
check("malformed monitoring metadata is absent from roster", liveSupervisorPids(dir: stateDir).isEmpty)
try FileManager.default.removeItem(at: stateDir.appendingPathComponent(currentPID + SessionMonitoring.suffix))
check("presence marker preserves refusal when metadata is missing", sessionControlRefusal(pid: currentPID, dir: stateDir) != nil)
check("missing metadata never publishes a monitored ghost", liveSupervisorPids(dir: stateDir).isEmpty)

let installRoot = root.appendingPathComponent("install-state")
let hooksURL = home.appendingPathComponent("hooks.json")
let user: [String: Any] = ["matcher": "*", "hooks": [["type": "command", "command": "echo user"]]]
let original: [String: Any] = ["extra": ["keep": true], "hooks": ["SessionStart": [user], "Stop": [user]]]
try JSONSerialization.data(withJSONObject: original).write(to: hooksURL)
let installCommand = "/fixture/tally codex-session-hook"
try CodexSessionHooks.install(homes: [home.path], root: installRoot, command: installCommand)
check("explicit installer registers three events", try CodexSessionHooks.installed(homes: [home.path], root: installRoot))
var installed = try CodexSessionHooks.document(path: hooksURL.path)
var hooks = installed["hooks"] as! [String: Any]
check("install preserves existing SessionStart registration", (hooks["SessionStart"] as! [[String: Any]]).contains { CodexSessionHooks.same($0, user) })
check("install leaves unrelated events unchanged", (hooks["Stop"] as! [[String: Any]]).count == 1)
check("install leaves top-level configuration unchanged", (installed["extra"] as? [String: Bool])?["keep"] == true)
try CodexSessionHooks.install(homes: [home.path], root: installRoot, command: installCommand)
check("repeated install is idempotent", (try CodexSessionHooks.receipt(root: installRoot))?.paths.count == 1)
var editedOwned = CodexSessionHooks.group(command: installCommand)
editedOwned["matcher"] = "user-edited"
var promptHooks = hooks["UserPromptSubmit"] as! [[String: Any]]
promptHooks.append(editedOwned)
hooks["UserPromptSubmit"] = promptHooks
installed["hooks"] = hooks
try JSONSerialization.data(withJSONObject: installed).write(to: hooksURL)
try CodexSessionHooks.remove(root: installRoot)
let after = try CodexSessionHooks.document(path: hooksURL.path)
let afterHooks = after["hooks"] as! [String: Any]
check("remove preserves original SessionStart", (afterHooks["SessionStart"] as! [[String: Any]]).count == 1)
check("remove preserves a user-edited lookalike", (afterHooks["UserPromptSubmit"] as! [[String: Any]]).count == 1)
check("remove clears only owned PermissionRequest registration", afterHooks["PermissionRequest"] == nil)
check("remove clears ownership receipt", try CodexSessionHooks.receipt(root: installRoot) == nil)
try FileManager.default.createSymbolicLink(at: otherHome.appendingPathComponent("hooks.json"), withDestinationURL: hooksURL)
check("shared hooks symlink is deduplicated", CodexSessionHooks.paths(homes: [home.path, otherHome.path]).count == 1)
try Data("broken".utf8).write(to: hooksURL)
do {
    try CodexSessionHooks.install(homes: [home.path], root: installRoot, command: installCommand)
    check("malformed user hooks are refused", false)
} catch { check("malformed user hooks are refused", true) }
check("malformed user hooks remain untouched", try Data(contentsOf: hooksURL) == Data("broken".utf8))

print("Codex supervisor checks: \(failures) failures")
exit(failures == 0 ? 0 : 1)
