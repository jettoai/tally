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
    private static func isSwitchHookEntry(_ entry: [String: Any]) -> Bool {
        guard entry["matcher"] as? String == switchHookMatcher else { return false }
        let hooks = entry["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.hasSuffix(" \(switchHookMarker)") == true }
    }

    private static func switchHookEntry(command: String) -> [String: Any] {
        ["matcher": switchHookMatcher,
         "hooks": [["type": "command", "command": command]]]
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
        let ours = switchHookEntry(command: command)
        if let index = entries.firstIndex(where: isSwitchHookEntry) {
            if NSDictionary(dictionary: entries[index]).isEqual(to: ours) { return nil }
            entries[index] = ours
        } else {
            entries.append(ours)
        }
        hooks[switchHookEvent] = entries
        var merged = settings
        merged["hooks"] = hooks
        return merged
    }

    /// The settings document without our hook, or nil when there was none. Removal takes the keys
    /// it added back out when they are left empty, so uninstalling returns the file to its shape.
    static func settingsWithoutSwitchHook(_ settings: [String: Any]) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[switchHookEvent] as? [[String: Any]] else { return nil }
        let kept = entries.filter { !isSwitchHookEntry($0) }
        guard kept.count != entries.count else { return nil }
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
        return entries.contains(where: isSwitchHookEntry)
    }

    // MARK: - Installed as one unit with the skill

    /// The homes to install into, deduplicated by physical path: shared setups symlink one config
    /// tree into several homes, and writing the same file N times would count one install N times.
    private static func homes(ofSkillFiles files: [URL]) -> [URL] {
        var seen = Set<String>()
        return files.map(claudeHome(ofSkillFile:)).filter {
            seen.insert($0.resolvingSymlinksInPath().path).inserted
        }
    }

    /// What one home's sync came to: what changed, what is now installed there, and what went
    /// wrong. A result rather than a throw, because a home that fails must not stop the next one.
    struct SwitchCommandSync {
        var changed = false
        /// The command file, when it is ours.
        var command: URL?
        /// The settings file, when the hook was registered in it. Nil when the hook was skipped,
        /// which is a state the caller must be able to see: it means this home is untouched.
        var settings: URL?
        var error: String?
    }

    /// One home's half of the sync, in the order that matters. Static and file-driven so it is
    /// testable without the singleton, whose manifest lives in the real `~/.tally`.
    ///
    /// THE ORDER IS THE POINT. The hook is registered only when the command file is ours, because
    /// the two are one instruction: the hook intercepts `/tally-switch` and exits 2, which STOPS
    /// the expansion. Registering it beside a `commands/tally-switch.md` that belongs to the user
    /// would take their command away from them - it would never run again, and nothing would say
    /// why. Neither half, or both.
    static func syncSwitchCommand(inHome home: URL, hookCommand: String) -> SwitchCommandSync {
        var result = SwitchCommandSync()
        let file = switchCommandFile(inHome: home)
        do {
            result.changed = try upsertSwitchCommand(in: file)
            result.command = file
        } catch {
            return SwitchCommandSync(error: error.localizedDescription)
        }
        let settings = home.appendingPathComponent("settings.json")
        do {
            result.changed = try upsertSwitchHook(in: settings, command: hookCommand)
                || result.changed
            result.settings = settings
        } catch {
            result.error = error.localizedDescription
        }
        return result
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
        var seenSettings = Set<String>()
        let command = Self.switchHookCommand(Self.bundledCLIURL)
        for home in Self.homes(ofSkillFiles: files) {
            let result = Self.syncSwitchCommand(inHome: home, hookCommand: command)
            changed = result.changed || changed
            if let error = result.error { lastError = error }
            if let file = result.command { commands.append(file.path) }
            // Recorded once per PHYSICAL file: two homes can share one settings.json by symlink
            // while their commands folders are their own, and a manifest listing the same file
            // twice would read as two installs.
            if let file = result.settings,
               seenSettings.insert(file.resolvingSymlinksInPath().path).inserted {
                settingsFiles.append(file.path)
            }
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
        let homes = Self.homes(ofSkillFiles: files)
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
        homes(ofSkillFiles: files).allSatisfy { home in
            let command = (try? String(contentsOf: switchCommandFile(inHome: home), encoding: .utf8))
            return command?.contains(switchCommandMarker) == true
                && settingsCarrySwitchHook(home.appendingPathComponent("settings.json"))
        }
    }
}
