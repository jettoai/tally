import Foundation
import os

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

    /// What one pipe has delivered so far. Filled from the pipe's readability handler (a dispatch
    /// queue) and read by the runner once the child has gone, so the lock orders the two.
    private final class Captured: Sendable {
        private let data = OSAllocatedUnfairLock(initialState: Data())
        func append(_ chunk: Data) { data.withLock { $0.append(chunk) } }
        var value: Data { data.withLock { $0 } }
    }

    /// After the child is gone, how long its pipes may stay open before the runner stops waiting
    /// for them. A grandchild that inherited the pipe (a `sleep` or helper the CLI started) holds
    /// it open after the CLI is killed; waiting for its EOF stretched a 60 second watchdog to
    /// 108 to 154 seconds (2026-11-04, B-3918). The same value is how long a child that ignores
    /// SIGTERM gets before the watchdog sends SIGKILL.
    static let pipeGrace: TimeInterval = 2

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
                // Set on the watchdog's queue and read once the child has exited; the lock orders the two.
                let timedOut = OSAllocatedUnfairLock(initialState: false)
                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.withLock { $0 = true }
                    process.terminate()
                    // A CLI that ignores SIGTERM is not allowed to outlive the watchdog.
                    DispatchQueue.global().asyncAfter(deadline: .now() + pipeGrace) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Both pipes are drained concurrently as the child writes: reading one to EOF while
                // the child is still filling the other is a deadlock waiting for a chatty CLI.
                let outData = Captured()
                let errorData = Captured()
                let draining = DispatchGroup()
                func drain(_ pipe: Pipe, into captured: Captured) {
                    draining.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            draining.leave()
                        } else {
                            captured.append(chunk)
                        }
                    }
                }
                drain(stdout, into: outData)
                drain(stderr, into: errorData)
                process.waitUntilExit()
                // EOF normally arrives with the exit; a grandchild still holding a pipe open does
                // not get to keep this run, whatever the child managed to print is already here.
                _ = draining.wait(timeout: .now() + pipeGrace)
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                watchdog.cancel()
                continuation.resume(returning: Output(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData.value, encoding: .utf8) ?? "",
                    stderr: String(data: errorData.value, encoding: .utf8) ?? "",
                    timedOut: timedOut.withLock { $0 }
                ))
            }
        }
    }
}
