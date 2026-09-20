import Darwin
import Foundation

func runCodexInputChecks() {
    let now = Date()
    let launch = now.addingTimeInterval(-100)
    let turn = now.addingTimeInterval(-30)
    check("Codex unknown keyboard evidence holds drafts", codexInputDraftSuspected(lastInput: nil, userTurnAt: turn, launchedAt: launch))
    check("Codex single pasted draft after turn is held", codexInputDraftSuspected(lastInput: turn.addingTimeInterval(1), userTurnAt: turn, launchedAt: launch))
    check("Codex old unsent draft does not expire into permission to overwrite", codexInputDraftSuspected(lastInput: launch.addingTimeInterval(1), userTurnAt: nil, launchedAt: launch))
    check("Codex submitted user input clears draft suspicion", !codexInputDraftSuspected(lastInput: turn.addingTimeInterval(-1), userTurnAt: turn, launchedAt: launch))
    check("Codex empty and slash input refuse before native menus", codexSessionInputProblem("") != nil && codexSessionInputProblem("/model") != nil && codexSessionInputProblem("!echo hello") != nil)
    check("Codex paste escape injection is refused", codexSessionInputProblem("hello\u{1b}[201~\r") != nil)
    check("Codex multiline plain prompt stays supported", codexSessionInputProblem("hello\nworld") == nil)
    var clock: Double = 0
    var polls = 0
    let confirmed = awaitCodexInputConfirmation(timeout: 1, poll: { polls += 1; return polls == 3 }, sleep: { clock += $0 }, clock: { clock })
    check("Codex native confirmation waits for actual receipt", confirmed && polls == 3)
    clock = 0
    check("Codex missing native receipt has a bounded refusal", !awaitCodexInputConfirmation(timeout: 1, poll: { false }, sleep: { clock += $0 }, clock: { clock }))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tally-codex-input-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let transcript = home.appendingPathComponent("sessions/root.jsonl")
    let queue = root.appendingPathComponent("queue")
    let log = root.appendingPathComponent("input.log")
    do {
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString, turnID = UUID().uuidString
        let iso = ISO8601DateFormatter()
        func line(_ type: String, _ payload: [String: Any], _ date: Date) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload, "timestamp": iso.string(from: date)])
            data.append(10); return data
        }
        var data = try line("session_meta", ["id": id, "session_id": id, "source": "cli"], launch)
        data += try line("event_msg", ["type": "task_started", "turn_id": turnID], turn)
        data += try line("event_msg", ["type": "user_message", "message": "first prompt"], turn)
        data += try line("event_msg", ["type": "task_complete", "turn_id": turnID], turn.addingTimeInterval(1))
        try data.write(to: transcript)
        var observer = CodexSessionObserver(binding: CodexSessionBinding(nonce: "fixture", sessionID: id, transcriptPath: transcript.path), launchedAt: launch)
        observer.poll(home: home.path)
        var input = SessionInputState(sessionKey: "101", servedEpoch: 0, dir: queue)
        var epoch = Int(now.timeIntervalSince1970 * 1000)
        try writeSessionInputRequest(SessionInputRequest(epoch: epoch, text: "target only"), sessionKey: "101", dir: queue)
        try writeSessionInputRequest(SessionInputRequest(epoch: epoch, text: "sibling only"), sessionKey: "202", dir: queue)
        var keyboard = KeyboardActivity()
        keyboard.observe(stamp: turn.addingTimeInterval(-1))
        var delivered: [String] = []
        var injection: SessionInputInjection = .done
        func apply(_ observed: CodexSessionObserver?, terminalReady: Bool = true, confirmed: Bool = true) -> SessionInputAction {
            applyCodexSessionInput(&input, observer: observed, keyboard: keyboard, launchedAt: launch,
                terminalReady: terminalReady, dir: queue, log: log, now: now,
                inject: { if injection == .done { delivered.append($0) }; return injection }, confirm: { confirmed })
        }
        check("Codex unknown session leaves queue untouched", apply(nil).typed == nil && delivered.isEmpty && readSessionInputRequest(sessionKey: "101", dir: queue) != nil)
        check("Codex lost terminal owner holds input", apply(observer, terminalReady: false).typed == nil && delivered.isEmpty)
        keyboard.observe(stamp: now.addingTimeInterval(-1))
        check("Codex human typing holds input", apply(observer).typed == nil && delivered.isEmpty)
        keyboard.lastStamp = turn.addingTimeInterval(2)
        keyboard.lastBurstAt = nil
        check("Codex quiet ambiguous input refuses without typing", apply(observer).typed == nil && delivered.isEmpty
            && readSessionInputResult(sessionKey: "101", dir: queue)?.outcome == "refused-unsafe-input"
            && readSessionInputRequest(sessionKey: "101", dir: queue) == nil)
        epoch += 1
        try writeSessionInputRequest(SessionInputRequest(epoch: epoch, text: "target only"), sessionKey: "101", dir: queue)
        keyboard.lastStamp = turn.addingTimeInterval(-1)
        injection = .held
        check("Codex late human input holds the original queued request", apply(observer).typed == nil && readSessionInputRequest(sessionKey: "101", dir: queue)?.text == "target only")
        injection = .done
        check("Codex exact target receives requested text", apply(observer).typed == "target only" && delivered == ["target only"])
        check("Codex sibling queue is isolated", readSessionInputRequest(sessionKey: "202", dir: queue)?.text == "sibling only")
        check("Codex confirmed injection writes result and audit", readSessionInputResult(sessionKey: "101", dir: queue)?.delivered == true && (try? String(contentsOf: log, encoding: .utf8))?.contains("target only") == true)
        check("Codex served request is not replayed", apply(observer).typed == nil && delivered.count == 1)
        epoch += 1
        try writeSessionInputRequest(SessionInputRequest(epoch: epoch, text: "unconfirmed"), sessionKey: "101", dir: queue)
        check("Codex tty bytes without native receipt never report delivered", apply(observer, confirmed: false).typed == nil
            && readSessionInputResult(sessionKey: "101", dir: queue)?.outcome == "unconfirmed-input"
            && readSessionInputResult(sessionKey: "101", dir: queue)?.delivered == false)
        epoch += 1
        injection = .uncertain
        try writeSessionInputRequest(SessionInputRequest(epoch: epoch, text: "partial"), sessionKey: "101", dir: queue)
        check("Codex partial write records uncertainty without delivery or replay", apply(observer).typed == nil
            && readSessionInputResult(sessionKey: "101", dir: queue)?.outcome == "unconfirmed-input"
            && readSessionInputResult(sessionKey: "101", dir: queue)?.delivered == false
            && readSessionInputRequest(sessionKey: "101", dir: queue) == nil)
        injection = .done
        var working = observer
        let activeID = UUID().uuidString
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: line("event_msg", ["type": "task_started", "turn_id": activeID], now))
        try handle.close()
        working.poll(home: home.path)
        try writeSessionInputRequest(SessionInputRequest(epoch: epoch + 1, text: "wait"), sessionKey: "101", dir: queue)
        check("Codex active turn holds queued input", apply(working).typed == nil && delivered.count == 2)
    } catch { check("Codex input fixture: \(error)", false) }
}

nonisolated(unsafe) private var codexPTYGo = false

/// Run only under the test runner's isolated PTY, before the ordinary suite initializes.
func runCodexInputPTYFixture() -> Never {
    guard let terminal = CodexInputRelay() else { exit(10) }
    signal(SIGUSR1) { _ in codexPTYGo = true }
    guard let child = terminal.spawn([CommandLine.arguments[0], "--codex-input-pty-reader", CommandLine.arguments.last!],
                                 environment: ProcessInfo.processInfo.environment) else { terminal.close(); exit(11) }
    func stop(_ code: Int32) -> Never {
        kill(child, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(child, &status, 0)
        terminal.close()
        exit(code)
    }
    guard let generation = SessionMonitoring.generation(child) else { stop(12) }
    let deadline = Date().addingTimeInterval(5)
    while !(terminal.terminalReady(child: child, startedAt: generation) && terminal.canSend) && Date() < deadline { terminal.pump(timeout: 0.01) }
    guard terminal.terminalReady(child: child, startedAt: generation) && terminal.canSend else { stop(13) }
    print("READY"); fflush(stdout)
    while !codexPTYGo && Date() < deadline { terminal.pump(timeout: 0.01) }
    guard codexPTYGo else { stop(14) }
    guard terminal.submit("wrong", child: child, startedAt: generation - 1) == .failed(ENOTTY) else { stop(15) }
    let cancelled = CommandLine.arguments.last! == "cancel"
    let cancellation = Date().addingTimeInterval(0.15)
    let result = terminal.submit(CommandLine.arguments.last!, child: child, startedAt: generation,
        shouldContinue: { !cancelled || Date() < cancellation })
    guard result == (cancelled ? .uncertain : .done) else { stop(16) }
    if cancelled {
        guard !terminal.canSend, terminal.submit("again", child: child, startedAt: generation) == .failed(ENOTTY) else { stop(18) }
    }
    var status: Int32 = 0
    var ended: pid_t = 0
    while Date() < deadline {
        terminal.pump(timeout: 0.01)
        ended = waitpid(child, &status, WNOHANG)
        if ended == child { break }
    }
    guard ended == child else { stop(17) }
    terminal.close()
    exit(supervisorExitCode(childStatus: status))
}

func runCodexInputPTYReader() -> Never {
    var mode = termios()
    guard tcgetattr(STDIN_FILENO, &mode) == 0 else { exit(20) }
    cfmakeraw(&mode)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &mode) == 0 else { exit(21) }
    print("\u{1b}[?2004h", terminator: ""); fflush(stdout)
    _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 512)
    let expected = Array(CommandLine.arguments.last!.utf8).count + (CommandLine.arguments.last! == "cancel" ? 17 : 18)
    let deadline = Date().addingTimeInterval(5)
    while bytes.count < expected && Date() < deadline {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count > 0 { bytes += buffer.prefix(count) }
        usleep(10_000)
    }
    print(Data(bytes).base64EncodedString()); fflush(stdout)
    exit(bytes.count == expected ? 0 : 22)
}
