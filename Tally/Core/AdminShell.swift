import Foundation

/// The one way this app runs a script as the administrator: the system's own password window
/// (`osascript ... with administrator privileges`). The password is typed into that window and never
/// reaches Tally; what comes back is an exit code and stderr. Used by the CLI-link install
/// (IntegrationsCLITool.swift) and the evidence helper's install (ProcessForensicsSetup.swift).
/// Foundation only, so a suite compiles it without the app.
enum AdminShell {
    /// `foreignFile` is the exit a script reports through `foreignMarker` on stderr (the link script's
    /// "a program of somebody else's is at that path").
    enum Result: Equatable { case done, cancelled, foreignFile, failed(String) }

    /// osascript reports a cancelled password window as error -128; its message is in the user's
    /// language, so the number is what is read.
    nonisolated static func result(exitCode: Int32, stderr: String, foreignMarker: String? = nil) -> Result {
        if exitCode == 0 { return .done }
        if stderr.contains("(-128)") { return .cancelled }
        if let foreignMarker, stderr.contains(foreignMarker) { return .foreignFile }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs `/bin/sh -c <script> sh <arguments...>` as root. The script, every argument and the prompt
    /// travel as osascript argv and are quoted by AppleScript itself, so no value can break out of the
    /// command (the AppleScript source holds none of them). Waits as long as the user takes at the
    /// password window.
    nonisolated static func run(script: String, arguments: [String], prompt: String,
                                foreignMarker: String? = nil) -> Result {
        // argv = [script, argument..., prompt]
        let words = arguments.indices.map { " & \" \" & quoted form of (item \($0 + 2) of argv)" }.joined()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv",
                             "-e", "do shell script \"/bin/sh -c \" & quoted form of (item 1 of argv) & \" sh\"\(words) with prompt (last item of argv) with administrator privileges",
                             "-e", "end run", script] + arguments + [prompt]
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do { try process.run() } catch { return .failed("osascript did not start: \(error)") }
        let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return result(exitCode: process.terminationStatus, stderr: text, foreignMarker: foreignMarker)
    }
}
