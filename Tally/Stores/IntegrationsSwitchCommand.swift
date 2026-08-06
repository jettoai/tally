import Foundation

// `/tally-switch` - the slash command that moves a session to another account, and the prompt hook
// that makes it free. Split from IntegrationsSkill.swift for file size; installed, updated and
// removed WITH the skill, because the two are one instruction to Claude Code from two directions.
//
// Why both halves exist:
//
// - The HOOK (`UserPromptExpansion`, matcher `tally-switch`) runs before any model is woken. It
//   reads the typed account name, queues the move, and stops the expansion (`tally hook-switch`,
//   SwitchHook.swift). Cost: zero tokens, zero turns.
// - The COMMAND FILE (`<home>/commands/tally-switch.md`) is what runs when the hook does not: it is
//   not registered yet, shell execution is disabled by policy, or the user typed `/tally-switch`
//   with no account and a choice has to be offered. A model turn then does the same work.
//
// The command file is the fallback, so it must be able to answer alone - and it is also the ONLY
// half a user can read, so it says what the hook does rather than assuming the hook is there.
//
// settings.json is the user's own file, shared by symlink across accounts on some setups, and holds
// their whole harness. Every write here is therefore read-modify-write over the parsed document,
// touching exactly one array entry: the one whose command runs OUR subcommand. A file that does not
// parse is left alone and reported, never rewritten from an empty dictionary.
extension IntegrationsStore {
    // MARK: - The command file

    /// Where Claude Code looks for `/tally-switch` in one config home.
    static func switchCommandFile(inHome home: URL) -> URL {
        home.appendingPathComponent("commands/tally-switch.md")
    }

    /// The config home a `<home>/skills/tally/SKILL.md` path belongs to. The command follows the
    /// skill's homes rather than discovering its own, which is what keeps the pair in step even for
    /// an account that has since logged out (its SKILL.md is still on disk, and so is its command).
    static func claudeHome(ofSkillFile file: URL) -> URL {
        file.deletingLastPathComponent()      // skills/tally
            .deletingLastPathComponent()      // skills
            .deletingLastPathComponent()      // the config home
    }

    /// Version marker, shared with the skill on purpose: the two ship together, so one number says
    /// whether an install is current and one bump brings both up to date.
    nonisolated static var switchCommandMarker: String { "tally-command v\(skillVersion)" }

    nonisolated static func switchCommandMarkdown() -> String {
        """
        ---
        description: Move this Claude Code session to another account, keeping the conversation
        argument-hint: [account name]
        allowed-tools: Bash(tally:*), AskUserQuestion
        ---

        <!-- \(switchCommandMarker), managed by Tally.app (Settings -> Integrations); safe to delete -->

        # Move this session to another account

        Tally normally answers `/tally-switch <account>` without waking a model at all: a prompt
        hook queues the move and stops the prompt there, so naming an account costs nothing.
        Reaching this file means the hook did not answer, which happens in two cases, and the
        second one is the common one:

        1. The hook is not registered, or shell execution is turned off by policy.
        2. The command was typed with no account named, because the user wants to choose.

        Either way, do the work here.

        ## When an account is named

        `$ARGUMENTS` carries whatever followed the command. If it names an account, queue the move
        and stop:

        ```
        tally switch "$ARGUMENTS"
        ```

        ## When nothing is named

        Read the fleet first, then ask:

        1. Run `tally status`. Every Claude account is listed with the percent left of its session
           (5 hour), weekly, and flagship model windows, and `->` marks the one a launch would land
           on right now.
        2. Ask with AskUserQuestion, one option per Claude account: the account's label as the
           option, its three remaining windows as the description. Put the account with the most
           headroom first and mark it Recommended. Do not pick for the user: the whole point of the
           bare command is that they want the choice.
        3. Queue the move to the account they chose: `tally switch "<account>"`.

        ## What to tell them afterwards

        Relay what the command printed, and these three things about it:

        - The move happens when this turn ENDS, not while the command runs. The session then comes
          back on the other account with this conversation intact, so the next thing they type is
          answered from the same context.
        - It is one shot. No pin is written and no project profile changes, so automatic handoff
          carries on from there.
        - A non-zero exit means nothing was queued (no such account, or a session nothing is
          supervising). Read the message rather than assuming it worked.

        For "this project should ALWAYS run on that account", the instruction is different and is
        written down instead: `tally project set --account "<account>"`.
        """
    }

    /// Writes the command file. Anything at that path which is not ours is never clobbered, exactly
    /// as the skill treats a foreign skills/tally: existence and readability stay distinct, so an
    /// unreadable file throws rather than being overwritten unseen. Returns true when it changed.
    static func upsertSwitchCommand(in file: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try String(contentsOf: file, encoding: .utf8)
            if existing == switchCommandMarkdown() { return false }   // already ours - idempotent
            guard existing.contains("tally-command v") else {
                throw NSError(domain: "tally", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: L("A different command occupies commands/tally-switch.md"),
                ])
            }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try switchCommandMarkdown().write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Reverses `upsertSwitchCommand`: removes only a file that IS ours, then the commands folder
    /// when nothing else lives in it. A user's own tally-switch.md survives untouched.
    static func removeSwitchCommand(in file: URL) throws {
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
    nonisolated static let switchHookEvent = "UserPromptExpansion"
    /// Which command it fires for.
    nonisolated static let switchHookMatcher = "tally-switch"
    /// The subcommand the hook runs. The binary PATH is deliberately not part of the identity: the
    /// path is the thing that moves (the app is dragged elsewhere, or replaced by an update), and
    /// an entry stranded on an old path is exactly what the sync exists to repair.
    nonisolated static let switchHookMarker = "hook-switch"

    /// Quoted, because the release app lives at a fixed path but a dev build does not, and app
    /// bundle paths may contain spaces.
    nonisolated static func switchHookCommand(_ binary: URL) -> String {
        "\"\(binary.path)\" \(switchHookMarker)"
    }

    /// Provenance, and the ONLY entry this code may rewrite or delete: it fires for OUR command and
    /// ends in our subcommand as its own word.
    ///
    /// Both halves are load-bearing, and the second is why this is a suffix rather than a substring
    /// (which is what it was): a user's `/usr/local/bin/my-hook-switcher` contains "hook-switch",
    /// and treating it as ours would silently replace their hook with a Tally registration and
    /// delete it on uninstall. Two conditions cost one line and mean an accident has to be
    /// deliberate.
    private static func isSwitchHook(_ hook: [String: Any]) -> Bool {
        ((hook["command"] as? String)?.hasSuffix(" \(switchHookMarker)")) == true
    }

    /// An entry that HOLDS our hook. Ownership stops here: what may be rewritten or deleted is the
    /// single hook above, never the entry around it.
    ///
    /// The distinction is the whole point. One entry's `hooks` array can hold several commands, all
    /// firing for the same slash command, and a user is free to put their own beside Tally's.
    /// Replacing the ENTRY (which is what this did) took the neighbours with it: overwritten on an
    /// update, deleted on uninstall, with nothing anywhere to say where they went.
    private static func holdsSwitchHook(_ entry: [String: Any]) -> Bool {
        guard entry["matcher"] as? String == switchHookMatcher else { return false }
        return (entry["hooks"] as? [[String: Any]] ?? []).contains(where: isSwitchHook)
    }

    /// The settings document with our hook registered, or nil when nothing needs to change.
    ///
    /// Pure, so the one property that matters can be tested without a home directory: everything
    /// that is not our entry comes out the other side untouched. Conservative in both directions -
    /// a `hooks` value, or an event list, of an unexpected SHAPE also returns nil, because the only
    /// safe edit to a document we cannot read is none.
    static func settingsRegisteringSwitchHook(_ settings: [String: Any],
                                              command: String) -> [String: Any]? {
        var hooks: [String: Any]
        switch settings["hooks"] {
        case nil: hooks = [:]
        case let existing as [String: Any]: hooks = existing
        default: return nil
        }
        var entries: [[String: Any]]
        switch hooks[switchHookEvent] {
        case nil: entries = []
        case let existing as [[String: Any]]: entries = existing
        default: return nil
        }
        let ours: [String: Any] = ["type": "command", "command": command]
        if let index = entries.firstIndex(where: holdsSwitchHook) {
            // Our hook, in place, with whatever else the user put in that entry left exactly where
            // it is and in the order they had it.
            var hooks = entries[index]["hooks"] as? [[String: Any]] ?? []
            guard let slot = hooks.firstIndex(where: isSwitchHook) else { return nil }
            if NSDictionary(dictionary: hooks[slot]).isEqual(to: ours) { return nil }
            hooks[slot] = ours
            entries[index]["hooks"] = hooks
        } else {
            // A fresh entry holding only ours. Deliberately not merged into a `tally-switch` entry
            // the user wrote themselves: that entry is theirs, and adding to it is still editing it.
            entries.append(["matcher": switchHookMatcher, "hooks": [ours]])
        }
        hooks[switchHookEvent] = entries
        var merged = settings
        merged["hooks"] = hooks
        return merged
    }

    /// The settings document without our hook, or nil when there was none. It takes out the one
    /// hook, then every container that is left empty by its going: the entry, the event, the
    /// `hooks` block. Anything a user put beside it survives at every level.
    static func settingsWithoutSwitchHook(_ settings: [String: Any]) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[switchHookEvent] as? [[String: Any]] else { return nil }
        var kept: [[String: Any]] = []
        var removed = false
        for entry in entries {
            guard holdsSwitchHook(entry) else { kept.append(entry); continue }
            removed = true
            let remaining = (entry["hooks"] as? [[String: Any]] ?? []).filter { !isSwitchHook($0) }
            // An entry that was ours alone goes; one the user shared with us keeps its own hooks.
            guard !remaining.isEmpty else { continue }
            var trimmed = entry
            trimmed["hooks"] = remaining
            kept.append(trimmed)
        }
        guard removed else { return nil }
        if kept.isEmpty { hooks.removeValue(forKey: switchHookEvent) } else { hooks[switchHookEvent] = kept }
        var merged = settings
        if hooks.isEmpty { merged.removeValue(forKey: "hooks") } else { merged["hooks"] = hooks }
        return merged
    }

    static func upsertSwitchHook(in file: URL, command: String) throws -> Bool {
        try editSettings(file) { settingsRegisteringSwitchHook($0, command: command) }
    }

    static func removeSwitchHook(in file: URL) throws -> Bool {
        try editSettings(file) { settingsWithoutSwitchHook($0) }
    }

    /// Whether a settings.json carries our hook at all, regardless of the path it points at. What
    /// detection asks (an entry that is stale is still installed; the launch sync repairs the path
    /// silently), which is also what keeps a dev build from reporting the release app's install as
    /// broken because the two bundles sit in different places.
    static func settingsCarrySwitchHook(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (settings["hooks"] as? [String: Any])?[switchHookEvent]
                as? [[String: Any]] else { return false }
        return entries.contains(where: holdsSwitchHook)
    }

    // MARK: - Installed as one unit with the skill

    /// What one group's sync came to: what changed, what is now installed, and what went wrong.
    /// A result rather than a throw, because a group that fails must not stop the next one.
    struct SwitchCommandSync {
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
    /// settings file, and it intercepts `/tally-switch` and exits 2, which STOPS the expansion. A
    /// shared settings.json therefore speaks for EVERY home pointing at it: registering the hook
    /// because home B is clean would take home A's own `commands/tally-switch.md` away from them,
    /// since A's sessions read the same hook. So the hook goes in only when every home in the group
    /// has a command file Tally may manage.
    ///
    /// The command files themselves are still installed wherever they can be. That is the honest
    /// half of the answer: a home with no command of its own gains a working `/tally-switch` (the
    /// model-turn path, one turn slower), and the home that has its own keeps running it. Skipping
    /// those too would punish the clean homes for their neighbour's file without protecting anyone.
    ///
    /// AND IT IS A DECISION, NOT A SKIP. The answer can change under a registration that is already
    /// there: a home whose `/tally-switch` was Tally's until the user wrote their own is a group
    /// that WAS manageable and is not any more, and the hook left behind goes on intercepting the
    /// command they just took back. So the unmanageable branch stands the registration down rather
    /// than returning early, which is the same instruction as never registering, applied late.
    static func syncSwitchCommand(inHomes homes: [URL], hookCommand: String) -> SwitchCommandSync {
        var result = SwitchCommandSync()
        var manageable = true
        for home in homes {
            let file = switchCommandFile(inHome: home)
            do {
                result.changed = try upsertSwitchCommand(in: file) || result.changed
                result.commands.append(file)
            } catch {
                result.error = result.error ?? error.localizedDescription
                manageable = false
            }
        }
        guard let settings = homes.first?.appendingPathComponent("settings.json") else { return result }
        do {
            if manageable {
                result.changed = try upsertSwitchHook(in: settings, command: hookCommand)
                    || result.changed
                result.settings = settings
            } else if try removeSwitchHook(in: settings) {
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
    /// the `/tally-switch` it may hold. Grouping on the survivor of that dedup asks the ownership
    /// question about one home and answers it for two.
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

    /// Bring the command file and the hook up to date for every home the skill is installed in.
    /// Returns true when anything on disk changed.
    ///
    /// Called on install AND at every launch (`autoUpdateSkill`), which is what repairs a hook whose
    /// binary path moved with the app. Failures land in `lastError` like every other integration:
    /// they never stop the skill itself from being installed.
    @discardableResult
    func syncSwitchCommand(forSkillFiles files: [URL]) -> Bool {
        var changed = false
        var commands: [String] = []
        var settingsFiles: [String] = []
        let command = Self.switchHookCommand(Self.bundledCLIURL)
        // One pass per PHYSICAL settings file. The manifest therefore records each shared file
        // once, which is also what it means: one registration, however many homes read it.
        for group in Self.settingsGroups(ofSkillFiles: files, population: Self.claudeHomes()) {
            let result = Self.syncSwitchCommand(inHomes: group, hookCommand: command)
            changed = result.changed || changed
            if let error = result.error { lastError = error }
            commands.append(contentsOf: result.commands.map(\.path))
            if let file = result.settings { settingsFiles.append(file.path) }
        }
        recordManifest("claudeSwitchCommand", paths: commands.isEmpty ? nil : commands)
        recordManifest("claudeSwitchHook", paths: settingsFiles.isEmpty ? nil : settingsFiles)
        return changed
    }

    /// Everywhere one half of the pair can be, deduplicated by physical path: the homes the skill
    /// is in now, plus every path the manifest remembers. The manifest is what makes an account
    /// that logged out since install reachable at all, exactly as it is for the skill itself
    /// (`installedSkillFiles`).
    private static func installedFiles(_ derived: [URL], manifest component: String) -> [URL] {
        var seen = Set<String>()
        return (derived + manifestPaths(component).map { URL(fileURLWithPath: $0) })
            .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// Take both halves back out.
    func removeSwitchCommand(forSkillFiles files: [URL]) {
        let homes = Self.homesCarrying(files, population: [])
        for file in Self.installedFiles(homes.map(Self.switchCommandFile(inHome:)),
                                        manifest: "claudeSwitchCommand") {
            do { try Self.removeSwitchCommand(in: file) } catch {
                lastError = error.localizedDescription
            }
        }
        for file in Self.installedFiles(homes.map { $0.appendingPathComponent("settings.json") },
                                        manifest: "claudeSwitchHook") {
            do { _ = try Self.removeSwitchHook(in: file) } catch {
                lastError = error.localizedDescription
            }
        }
        recordManifest("claudeSwitchCommand", paths: nil)
        recordManifest("claudeSwitchHook", paths: nil)
    }

    /// Whether every home with the skill also has a current command file and a registered hook.
    /// Detection only, so Settings can offer to fix an install from an older app version.
    static func switchCommandIsCurrent(forSkillFiles files: [URL]) -> Bool {
        homesCarrying(files, population: []).allSatisfy { home in
            let command = (try? String(contentsOf: switchCommandFile(inHome: home), encoding: .utf8))
            return command?.contains(switchCommandMarker) == true
                && settingsCarrySwitchHook(home.appendingPathComponent("settings.json"))
        }
    }
}
