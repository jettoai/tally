import Darwin
import Foundation

// B-2096: moving a live Codex window to another Codex account. The pure rules of
// TallyCLI/CodexHandoff.swift: the argv it execs, the conversation it carries, the turn boundary,
// the supervisor's reading of a request, and which account a window is reported on afterwards.

func runHandoffChecks() throws {
    let hroot = root.appendingPathComponent("handoff")
    let sourceHome = hroot.appendingPathComponent("home-a")
    let targetHome = hroot.appendingPathComponent("home-b")
    let work = hroot.appendingPathComponent("work")
    let state = hroot.appendingPathComponent("state")
    let day = sourceHome.appendingPathComponent("sessions/2026/10/17")
    for dir in [day, work, state, targetHome] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    try FileManager.default.createSymbolicLink(at: targetHome.appendingPathComponent("sessions"),
                                               withDestinationURL: sourceHome.appendingPathComponent("sessions"))
    let thread = UUID().uuidString
    let transcript = day.appendingPathComponent("rollout-2026-10-17T00-00-00-\(thread).jsonl")
    try meta(id: thread).write(to: transcript)

    let pid = String(getpid())
    let identity = SessionMonitoring(provider: "codex", supervisorPID: getpid(),
        supervisorStart: SessionMonitoring.generation(getpid())!, nonce: "handoff-nonce", home: sourceHome.path)
    try identity.write(dir: state)
    try (SessionMonitoring.presencePrefix + String(identity.supervisorStart)).write(
        to: state.appendingPathComponent(pid), atomically: true, encoding: .utf8)
    func bind(nonce: String = "handoff-nonce", id: String = thread, path: String = transcript.path,
              directory: String? = work.path, as owner: String = pid) throws {
        try JSONEncoder().encode(CodexSessionBinding(nonce: nonce, sessionID: id, transcriptPath: path,
            model: nil, directory: directory)).write(to: state.appendingPathComponent(owner + ".codex-binding"))
    }
    func source(_ target: URL = targetHome, fallback: String? = nil) -> CodexHandoffSource {
        codexHandoffSource(pid: pid, targetHome: target.path, fallbackDirectory: fallback, dir: state)
    }
    func refused(_ result: CodexHandoffSource) -> Bool {
        if case .refused = result { return true }
        return false
    }

    // 1. the argv the supervisor execs
    let argv = codexHandoffArgv(targetHome: "/x/.codex2", threadID: thread, spendReserve: false)
    check("handoff argv: tally codex on the target's config dir, resume by id, session directory kept",
          argv == ["tally", "codex", "--account", ".codex2", "resume", thread, "-c", "tui.resume_cwd=\"session\""])
    let reserve = codexHandoffArgv(targetHome: "/x/.codex2", threadID: thread, spendReserve: true)
    check("handoff argv: --spend-reserve only when asked, ahead of resume",
          reserve.contains("--spend-reserve") && !argv.contains("--spend-reserve")
              && reserve.firstIndex(of: "--spend-reserve")! < reserve.firstIndex(of: "resume")!)
    check("handoff argv: the thread id follows `resume` directly",
          argv[argv.firstIndex(of: "resume")! + 1] == thread)

    // 4. the conversation it carries
    try bind()
    check("source: a bound, shared conversation is ready with its own directory",
          source() == .ready(threadID: thread, directory: work.path))
    try FileManager.default.removeItem(at: state.appendingPathComponent(pid + ".codex-binding"))
    check("source: no binding yet is refused", refused(source()))
    try bind(nonce: "stale")
    check("source: a binding from another launch is refused", refused(source()))
    try bind(id: "not-a-uuid")
    check("source: a session id that is not a UUID is refused", refused(source()))
    let mismatched = day.appendingPathComponent("rollout-2026-10-17T00-00-00-\(UUID().uuidString).jsonl")
    try meta(id: thread).write(to: mismatched)
    try bind(path: mismatched.path)
    check("source: a rollout whose file name carries another id is refused", refused(source()))
    let archived = sourceHome.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    let archivedFile = archived.appendingPathComponent("rollout-2026-10-17T00-00-00-\(thread).jsonl")
    try meta(id: thread).write(to: archivedFile)
    try bind(path: archivedFile.path)
    check("source: an archived conversation is refused", refused(source()))
    try bind()
    let unshared = hroot.appendingPathComponent("home-c")
    try FileManager.default.createDirectory(at: unshared.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    check("source: a target with its own sessions directory is refused", refused(source(unshared)))
    try bind(directory: nil)
    check("source: no directory in the binding falls back to the supervisor's",
          source(fallback: work.path) == .ready(threadID: thread, directory: work.path))
    check("source: no directory anywhere is refused", refused(source()))
    try bind(directory: work.appendingPathComponent("gone").path)
    check("source: a directory that no longer exists is refused", refused(source()))
    try bind()

    // 5. a second writer
    check("owners: only this window holds it, nothing to refuse",
          codexHandoffOtherWriter(thread: thread, pid: pid, dir: state) == nil)
    let parent = String(getppid())
    let parentIdentity = SessionMonitoring(provider: "codex", supervisorPID: getppid(),
        supervisorStart: SessionMonitoring.generation(getppid())!, nonce: "other", home: sourceHome.path)
    try parentIdentity.write(dir: state)
    try (SessionMonitoring.presencePrefix + String(parentIdentity.supervisorStart)).write(
        to: state.appendingPathComponent(parent), atomically: true, encoding: .utf8)
    try bind(nonce: "other", as: parent)
    check("owners: another live window on the same thread is refused",
          codexHandoffOtherWriter(thread: thread, pid: pid, dir: state) != nil)
    try bind(nonce: "wrong", as: parent)
    check("owners: a binding from another launch does not count",
          codexHandoffOtherWriter(thread: thread, pid: pid, dir: state) == nil)
    check("owners: the pairs are what the Set form is made of",
          liveCodexConversationOwners(dir: state).map(\.thread) == [thread])

    // 6. the supervisor's reading of a request
    let target = "codex:.codex2"
    func request(_ id: String = thread, at: Date = Date()) -> CodexHandoffRequest {
        CodexHandoffRequest(nonce: UUID().uuidString, accountID: target, threadID: id, spendReserve: true, at: at)
    }
    func put(_ request: CodexHandoffRequest) throws {
        try startupChoiceEncoder().encode(request).write(to: state.appendingPathComponent(pid + codexHandoffSuffix))
    }
    func receipt() -> CodexHandoffReceipt? {
        (try? Data(contentsOf: state.appendingPathComponent(pid + codexHandoffReceiptSuffix)))
            .flatMap { try? startupChoiceDecoder().decode(CodexHandoffReceipt.self, from: $0) }
    }
    func serve(busy: String? = nil, home: String? = targetHome.path) -> CodexHandoffPlan? {
        serveCodexHandoff(pid: pid, busy: busy, targetHome: { _ in home }, fallbackDirectory: nil, dir: state)
    }
    var ask = request()
    try put(ask)
    var plan = serve()
    check("serve: a good request is queued, its file is gone, and the receipt carries its nonce",
          plan == CodexHandoffPlan(threadID: thread, directory: work.path, targetHome: targetHome.path, spendReserve: true)
              && receipt() == CodexHandoffReceipt(nonce: ask.nonce, result: codexHandoffQueued)
              && !FileManager.default.fileExists(atPath: state.appendingPathComponent(pid + codexHandoffSuffix).path))
    ask = request(UUID().uuidString)
    try put(ask)
    plan = serve()
    check("serve: a request for another conversation is refused",
          plan == nil && receipt()?.nonce == ask.nonce && receipt()?.result != codexHandoffQueued)
    ask = request()
    try put(ask)
    plan = serve(home: nil)
    check("serve: an account that left the fleet is refused", plan == nil && receipt()?.result != codexHandoffQueued)
    ask = request()
    try put(ask)
    plan = serve(busy: "a clear is already reopening this window")
    check("serve: a window that is reopening is refused with that reason",
          plan == nil && receipt()?.result == "a clear is already reopening this window")
    ask = request(at: Date().addingTimeInterval(-60))
    try put(ask)
    plan = serve()
    check("serve: an old request is refused unread", plan == nil && receipt()?.result != codexHandoffQueued)
    try Data("garbage".utf8).write(to: state.appendingPathComponent(pid + codexHandoffSuffix))
    check("serve: an unreadable request is dropped",
          serve() == nil && !FileManager.default.fileExists(atPath: state.appendingPathComponent(pid + codexHandoffSuffix).path))
    check("serve: nothing pending is nothing", serve() == nil)

    // 7. the turn boundary
    func gate(ended: Bool = true, permission: Bool = false, question: Bool = false, draft: Bool = false,
              idle: Bool = true, pending: Bool = false, queued: Bool = false) -> String? {
        codexHandoffGate(turnEnded: ended, permissionPending: permission, questionPending: question,
                         draftSuspected: draft, keyboardIdle: idle, inputPending: pending, inputQueued: queued)
    }
    check("gate: everything quiet lets it go", gate() == nil)
    check("gate: each of the seven conditions holds it back alone",
          [gate(ended: false), gate(permission: true), gate(question: true), gate(draft: true),
           gate(idle: false), gate(pending: true), gate(queued: true)].allSatisfy { $0 != nil })

    // 8. which account the window is on
    let account = hroot.appendingPathComponent("account-state")
    let first = try line("session_meta", ["id": thread, "session_id": thread, "source": "cli",
                                          "creator_account_id": "account-a-uuid"], after: -1)
    let rollout = day.appendingPathComponent("rollout-2026-10-17T00-00-01-\(thread).jsonl")
    try (first + event("task_started")
        + line("event_msg", ["type": "token_count", "rate_limits": ["plan_type": "team"]])
        + event("task_complete")).write(to: rollout)
    var landed = CodexSessionObserver(binding: CodexSessionBinding(nonce: "n", sessionID: thread,
        transcriptPath: rollout.path, model: nil), launchedAt: start)
    landed.poll(home: sourceHome.path)
    var writer = CodexSessionContextWriter()
    writer.sync(accountID: "codex:.codex2", launchModel: nil, launchEffort: nil, observer: landed,
                pid: pid, dir: account, notify: { _ in })
    let published = (try? Data(contentsOf: account.appendingPathComponent(pid + ".session")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check("account: the window reports the account its supervisor launched it on, whatever the rollout's first line names",
          published?["accountID"] as? String == "codex:.codex2")
    check("account: the server's plan from the first token_count rides along, as a plan and not an account",
          landed.planType == "team" && published?["runningPlan"] as? String == "team")
    let readers = ["TallyCLI", "Tally"].flatMap { dir -> [String] in
        let files = FileManager.default.enumerator(atPath: dir)?.compactMap { $0 as? String } ?? []
        return files.filter { $0.hasSuffix(".swift") }.map { dir + "/" + $0 }
    }
    check("account: no code reads the rollout's creator_account_id",
          !readers.contains { ((try? String(contentsOfFile: $0, encoding: .utf8)) ?? "").contains("creator_account") })
}
