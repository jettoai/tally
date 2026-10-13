import Foundation

/// Spawns a provider's own CLI and captures its stdout for usage readers.
///
/// Those readers use the official clients (`claude -p "/usage"`, `codex app-server`), which
/// handle their own credentials and vendor requests. This runner does not read credentials
/// or call vendor endpoints.
enum CLIRunner {
    /// GUI apps get a minimal PATH (`/usr/bin:/bin:…`), so the binary is looked for where CLIs
    /// install to, on the user's login-shell PATH, and on the app's own PATH, never in Tally's
    /// shim directory (`CLISearchPath`).
    static func resolve(_ name: String) -> String? {
        CLISearchPath.shared.resolve(name)
    }

    struct Output: Sendable {
        var exitCode: Int32
        var stdout: String
        /// Captured too, because a CLI's answer is not always on stdout: `codex login status`
        /// reports the whole of it here. Drained on its own queue rather than after stdout - a
        /// child that fills the stderr pipe (64 KB) while the parent blocks on stdout deadlocks,
        /// and the previous version, which never read this pipe at all, could do exactly that.
        var stderr: String = ""
        /// The watchdog ended the run, as opposed to the CLI exiting on its own (B-1745): a reader
        /// can tell "took too long" from "said no" and decide whether a second attempt is worth it.
        var timedOut = false
    }

    /// One background read's result. A reference so the reading queue and the caller share it.
    /// Unchecked because the `DispatchGroup` below IS the synchronisation the compiler cannot see:
    /// exactly one queue writes `value`, and nothing reads it until `wait()` has returned, which
    /// orders the write before every later read.
    private final class Captured: @unchecked Sendable {
        var value = Data()
    }

    /// Set on the watchdog's queue and read once the child has exited; the lock orders the two.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Run a CLI to completion off the main actor. `environment` entries overlay the app's env;
    /// a nil value REMOVES the variable (the default-home rule: `CLAUDE_CONFIG_DIR` must be unset
    /// for `~/.claude`, or the CLI looks up a hashed Keychain item that doesn't exist).
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String?] = [:],
        currentDirectory: URL? = nil,
        input: String? = nil,
        timeout: TimeInterval = 30,
        claudeInstall: ClaudeNativeInstall = .current,
        searchPath: CLISearchPath = .shared
    ) async -> Output? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                // Off the main actor: the mapping may re-link the bundle (ClaudeStableExecutable.swift).
                process.executableURL = URL(fileURLWithPath: claudeStableExecutable(executable, install: claudeInstall))
                process.arguments = arguments
                // The CLI's own directory and the login shell's PATH: an npm CLI starts with
                // `#!/usr/bin/env node`, which the app's PATH cannot satisfy (issue #8).
                var env = searchPath.environment(for: executable)
                for (key, value) in environment {
                    if let value { env[key] = value } else { env.removeValue(forKey: key) }
                }
                process.environment = env
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let stdin = Pipe()
                process.standardInput = stdin

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                if let input {
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                }
                try? stdin.fileHandleForWriting.close()

                // Watchdog: a wedged CLI must never stall the refresh loop.
                let timedOut = TimeoutFlag()
                let watchdog = DispatchWorkItem {
                    if process.isRunning { timedOut.set(); process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Both pipes are drained concurrently, then joined: reading one to EOF while the
                // child is still filling the other is a deadlock waiting for a chatty CLI.
                let errorData = Captured()
                let draining = DispatchGroup()
                DispatchQueue.global(qos: .utility).async(group: draining) {
                    errorData.value = stderr.fileHandleForReading.readDataToEndOfFile()
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                draining.wait()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: Output(
                    exitCode: process.terminationStatus,
                    stdout: String(data: data, encoding: .utf8) ?? "",
                    stderr: String(data: errorData.value, encoding: .utf8) ?? "",
                    timedOut: timedOut.isSet
                ))
            }
        }
    }
}
