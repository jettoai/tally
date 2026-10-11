import Foundation
import Darwin

// THE USER'S OWN CHECK BEFORE A SUPERVISED SPAWN (issue #7).
//
// One command, set on this Mac by `tally prespawn set` and stored in ~/.tally/prespawn.json, never
// in a repository file: a repo's own files (or its .envrc) must not be able to add a program that
// runs on every handoff. Tally runs it and reads only its exit status and the first line of its
// stderr; it never reads or changes the login in any home.
//
// Exit 0 passes. Nonzero rejects THIS spawn. A timeout passes, so a hung check can delay a launch
// but never block one. No file means nothing runs and nothing changes.
//
// Self-contained (Foundation and Darwin only) so tests/prespawn compiles it on its own.

let preSpawnConfigURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/prespawn.json")
let preSpawnDefaultTimeout = 5
let preSpawnTimeoutRange = 1...30
/// How long a rejected relaunch target is left alone before the supervisor asks again.
let preSpawnHoldSeconds: TimeInterval = 120
/// `PendingNotice.kind` of the badge a rejected relaunch leaves on the status line.
let preSpawnNoticeKind = "prespawn-held"

struct PreSpawnEntry: Codable, Equatable {
    var command: String
    var timeoutSeconds: Int?
}
typealias PreSpawnFile = [String: PreSpawnEntry]   // provider id -> entry

enum PreSpawnRead: Equatable { case unset, unreadable, entry(PreSpawnEntry) }

/// The whole file, for a writer. A missing file is an empty one; nil means it is there but could
/// not be read, which a writer must not overwrite.
func loadPreSpawnFile(_ url: URL = preSpawnConfigURL) -> PreSpawnFile? {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(PreSpawnFile.self, from: data)
}

func readPreSpawn(provider: String, url: URL = preSpawnConfigURL) -> PreSpawnRead {
    guard let file = loadPreSpawnFile(url) else { return .unreadable }
    guard let entry = file[provider],
          !entry.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unset }
    return .entry(entry)
}

/// Write the file atomically, owner-only. An empty file is removed instead, so "nothing set" is
/// the same state as before anything was ever set: no file at all.
func savePreSpawn(_ file: PreSpawnFile, to url: URL = preSpawnConfigURL) throws {
    if file.isEmpty {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try encoder.encode(file).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

struct PreSpawnContext {
    let provider: String
    let homePath: String
    let label: String
    let accountID: String
    /// `launch` for the first start, otherwise the relaunch plan's own tag (`self-update`, `cap`...).
    let reason: String
}

enum PreSpawnVerdict: Equatable {
    case unset                                          // nothing configured: the caller does nothing
    case passed
    case timedOut(seconds: Int)
    case rejected(status: String, firstLine: String)    // status: "exit 1", "signal 9", "spawn failed"
}

func preSpawnEnvironment(_ ctx: PreSpawnContext, base: [String: String]) -> [String: String] {
    var env = base
    env["TALLY_HOME_PATH"] = ctx.homePath
    env["TALLY_HOME_LABEL"] = ctx.label
    env["TALLY_ACCOUNT_ID"] = ctx.accountID
    env["TALLY_SPAWN_REASON"] = ctx.reason
    env["TALLY_PROVIDER"] = ctx.provider
    if ctx.provider == "claude" { env["CLAUDE_CONFIG_DIR"] = ctx.homePath }
    return env
}

/// Run `/bin/sh -c command` in its own process group with stdin and stdout on /dev/null (the
/// terminal belongs to the user and to claude) and stderr in a temp file (a file, not a pipe: a
/// pipe needs a reader thread, and a background grandchild holding the write end would keep EOF
/// from ever arriving). On timeout the whole group is terminated, then killed, then reaped.
func runPreSpawnCommand(_ command: String, timeout: Int, environment: [String: String],
                        pollInterval: useconds_t = 50_000,
                        termGrace: TimeInterval = 1) -> PreSpawnVerdict {
    let errURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-prespawn-\(getpid())-\(UUID().uuidString).err")
    defer { try? FileManager.default.removeItem(at: errURL) }
    func spawnFailed(_ code: Int32) -> PreSpawnVerdict {
        .rejected(status: "spawn failed",
                  firstLine: "could not run pre-spawn command: \(String(cString: strerror(code)))")
    }

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return spawnFailed(errno) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { return spawnFailed(errno) }
    defer { posix_spawnattr_destroy(&attributes) }

    // The supervisor ignores SIGINT/SIGQUIT and an ignored signal survives exec; give them back.
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGINT, SIGQUIT, SIGPIPE] { sigaddset(&defaults, sig) }
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
    guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
          posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
          errURL.path.withCString({
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, $0,
                                               O_WRONLY | O_CREAT | O_TRUNC, 0o600)
          }) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
          posix_spawnattr_setflags(&attributes, Int16(flags)) == 0
    else { return spawnFailed(errno) }

    var cArgs: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", command].map { strdup($0) }
    cArgs.append(nil)
    var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    cEnv.append(nil)
    defer { for pointer in cArgs + cEnv { free(pointer) } }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, "/bin/sh", &actions, &attributes, cArgs, cEnv)
    guard rc == 0 else { return spawnFailed(rc) }

    var status: Int32 = 0
    let deadline = Date().addingTimeInterval(TimeInterval(timeout))
    while waitpid(pid, &status, WNOHANG) != pid {
        guard Date() < deadline else {
            killpg(pid, SIGTERM)
            let graceEnd = Date().addingTimeInterval(termGrace)
            var reaped = false
            while Date() < graceEnd {
                if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
                usleep(pollInterval)
            }
            killpg(pid, SIGKILL)   // grandchildren that ignored TERM, or outlived their shell
            if !reaped { _ = waitpid(pid, &status, 0) }
            return .timedOut(seconds: timeout)
        }
        usleep(pollInterval)
    }

    let signal = status & 0x7f, code = (status >> 8) & 0xff
    if signal == 0 && code == 0 { return .passed }
    return .rejected(status: signal == 0 ? "exit \(code)" : "signal \(signal)",
                     firstLine: preSpawnFirstLine(errURL))
}

/// The first non-empty line of what the command wrote to stderr, trimmed and capped.
func preSpawnFirstLine(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 4096)) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    let line = text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty } ?? ""
    return String(line.prefix(200))
}

/// The one entry both gates call. `unreadable` tells the first-launch caller whether to say the
/// file is broken; the verdict is `.unset` then, exactly as with no file.
func preSpawnVerdict(_ ctx: PreSpawnContext, url: URL = preSpawnConfigURL,
                     base: [String: String] = ProcessInfo.processInfo.environment)
    -> (verdict: PreSpawnVerdict, unreadable: Bool) {
    switch readPreSpawn(provider: ctx.provider, url: url) {
    case .unset: return (.unset, false)
    case .unreadable: return (.unset, true)
    case .entry(let entry):
        let timeout = min(max(entry.timeoutSeconds ?? preSpawnDefaultTimeout,
                              preSpawnTimeoutRange.lowerBound), preSpawnTimeoutRange.upperBound)
        return (runPreSpawnCommand(entry.command, timeout: timeout,
                                   environment: preSpawnEnvironment(ctx, base: base)), false)
    }
}

/// Terminal wording, first launch only. nil when there is nothing to say.
func preSpawnTerminalLine(_ verdict: PreSpawnVerdict, label: String) -> String? {
    switch verdict {
    case .unset, .passed: return nil
    case .timedOut(let seconds):
        return "pre-spawn check timed out after \(seconds)s for \(label); launching anyway"
    case .rejected(let status, let firstLine):
        return "pre-spawn check rejected \(label) (\(status))" + (firstLine.isEmpty ? "" : ": \(firstLine)")
    }
}

/// handoff.log line, relaunch only (the terminal belongs to the child then). One line, fixed
/// tab-separated fields, whatever the command printed.
func preSpawnLogLine(_ verdict: PreSpawnVerdict, pid: String, from: String, to: String,
                     reason: String, at: Date = Date()) -> String? {
    let event: String, status: String, firstLine: String
    switch verdict {
    case .unset, .passed: return nil
    case .timedOut(let seconds): (event, status, firstLine) = ("prespawn-timeout", "timeout \(seconds)s", "")
    case .rejected(let s, let line): (event, status, firstLine) = ("prespawn-rejected", s, line)
    }
    let clean = { (field: String) in
        field.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
    let fields = [ISO8601DateFormatter().string(from: at), event, "pid=\(pid)", "from=\(from)",
                  "to=\(to)", "reason=\(reason)", status, firstLine].map(clean)
    return fields.joined(separator: "\t") + "\n"
}
