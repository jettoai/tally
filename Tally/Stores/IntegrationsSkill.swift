import Foundation

// The Claude Code skill integration - split from IntegrationsStore.swift for file size. The
// stored `skillStatus` property stays in the store (extensions cannot add stored properties);
// where the skill file goes, who owns it, and how an install is brought forward live here. Its
// TEXT is IntegrationsSkillContent.swift, and the move between skill folders (which is where an
// install already on disk comes from) is IntegrationsSkillFolderMove.swift.
extension IntegrationsStore {
    /// One SKILL.md per discovered claude home, deduplicated by physical file (shared setups
    /// symlink the same skills tree everywhere - one edit must not be counted N times).
    private static func claudeSkillFiles() -> [URL] {
        var seen = Set<String>()
        return ClaudeAccounts.discover().compactMap { account -> URL? in
            guard let home = account.launchHome else { return nil }
            let url = claudeSkillFile(inHome: URL(fileURLWithPath: home))
            return seen.insert(url.resolvingSymlinksInPath().path).inserted ? url : nil
        }
    }

    /// Every path the skill can actually live at: the discovered accounts' files plus every path
    /// the manifest remembers. Accounts that logged out since install are no longer discovered,
    /// but their SKILL.md is still on disk, so both remove and the auto-update must see it -
    /// otherwise an orphan lies in wait for a later re-login.
    ///
    /// A remembered path is read through `currentSkillFile(forRecordedPath:)`, which is what makes
    /// a manifest written before the folder move name the install of today rather than the one it
    /// recorded (IntegrationsSkillFolderMove.swift).
    static func installedSkillFiles() -> [URL] {
        var files = claudeSkillFiles()
        for path in manifestPaths("claudeSkill") {
            let file = currentSkillFile(forRecordedPath: URL(fileURLWithPath: path))
            if !files.contains(where: { $0.path == file.path }) { files.append(file) }
        }
        return files
    }

    /// Whether a skills file on disk is one Tally wrote. The one predicate behind "is the skill
    /// installed here", asked by the launch-time update and by the settings self-heal, which must
    /// agree: a heal that judged installation differently would put hooks back into a home the user
    /// had uninstalled from.
    static func skillFileIsOurs(_ contents: String) -> Bool { contents.contains("tally-skill v") }

    /// Those of `files` that exist and are ours. Absence is the signal the self-heal reads as "the
    /// user does not want this here", so it is asked of the file rather than of the manifest, which
    /// records intent from install time and not the state now.
    static func oursAmong(_ files: [URL]) -> [URL] {
        files.filter {
            (try? String(contentsOf: $0, encoding: .utf8)).map(skillFileIsOurs) == true
        }
    }

    /// The whole provenance record, or an empty one when the file is absent, unreadable, or not a
    /// JSON object. One reader for every asker, which is what lets a question about the manifest as
    /// a WHOLE be asked at all: whether any component has ever written a Claude settings.json is not
    /// answerable one component at a time (`settingsWriteAuthorized`).
    static func manifestDocument(_ url: URL = manifestURL) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(
            with: (try? Data(contentsOf: url)) ?? Data())) as? [String: Any]) ?? [:]
    }

    /// The paths the manifest records for one component; empty when the entry, or the file, is
    /// absent or unreadable. Internal for the unit tests.
    static func manifestPaths(_ component: String, manifest url: URL = manifestURL) -> [String] {
        ((manifestDocument(url)[component] as? [String: Any])?["paths"] as? [String]) ?? []
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
        if foreign > 0 { return .broken(occupiedSkillMessage) }
        if older > 0 { return .broken(L("Older version installed")) }
        if ours == 0 { return .notInstalled }
        guard ours == files.count else { return .broken(L("Not installed for every account")) }
        // The slash commands and their prompt hooks ship WITH the skill, so an install carrying
        // only the SKILL.md - or carrying one command but not a second the app has since gained -
        // is an install from an older app: the same "bring it up to date" answer the version marker
        // gets, and `autoUpdateSkill()` does exactly that at the next launch.
        return Self.promptCommandsAreCurrent(forSkillFiles: files, population: Self.claudeHomes())
            ? .installed : .broken(L("Older version installed"))
    }

    func installSkill() {
        guard guardNotDev() else { return }
        lastError = nil
        let files = Self.claudeSkillFiles()
        do {
            // Whatever of ours is still in a folder the skill has left goes with the same press:
            // the install just written is the one Claude Code loads, and the other is shadowing a
            // slash command (IntegrationsSkillFolderMove.swift).
            for file in files { _ = try Self.upsertSkillClearingFormerFolders(in: file) }
            recordManifest("claudeSkill", paths: files.isEmpty ? nil : files.map(\.path))
        } catch {
            lastError = error.localizedDescription
        }
        // Outside the do/catch above on purpose: a skills folder that refused the SKILL.md says
        // nothing about the commands folder next to it, and this call reports its own failures.
        syncPromptCommands(forSkillFiles: files)
        refresh()
    }

    func removeSkill() {
        guard guardNotDev() else { return }
        lastError = nil
        let files = Self.installedSkillFiles()
        do {
            for file in files {
                try Self.removeSkill(in: file)
                // And the folders the skill has left, so an uninstall on a machine that never got
                // the move does not leave the orphan behind that nothing is ever coming for.
                try Self.clearFormerSkillFolders(besides: file)
            }
            recordManifest("claudeSkill", paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        removePromptCommands(forSkillFiles: files)
        refresh()
    }

    /// Launch-time upkeep: a skill left behind by an older app version is brought to the current
    /// one, so the agent guidance ships with the app instead of waiting for someone to notice the
    /// "Older version installed" row in Settings. Deliberately narrow, and nothing here asks the
    /// user first: an absent file stays absent (not having the skill is a choice), a foreign skill
    /// of that name is never touched, and a failure only lands in `lastError`. The one thing it
    /// does beyond a rewrite is carry an install out of a folder the skill has left, which is the
    /// same instruction applied to a path rather than to a version.
    func autoUpdateSkill() {
        // Shared state belongs to the INSTALLED release app; not `guardNotDev()`, whose user-facing
        // error has no place in a task that runs silently at launch. A locally built Release is
        // caught here too (`isUnshipped`): it wears the release bundle id, so nothing else about it
        // says it must not write, and what it wrote was a hook path inside a build tree.
        guard !BuildVariant.isUnshipped else { return }
        let result = Self.autoUpdateSkills(in: Self.installedSkillFiles())
        // Before the early return: when EVERY update failed (an unwritable skills folder) there is
        // nothing to record, but the failure is exactly what Settings must be able to show.
        if let error = result.error { lastError = error }
        // The command files and their hooks follow the SKILL.md's PRESENCE, not their own: an
        // install from an app that predates one has neither, and "an absent file stays absent" would
        // keep it that way forever. Run whether or not the skill itself needed rewriting, because a
        // hook can also go stale on its own (the app moved, so its binary path did).
        let commandsChanged = result.ours.isEmpty ? false
            : syncPromptCommands(forSkillFiles: result.ours)
        guard result.updated > 0 || commandsChanged else { return }
        recordManifest("claudeSkill", paths: result.ours.map(\.path))
        refresh()
    }

    /// The auto-update over a given file set, split out so it is testable without discovering the
    /// machine's real claude homes. Rewrites every file that exists AND carries our marker AND is
    /// not already current; returns the files that are ours (the install set the manifest should
    /// record), how many changes it made on disk (a file rewritten, or a former folder let go), and
    /// the first failure if any.
    static func autoUpdateSkills(in files: [URL]) -> (ours: [URL], updated: Int, error: String?) {
        var ours: [URL] = []
        var updated = 0
        var failure: String?
        for file in files {
            // THE FOLDER MOVE FIRST, because it is the one case where an absent file does not mean
            // "the user does not want this here": it is missing because the install is still in the
            // folder the skill used to live in, where it shadows the `/tally` command
            // (IntegrationsSkillFolderMove.swift). Keyed on the old folder rather than on a version,
            // since the installs that need moving are already at the current one.
            if formerSkillFolderCarriesOurs(besides: file) {
                do { updated += try upsertSkillClearingFormerFolders(in: file) } catch {
                    failure = failure ?? error.localizedDescription
                }
            }
            // Absent, unreadable, or not ours: leave it exactly as it is.
            guard let existing = try? String(contentsOf: file, encoding: .utf8),
                  skillFileIsOurs(existing) else { continue }
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

    /// What Settings shows when somebody else's skill sits where ours goes. The FOLDER NAME is an
    /// argument, never part of the key: interpolating it would build a key that only exists in the
    /// catalog for whatever the folder was called that day, so the move to `tally-quota` would have
    /// dropped all four translations back to English - which is exactly what the `/tally-switch`
    /// rename did to the command's message (localizationchecks.swift).
    static var occupiedSkillMessage: String {
        String(format: L("A different skill occupies skills/%@"), skillFolderName)
    }

    /// Writes the skill into one skills file. A file that is not ours is never clobbered -
    /// a user's own skill of that name survives untouched (install reports the conflict instead).
    /// Existence and readability are distinct on purpose: an unreadable or non-UTF-8 file
    /// throws here (never overwrite what could not be inspected); only a truly absent file
    /// is a fresh install. Returns true when the file changed. Internal for the unit tests.
    static func upsertSkill(in file: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try String(contentsOf: file, encoding: .utf8)
            if existing == skillMarkdown() { return false }   // already ours - idempotent
            guard existing.contains("tally-skill v") else {
                throw NSError(domain: "tally", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: occupiedSkillMessage,
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
