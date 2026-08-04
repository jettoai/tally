import Foundation

// The Claude Code skill integration - split from IntegrationsStore.swift for file size. The
// stored `skillStatus` property stays in the store (extensions cannot add stored properties);
// everything else about the skill (content, discovery, surgery) lives here.
extension IntegrationsStore {
    // MARK: Claude Code skill - agent sessions learn to answer quota questions themselves

    /// Bump when the skill markdown changes; older installs are flagged in Settings and brought
    /// up to date by `autoUpdateSkill()` at the next launch.
    nonisolated static let skillVersion = 4

    /// The skill Tally installs into every Claude account's skills folder: Claude Code loads
    /// it on demand and learns to read `tally status --json` instead of guessing at quota.
    /// The comment line under the frontmatter carries the version for detection.
    nonisolated static func skillMarkdown() -> String {
        """
        ---
        name: tally-quota
        description: Check AI subscription quota on this machine with Tally, every Claude and Codex account's 5-hour, weekly, and flagship-model windows, reset times, the pooled fleet view, which account a launch would land on, and the usage advisor's verdict on whether the current accounts cover the workload. Use when the user asks how much quota is left, about rate limits or resets, which account to use, whether to add another account, how usage is trending, or before starting heavy multi-agent work.
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
        - `advisor.<provider>` is the usage advisor's verdict, computed from the burn-rate
          history the app records rather than from the current percentages. The key is
          absent when there is no history yet (the app has not been running long enough):
          say so instead of inventing a trend.
        - Top-level `stale: true`, or a non-zero exit, means the Tally app is not running
          and the numbers are old: say so rather than quoting them as current.

        Reading the advisor:

        - `verdict` is one of three values. `collecting` means there is too little history
          to judge yet, so draw no conclusion from it. `addAccount` means weekly demand or
          starved time crossed the trigger, so another account would pay off. `sufficient`
          means the current accounts cover the demand.
        - `headline` is a finished English one-liner for that verdict, safe to quote as is.
        - The numbers behind it: `demandPerWeek` is the pooled weekly burn in account-weeks
          (1.0 is one full account's weekly quota spent per week, so 2.4 needs three
          accounts), `starvedHoursPerWeek` is how many hours a week every account in a pool
          sat at zero quota at once, `activeBurnPerHour` is percent of a window spent per
          hour of actual work, and `daysOfData` is how much history the reading rests on.
        - `tierDemands[]` splits `demandPerWeek` by the plan each account is on (`plan`,
          `demandPerWeek`, `accountCount`), largest first, and always adds back up to it.
          Read it whenever it holds more than one plan: accounts are interchangeable only
          within a tier, so "0.9 on Pro and 1.0 on Team" is the answer and their 1.9 is
          not a plan anyone can buy. A snapshot that names no plan yields ONE tier that
          carries the whole figure with its `plan` key left out entirely, not an empty
          list, so the array can always be summed; the list is empty only when there are
          no weekly samples at all.

        Guidance:

        - Answer quota questions from this data directly; include reset times when a
          window is low.
        - For "which account should I use", prefer the account with `best: true`;
          launching through `tally claude` / `tally codex` applies the same choice
          automatically.
        - For "is my quota enough", "should I add an account", or "how is my usage
          trending", answer from `advisor` and quote its `headline`: the account
          percentages describe only this moment, the advisor is the trend. When the verdict
          is `collecting`, say the app is still gathering history instead of guessing. With
          more than one plan in `tierDemands`, name the tier the demand is on rather than
          answering "add an account" in the abstract.
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

    /// Every path the skill can actually live at: the discovered accounts' files plus every path
    /// the manifest remembers. Accounts that logged out since install are no longer discovered,
    /// but their SKILL.md is still on disk, so both remove and the auto-update must see it -
    /// otherwise an orphan lies in wait for a later re-login.
    private static func installedSkillFiles() -> [URL] {
        var files = claudeSkillFiles()
        for path in manifestPaths("claudeSkill") where !files.contains(where: { $0.path == path }) {
            files.append(URL(fileURLWithPath: path))
        }
        return files
    }

    /// The paths the manifest records for one component; empty when the entry, or the file, is
    /// absent or unreadable. Internal for the unit tests.
    static func manifestPaths(_ component: String, manifest url: URL = manifestURL) -> [String] {
        let manifest = (try? JSONSerialization.jsonObject(
            with: (try? Data(contentsOf: url)) ?? Data())) as? [String: Any]
        return ((manifest?[component] as? [String: Any])?["paths"] as? [String]) ?? []
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
            for file in Self.installedSkillFiles() { try Self.removeSkill(in: file) }
            recordManifest("claudeSkill", paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Launch-time upkeep: a skill left behind by an older app version is brought to the current
    /// one, so the agent guidance ships with the app instead of waiting for someone to notice the
    /// "Older version installed" row in Settings. Deliberately narrow, and nothing here asks the
    /// user first: an absent file stays absent (not having the skill is a choice), a foreign
    /// skills/tally is never touched, and a failure only lands in `lastError`.
    func autoUpdateSkill() {
        // Shared state belongs to the release app; not `guardNotDev()`, whose user-facing error
        // has no place in a task that runs silently at launch.
        guard !BuildVariant.isDev else { return }
        let result = Self.autoUpdateSkills(in: Self.installedSkillFiles())
        // Before the early return: when EVERY update failed (an unwritable skills folder) there is
        // nothing to record, but the failure is exactly what Settings must be able to show.
        if let error = result.error { lastError = error }
        guard result.updated > 0 else { return }
        recordManifest("claudeSkill", paths: result.ours.map(\.path))
        refresh()
    }

    /// The auto-update over a given file set, split out so it is testable without discovering the
    /// machine's real claude homes. Rewrites every file that exists AND carries our marker AND is
    /// not already current; returns the files that are ours (the install set the manifest should
    /// record), how many were rewritten, and the first failure if any.
    static func autoUpdateSkills(in files: [URL]) -> (ours: [URL], updated: Int, error: String?) {
        var ours: [URL] = []
        var updated = 0
        var failure: String?
        for file in files {
            // Absent, unreadable, or not ours: leave it exactly as it is.
            guard let existing = try? String(contentsOf: file, encoding: .utf8),
                  existing.contains("tally-skill v") else { continue }
            ours.append(file)
            guard !existing.contains("tally-skill v\(skillVersion)") else { continue }
            do {
                if try upsertSkill(in: file) { updated += 1 }
            } catch {
                failure = failure ?? error.localizedDescription
            }
        }
        return (ours, updated, failure)
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
