import Foundation
import Observation

/// The valid `--effort` levels of the INSTALLED claude CLI, parsed at runtime from its own
/// `--help` - the only machine-readable source, and it tracks the binary the user actually has
/// (a CLI update that adds a level updates the picker with zero code changes). Parsing failure
/// falls back to the last-known list. Codex exposes no such enumeration (effort is a config.toml
/// override, absent from its help), so its list stays doc-anchored.
@MainActor
@Observable
final class EffortLevels {
    static let shared = EffortLevels()

    private(set) var claude = EffortLevels.withAliases(["low", "medium", "high", "xhigh", "max"])
    let codex = ["low", "medium", "high", "xhigh"]

    /// Accepted by the claude CLI's `--effort` parser but absent from its help enumeration:
    /// "ultracode" (xhigh + the CLI's session-scoped multi-agent orchestration mode; alias map
    /// and activation path verified in binary 2.1.214).
    private nonisolated static let undocumentedClaudeAliases = ["ultracode"]

    nonisolated static func withAliases(_ levels: [String]) -> [String] {
        levels + undocumentedClaudeAliases.filter { !levels.contains($0) }
    }

    private init() {
        Task.detached(priority: .utility) {
            guard let parsed = Self.parseClaudeLevels() else { return }
            await MainActor.run { EffortLevels.shared.claude = Self.withAliases(parsed) }
        }
    }

    /// `claude --help` documents `--effort` as "... (low, medium, high, xhigh, max)"; the
    /// parenthesised list right after the flag is the enumeration.
    nonisolated static func parseClaudeLevels(helpText: String? = nil) -> [String]? {
        let text: String
        if let helpText {
            text = helpText
        } else {
            guard let binary = CLIRunner.resolve("claude") else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["--help"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            text = output
        }
        guard let flag = text.range(of: "--effort") else { return nil }
        let tail = text[flag.upperBound...].prefix(250)
        guard let open = tail.firstIndex(of: "("),
              let close = tail[open...].firstIndex(of: ")") else { return nil }
        let levels = tail[tail.index(after: open) ..< close]
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
        // A sanity floor: a real enumeration has several levels; anything less means the help
        // text changed shape and the fallback list is safer.
        return levels.count >= 3 ? levels : nil
    }
}
