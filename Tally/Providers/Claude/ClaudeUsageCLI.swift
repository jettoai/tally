import Foundation

/// Reads Claude usage through the official CLI (`claude -p "/usage"`), so the CLI talks to
/// Anthropic with its own first-party identity. This usage reader does not read tokens, and an
/// expired token heals itself (the CLI refreshes it as part of the run).
enum ClaudeUsageCLI {
    /// Dedicated probe cwd: a `-p` run from a CLI older than `--no-session-persistence` writes a
    /// session transcript under the account's `projects/<cwd-slug>/`, so giving the probe its own
    /// cwd both isolates that noise and makes it safe to prune.
    static let probeDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tally/probe", isDirectory: true)

    /// Where each account's isolated probe home lives (one directory per account, 0700).
    ///
    /// WHY: in print mode `/usage` also builds "What's contributing to your limits usage?" by reading
    /// every transcript written in the last 7 days under `CLAUDE_CONFIG_DIR/projects`, and the
    /// Tally-managed homes share that directory through a symlink (3,695 files, 5.07 GB measured
    /// 2026-09-27). Tally never shows that section. Pointing `CLAUDE_CONFIG_DIR` at an empty home
    /// while `CLAUDE_SECURESTORAGE_CONFIG_DIR` keeps the Keychain lookup on the real account gives the
    /// same three windows at about 0.6 CPU seconds instead of 7 to 15 (CC 2.1.283).
    /// `CLAUDE_SECURESTORAGE_CONFIG_DIR` is not documented (found in the 2.1.283 binary, where the CLI
    /// uses it for agent-team teammates), so every isolated read has the old read behind it.
    /// The CLI writes `.claude.json` here (it carries `oauthAccount`: email and organisation, no
    /// token), which is why the directory is private to the user. Tally does not read the file. Its
    /// only write is a manual refresh removing `cachedUsageUtilization` (Claude Code 2.1.285 answers a
    /// `/usage` asked within 60 seconds from that snapshot), so the manual read really asks the
    /// endpoint. If the key is renamed, the refresh falls back to the snapshot; nothing breaks.
    static let probeHomeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tally/probe-home", isDirectory: true)

    /// How long an account whose isolated read proved unusable goes straight to the old read.
    static let legacyHold: TimeInterval = 60 * 60

    /// `configDir` nil = the default `~/.claude` account, which must run with CLAUDE_CONFIG_DIR
    /// UNSET on the old read (the CLI namespaces its Keychain item by the exact env value; explicitly
    /// passing the default path makes it look up a hashed item that doesn't exist - "Not logged in").
    /// On the isolated read the same rule is expressed as `CLAUDE_SECURESTORAGE_CONFIG_DIR=""`.
    static func fetchUsageText(configDir: String?, userInitiated: Bool = false, executable: String? = nil,
                               probeHomeRoot: URL = probeHomeRoot,
                               now: Date = Date()) async -> String? {
        guard let binary = executable ?? CLIRunner.resolve("claude") else { return nil }
        try? FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        let key = configDir ?? ""
        guard await routes.isolatedAllowed(key, now: now),
              let home = prepareProbeHome(root: probeHomeRoot, name: probeHomeName(configDir: configDir))
        else { return await legacyRead(binary: binary, configDir: configDir) }

        if userInitiated { dropUsageSnapshot(home: home) }
        let isolated = await read(binary: binary, environment: [
            "CLAUDE_CONFIG_DIR": home.path,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": configDir ?? "",
        ])
        let verdict = isolatedVerdict(isolated, shapeVerified: await routes.shapeVerified(key))
        switch verdict {
        case .accept(let sawModelWindow):
            if sawModelWindow { await routes.apply(.shapeVerified, key: key, now: now) }
            return isolated
        case .fallBack(let reason):
            let legacy = await legacyRead(binary: binary, configDir: configDir)
            await routes.apply(memoryUpdate(reason: reason, legacy: legacy), key: key, now: now)
            return legacy
        }
    }

    /// Removes the CLI's cached `/usage` snapshot from the probe home's `.claude.json`. Any read,
    /// parse or shape problem leaves the file exactly as it was.
    static func dropUsageSnapshot(home: URL) {
        let file = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object.removeValue(forKey: "cachedUsageUtilization") != nil,
              let updated = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
        guard (try? updated.write(to: file, options: .atomic)) != nil else { return }
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
    }

    // MARK: - The two reads

    /// The read as it was before the isolated home: the account's own config dir, and the
    /// secure-storage override explicitly removed so an inherited value cannot redirect it.
    private static func legacyRead(binary: String, configDir: String?) async -> String? {
        let text = await read(binary: binary, environment: [
            "CLAUDE_CONFIG_DIR": configDir,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": nil,
        ])
        pruneProbeTranscripts(configDir: configDir)
        return text
    }

    /// One `/usage` run. Returns stdout on success, "Not logged in" on an authentication rejection
    /// (which commonly exits nonzero), nil otherwise.
    // --strict-mcp-config: the probe must never load MCP servers (fork-bomb guard + speed).
    // --safe-mode: nor the user's hooks and plugins. This runs once a minute per account, and
    // without it every run fired the whole SessionStart hook set of ~/.claude/settings.json
    // (seen in the probe transcripts as hook_success / hook_additional_context lines). Auth is
    // untouched by it; EarlyStartCommand.swift carries the same flag and the reasoning in full.
    // --no-session-persistence: the run leaves no transcript (print mode only), which kept about
    // 300 files in the probe directory at steady state. The prune in `legacyRead` stays for the
    // files an older CLI, or a run from before this flag, still leaves behind.
    private static func read(binary: String, environment: [String: String?]) async -> String? {
        let output = await CLIRunner.run(
            binary,
            arguments: ["-p", "/usage", "--strict-mcp-config", "--safe-mode",
                        "--no-session-persistence"],
            environment: environment,
            currentDirectory: probeDirectory,
            timeout: 60
        )
        guard let output else { return nil }
        let combined = output.stdout + "\n" + output.stderr
        // An authentication rejection commonly exits nonzero. Preserve that diagnosis only;
        // network failures and arbitrary stderr are not successful usage readings.
        if authenticationRejected(combined) { return "Not logged in" }
        guard output.exitCode == 0 else { return nil }
        return output.stdout
    }

    // MARK: - Deciding whether the isolated read counts (pure, tested directly)

    enum FallbackReason: Equatable {
        /// Nonzero exit or timeout with no authentication wording: may be transient.
        case noOutput
        /// The CLI found no login from the isolated home: the override is not honoured.
        case notLoggedIn
        /// Signed in, but the session or the all-models week is missing.
        case incomplete
        /// Both main windows, no model window, and this account's shape is not yet confirmed.
        case unconfirmedModelWindow
    }

    enum IsolatedVerdict: Equatable {
        case accept(sawModelWindow: Bool)
        case fallBack(FallbackReason)
    }

    static func isolatedVerdict(_ text: String?, shapeVerified: Bool) -> IsolatedVerdict {
        guard let text else { return .fallBack(.noOutput) }
        if authenticationRejected(text) { return .fallBack(.notLoggedIn) }
        let found = windows(in: text)
        guard found.main else { return .fallBack(.incomplete) }
        if !found.model && !shapeVerified { return .fallBack(.unconfirmedModelWindow) }
        return .accept(sawModelWindow: found.model)
    }

    /// Which windows a reading carries: both main ones (session and all-models week), and any
    /// model week.
    private static func windows(in text: String) -> (main: Bool, model: Bool) {
        let ids = Set(ClaudeUsageTextMapper.map(text: text).map(\.id))
        return (ids.contains("session") && ids.contains("weekly_all"),
                ids.contains { $0.hasPrefix("weekly_model:") })
    }

    enum MemoryUpdate: Equatable { case none, holdLegacy, shapeVerified }

    /// What one fallback teaches about the account. Only an old read that DID produce both main
    /// windows can convict the isolated read; a transient failure convicts nothing.
    static func memoryUpdate(reason: FallbackReason, legacy: String?) -> MemoryUpdate {
        guard let legacy, !authenticationRejected(legacy) else { return .none }
        let found = windows(in: legacy)
        guard found.main else { return .none }
        switch reason {
        case .noOutput: return .none
        case .notLoggedIn, .incomplete: return .holdLegacy
        case .unconfirmedModelWindow: return found.model ? .holdLegacy : .shapeVerified
        }
    }

    // MARK: - The isolated home

    /// `~/.claude` → "claude", `~/.claude3` → "claude3". Accounts are discovered only as direct
    /// children of the home directory (`accountConfigDirs`), so the last component is unique.
    static func probeHomeName(configDir: String?) -> String {
        guard let configDir else { return "claude" }
        let last = URL(fileURLWithPath: configDir).lastPathComponent
        return last.hasPrefix(".") ? String(last.dropFirst()) : last
    }

    /// Create or repair `<root>/<name>` as a private directory. nil (use the old read) when either
    /// level is not a real directory or cannot be made 0700.
    static func prepareProbeHome(root: URL, name: String) -> URL? {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(name, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            for url in [root, dir] {
                let attributes = try fm.attributesOfItem(atPath: url.path)  // lstat: a symlink fails
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { return nil }
                if (attributes[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
                    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
            }
            return dir
        } catch {
            return nil
        }
    }

    // MARK: - Per-account memory (process lifetime)

    private static let routes = ProbeRoutes()

    private actor ProbeRoutes {
        struct Entry { var legacyUntil: Date?; var shapeVerified = false }
        var entries: [String: Entry] = [:]

        func isolatedAllowed(_ key: String, now: Date) -> Bool {
            guard let until = entries[key]?.legacyUntil else { return true }
            return now >= until
        }
        func shapeVerified(_ key: String) -> Bool { entries[key]?.shapeVerified ?? false }
        func apply(_ update: MemoryUpdate, key: String, now: Date) {
            switch update {
            case .none: break
            case .holdLegacy: entries[key, default: Entry()].legacyUntil = now.addingTimeInterval(legacyHold)
            case .shapeVerified: entries[key, default: Entry()].shapeVerified = true
            }
        }
    }

    static func authenticationRejected(_ text: String) -> Bool {
        let plain = text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#,
                                             with: "", options: .regularExpression)
        return plain.split(separator: "\n").contains { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value == "not logged in" || value.hasPrefix("not logged in ·")
                || value.hasPrefix("not logged in. please run /login")
                || value == "please run /login" || value == "authentication_failed"
        }
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

    /// "Jul 17 at 3:19am (Asia/Taipei)" → Date. On-the-hour stamps drop the minutes entirely -
    /// "Jul 17 at 4am" (live output, 2026-07-17) - so minutes are optional. The year is inferred
    /// as the occurrence CLOSEST to now, past allowed: a stamp read minutes after its reset
    /// passed must stay "just passed" (stale data, harmless), not jump a year ahead - that jump
    /// made the smart pick score a fresh session as needing to last 8760h (2026-07-19).
    static func parseReset(_ string: String, now: Date = Date()) -> Date? {
        guard let stampRange = string.range(
            of: #"^[A-Z][a-z]{2} \d{1,2} at \d{1,2}(:\d{2})?(am|pm)"#, options: .regularExpression)
        else { return nil }
        // Normalize "4am" → "4:00am" so a single format string parses both variants.
        var stamp = String(string[stampRange])
        if !stamp.contains(":"),
           let meridiem = stamp.range(of: #"(am|pm)$"#, options: .regularExpression) {
            stamp.insert(contentsOf: ":00", at: meridiem.lowerBound)
        }
        let zone = string.range(of: #"\(([^)]+)\)"#, options: .regularExpression)
            .map { String(string[$0].dropFirst().dropLast()) }
            .flatMap(TimeZone.init(identifier:)) ?? .current

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "MMM d 'at' h:mma yyyy"

        let year = Calendar.current.component(.year, from: now)
        return (year - 1 ... year + 1)
            .compactMap { formatter.date(from: "\(stamp) \($0)") }
            .min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }
}
