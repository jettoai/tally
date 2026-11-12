import Foundation

/// Installing Claude Code inside the app: the rules that read the official install script's run,
/// kept pure so tests/claudeinstall and tests/welcome compile them alone. The script itself is
/// Anthropic's (WelcomeFlow.installCommand); Tally runs it and reads what it prints.
enum ClaudeInstall {
    /// Only Claude Code's installer has been read; Codex keeps "Install in Terminal".
    static func supports(_ providerID: String) -> Bool { providerID == "claude" }

    /// What the script is doing, as far as its output and its download file say.
    enum Stage: Equatable, Sendable {
        /// Before the download file exists.
        case fetching
        /// nil = the file is not readable (the script was reworded).
        case downloading(bytes: Int64?)
        /// "Setting up Claude Code..." printed (install.sh:224).
        case settingUp
    }

    enum Failure: Equatable, Sendable { case unreachable, checksum, stalled, tooLong, notFound, other }

    /// How a failed run ended: the reason, and the script's last non-empty line, verbatim.
    struct Report: Equatable, Sendable {
        var failure: Failure
        var lastLine: String
    }

    static let settingUpMarker = "Setting up Claude Code"
    /// No output and no download growth for this long is a stall. Not 60: the first launch of the
    /// downloaded binary sits silent while macOS scans it, measured up to 53 s on a clean Mac.
    static let stallSeconds: TimeInterval = 90
    static let overallSeconds: TimeInterval = 600

    static func stage(plainOutput: String, downloadBytes: Int64?, downloadSeen: Bool) -> Stage {
        if plainOutput.contains(settingUpMarker) { return .settingUp }
        return downloadSeen ? .downloading(bytes: downloadBytes) : .fetching
    }

    /// nil = installed. Exit 0 without a findable CLI is not an install. (`.stalled` and `.tooLong`
    /// are the runner's own verdicts and never come through here.)
    static func failure(lastLine: String, exitCode: Int32, cliFound: Bool) -> Failure? {
        if exitCode == 0 && cliFound { return nil }
        if exitCode == 0 { return .notFound }
        let line = lastLine.lowercased()
        if ["failed to get a valid version", "could not resolve host", "downloads.claude.ai"]
            .contains(where: { line.contains($0) }) { return .unreachable }
        if line.contains("checksum verification failed") { return .checksum }
        return .other
    }

    /// The last non-empty line, trimmed and capped, so the failure page can quote the script.
    static func lastLine(_ plain: String) -> String {
        let line = plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return String(line.prefix(300))
    }

    /// The last `lines` non-empty lines, for the details box.
    static func tail(_ plain: String, lines: Int = 200) -> [String] {
        let all = plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(all.suffix(lines))
    }

    /// The largest `claude-*` entry in the script's download folder (install.sh:196), or nil.
    static func downloadBytes(_ listing: [(name: String, size: Int64)]) -> Int64? {
        listing.filter { $0.name.hasPrefix("claude-") }.map(\.size).max()
    }
}
