import Foundation

/// Runs one provider's login command in the background and watches it for an answer.
///
/// The user never sees a terminal: the CLI opens the browser itself and finishes on its own
/// localhost callback, so the only thing this has to do is start it in the shape it expects (a pty
/// for the one that draws a UI, a plain pipe for the one that doesn't), read enough of its output
/// to tell renewed from refused, and refuse to wait forever.
///
/// What it reads is COMPARED AND DROPPED. The output is matched against Tally's own marker strings
/// and never logged, written, notified or returned; an outcome carries a case, not a line. A login
/// screen holds a one-time authorization URL, and the app has no business keeping one.
enum RenewLoginRunner {
    enum Failure: Sendable, Equatable {
        /// The CLI could not be started at all (missing binary, no pty available).
        case couldNotStart
        /// The CLI itself said the login did not happen.
        case reported
        /// One of the two clocks below ran out.
        case timedOut
    }

    enum Outcome: Sendable, Equatable {
        case renewed
        case failed(Failure)
    }

    /// Silence BEFORE the browser is up means the CLI is stuck on something Tally cannot see (a
    /// missing port, a changed screen, a prompt no marker matches), and waiting longer only delays
    /// the fallback that would have worked.
    static let handshakeIdleLimit: TimeInterval = 120

    /// The whole renewal, browser round trip included. Past this the user has almost certainly
    /// walked away from the consent page, and a login process left running against a stale
    /// challenge is worse than one visible Terminal window they can finish in.
    static let overallLimit: TimeInterval = 180

    /// After the answer is known, how long the CLI is left alone to close itself down. It has just
    /// been handed the key its success screen was waiting on, and the writes it makes on the way
    /// out are the credential: terminating it the instant the marker appears is a race against the
    /// very thing the renewal was for.
    private static let windDownLimit: TimeInterval = 5

    static func run(executable: String, plan: RenewLoginCommand.Plan,
                    environment: [String: String?],
                    handshakeIdleLimit: TimeInterval = handshakeIdleLimit,
                    overallLimit: TimeInterval = overallLimit) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(
                    executable: executable, plan: plan, environment: environment,
                    handshakeIdleLimit: handshakeIdleLimit, overallLimit: overallLimit))
            }
        }
    }

    private static func runSync(executable: String, plan: RenewLoginCommand.Plan,
                                environment: [String: String?],
                                handshakeIdleLimit: TimeInterval,
                                overallLimit: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = plan.arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            if let value { env[key] = value } else { env.removeValue(forKey: key) }
        }
        process.environment = env

        // The reading end, and (pty only) the writing end for the one keystroke a success screen
        // waits on. A pty is not an optimization here: without one the terminal UI aborts on raw
        // mode instead of logging anybody in.
        let readFD: Int32
        let writeFD: Int32
        var replicaFD: Int32 = -1
        if plan.needsTerminal {
            var primary: Int32 = 0, replica: Int32 = 0
            var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&primary, &replica, nil, nil, &size) == 0 else {
                return .failed(.couldNotStart)
            }
            let terminal = FileHandle(fileDescriptor: replica, closeOnDealloc: false)
            process.standardInput = terminal
            process.standardOutput = terminal
            process.standardError = terminal
            readFD = primary
            writeFD = primary
            replicaFD = replica
        } else {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            readFD = pipe.fileHandleForReading.fileDescriptor
            writeFD = -1
        }

        do {
            try process.run()
        } catch {
            if replicaFD >= 0 { close(replicaFD) }
            if plan.needsTerminal { close(readFD) }
            return .failed(.couldNotStart)
        }
        // The parent's own copy of the child's terminal, or the read side never reaches EOF.
        if replicaFD >= 0 { close(replicaFD) }

        var raw = ""
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(overallLimit)
        var lastOutput = Date()
        // No progress markers = no handshake phase to guard (a provider judged by its exit code
        // prints nothing Tally reads), so only the overall clock applies.
        var browserIsUp = plan.progressMarkers.isEmpty
        var verdict: Outcome?
        /// Set once the login has succeeded and been handed its keystroke: the clocks above stop
        /// applying and the child is given a moment to exit on its own terms.
        var windDown: Date?

        while true {
            let now = Date()
            if let windDown {
                if !process.isRunning || now >= windDown { break }
            } else if now >= deadline {
                verdict = .failed(.timedOut)
                break
            } else if !browserIsUp, now.timeIntervalSince(lastOutput) > handshakeIdleLimit {
                verdict = .failed(.timedOut)
                break
            }
            var poller = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 500)
            if ready < 0 { if errno == EINTR { continue } else { break } }
            if ready == 0 {
                // Nothing to read. A child that has already exited will never say more.
                if !process.isRunning { break }
                continue
            }
            let count = read(readFD, &buffer, buffer.count)
            guard count > 0 else { break }   // EOF, or the terminal went away with the child
            lastOutput = Date()
            guard verdict == nil else { continue }   // winding down: read it, drop it, judge nothing
            // Bounded on purpose: a marker is a phrase, and the app has no reason to hold a login
            // screen's scrollback. Stripped only for matching, never stored anywhere else.
            raw = String((raw + String(decoding: buffer[0 ..< count], as: UTF8.self)).suffix(8000))
            let text = RenewLoginCommand.plainText(raw)
            if RenewLoginCommand.contains(anyOf: plan.failureMarkers, in: text) {
                verdict = .failed(.reported)
                break
            } else if RenewLoginCommand.contains(anyOf: plan.successMarkers, in: text) {
                if let key = plan.confirmKeystroke, writeFD >= 0 {
                    _ = key.withCString { write(writeFD, $0, strlen($0)) }
                }
                verdict = .renewed
                windDown = Date().addingTimeInterval(windDownLimit)
            } else if !browserIsUp,
                      RenewLoginCommand.contains(anyOf: plan.progressMarkers, in: text) {
                browserIsUp = true
            }
        }

        let outcome = verdict ?? exitOutcome(of: process, within: 5)
        stop(process, within: 5)
        if plan.needsTerminal { close(readFD) }
        return outcome
    }

    /// The answer for a CLI that ended without saying anything Tally recognises: its exit code.
    /// This is the WHOLE answer for a provider with no markers at all (Codex), and the backstop for
    /// one whose screens were reworded by an update.
    private static func exitOutcome(of process: Process, within seconds: TimeInterval) -> Outcome {
        guard wait(for: process, within: seconds) else { return .failed(.timedOut) }
        return process.terminationStatus == 0 ? .renewed : .failed(.reported)
    }

    /// End the child if it is still up: ask, then insist. A login process outliving its own window
    /// would sit on a dead challenge and on the account's config home.
    private static func stop(_ process: Process, within seconds: TimeInterval) {
        guard process.isRunning else { return }
        process.terminate()
        guard !wait(for: process, within: seconds) else { return }
        kill(process.processIdentifier, SIGKILL)
        _ = wait(for: process, within: seconds)
    }

    /// `waitUntilExit` with a clock. Polling rather than blocking, because the whole point of the
    /// deadlines above is that nothing in here can hang forever.
    private static func wait(for process: Process, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(50_000)
        }
        return true
    }
}
