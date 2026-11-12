import Foundation

/// "Install in Terminal": a one-off `.command` file that Terminal runs as soon as it opens it, so
/// the user has nothing to copy, paste or press. Opening a document needs no Automation permission
/// (unlike typing into a Terminal window), and the file deletes itself on its first line.
enum TerminalInstallScript {
    /// The sentences the script prints around the vendor's command, already localized by the caller.
    struct Words: Equatable {
        var intro: String
        var done: String
        var failed: String
        var pathNote: String?
    }

    /// `s` as one single-quoted shell word: a translation may contain `'` (Turkish does).
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The script. The receipt is touched before anything else runs, so Tally can tell "Terminal
    /// opened it and it is running" from "Terminal was asked to". `pipefail` because a failed curl
    /// hands bash an empty script, which exits 0.
    static func text(command: String, receipt: String, words: Words) -> String {
        var lines = [
            "#!/bin/bash",
            "rm -f -- \"$0\"",
            ": > \(quoted(receipt))",
            "printf '%s\\n' \(quoted(words.intro)) \(quoted("  " + command))",
            "echo",
            "set -o pipefail",
            "if \(command); then",
            "  echo",
            "  printf '%s\\n' \(quoted(words.done))",
        ]
        if let note = words.pathNote { lines.append("  printf '%s\\n' \(quoted(note))") }
        lines += ["else", "  echo", "  printf '%s\\n' \(quoted(words.failed))", "fi", ""]
        return lines.joined(separator: "\n")
    }

    /// Writes the script (0755) and returns it with its receipt path. Both live in the per-user temp
    /// directory, named per run, so two runs never share a receipt.
    static func write(command: String, words: Words,
                      in dir: URL = URL(fileURLWithPath: NSTemporaryDirectory())) throws -> (script: URL, receipt: URL) {
        let id = UUID().uuidString
        let script = dir.appendingPathComponent("tally-install-\(id).command")
        let receipt = dir.appendingPathComponent("tally-install-\(id).started")
        let body = text(command: command, receipt: receipt.path, words: words)
        guard FileManager.default.createFile(atPath: script.path, contents: Data(body.utf8),
                                             attributes: [.posixPermissions: 0o755]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return (script, receipt)
    }

    /// Whether the script has started (its receipt exists).
    static func hasStarted(_ receipt: URL) -> Bool {
        FileManager.default.fileExists(atPath: receipt.path)
    }

    /// Remove a receipt nobody reads any more. Best-effort.
    static func discard(_ receipt: URL) {
        try? FileManager.default.removeItem(at: receipt)
    }
}
