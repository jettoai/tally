import Foundation

func runCodexStartChecks() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-codex-start-\(UUID().uuidString)")
    let home = root.appendingPathComponent("home")
    let project = root.appendingPathComponent("project")
    let other = root.appendingPathComponent("other")
    let sessions = home.appendingPathComponent("sessions/2026/09/10")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        for dir in [sessions, project, other] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var policy = LaunchPolicy()
        policy.startMode = "continue"
        func apply(_ args: [String] = [], wantsNew: Bool = false, interactive: Bool = true,
                   home selected: URL? = nil, live: Set<String> = []) -> [String] {
            applyCodexStartMode(args, policy: policy, wantsNew: wantsNew,
                home: (selected ?? home).path, cwd: project.path, interactive: interactive, live: live)
        }
        func record(_ id: String, at: String, source: Any = "cli", cwd: URL? = nil,
                    extra: [String: Any] = [:], padding: Int = 0, tailPadding: Int = 0) throws -> URL {
            var meta: [String: Any] = ["id": id, "source": source, "cwd": (cwd ?? project).path,
                                       "base_instructions": String(repeating: "x", count: padding)]
            meta.merge(extra) { _, new in new }
            let rows: [[String: Any]] = [
                ["type": "session_meta", "timestamp": "2026-09-10T00:00:00Z", "payload": meta],
                ["type": "event_msg", "timestamp": at,
                 "payload": ["type": "user_message", "message": "Fixture question"]],
                ["type": "response_item", "timestamp": at,
                 "payload": ["type": "message", "role": "assistant",
                             "content": String(repeating: "z", count: tailPadding)]]
            ]
            let bytes = try rows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                .reduce(into: Data()) { $0.append($1); $0.append(10) }
            let file = sessions.appendingPathComponent("rollout-2026-09-10T00-00-00-\(id).jsonl")
            try bytes.write(to: file)
            return file
        }
        check("Codex continue with no history starts a new session", apply().isEmpty)
        let older = "11111111-1111-4111-8111-111111111111"
        let newer = "22222222-2222-4222-8222-222222222222"
        let otherID = "33333333-3333-4333-8333-333333333333"
        let firstFile = try record(older, at: "2026-09-10T01:00:00Z")
        check("Codex bare continue resolves a same-directory root CLI session", apply() == ["resume", older])
        let latestFile = try record(newer, at: "2026-09-10T02:00:00Z", padding: 80_000, tailPadding: 150_000)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(86_400)],
                                             ofItemAtPath: firstFile.path)
        check("Codex ranks large rollouts by event time rather than file mtime", apply() == ["resume", newer])
        _ = try record(otherID, at: "2026-09-10T03:00:00Z", cwd: other)
        check("Codex never selects a newer conversation from another project", apply() == ["resume", newer])
        for source: Any in ["exec", "unknown", ["subagent": "review"],
                            ["subagent": ["thread_spawn": ["parent_thread_id": older]]], NSNull()] {
            let id = UUID().uuidString
            _ = try record(id, at: "2026-09-10T04:00:00Z", source: source)
        }
        _ = try record(UUID().uuidString, at: "2026-09-10T05:00:00Z", extra: ["parent_thread_id": older])
        check("Codex excludes exec, unknown, review and spawned-child metadata", apply() == ["resume", newer])
        for args in [["resume"], ["resume", "--last"], ["resume", older], ["exec", "question"],
                     ["review"], ["login"], ["question"], ["-m", "model", "question"],
                     ["--", "question"], ["--"], ["-h"], ["--help"], ["-V"], ["--version"],
                     ["-i", "image.png"], ["--image=image.png"], ["-iimage.png"],
                     ["--remote", "unix:///tmp/codex.sock"]] {
            check("Codex explicit launch remains unchanged: \(args)", apply(args) == args)
        }
        check("Codex --new suppression starts fresh", apply(wantsNew: true).isEmpty)
        check("Codex piped launch does not resume automatically", apply(interactive: false).isEmpty)
        check("Codex a live latest session starts fresh without walking back", apply(live: [newer]).isEmpty)
        check("Codex model and permission defaults survive resume injection",
              apply(["--model", "gpt-6-astra", "-s", "read-only", "-c", "model_reasoning_effort=high"])
                == ["resume", newer, "--model", "gpt-6-astra", "-s", "read-only", "-c", "model_reasoning_effort=high"])
        for args in [["--cd", other.path], ["--cd=\(other.path)"], ["-C", "../other"],
                     ["-C\(other.path)"], ["-C=\(other.path)"]] {
            check("Codex working-root spelling selects its own project: \(args)",
                  apply(args) == ["resume", otherID] + args)
        }
        check("Codex a config value resembling -C is not a directory override",
              apply(["-c", "-C/absent"]) == ["resume", newer, "-c", "-C/absent"])
        let shared = root.appendingPathComponent("shared-home")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("sessions"),
                                                   withDestinationURL: home.appendingPathComponent("sessions"))
        check("Codex shared account history resolves through the sessions symlink",
              apply(home: shared) == ["resume", newer])
        check("Codex an unshared selected home cannot borrow another home's history",
              apply(home: root.appendingPathComponent("unshared-home")).isEmpty)
        let linkedProject = root.appendingPathComponent("linked-project")
        try FileManager.default.createSymbolicLink(at: linkedProject, withDestinationURL: project)
        check("Codex canonicalizes project symlinks before matching metadata",
              apply(["-C", linkedProject.path]) == ["resume", newer, "-C", linkedProject.path])
        let desktop = UUID().uuidString
        _ = try record(desktop, at: "2026-09-10T06:00:00Z", source: "vscode")
        check("Codex root editor sessions are resumable alongside CLI sessions", apply() == ["resume", desktop])
        let malformed = sessions.appendingPathComponent("rollout-broken-\(UUID().uuidString).jsonl")
        try Data("{broken\n".utf8).write(to: malformed)
        _ = try record("not-a-uuid", at: "2026-09-10T08:00:00Z")
        let oversized = try record(UUID().uuidString, at: "2026-09-10T08:00:00Z", padding: 1 << 20)
        check("Codex malformed and oversized metadata cannot override valid history", apply() == ["resume", desktop])
        try FileManager.default.removeItem(at: oversized)
        try FileManager.default.removeItem(at: latestFile)
        policy.startMode = nil
        check("Codex new setting injects no resume even with history", apply().isEmpty)
    } catch {
        check("Codex start-mode fixture setup: \(error)", false)
    }
}
