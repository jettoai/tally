import Foundation

/// Spawns a provider's own CLI and captures its stdout - the data path for every usage read.
///
/// Tally reads usage EXCLUSIVELY through the providers' official clients (`claude -p "/usage"`,
/// `codex app-server`): the CLI talks to its vendor with its own first-party identity and
/// credentials, so Tally never touches an OAuth token, a Keychain credential, or a vendor
/// endpoint itself.
enum CLIRunner {
    /// GUI apps get a minimal PATH (`/usr/bin:/bin:…`), so resolve the binary from the places
    /// CLIs actually install to, falling back to PATH lookup for good measure.
    static func resolve(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.claude/local/\(name)",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        // PATH fallback (covers a shell-managed install in an unusual prefix).
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        which.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    struct Output: Sendable {
        var exitCode: Int32
        var stdout: String
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
        timeout: TimeInterval = 30
    ) async -> Output? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment {
                    if let value { env[key] = value } else { env.removeValue(forKey: key) }
                }
                process.environment = env
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }

                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
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
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: Output(
                    exitCode: process.terminationStatus,
                    stdout: String(data: data, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
