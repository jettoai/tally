import Foundation

/// Reads Claude usage through the official CLI (`claude -p "/usage"`), so the CLI talks to
/// Anthropic with its own first-party identity — Tally never touches the OAuth token, and an
/// expired token heals itself (the CLI refreshes it as part of the run).
enum ClaudeUsageCLI {
    /// Dedicated probe cwd: every `-p` run writes a session transcript under the account's
    /// `projects/<cwd-slug>/`, so giving the probe its own cwd both isolates that noise and makes
    /// it safe to prune.
    static let probeDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tally/probe", isDirectory: true)

    /// `configDir` nil = the default `~/.claude` account, which must run with CLAUDE_CONFIG_DIR
    /// UNSET (the CLI namespaces its Keychain item by the exact env value; explicitly passing the
    /// default path makes it look up a hashed item that doesn't exist — "Not logged in").
    static func fetchUsageText(configDir: String?) async -> String? {
        guard let binary = CLIRunner.resolve("claude") else { return nil }
        try? FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        // --strict-mcp-config: the probe must never load MCP servers (fork-bomb guard + speed).
        let output = await CLIRunner.run(
            binary,
            arguments: ["-p", "/usage", "--strict-mcp-config"],
            environment: ["CLAUDE_CONFIG_DIR": configDir],
            currentDirectory: probeDirectory,
            timeout: 60
        )
        pruneProbeTranscripts(configDir: configDir)
        guard let output, output.exitCode == 0 else { return nil }
        return output.stdout
    }

    /// Delete the probe's own stale session transcripts (ours, minutes old, zero value) so polling
    /// never accumulates thousands of files. Only the dedicated probe slug is ever touched.
    private static func pruneProbeTranscripts(configDir: String?) {
        let home = configDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path
        let slug = probeDirectory.path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let dir = URL(fileURLWithPath: home).appendingPathComponent("projects/\(slug)")
        let cutoff = Date().addingTimeInterval(-3600)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// Parses the human-readable `/usage` output. Grounded in live output (2026-07-17):
///
///   Current session: 63% used · resets Jul 17 at 3:19am (Asia/Taipei)
///   Current week (all models): 29% used · resets Jul 17 at 12:59am (Asia/Taipei)
///   Current week (Fable): 41% used · resets Jul 17 at 12:59am (Asia/Taipei)
///
/// Unknown lines are ignored, so the local-behavior blurb below those lines never breaks parsing.
enum ClaudeUsageTextMapper {
    static func map(text: String, now: Date = Date()) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Current "), let colon = line.firstIndex(of: ":") else { continue }
            let subject = String(line[line.index(line.startIndex, offsetBy: 8) ..< colon])
            let rest = String(line[line.index(after: colon)...])
            guard let percentRange = rest.range(of: #"\d+(\.\d+)?% used"#, options: .regularExpression),
                  let used = Double(rest[percentRange].dropLast("% used".count)) else { continue }
            let resets = rest.range(of: "resets ").flatMap {
                parseReset(String(rest[$0.upperBound...]), now: now)
            }

            if subject == "session" {
                metrics.append(UsageMetric(
                    id: "session", kind: .session, label: "Session", modelName: nil,
                    usedPercent: used, severity: .fromUsedPercent(used),
                    resetsAt: resets, isActive: false))
            } else if subject.hasPrefix("week") {
                let model = subject.range(of: #"\(([^)]+)\)"#, options: .regularExpression)
                    .map { String(subject[$0].dropFirst().dropLast()) } ?? ""
                if model == "all models" {
                    metrics.append(UsageMetric(
                        id: "weekly_all", kind: .weeklyAll, label: "Weekly", modelName: nil,
                        usedPercent: used, severity: .fromUsedPercent(used),
                        resetsAt: resets, isActive: false))
                } else if !model.isEmpty {
                    metrics.append(UsageMetric(
                        id: "weekly_model:\(model)", kind: .weeklyModel, label: model, modelName: model,
                        usedPercent: used, severity: .fromUsedPercent(used),
                        resetsAt: resets, isActive: false))
                }
            }
        }
        return metrics.uniquingIDs()
    }

    /// "Jul 17 at 3:19am (Asia/Taipei)" → Date. The year is inferred: the nearest occurrence that
    /// isn't already in the past (a reset is always in the future).
    static func parseReset(_ string: String, now: Date = Date()) -> Date? {
        guard let stampRange = string.range(
            of: #"^[A-Z][a-z]{2} \d{1,2} at \d{1,2}:\d{2}(am|pm)"#, options: .regularExpression)
        else { return nil }
        let stamp = String(string[stampRange])
        let zone = string.range(of: #"\(([^)]+)\)"#, options: .regularExpression)
            .map { String(string[$0].dropFirst().dropLast()) }
            .flatMap(TimeZone.init(identifier:)) ?? .current

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "MMM d 'at' h:mma yyyy"

        let year = Calendar.current.component(.year, from: now)
        guard let candidate = formatter.date(from: "\(stamp) \(year)") else { return nil }
        if candidate < now.addingTimeInterval(-60),
           let next = formatter.date(from: "\(stamp) \(year + 1)") {
            return next   // e.g. a late-December "Jan 2" reset read in the old year
        }
        return candidate
    }
}
