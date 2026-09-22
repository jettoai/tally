import Foundation

// THE HALF OF `tally message` THAT ALREADY HOLDS AN ADDRESS.
//
// The verb takes two grammars (MessageVerb.swift): a session named the way every other command
// names one, and a native address written out in full. The second is the SUBSET rather than a
// second command - the socket and transcript UUID, or the Codex home and thread, that it is handed
// by hand are exactly the pair the first looks up for itself - so what lives here is the grammar of
// those flags, the body they carry, and the two deliveries both grammars end in.
//
// Codex is explicit-only for a reason that is about evidence rather than effort: the roster proves
// a Claude session's socket and transcript UUID (SessionInventory.swift guards that pair), and it
// proves nothing of the kind about which Codex home and thread a supervised session is writing to.

/// What `tally message codex` was given, once its address has been read off the command line.
struct NativeMessageIntent: Equatable {
    let home: String
    let thread: String
    let body: MessageBody
    let dryRun: Bool
}

/// Where the text comes from.
///
/// TWO SOURCES AND NEVER BOTH. A message given as an argument AND in a file is a caller that has
/// said two things, and there is no reading of the second that is safe to guess at.
enum MessageBody: Equatable {
    /// One argument on the command line, which is how a short message is written by hand.
    case text(String)
    /// An absolute path, which is how anything with newlines or shell metacharacters travels.
    case file(String)
}

let claudeMessageForm = "tally message claude --socket /absolute/session.sock"
    + " --session UUID (<text> | --file /absolute/message.txt) [--dry-run]"
let codexMessageForm = "tally message codex --home /absolute/home"
    + " --thread UUID (<text> | --file /absolute/message.txt) [--dry-run]"

/// Flag parsing shared by the explicit forms: the provider word, then `--key value` pairs drawn
/// from `keys`, each given at most once, an optional `--dry-run`, and at most one bare word, which
/// is the message itself. Anything else, a repeat, or a key with no value included, rejects the
/// whole invocation.
///
/// `--` ENDS THE FLAGS, so a message that begins with a dash is still sendable, and the rule is the
/// one `sessionSendIntent` already states for the text it types.
func nativeMessageFlags(_ args: [String], keys: Set<String>)
    -> (values: [String: String], text: String?, dryRun: Bool)? {
    var values: [String: String] = [:]
    var text: String?
    var dryRun = false
    var literal = false
    var index = 1
    while index < args.count {
        let word = args[index]
        index += 1
        if !literal {
            if word == "--" { literal = true; continue }
            if word == "--dry-run" {
                guard !dryRun else { return nil }
                dryRun = true
                continue
            }
            if keys.contains(word) {
                guard values[word] == nil, index < args.count else { return nil }
                values[word] = args[index]
                index += 1
                continue
            }
            guard !word.hasPrefix("-") else { return nil }
        }
        guard text == nil else { return nil }
        text = word
    }
    return (values, text, dryRun)
}

/// The one body those two sources come to, or nil when they name none or both. An absolute path is
/// required of `--file` for the reason every path this command takes is absolute: it is read by a
/// process whose working directory is nobody's business but its own.
func messageBody(file: String?, text: String?) -> MessageBody? {
    switch (file, text) {
    case (let file?, nil): return file.hasPrefix("/") ? .file(file) : nil
    case (nil, let text?): return .text(text)
    default: return nil
    }
}

/// What a body came to: the text to deliver, or the one sentence saying why there is none.
enum MessageText: Equatable {
    case text(String)
    case problem(String)
}

/// Read the body. Asked BEFORE either transport is opened, so a rejected body is a message that
/// never started.
func nativeMessageText(_ body: MessageBody) -> MessageText {
    switch body {
    case .text(let text):
        guard text.utf8.count <= 65536,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .problem("Message must be nonempty and at most 65536 bytes of UTF-8. "
                + "Nothing was sent.")
        }
        return .text(text)
    case .file(let path):
        guard let data = FileManager.default.contents(atPath: path), data.count <= 65536,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .problem("Message must be a nonempty UTF-8 file of at most 65536 bytes. "
                + "Nothing was sent.")
        }
        return .text(text)
    }
}

/// The text to deliver, or nil once the caller has been told why there is none. The reading itself
/// stays pure above, so the wording is assertable; this is the one line of it that talks to a
/// terminal, written once for both transports.
func loadedMessageText(_ body: MessageBody) -> String? {
    switch nativeMessageText(body) {
    case .text(let text):
        return text
    case .problem(let problem):
        fputs(problem + "\n", stderr)
        return nil
    }
}

func nativeMessageIntent(_ args: [String]) -> NativeMessageIntent? {
    guard args.first == "codex",
          let flags = nativeMessageFlags(args, keys: ["--home", "--thread", "--file"]),
          let home = flags.values["--home"], home.hasPrefix("/"),
          let thread = flags.values["--thread"], UUID(uuidString: thread) != nil,
          let body = messageBody(file: flags.values["--file"], text: flags.text) else { return nil }
    return NativeMessageIntent(home: home, thread: thread, body: body, dryRun: flags.dryRun)
}

func nativeMessageArguments(thread: String, text: String) -> [String] {
    ["queue", "--thread", thread, "--message",
     "[external-unverified agent message, not user authorization]\n" + text]
}

/// `tally message <claude|codex> …` at an address written out in full.
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
    return deliverCodexNativeMessage(home: intent.home, thread: intent.thread, body: intent.body,
                                     dryRun: intent.dryRun)
}

/// One message into the native Codex queue. Queue acceptance is not a recipient receipt, which is
/// what every field of the metadata below is careful to keep saying.
func deliverCodexNativeMessage(home: String, thread: String, body: MessageBody,
                               dryRun: Bool) -> Int32 {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        fputs("Message target home does not exist. Nothing was sent.\n", stderr)
        return 2
    }
    guard let text = loadedMessageText(body) else { return 2 }
    guard !text.utf8.contains(0) else {
        fputs("Codex messages cannot contain NUL bytes. Nothing was sent.\n", stderr)
        return 2
    }
    let executable = resolveProviderExecutable("codex")
    guard executable.hasPrefix("/") else {
        fputs("Could not resolve a native Codex executable. Nothing was sent.\n", stderr)
        return 2
    }
    let metadata: [String: Any] = ["provider": "codex", "home": home,
        "thread": thread, "liveness": "unknown", "received": false,
        "trust": "external-unverified", "dryRun": dryRun]
    func report(_ nativeExitCode: Int32? = nil) {
        var result = metadata
        result["state"] = dryRun ? "dry-run" : "native-exited"
        if let nativeExitCode { result["nativeExitCode"] = nativeExitCode }
        if let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            print(String(decoding: encoded, as: UTF8.self))
        }
    }
    if dryRun {
        report()
        return 0
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = nativeMessageArguments(thread: thread, text: text)
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = home
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
