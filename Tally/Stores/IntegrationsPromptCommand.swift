import Foundation

// The slash commands Tally installs beside its skill, and the prompt hooks that make them free.
// Split from IntegrationsSwitchCommand.swift when a second command arrived: everything here is about
// "a command file plus a hook entry" and nothing about which command, so the two descriptors
// (`switchPromptCommand`, `modelPromptCommand`) are all their own files still hold.
//
// Why each command has both halves:
//
// - The HOOK (`UserPromptExpansion`, matched on the command's own name) runs before any model is
//   woken. It reads what was typed, does the work, and stops the expansion. Cost: zero tokens.
// - The COMMAND FILE (`<home>/commands/<name>.md`) is what runs when the hook does not: it is not
//   registered yet, or shell execution is disabled by policy. A model turn then does the same work.
//
// The command file is the fallback, so it must be able to answer alone - and it is also the ONLY
// half a user can read, so it says what the hook does rather than assuming the hook is there.
//
// settings.json is the user's own file, shared by symlink across accounts on some setups, and holds
// their whole harness. Every write here is therefore read-modify-write over the parsed document,
// touching exactly one array entry: the one whose command runs OUR subcommand. A file that does not
// parse is left alone and reported, never rewritten from an empty dictionary.

/// One slash command Tally manages: the file it installs, the hook that pre-empts it, and the
/// manifest keys the two are recorded under.
///
/// A value type rather than a second copy of every function, because the FAILURES this machinery
/// exists to prevent are all about ownership - never clobbering a user's own file, never deleting a
/// hook they put beside ours - and a second copy is a second chance to get one of them wrong. What
/// differs between commands is a name, a subcommand and a body; what must not differ is any of the
/// rest.
struct PromptCommand: Sendable {
    /// The slash command, which is also the command file's basename and the hook's matcher.
    let name: String
    /// The `tally` subcommand the hook runs, and the word an entry is recognised as ours by.
    let hookMarker: String
    /// The file's contents, marker line included.
    let markdown: String
    /// Where an install records the command files it wrote, and the settings files it registered in.
    let commandManifest: String
    let hookManifest: String
}

extension IntegrationsStore {
    // MARK: - The command file

    /// Where Claude Code looks for one of these in a config home.
    static func promptCommandFile(inHome home: URL, command: PromptCommand) -> URL {
        home.appendingPathComponent("commands/\(command.name).md")
    }

    /// The config home a `<home>/skills/tally/SKILL.md` path belongs to. The commands follow the
    /// skill's homes rather than discovering their own, which is what keeps them in step even for an
    /// account that has since logged out (its SKILL.md is still on disk, and so are its commands).
    static func claudeHome(ofSkillFile file: URL) -> URL {
        file.deletingLastPathComponent()      // skills/tally
            .deletingLastPathComponent()      // skills
            .deletingLastPathComponent()      // the config home
    }

    /// Version marker, shared with the skill on purpose: they ship together, so one number says
    /// whether an install is current and one bump brings all of them up to date.
    nonisolated static var promptCommandMarker: String { "tally-command v\(skillVersion)" }

    /// Writes one command file. Anything at that path which is not ours is never clobbered, exactly
    /// as the skill treats a foreign skills/tally: existence and readability stay distinct, so an
    /// unreadable file throws rather than being overwritten unseen. Returns true when it changed.
    static func upsertPromptCommand(in file: URL, command: PromptCommand) throws -> Bool {
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try String(contentsOf: file, encoding: .utf8)
            if existing == command.markdown { return false }   // already ours - idempotent
            guard existing.contains("tally-command v") else {
                throw NSError(domain: "tally", code: 4, userInfo: [
                    NSLocalizedDescriptionKey:
                        L("A different command occupies commands/\(command.name).md"),
                ])
            }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try command.markdown.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Reverses `upsertPromptCommand`: removes only a file that IS ours, then the commands folder
    /// when nothing else lives in it. A user's own file of the same name survives untouched.
    static func removePromptCommand(in file: URL) throws {
        guard let existing = try? String(contentsOf: file, encoding: .utf8),
              existing.contains("tally-command v") else { return }
        try FileManager.default.removeItem(at: file)
        let dir = file.deletingLastPathComponent()
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           leftovers.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - The prompt hook

    /// The hook event Claude Code fires when a slash command is typed, before a model runs.
    nonisolated static let promptHookEvent = "UserPromptExpansion"

    /// Quoted, because the release app lives at a fixed path but a dev build does not, and app
    /// bundle paths may contain spaces.
    nonisolated static func promptHookCommand(_ binary: URL, command: PromptCommand) -> String {
        "\"\(binary.path)\" \(command.hookMarker)"
    }

    /// Provenance, and the ONLY entry this code may rewrite or delete: it fires for OUR command and
    /// ends in our subcommand as its own word.
    ///
    /// Both halves are load-bearing, and the second is why this is a suffix rather than a substring
    /// (which is what it was): a user's `/usr/local/bin/my-hook-switcher` contains "hook-switch",
    /// and treating it as ours would silently replace their hook with a Tally registration and
    /// delete it on uninstall. Two conditions cost one line and mean an accident has to be
    /// deliberate.
    private static func isOurHook(_ hook: [String: Any], command: PromptCommand) -> Bool {
        ((hook["command"] as? String)?.hasSuffix(" \(command.hookMarker)")) == true
    }

    /// An entry that HOLDS our hook. Ownership stops here: what may be rewritten or deleted is the
    /// single hook above, never the entry around it.
    ///
    /// The distinction is the whole point. One entry's `hooks` array can hold several commands, all
    /// firing for the same slash command, and a user is free to put their own beside Tally's.
    /// Replacing the ENTRY (which is what this did) took the neighbours with it: overwritten on an
    /// update, deleted on uninstall, with nothing anywhere to say where they went.
    private static func holdsOurHook(_ entry: [String: Any], command: PromptCommand) -> Bool {
        guard entry["matcher"] as? String == command.name else { return false }
        return (entry["hooks"] as? [[String: Any]] ?? []).contains { isOurHook($0, command: command) }
    }

    /// The settings document with our hook registered, or nil when nothing needs to change.
    ///
    /// Pure, so the one property that matters can be tested without a home directory: everything
    /// that is not our entry comes out the other side untouched. Conservative in both directions -
    /// a `hooks` value, or an event list, of an unexpected SHAPE also returns nil, because the only
    /// safe edit to a document we cannot read is none.
    static func settingsRegisteringPromptHook(_ settings: [String: Any], command hookCommand: String,
                                              hook: PromptCommand) -> [String: Any]? {
        var hooks: [String: Any]
        switch settings["hooks"] {
        case nil: hooks = [:]
        case let existing as [String: Any]: hooks = existing
        default: return nil
        }
        var entries: [[String: Any]]
        switch hooks[promptHookEvent] {
        case nil: entries = []
        case let existing as [[String: Any]]: entries = existing
        default: return nil
        }
        let ours: [String: Any] = ["type": "command", "command": hookCommand]
        if let index = entries.firstIndex(where: { holdsOurHook($0, command: hook) }) {
            // Our hook, in place, with whatever else the user put in that entry left exactly where
            // it is and in the order they had it.
            var inner = entries[index]["hooks"] as? [[String: Any]] ?? []
            guard let slot = inner.firstIndex(where: { isOurHook($0, command: hook) }) else {
                return nil
            }
            if NSDictionary(dictionary: inner[slot]).isEqual(to: ours) { return nil }
            inner[slot] = ours
            entries[index]["hooks"] = inner
        } else {
            // A fresh entry holding only ours. Deliberately not merged into an entry the user wrote
            // themselves: that entry is theirs, and adding to it is still editing it.
            entries.append(["matcher": hook.name, "hooks": [ours]])
        }
        hooks[promptHookEvent] = entries
        var merged = settings
        merged["hooks"] = hooks
        return merged
    }

    /// The settings document without our hook, or nil when there was none. It takes out the one
    /// hook, then every container that is left empty by its going: the entry, the event, the
    /// `hooks` block. Anything a user put beside it survives at every level.
    static func settingsWithoutPromptHook(_ settings: [String: Any],
                                          hook: PromptCommand) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[promptHookEvent] as? [[String: Any]] else { return nil }
        var kept: [[String: Any]] = []
        var removed = false
        for entry in entries {
            guard holdsOurHook(entry, command: hook) else { kept.append(entry); continue }
            removed = true
            let remaining = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurHook($0, command: hook) }
            // An entry that was ours alone goes; one the user shared with us keeps its own hooks.
            guard !remaining.isEmpty else { continue }
            var trimmed = entry
            trimmed["hooks"] = remaining
            kept.append(trimmed)
        }
        guard removed else { return nil }
        if kept.isEmpty { hooks.removeValue(forKey: promptHookEvent) } else {
            hooks[promptHookEvent] = kept
        }
        var merged = settings
        if hooks.isEmpty { merged.removeValue(forKey: "hooks") } else { merged["hooks"] = hooks }
        return merged
    }

    static func upsertPromptHook(in file: URL, command: String, hook: PromptCommand) throws -> Bool {
        try editSettings(file) { settingsRegisteringPromptHook($0, command: command, hook: hook) }
    }

    static func removePromptHook(in file: URL, hook: PromptCommand) throws -> Bool {
        try editSettings(file) { settingsWithoutPromptHook($0, hook: hook) }
    }

    /// Whether a settings.json carries our hook at all, regardless of the path it points at. What
    /// detection asks (an entry that is stale is still installed; the launch sync repairs the path
    /// silently), which is also what keeps a dev build from reporting the release app's install as
    /// broken because the two bundles sit in different places.
    static func settingsCarryPromptHook(_ file: URL, hook: PromptCommand) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (settings["hooks"] as? [String: Any])?[promptHookEvent]
                as? [[String: Any]] else { return false }
        return entries.contains { holdsOurHook($0, command: hook) }
    }

    // MARK: - Installed as one unit with the skill

    /// What one group's sync came to: what changed, what is now installed, and what went wrong.
    /// A result rather than a throw, because a group that fails must not stop the next one.
    struct PromptCommandSync {
        var changed = false
        /// The command files that are ours now, one per home that accepted one.
        var commands: [URL] = []
        /// The settings file whose hook is, or may still be, ours: just registered, or left in
        /// place by a write that failed. This is what the manifest records, so an uninstall can
        /// always reach what an install left. Nil means nothing of ours is in that file - either
        /// the hook was never registered, or it was just stood down.
        var settings: URL?
        var error: String?
    }

    /// The homes sharing ONE physical settings.json, synced together. Static and file-driven so it
    /// is testable without the singleton, whose manifest lives in the real `~/.tally`.
    ///
    /// THE GROUP IS THE UNIT, and that is the whole reason this takes a list. The hook lives in the
    /// settings file, and it intercepts the command and exits 2, which STOPS the expansion. A shared
    /// settings.json therefore speaks for EVERY home pointing at it: registering the hook because
    /// home B is clean would take home A's own command file away from them, since A's sessions read
    /// the same hook. So the hook goes in only when every home in the group has a command file Tally
    /// may manage.
    ///
    /// The command files themselves are still installed wherever they can be. That is the honest
    /// half of the answer: a home with no command of its own gains a working one (the model-turn
    /// path, one turn slower), and the home that has its own keeps running it. Skipping those too
    /// would punish the clean homes for their neighbour's file without protecting anyone.
    ///
    /// AND IT IS A DECISION, NOT A SKIP. The answer can change under a registration that is already
    /// there: a home whose command was Tally's until the user wrote their own is a group that WAS
    /// manageable and is not any more, and the hook left behind goes on intercepting the command
    /// they just took back. So the unmanageable branch stands the registration down rather than
    /// returning early, which is the same instruction as never registering, applied late.
    static func syncPromptCommand(inHomes homes: [URL], hookCommand: String,
                                  command: PromptCommand) -> PromptCommandSync {
        var result = PromptCommandSync()
        var manageable = true
        for home in homes {
            let file = promptCommandFile(inHome: home, command: command)
            do {
                result.changed = try upsertPromptCommand(in: file, command: command) || result.changed
                result.commands.append(file)
            } catch {
                result.error = result.error ?? error.localizedDescription
                manageable = false
            }
        }
        guard let settings = homes.first?.appendingPathComponent("settings.json") else { return result }
        do {
            if manageable {
                result.changed = try upsertPromptHook(in: settings, command: hookCommand,
                                                      hook: command) || result.changed
                result.settings = settings
            } else if try removePromptHook(in: settings, hook: command) {
                result.changed = true
            }
        } catch {
            result.error = result.error ?? error.localizedDescription
            // The file could not be acted on, so whatever is in it is still in it. Tracked
            // deliberately: a manifest that forgets it can never reach the hook we failed to reach
            // today, and an uninstall would leave it interposed forever.
            result.settings = settings
        }
        return result
    }

    /// Every home the skill is installed in, drawn from the whole account POPULATION rather than
    /// from the deduplicated skill files alone.
    ///
    /// `claudeSkillFiles()` deduplicates by physical SKILL.md, because one edit to a shared skills
    /// tree must not be counted twice. A home whose skills tree is symlinked at another's therefore
    /// never appears in `files` at all - while its commands folder is entirely its own, and so is
    /// anything it may hold. Grouping on the survivor of that dedup asks the ownership question
    /// about one home and answers it for two.
    ///
    /// Homes named by `files` are kept even when the population does not list them: an account that
    /// logged out since install is no longer discovered, and its SKILL.md is still on disk.
    static func homesCarrying(_ files: [URL], population: [URL]) -> [URL] {
        let wanted = Set(files.map { $0.resolvingSymlinksInPath().path })
        let sharing = population.filter {
            wanted.contains(claudeSkillFile(inHome: $0).resolvingSymlinksInPath().path)
        }
        var seen = Set<String>()
        return (files.map(claudeHome(ofSkillFile:)) + sharing).filter {
            seen.insert($0.resolvingSymlinksInPath().path).inserted
        }
    }

    /// Those homes grouped by the physical settings.json they share, in a stable order. A group is
    /// what the hook decision is made for (above).
    private static func settingsGroups(ofSkillFiles files: [URL], population: [URL]) -> [[URL]] {
        var groups: [String: [URL]] = [:]
        var order: [String] = []
        for home in homesCarrying(files, population: population) {
            let key = home.appendingPathComponent("settings.json").resolvingSymlinksInPath().path
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(home)
        }
        return order.compactMap { groups[$0] }
    }

    /// Bring every command file and hook up to date for every home the skill is installed in.
    /// Returns true when anything on disk changed.
    ///
    /// Called on install AND at every launch (`autoUpdateSkill`), which is what repairs a hook whose
    /// binary path moved with the app. Failures land in `lastError` like every other integration:
    /// they never stop the skill itself from being installed.
    @discardableResult
    func syncPromptCommands(forSkillFiles files: [URL]) -> Bool {
        var changed = false
        let groups = Self.settingsGroups(ofSkillFiles: files, population: Self.claudeHomes())
        for command in Self.promptCommands {
            var commands: [String] = []
            var settingsFiles: [String] = []
            let hookCommand = Self.promptHookCommand(Self.bundledCLIURL, command: command)
            // One pass per PHYSICAL settings file. The manifest therefore records each shared file
            // once, which is also what it means: one registration, however many homes read it.
            for group in groups {
                let result = Self.syncPromptCommand(inHomes: group, hookCommand: hookCommand,
                                                    command: command)
                changed = result.changed || changed
                if let error = result.error { lastError = error }
                commands.append(contentsOf: result.commands.map(\.path))
                if let file = result.settings { settingsFiles.append(file.path) }
            }
            recordManifest(command.commandManifest, paths: commands.isEmpty ? nil : commands)
            recordManifest(command.hookManifest, paths: settingsFiles.isEmpty ? nil : settingsFiles)
        }
        // The manifest just moved, and it is what says where to watch: an install performed in a
        // running app has to be watched from now, not from the next launch (IntegrationsSelfHeal).
        // A no-op whenever the set is unchanged, which is every heal.
        refreshSettingsWatcher()
        return changed
    }

    /// Everywhere one half of a pair can be, deduplicated by physical path: the homes the skill is
    /// in now, plus every path the manifest remembers. The manifest is what makes an account that
    /// logged out since install reachable at all, exactly as it is for the skill itself
    /// (`installedSkillFiles`).
    private static func installedFiles(_ derived: [URL], manifest component: String) -> [URL] {
        var seen = Set<String>()
        return (derived + manifestPaths(component).map { URL(fileURLWithPath: $0) })
            .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// Take every half back out.
    func removePromptCommands(forSkillFiles files: [URL]) {
        let homes = Self.homesCarrying(files, population: [])
        for command in Self.promptCommands {
            for file in Self.installedFiles(homes.map {
                Self.promptCommandFile(inHome: $0, command: command)
            }, manifest: command.commandManifest) {
                do { try Self.removePromptCommand(in: file) } catch {
                    lastError = error.localizedDescription
                }
            }
            for file in Self.installedFiles(homes.map { $0.appendingPathComponent("settings.json") },
                                            manifest: command.hookManifest) {
                do { _ = try Self.removePromptHook(in: file, hook: command) } catch {
                    lastError = error.localizedDescription
                }
            }
            recordManifest(command.commandManifest, paths: nil)
            recordManifest(command.hookManifest, paths: nil)
        }
        // Nothing left to watch: the same call stops the stream rather than leaving one running
        // over a directory this app has no business in any more.
        refreshSettingsWatcher()
    }

    /// Whether every home with the skill also has a current file and a registered hook for EVERY
    /// command. Detection only, so Settings can offer to fix an install from an older app version -
    /// including one that predates a command entirely, which is exactly what a second command makes
    /// possible.
    ///
    /// Through the same population the sync uses, and for the same reason: a home whose skills tree
    /// is symlinked at another's is absent from the deduplicated file list while its commands folder
    /// is its own. Judging on the survivors alone reported an install complete while a home was
    /// missing its half of it. Injected rather than discovered so the tests never touch a real
    /// config home (`claudeHomes()` enumerates the machine's).
    static func promptCommandsAreCurrent(forSkillFiles files: [URL], population: [URL]) -> Bool {
        promptCommands.allSatisfy {
            promptCommandIsCurrent(forSkillFiles: files, population: population, command: $0)
        }
    }

    /// The same question about ONE command. Separate because they are separate answers: an app that
    /// gained a second command leaves every existing install current in the first and missing the
    /// second, and telling those apart is what makes the repair reportable.
    static func promptCommandIsCurrent(forSkillFiles files: [URL], population: [URL],
                                       command: PromptCommand) -> Bool {
        homesCarrying(files, population: population).allSatisfy { home in
            let text = try? String(contentsOf: promptCommandFile(inHome: home, command: command),
                                   encoding: .utf8)
            return text?.contains(promptCommandMarker) == true
                && settingsCarryPromptHook(home.appendingPathComponent("settings.json"),
                                           hook: command)
        }
    }
}
