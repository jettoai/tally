import Darwin
import Foundation

/// Runs Anthropic's official install line in the background, on a pty, in its own process group, and
/// reads it: progress for the page, a log for the user, an answer from the exit code and the CLI
/// being findable (never from the script's words). Nothing here touches a credential; the script
/// downloads a binary and verifies it against Anthropic's published checksum itself.
enum ClaudeInstallRunner {
    /// Raised by Cancel; read by the run loop (same shape as RenewLoginRunner.LoginCancel).
    final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    struct Update: Sendable {
        var stage: ClaudeInstall.Stage
        var lines: [String]
    }

    enum Outcome: Equatable, Sendable {
        case installed
        case cancelled
        case failed(ClaudeInstall.Report)
    }

    static let defaultLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Tally/claude-install.log")

    /// `command` is `WelcomeFlow.installCommand` verbatim; `home` is where the script installs (and
    /// where its download folder is watched), a parameter so tests never touch the real one.
    static func run(command: String, home: String = NSHomeDirectory(), log: URL = defaultLog,
                    stallSeconds: TimeInterval = ClaudeInstall.stallSeconds,
                    overallSeconds: TimeInterval = ClaudeInstall.overallSeconds,
                    cancel: Cancel,
                    onStart: (@Sendable (pid_t) -> Void)? = nil,
                    onUpdate: @escaping @Sendable (Update) -> Void,
                    cliFound: @escaping @Sendable () -> Bool) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(
                    command: command, home: home, log: log, stallSeconds: stallSeconds,
                    overallSeconds: overallSeconds, cancel: cancel, onStart: onStart,
                    onUpdate: onUpdate, cliFound: cliFound))
            }
        }
    }

    private static func runSync(command: String, home: String, log: URL,
                                stallSeconds: TimeInterval, overallSeconds: TimeInterval,
                                cancel: Cancel, onStart: (@Sendable (pid_t) -> Void)?,
                                onUpdate: @Sendable (Update) -> Void,
                                cliFound: @Sendable () -> Bool) -> Outcome {
        let report = { (failure: ClaudeInstall.Failure, last: String) -> Outcome in
            .failed(ClaudeInstall.Report(failure: failure, lastLine: last))
        }
        // The log is overwritten per run (it holds the last install only) and is best-effort: a
        // folder that cannot be made must not stop the install.
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: log)
        defer { try? logHandle?.close() }

        var primary: Int32 = 0, replica: Int32 = 0
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &replica, nil, nil, &size) == 0 else { return report(.other, "") }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            close(primary); close(replica)
            return report(.other, "")
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        // No input at all: a program that reads stdin gets EOF instead of waiting for a person. Its
        // own process group, so Cancel and the clocks can end bash, curl and the installer together.
        // This runs on a GCD worker thread, which blocks the asynchronous signals, and a spawned child
        // inherits that mask: without a clean one SIGTERM never reaches bash, sleep, cat or curl and
        // killGroup can only insist. So the child starts with an empty mask and default dispositions.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, replica, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, replica, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, primary) == 0,
              posix_spawn_file_actions_addclose(&actions, replica) == 0,
              posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
              posix_spawnattr_setsigmask(&attributes, &noSignals) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(primary); close(replica)
            return report(.other, "")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "xterm-256color"
        environment["HOME"] = home
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        var argv = ["/bin/bash", "-o", "pipefail", "-c", command].map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { a in
            envp.withUnsafeMutableBufferPointer { e in
                posix_spawn(&pid, "/bin/bash", &actions, &attributes, a.baseAddress!, e.baseAddress!)
            }
        }
        // The parent's copy of the child's end, or the read side never reaches EOF.
        close(replica)
        guard spawned == 0 else { close(primary); return report(.other, "") }
        defer { close(primary) }
        onStart?(pid)

        let started = Date()
        var lastProgress = started
        var lastUpdate = Date.distantPast
        var raw = [UInt8]()                 // the last 64 KB of output, for the page and the verdict
        var logCarry = [UInt8]()            // bytes of a character or escape sequence not yet complete
        var downloadSeen = false
        var downloadBytes: Int64?
        var sentSignature = ""
        var eof = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        let downloads = home + "/.claude/downloads"

        func plain() -> String {
            RenewLoginCommand.plainText(String(decoding: raw, as: UTF8.self)).replacingOccurrences(of: "\r\n", with: "\n")
        }
        func send(force: Bool) {
            let text = plain()
            let stage = ClaudeInstall.stage(plainOutput: text, downloadBytes: downloadBytes, downloadSeen: downloadSeen)
            let lines = ClaudeInstall.tail(text)
            let signature = "\(stage)|\(lines.count)|\(lines.last ?? "")"
            guard force || (signature != sentSignature && Date().timeIntervalSince(lastUpdate) >= 0.5) else { return }
            sentSignature = signature
            lastUpdate = Date()
            onUpdate(Update(stage: stage, lines: lines))
        }
        func absorb(count: Int) {
            raw.append(contentsOf: buffer[0 ..< count])
            if raw.count > 65_536 { raw.removeFirst(raw.count - 65_536) }
            writeLog(buffer[0 ..< count], carry: &logCarry, to: logHandle)
        }
        func drain() {
            _ = fcntl(primary, F_SETFL, fcntl(primary, F_GETFL) | O_NONBLOCK)
            while true {
                let count = read(primary, &buffer, buffer.count)
                guard count > 0 else { break }
                absorb(count: count)
            }
        }

        while true {
            if !eof {
                var poller = pollfd(fd: primary, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, 500)
                if ready < 0, errno != EINTR { eof = true }
                if ready > 0 {
                    let count = read(primary, &buffer, buffer.count)
                    if count > 0 { absorb(count: count); lastProgress = Date() } else { eof = true }
                }
            } else {
                usleep(100_000)
            }
            // The script's download file growing is progress even while it prints nothing.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: downloads))?
                .filter { $0.hasPrefix("claude-") } ?? []
            if !names.isEmpty {
                downloadSeen = true
                let listing = names.compactMap { name -> (name: String, size: Int64)? in
                    guard let bytes = (try? FileManager.default.attributesOfItem(atPath: downloads + "/" + name))?[.size] as? NSNumber
                    else { return nil }
                    return (name, bytes.int64Value)
                }
                let bytes = ClaudeInstall.downloadBytes(listing)
                if bytes != downloadBytes { lastProgress = Date() }
                downloadBytes = bytes
            }
            send(force: false)

            let now = Date()
            if cancel.isRaised {
                killGroup(pid); drain(); send(force: true)
                return .cancelled
            }
            if now.timeIntervalSince(started) >= overallSeconds {
                killGroup(pid); drain(); send(force: true)
                return report(.tooLong, ClaudeInstall.lastLine(plain()))
            }
            if now.timeIntervalSince(lastProgress) >= stallSeconds {
                killGroup(pid); drain(); send(force: true)
                return report(.stalled, ClaudeInstall.lastLine(plain()))
            }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                drain(); send(force: true)
                let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                let last = ClaudeInstall.lastLine(plain())
                guard let failure = ClaudeInstall.failure(lastLine: last, exitCode: code, cliFound: cliFound())
                else { return .installed }
                return report(failure, last)
            }
        }
    }

    /// End bash and everything it started: ask the group, then insist. Killing only bash would leave
    /// a download in flight.
    private static func killGroup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0 ..< 60 {
            if waitpid(pid, &status, WNOHANG) == pid { return }
            usleep(50_000)
        }
        kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
    }

    /// Appends the chunk to the log with terminal control codes removed. A multi-byte character or
    /// an escape sequence cut by the read boundary waits in `carry` for its rest.
    private static func writeLog(_ chunk: ArraySlice<UInt8>, carry: inout [UInt8], to handle: FileHandle?) {
        guard let handle else { return }
        var bytes = carry + chunk
        carry = []
        // Hold back a trailing, incomplete UTF-8 character (at most 3 bytes).
        var cut = bytes.count
        var back = 0
        while back < 4, cut > 0 {
            let b = bytes[cut - 1]
            if b & 0xC0 == 0x80 { cut -= 1; back += 1; continue }
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if need > back + 1 { cut -= 1 } else { cut = bytes.count }
            break
        }
        if cut < bytes.count { carry = Array(bytes[cut...]); bytes = Array(bytes[..<cut]) }
        var text = RenewLoginCommand.plainText(String(decoding: bytes, as: UTF8.self))
        // An escape sequence still open at the end is finished by the next chunk.
        if let esc = text.lastIndex(of: "\u{1B}") {
            let open = Array(text[esc...].utf8)
            if open.count < 64 { carry = open + carry; text = String(text[..<esc]) }
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
