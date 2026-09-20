import Darwin
import Foundation

// A bounded integration fixture for the resumed-Codex initialization path. The outer process is
// the real supervisor, the inner process is its real private-PTY child, and the child invokes the
// real hook recorder. It is deliberately a native-contract fixture. The separate live smoke runs
// the real Codex client against its local fixture transport; neither check validates a paid service.

private let codexResumeInitializationPrompt = "Tally session initialization. Do not execute tools or continue earlier work. Reply only TALLY_SESSION_READY."

private func codexResumeFixtureStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func codexResumeFixtureLine(type: String, payload: [String: Any], at date: Date) -> Data {
    let object: [String: Any] = ["type": type, "payload": payload,
                                 "timestamp": codexResumeFixtureStamp(date)]
    // Keep this a dictionary so JSONSerialization is the same parser the observer reads.
    var data = try! JSONSerialization.data(withJSONObject: object)
    data.append(10)
    return data
}

private func appendCodexResumeFixture(_ data: Data, to file: URL) {
    let handle = try! FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try! handle.seekToEnd()
    try! handle.write(contentsOf: data)
}

private func codexResumeFixtureTranscript(home: String, sessionID: String) -> URL {
    URL(fileURLWithPath: home).appendingPathComponent("sessions/rollout-\(sessionID).jsonl")
}

private func codexResumeFixtureUserItem(_ text: String, turn: String, at: Date) -> Data {
    codexResumeFixtureLine(type: "event_msg", payload: [
        "type": "item_completed", "turn_id": turn,
        "item": ["type": "UserMessage", "content": [["type": "text", "text": text,
            "text_elements": []]]]
    ], at: at)
}

private func codexResumeFixtureTurn(_ text: String, to file: URL) {
    let turn = UUID().uuidString
    let at = Date().addingTimeInterval(1)
    appendCodexResumeFixture(codexResumeFixtureLine(type: "event_msg", payload: [
        "type": "task_started", "turn_id": turn
    ], at: at), to: file)
    appendCodexResumeFixture(codexResumeFixtureUserItem(text, turn: turn, at: at), to: file)
    appendCodexResumeFixture(codexResumeFixtureLine(type: "event_msg", payload: [
        "type": "task_complete", "turn_id": turn
    ], at: at), to: file)
}

/// Invoked in a separate process by the PTY runner. It creates a historical rollout, marks this
/// home as hook-installed, then hands the exact `resume <UUID>` argv to the production supervisor.
func runCodexResumePTYFixture() -> Never {
    guard let sessionID = CommandLine.arguments.last, UUID(uuidString: sessionID) != nil else { exit(40) }
    let userHome = FileManager.default.homeDirectoryForCurrentUser
    // Both fixture sessions model two historical threads under one installed Codex home. The
    // installation receipt is account-scoped, so separate homes would correctly reject a second
    // concurrent install rather than exercising sibling isolation.
    let home = userHome.appendingPathComponent("codex-resume-fixture")
    let transcript = codexResumeFixtureTranscript(home: home.path, sessionID: sessionID)
    do {
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let historical = Date(timeIntervalSince1970: 1_700_000_000)
        let historyTurn = UUID().uuidString
        var history = codexResumeFixtureLine(type: "session_meta", payload: [
            "id": sessionID, "session_id": sessionID, "source": "cli"
        ], at: historical)
        history += codexResumeFixtureLine(type: "event_msg", payload: [
            "type": "task_started", "turn_id": historyTurn
        ], at: historical.addingTimeInterval(1))
        history += codexResumeFixtureLine(type: "event_msg", payload: [
            "type": "task_complete", "turn_id": historyTurn
        ], at: historical.addingTimeInterval(2))
        try history.write(to: transcript)
        try CodexSessionHooks.install(homes: [home.path],
                                      root: supervisorStateDir.deletingLastPathComponent())
    } catch {
        fputs("resume fixture setup failed: \(error)\n", stderr)
        exit(41)
    }
    // `runCodexSupervised` deliberately passes native argv through untouched. This fixture marker
    // is inherited only by its private child, where main dispatches the owned fake native endpoint.
    // The endpoint still requires the exact initialization argv before it writes any event.
    setenv("TALLY_TEST_CODEX_RESUME_READER", "1", 1)
    let account = Snapshot.Account(id: "codex:resume-fixture", provider: "codex", label: "Resume fixture",
        plan: nil, launchHome: home.path, sessionRemaining: 100, weeklyRemaining: 100,
        modelRemaining: nil, sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
        modelWindowName: nil, resetCreditsAvailable: nil, isStale: false, error: nil,
        refreshedAt: Date(), lastRefreshFailed: false)
    runCodexSupervised(Provider(id: "codex", cli: CommandLine.arguments[0], envKey: "CODEX_HOME",
                                 modelEnvKey: nil), account: account, args: ["resume", sessionID])
}

private func codexResumeReaderSessionID() -> String? {
    let args = CommandLine.arguments
    // The fixture must only manufacture its fresh native lifecycle for the precise argv the
    // wrapper created. Without this check an ordinary historical `resume <UUID>` would be made
    // send-capable by the test double itself, hiding the regression this fixture exists to catch.
    guard args.count == 5, args[1] == "resume", args[3] == "--",
          args[4] == codexResumeInitializationPrompt, UUID(uuidString: args[2]) != nil else { return nil }
    return args[2]
}

private func codexResumeBytes(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
    guard needle.count <= haystack.count, from <= haystack.count - needle.count else { return nil }
    for index in from...(haystack.count - needle.count) where
        Array(haystack[index..<(index + needle.count)]) == needle { return index }
    return nil
}

/// The fake native child is only an owned terminal endpoint. It uses the production hook validator,
/// writes a current lifecycle turn for the initialization argv, and writes a receipt only after the
/// real relay has submitted an exact bracketed-paste request.
func runCodexResumeReader() -> Never {
    guard let home = ProcessInfo.processInfo.environment["CODEX_HOME"],
          let sessionID = codexResumeReaderSessionID() else { exit(50) }
    let transcript = codexResumeFixtureTranscript(home: home, sessionID: sessionID)
    guard FileManager.default.fileExists(atPath: transcript.path) else { exit(51) }
    recordCodexSessionHook(["hook_event_name": "SessionStart", "session_id": sessionID,
                            "transcript_path": transcript.path,
                            "cwd": FileManager.default.currentDirectoryPath],
                           environment: ProcessInfo.processInfo.environment, reporterPID: getpid(),
                           dir: supervisorStateDir)
    // This is the turn the current wrapper's argv asks the native CLI to make. It must be fresh,
    // because historical turn completion never grants direct-input capability.
    codexResumeFixtureTurn(codexResumeInitializationPrompt, to: transcript)
    var mode = termios()
    guard tcgetattr(STDIN_FILENO, &mode) == 0 else { exit(52) }
    cfmakeraw(&mode)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &mode) == 0 else { exit(53) }
    print("\u{1b}[?2004h", terminator: "")
    fflush(stdout)
    _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
    let start = Array("\u{1b}[200~".utf8)
    let end = Array("\u{1b}[201~".utf8)
    var received: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 512)
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count > 0 { received += buffer.prefix(count) }
        if let paste = codexResumeBytes(start, in: received, from: 0),
           let finish = codexResumeBytes(end, in: received, from: paste + start.count),
           received.indices.contains(finish + end.count), received[finish + end.count] == 13,
           let text = String(bytes: received[(paste + start.count)..<finish], encoding: .utf8) {
            codexResumeFixtureTurn(text, to: transcript)
            print("TALLY_RESUME_INPUT \(Data(text.utf8).base64EncodedString())")
            fflush(stdout)
            // Keep the child alive while the production supervisor reads the matching receipt.
            // An immediate PTY hangup would turn a delivered transcript record into an
            // unconfirmed input, which tests relay shutdown rather than receipt correlation.
            while true { pause() }
        }
        usleep(10_000)
    }
    exit(54)
}
