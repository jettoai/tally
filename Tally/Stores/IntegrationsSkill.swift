import Foundation

// The Claude Code skill integration - split from IntegrationsStore.swift for file size. The
// stored `skillStatus` property stays in the store (extensions cannot add stored properties);
// everything else about the skill (content, discovery, surgery) lives here.
extension IntegrationsStore {
    // MARK: Claude Code skill - agent sessions learn to answer quota questions themselves

    /// Bump when the skill markdown changes; the store flags older installs for reinstall.
    nonisolated static let skillVersion = 1

    /// The skill Tally installs into every Claude account's skills folder: Claude Code loads
    /// it on demand and learns to read `tally status --json` instead of guessing at quota.
    /// The comment line under the frontmatter carries the version for detection.
    nonisolated static func skillMarkdown() -> String {
        """
        ---
        name: tally-quota
        description: Check AI subscription quota on this machine with Tally, every Claude and Codex account's 5-hour, weekly, and flagship-model windows, reset times, the pooled fleet view, and which account a launch would land on. Use when the user asks how much quota is left, about rate limits or resets, which account to use, or before starting heavy multi-agent work.
        ---

        <!-- tally-skill v\(skillVersion), managed by Tally.app (Settings -> Integrations); safe to delete -->

        # Checking quota with Tally

        Run:

        ```
        tally status --json
        ```

        The output is a versioned, additive-only contract (`version: 1`). How to read it:

        - `accounts[]`: one entry per account. `sessionRemaining` (the 5-hour window),
          `weeklyRemaining`, and `modelRemaining` (the flagship window named by
          `modelWindowName`, e.g. Fable) are percent left, 0-100; each pairs with a
          `...ResetsAt` ISO 8601 timestamp. A missing key means the provider does not
          report that window.
        - `best: true` marks the account `tally claude` / `tally codex` would launch right
          now (a manual pin is honoured); `pinned` marks the pin itself. `launchHome` is
          that account's config directory (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`).
        - `fleetPools.<provider>[]` is the pooled view across accounts, leading pool first
          (a flagship pool like Fable may lead the weekly pool). Pool units differ from
          account percents: `remaining` and `capacity` count one account's full weekly
          window as 100, so capacity 200 means two accounts. `dryAt` forecasts when the
          pool runs dry at the current pace; `sustainable: true` means the pace holds to
          the reset.
        - Top-level `stale: true`, or a non-zero exit, means the Tally app is not running
          and the numbers are old: say so rather than quoting them as current.

        Guidance:

        - Answer quota questions from this data directly; include reset times when a
          window is low.
        - For "which account should I use", prefer the account with `best: true`;
          launching through `tally claude` / `tally codex` applies the same choice
          automatically.
        - Before heavy multi-agent or long autonomous work, check the binding window (the
          smallest remaining among session, weekly, and model) and warn when it is nearly
          drained.
        - If the `tally` command is missing, the Command line tool integration in Tally's
          Settings installs it.
        """
    }

    /// One SKILL.md per discovered claude home, deduplicated by physical file (shared setups
    /// symlink the same skills tree everywhere - one edit must not be counted N times).
    private static func claudeSkillFiles() -> [URL] {
        var seen = Set<String>()
        return ClaudeAccounts.discover().compactMap { account -> URL? in
            guard let home = account.launchHome else { return nil }
            let url = URL(fileURLWithPath: home).appendingPathComponent("skills/tally/SKILL.md")
            return seen.insert(url.resolvingSymlinksInPath().path).inserted ? url : nil
        }
    }

    static func detectSkill() -> Status {
        let files = claudeSkillFiles()
        guard !files.isEmpty else { return .notInstalled }
        var ours = 0, older = 0, foreign = 0
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if content.contains("tally-skill v\(skillVersion)") { ours += 1 }
            else if content.contains("tally-skill v") { older += 1 }
            else { foreign += 1 }
        }
        if foreign > 0 { return .broken(L("A different skill occupies skills/tally")) }
        if older > 0 { return .broken(L("Older version installed")) }
        if ours == 0 { return .notInstalled }
        return ours == files.count ? .installed : .broken(L("Not installed for every account"))
    }

    func installSkill() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            let files = Self.claudeSkillFiles()
            for file in files { _ = try Self.upsertSkill(in: file) }
            recordManifest("claudeSkill", paths: files.isEmpty ? nil : files.map(\.path))
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func removeSkill() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            // Accounts that logged out since install are no longer discovered, but the
            // manifest remembers every path the skill went to - remove honours the actual
            // install set, so no orphan skill lies in wait for a later re-login.
            var files = Self.claudeSkillFiles()
            let manifest = (try? JSONSerialization.jsonObject(
                with: (try? Data(contentsOf: Self.manifestURL)) ?? Data())) as? [String: Any]
            for path in ((manifest?["claudeSkill"] as? [String: Any])?["paths"] as? [String]) ?? []
            where !files.contains(where: { $0.path == path }) {
                files.append(URL(fileURLWithPath: path))
            }
            for file in files { try Self.removeSkill(in: file) }
            recordManifest("claudeSkill", paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Writes the skill into one skills file. A file that is not ours is never clobbered -
    /// a user's own skills/tally survives untouched (install reports the conflict instead).
    /// Existence and readability are distinct on purpose: an unreadable or non-UTF-8 file
    /// throws here (never overwrite what could not be inspected); only a truly absent file
    /// is a fresh install. Returns true when the file changed. Internal for the unit tests.
    static func upsertSkill(in file: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try String(contentsOf: file, encoding: .utf8)
            if existing == skillMarkdown() { return false }   // already ours - idempotent
            guard existing.contains("tally-skill v") else {
                throw NSError(domain: "tally", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: L("A different skill occupies skills/tally"),
                ])
            }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try skillMarkdown().write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Reverses `upsertSkill`: removes only a skill that IS ours, then clears the skill
    /// folder when nothing else lives inside. Anything not ours is left untouched.
    static func removeSkill(in file: URL) throws {
        guard let existing = try? String(contentsOf: file, encoding: .utf8),
              existing.contains("tally-skill v") else { return }
        try FileManager.default.removeItem(at: file)
        let dir = file.deletingLastPathComponent()
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           leftovers.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
