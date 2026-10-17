import Darwin
import Foundation

// B-2096: `tally account <codex account> --session <pid>`, the CLI-bound half. The pure rules
// (argv, source, gate, serve) are in tests/codex-supervisor/handoffchecks.swift; this is the part
// that needs the rest of the CLI: how a window is addressed, what the asking side writes and
// refuses, the argv against the launcher's own readers, and the wiring locks.

func runCodexHandoffChecks() {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-codexhandoff-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let homeA = base.appendingPathComponent("home-a")
    let homeB = base.appendingPathComponent("home-b")
    let homeC = base.appendingPathComponent("home-c")
    let work = base.appendingPathComponent("work")
    let dir = base.appendingPathComponent("state")
    let day = homeA.appendingPathComponent("sessions/2026/10/17")
    let thread = UUID().uuidString
    let pid = String(getpid())
    let transcript = day.appendingPathComponent("rollout-2026-10-17T00-00-00-\(thread).jsonl")
    do {
        for url in [day, work, dir, homeB, homeC.appendingPathComponent("sessions")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: homeB.appendingPathComponent("sessions"),
                                                   withDestinationURL: homeA.appendingPathComponent("sessions"))
        var first = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": [
            "id": thread, "session_id": thread, "source": "cli"]])
        first.append(10)
        try first.write(to: transcript)
        let identity = SessionMonitoring(provider: "codex", supervisorPID: getpid(),
            supervisorStart: SessionMonitoring.generation(getpid())!, nonce: "n", home: homeA.path)
        try identity.write(dir: dir)
        try (SessionMonitoring.presencePrefix + String(identity.supervisorStart)).write(
            to: dir.appendingPathComponent(pid), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(CodexSessionBinding(nonce: "n", sessionID: thread, transcriptPath: transcript.path,
            model: nil, directory: work.path)).write(to: dir.appendingPathComponent(pid + ".codex-binding"))
    } catch {
        check("codex handoff fixture builds", false)
        return
    }
    writeSupervisorCwd(work.path, pid: pid, dir: dir)
    writeSupervisorAccount("codex:.codex1", pid: pid, dir: dir)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func account(_ id: String, _ label: String, home: URL?, left: Double = 80) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "codex", label: label, launchHome: home?.path,
                         sessionRemaining: left, weeklyRemaining: left, modelRemaining: left,
                         sessionResetsAt: now.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: now.addingTimeInterval(100 * 3600),
                         modelResetsAt: now.addingTimeInterval(100 * 3600), modelWindowName: nil,
                         resetCreditsAvailable: nil, isStale: false, error: nil, refreshedAt: now)
    }
    let current = account("codex:.codex1", "Codex Pro", home: homeA)
    let target = account("codex:.codex2", "Codex Team", home: homeB)
    let unshared = account("codex:.codex3", "Codex Solo", home: homeC)
    // Two accounts whose config directories carry the same name, which the exec's `--account` could not tell apart.
    let twinA = account("codex:.codex4", "Twin one", home: base.appendingPathComponent("d1/dup"))
    let twinB = account("codex:.codex5", "Twin two", home: base.appendingPathComponent("d2/dup"))
    let snapshot = Snapshot(version: 2, generatedAt: now, accounts: [current, target, unshared, twinA, twinB])
    let requestURL = dir.appendingPathComponent(pid + codexHandoffSuffix)
    func attempt(_ intent: SwitchIntent, polls: Int = 2) -> SwitchAttempt {
        attemptCodexHandoff(intent, pid: pid, snapshot: snapshot, notes: [], cwd: work.path,
                            reserveGate: false, dir: dir, receiptPolls: polls)
    }

    // How a window is addressed
    check("--session naming a Codex window addresses it",
          codexSessionAddressed(sessionPID: pid, cwd: "/", marker: .trusted(nil), dir: dir) == .codex(pid))
    if case .refused = codexSessionAddressed(sessionPID: "999999", cwd: "/", marker: .trusted(nil), dir: dir) {
        check("--session naming nothing this machine supervises is refused", true)
    } else { check("--session naming nothing this machine supervises is refused", false) }
    if case .refused = codexSessionAddressed(sessionPID: String(getppid()), cwd: "/", marker: .trusted(nil), dir: dir) {
        check("--session naming a live process that is not a supervisor is refused", true)
    } else { check("--session naming a live process that is not a supervisor is refused", false) }
    check("without --session the window's own marker addresses it",
          codexSessionAddressed(sessionPID: nil, cwd: work.path, marker: .trusted(pid), dir: dir) == .codex(pid))
    check("without --session and without a window here the Claude path carries on",
          codexSessionAddressed(sessionPID: nil, cwd: base.path, marker: .trusted(nil), dir: dir) == .notCodex)

    // What the asking side refuses, and writes nothing for
    func wrote() -> Bool { FileManager.default.fileExists(atPath: requestURL.path) }
    check("--auto does not apply to a Codex window", attempt(.auto).result == .refused && !wrote())
    check("a name no codex account answers to is refused", attempt(.pin("nobody")).result == .refused && !wrote())
    check("a name two accounts answer to is refused, not guessed",
          attempt(.pin("twin")).result == .refused && !wrote())
    check("an account that shares a config-dir name with another is refused (the exec could not name it)",
          attempt(.pinAccount("codex:.codex4")).result == .refused && !wrote())
    check("the account the window is already on moves nothing",
          attempt(.pin("Codex Pro")).result == .alreadyThere && !wrote())
    check("an account that does not share the conversation's history is refused",
          attempt(.pin("Codex Solo")).result == .refused && !wrote())
    let silent = attempt(.pin("Codex Team"))
    check("a supervisor that never answers is refused and its request taken back",
          silent.result == .refused && silent.message.contains("did not answer") && !wrote())

    // The good path, with a supervisor that answers
    let answered = DispatchSemaphore(value: 0)
    var seen: CodexHandoffRequest?
    DispatchQueue.global().async {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: requestURL),
               let request = try? startupChoiceDecoder().decode(CodexHandoffRequest.self, from: data) {
                seen = request
                writeCodexHandoffReceipt(.init(nonce: request.nonce, result: codexHandoffQueued), pid: pid, dir: dir)
                break
            }
            usleep(50_000)
        }
        answered.signal()
    }
    let queued = attempt(.pin("Codex Team"), polls: 50)
    _ = answered.wait(timeout: .now() + 10)
    check("a queued hand-off says it waits for the turn end and names the account",
          queued.result == .queued && queued.message.contains("Codex Team") && queued.message.contains("turn ends"))
    check("…and the request it wrote names this conversation and the target, not the reserve flag it was not given",
          seen?.threadID == thread && seen?.accountID == target.id && seen?.spendReserve == true)
    check("…and the receipt is taken away once read",
          !FileManager.default.fileExists(atPath: dir.appendingPathComponent(pid + codexHandoffReceiptSuffix).path))

    // The argv against the launcher's own readers
    let tail = Array(codexHandoffArgv(targetHome: homeB.path, threadID: thread, spendReserve: false).dropFirst(4))
    let initialized = codexResumeInitializationArgs(tail)
    check("the hand-off's resume vector still gains the one initialization prompt",
          initialized.count == tail.count + 2 && initialized.last?.contains("TALLY_SESSION_READY") == true)
    var policy = LaunchPolicy()
    policy.startMode = "continue"
    check("start-mode resolution leaves an explicit resume alone",
          applyCodexStartMode(tail, policy: policy, wantsNew: false, home: homeB.path, cwd: work.path,
                              interactive: true) == tail)
    check("the config-dir name the argv carries reaches exactly the target account",
          { if case .one(let reached) = accountMatching(homeB.lastPathComponent, provider: "codex", in: snapshot) { return reached.id == target.id }
            return false }())

    // What a window leaves behind, and the wiring
    try? Data("x".utf8).write(to: requestURL)
    try? Data("x".utf8).write(to: dir.appendingPathComponent(pid + codexHandoffReceiptSuffix))
    clearCodexSupervisorState(pid: pid, dir: dir)
    check("a window that ends takes its hand-off request and receipt with it",
          !wrote() && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(pid + codexHandoffReceiptSuffix).path))
    let receiptURL = dir.appendingPathComponent(pid + codexHandoffReceiptSuffix)
    try? Data("x".utf8).write(to: requestURL)
    try? Data("x".utf8).write(to: receiptURL)
    clearCodexSupervisorState(pid: pid, dir: dir, keepHandoffReceipt: true)
    check("a hand-off exit keeps the receipt its asker is still polling for, and clears the request",
          FileManager.default.fileExists(atPath: receiptURL.path) && !wrote())
    try? FileManager.default.removeItem(at: receiptURL)
    check("…and the window's own exit passes that only when it is handing off",
          ((try? String(contentsOfFile: "TallyCLI/CodexSupervisor.swift", encoding: .utf8)) ?? "")
              .contains("keepHandoffReceipt: handoffTo != nil)"))
    check("the two files are in the list a dead supervisor's state is swept by",
          supervisorStateSuffixes.contains(codexHandoffSuffix) && supervisorStateSuffixes.contains(codexHandoffReceiptSuffix)
              && supervisorStatePid(ofFile: pid + codexHandoffReceiptSuffix) == getpid())
    let command = (try? String(contentsOfFile: "TallyCLI/SwitchCommand.swift", encoding: .utf8)) ?? ""
    let dispatch = command.range(of: "codexSessionAddressed(sessionPID: sessionPID")
    check("`tally account` asks the Codex addressing before the Claude path reads a thing",
          dispatch != nil && dispatch!.lowerBound < (command.range(of: "let provider = providers[0]")?.lowerBound ?? command.startIndex)
              && command.contains("takeSessionFlag(args)"))
    let refusal = (try? String(contentsOfFile: "Tally/Core/SessionMonitoring.swift", encoding: .utf8)) ?? ""
    check("the Codex control refusal points at the account hand-off instead of denying it",
          refusal.contains("`tally account <codex account> --session <pid>` hands it to another Codex account")
              && !refusal.contains("not account, model, or reload controls"))
    let supervisor = (try? String(contentsOfFile: "TallyCLI/CodexSupervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor execs a hand-off before a clear's reopen, and a clear cannot reopen a queued window",
          (supervisor.range(of: "execCodexHandoff(handoffTo")?.lowerBound ?? supervisor.endIndex)
              < (supervisor.range(of: "execProviderReopen(reopenAs")?.lowerBound ?? supervisor.startIndex)
              && supervisor.contains("reopen: { handoff != nil ? nil"))
}
