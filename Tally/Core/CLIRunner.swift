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
        /// The run was ended because `answerComplete` said the answer was all there (B-3918); the
        /// CLI's own exit status is then the kill's, not a verdict on the answer.
        var answered = false
        /// Seconds from launch to the first byte on stdout; nil when nothing was printed.
        var firstByteSeconds: TimeInterval?
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

    /// How long the runner keeps reading after `answerComplete` first holds, so a last line printed
    /// right behind the one that completed the answer is still captured.
    static let answerSettle: TimeInterval = 0.5

    /// Run a CLI to completion off the main actor. `environment` entries overlay the app's env;
    /// a nil value REMOVES the variable (the default-home rule: `CLAUDE_CONFIG_DIR` must be unset
    /// for `~/.claude`, or the CLI looks up a hashed Keychain item that doesn't exist).
    ///
    /// `answerComplete`, when given, is asked about everything stdout holds after each chunk. Once it
    /// says yes the watchdog is disarmed and, after `answerSettle`, the child is ended and the run
    /// returns without waiting for the pipes: a CLI that prints its answer and then lingers (or whose
    /// grandchildren keep the pipe open) must not hold the round up (B-3918).
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String?] = [:],
        currentDirectory: URL? = nil,
        input: String? = nil,
        timeout: TimeInterval = 30,
        answerComplete: (@Sendable (String) -> Bool)? = nil,
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

                let launched = Date()
                // Why the run was ended, if it was: set on the watchdog's or the settle timer's queue and
                // read once the child has exited; the lock orders them, and whichever comes first wins.
                let ended = OSAllocatedUnfairLock(initialState: (timedOut: false, answered: false))
                let end: @Sendable () -> Void = {
                    process.terminate()
                    // A CLI that ignores SIGTERM is not allowed to outlive its watchdog.
                    DispatchQueue.global().asyncAfter(deadline: .now() + pipeGrace) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                // Watchdog: a wedged CLI must never stall the refresh loop.
                let watchdog = DispatchWorkItem {
                    guard process.isRunning,
                          ended.withLock({ state in
                              guard !state.answered else { return false }
                              state.timedOut = true
                              return true
                          })
                    else { return }
                    end()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Both pipes are drained concurrently as the child writes: reading one to EOF while
                // the child is still filling the other is a deadlock waiting for a chatty CLI.
                let outData = Captured()
                let errorData = Captured()
                let draining = DispatchGroup()
                let firstByte = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)
                let settling = OSAllocatedUnfairLock(initialState: false)
                func drain(_ pipe: Pipe, into captured: Captured, isAnswer: Bool = false) {
                    draining.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            draining.leave()
                            return
                        }
                        captured.append(chunk)
                        guard isAnswer else { return }
                        firstByte.withLock { if $0 == nil { $0 = Date().timeIntervalSince(launched) } }
                        guard let answerComplete,
                              !settling.withLock({ $0 }),
                              answerComplete(String(decoding: captured.value, as: UTF8.self))
                        else { return }
                        settling.withLock { $0 = true }
                        DispatchQueue.global().asyncAfter(deadline: .now() + answerSettle) {
                            guard process.isRunning,
                                  ended.withLock({ state in
                                      guard !state.timedOut else { return false }
                                      state.answered = true
                                      return true
                                  })
                            else { return }
                            end()
                        }
                    }
                }
                drain(stdout, into: outData, isAnswer: true)
                drain(stderr, into: errorData)
                process.waitUntilExit()
                let endState = ended.withLock { $0 }
                // EOF normally arrives with the exit; a grandchild still holding a pipe open does
                // not get to keep this run, whatever the child managed to print is already here.
                // An answered run does not wait at all: the answer is already in.
                if !endState.answered { _ = draining.wait(timeout: .now() + pipeGrace) }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                watchdog.cancel()
                continuation.resume(returning: Output(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData.value, encoding: .utf8) ?? "",
                    stderr: String(data: errorData.value, encoding: .utf8) ?? "",
                    timedOut: endState.timedOut,
                    answered: endState.answered,
                    firstByteSeconds: firstByte.withLock { $0 }
                ))
            }
        }
    }
}
