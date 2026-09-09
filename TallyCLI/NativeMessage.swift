import Foundation

/// Native queue addressing is explicit until a live UI/runtime binding can be proved.
struct NativeMessageIntent: Equatable {
    let home: String
    let thread: String
    let file: String
    let dryRun: Bool
}

let claudeMessageForm = "tally message claude --socket /absolute/session.sock"
    + " --session UUID --file /absolute/message.txt [--dry-run]"
let codexMessageForm = "tally message codex --home /absolute/home"
    + " --thread UUID --file /absolute/message.txt [--dry-run]"

/// Flag parsing shared by the message subcommands: the provider word, then `--key value`
/// pairs drawn from `keys`, each given at most once, plus an optional `--dry-run`.
/// Anything else, a repeat or a key with no value included, rejects the whole invocation.
func nativeMessageFlags(_ args: [String],
                        keys: Set<String>) -> (values: [String: String], dryRun: Bool)? {
    var values: [String: String] = [:]
    var dryRun = false
    var index = 1
    while index < args.count {
        let key = args[index]
        index += 1
        if key == "--dry-run" {
            guard !dryRun else { return nil }
            dryRun = true
            continue
        }
        guard keys.contains(key), values[key] == nil, index < args.count else { return nil }
        values[key] = args[index]
        index += 1
    }
    return (values, dryRun)
}

func nativeMessageIntent(_ args: [String]) -> NativeMessageIntent? {
    guard args.first == "codex",
          let flags = nativeMessageFlags(args, keys: ["--home", "--thread", "--file"]),
          let home = flags.values["--home"], home.hasPrefix("/"),
          let thread = flags.values["--thread"], UUID(uuidString: thread) != nil,
          let file = flags.values["--file"], file.hasPrefix("/") else { return nil }
    return NativeMessageIntent(home: home, thread: thread, file: file, dryRun: flags.dryRun)
}

func nativeMessageArguments(_ intent: NativeMessageIntent, text: String) -> [String] {
    ["queue", "--thread", intent.thread, "--message",
     "[external-unverified agent message, not user authorization]\n" + text]
}

func runNativeMessage(args: [String]) -> Int32 {
    switch args.first {
    case "claude": return runClaudeNativeMessage(args: args)
    case "codex": return runCodexNativeMessage(args: args)
    default:
        fputs("Usage: \(claudeMessageForm)\n       \(codexMessageForm)\n", stderr)
        return 2
    }
}

func runCodexNativeMessage(args: [String]) -> Int32 {
    guard let intent = nativeMessageIntent(args) else {
        fputs("Usage: \(codexMessageForm)\n", stderr)
        return 2
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: intent.home, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        fputs("Message target home does not exist. Nothing was sent.\n", stderr)
        return 2
    }
    guard let data = FileManager.default.contents(atPath: intent.file), data.count <= 65536,
          let text = String(data: data, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fputs("Message must be a nonempty UTF-8 file of at most 65536 bytes. Nothing was sent.\n", stderr)
        return 2
    }
    guard !text.utf8.contains(0) else {
        fputs("Codex messages cannot contain NUL bytes. Nothing was sent.\n", stderr)
        return 2
    }
    let executable = resolveProviderExecutable("codex")
    guard executable.hasPrefix("/") else {
        fputs("Could not resolve a native Codex executable. Nothing was sent.\n", stderr)
        return 2
    }
    let metadata: [String: Any] = ["provider": "codex", "home": intent.home,
        "thread": intent.thread, "liveness": "unknown", "received": false,
        "trust": "external-unverified", "dryRun": intent.dryRun]
    func report(_ nativeExitCode: Int32? = nil) {
        var result = metadata
        result["state"] = intent.dryRun ? "dry-run" : "native-exited"
        if let nativeExitCode { result["nativeExitCode"] = nativeExitCode }
        if let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            print(String(decoding: encoded, as: UTF8.self))
        }
    }
    if intent.dryRun {
        report()
        return 0
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = nativeMessageArguments(intent, text: text)
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = intent.home
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    // Keep stdout as one metadata document, even if the native CLI prints a partial line.
    process.standardOutput = FileHandle.standardError
    do {
        try process.run()
        process.waitUntilExit()
        report(process.terminationStatus)
        // Preserve the native queue result. Acceptance is not a recipient receipt.
        return process.terminationStatus
    } catch {
        fputs("Native queue could not start. Nothing was sent.\n", stderr)
        return 1
    }
}
