import Darwin
import Foundation

// B-1736 round 2, P1/P2: a `tally session skip-update` request served by `handleStartupChoice`
// through a real CodexInputRelay into a real PTY child that drew the 0.162.1 update menu. Driven by
// tests/supervisor/codexstartuppty.py; the mode is "match", "stale" or "none" (no request at all).

func runCodexStartupPTYFixture() -> Never {
    let mode = CommandLine.arguments.last!
    guard let terminal = CodexInputRelay() else { exit(10) }
    guard let child = terminal.spawn([CommandLine.arguments[0], "--codex-startup-pty-reader"],
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
    while !(terminal.terminalReady(child: child, startedAt: generation)
            && terminal.startupScreen.menuLines?.contains("3. Skip until next version") == true) && Date() < deadline {
        _ = terminal.pump(timeout: 0.01)
    }
    let launched = Date().addingTimeInterval(-30)
    let stall = codexStartupStall(screen: terminal.startupScreen, launchedAt: launched, bindingLanded: false, now: Date())
    guard let record = codexStartupScreenRecord(terminal.startupScreen, stall: stall), let id = record.screenID else { stop(13) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-startup-pty-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = String(getpid())
    var spawned = false
    var result = "none"
    if mode != "none" {
        let request = StartupChoiceRequest(screenID: mode == "match" ? id : "scr_0000000000000000", nonce: "n", at: Date())
        guard let data = try? startupChoiceEncoder().encode(request),
              writePrivateAtomically(data, to: dir.appendingPathComponent(key + startupChoiceSuffix)) else { stop(14) }
        result = handleStartupChoice(pid: key, record: record, relay: terminal, child: child, childStart: generation,
                                     dir: dir, sent: { spawned = true }) ?? "unserved"
    }
    let receipt = (try? Data(contentsOf: dir.appendingPathComponent(key + startupChoiceReceiptSuffix)))
        .flatMap { try? startupChoiceDecoder().decode(StartupChoiceReceipt.self, from: $0) }
    let leftover = FileManager.default.fileExists(atPath: dir.appendingPathComponent(key + startupChoiceSuffix).path)
    print("RESULT \(result) receipt=\(receipt?.result ?? "none") spawned=\(spawned) leftover=\(leftover)\r")
    fflush(stdout)
    var status: Int32 = 0
    var ended: pid_t = 0
    let end = Date().addingTimeInterval(5)
    while Date() < end {
        _ = terminal.pump(timeout: 0.01)
        ended = waitpid(child, &status, WNOHANG)
        if ended == child { break }
    }
    guard ended == child else { stop(17) }
    terminal.drainOutput()
    terminal.close()
    exit(supervisorExitCode(childStatus: status))
}

/// The child: draws the real 0.162.1 menu bytes, then reports every byte it is sent for 1.5s.
func runCodexStartupPTYReader() -> Never {
    var mode = termios()
    guard tcgetattr(STDIN_FILENO, &mode) == 0 else { exit(20) }
    cfmakeraw(&mode)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &mode) == 0 else { exit(21) }
    guard let menu = try? Data(contentsOf: URL(fileURLWithPath: "tests/codex-supervisor/fixtures/update-menu-0.162.1.bin")) else { exit(22) }
    FileHandle.standardOutput.write(menu)
    _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 512)
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count > 0 { bytes += buffer.prefix(count) }
        usleep(10_000)
    }
    print("\r\nBYTES \(Data(bytes).base64EncodedString())\r")
    fflush(stdout)
    exit(0)
}
