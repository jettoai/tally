import Foundation

// Putting the prompt hooks back when something takes them out (IntegrationsSelfHeal.swift).
//
// The hooks live in settings.json, which is the user's whole harness configuration and is rewritten
// by things that know nothing about Tally: another tool's config sync, a restore from a dotfiles
// repo, an editor saving a stale buffer. Until the app watched that file the only repair was
// relaunching it, because the sync runs once at launch - and in between, `/tally-switch` and
// `/tally-model` silently start costing a model turn each.
//
// TWO GUARDS CARRY THE WHOLE FEATURE, and both are asserted here rather than trusted:
//
//   - IT MUST TERMINATE. The repair WRITES settings.json, that write is a filesystem event, and the
//     event arrives back at the watcher. "Everything is already in place, so do nothing" is what
//     makes the second pass a no-op instead of the next link in a chain.
//   - IT MUST NOT UNDO AN UNINSTALL. A user who turned the integration off has said something, and
//     an app that put it back within seconds would be overriding them with a watchdog.
@MainActor
func runSelfHealChecks(tmp: URL, skill currentSkill: String) throws {
    let binary = URL(fileURLWithPath: "/Applications/Tally.app/Contents/Helpers/tally")

    /// A config home, with a SKILL.md whose contents are given (nil for a home with none at all).
    func makeHome(_ name: String, skill: String?) throws -> URL {
        let home = tmp.appendingPathComponent("heal-\(name)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let skill {
            let file = IntegrationsStore.claudeSkillFile(inHome: home)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try skill.write(to: file, atomically: true, encoding: .utf8)
        }
        return home
    }
    /// Install every slash command Tally manages into one home, the way a launch does.
    @discardableResult
    func installAll(_ home: URL) -> Bool {
        var changed = false
        for command in IntegrationsStore.promptCommands {
            let result = IntegrationsStore.syncPromptCommand(
                inHomes: [home],
                hookCommand: IntegrationsStore.promptHookCommand(binary, command: command),
                command: command)
            changed = result.changed || changed
        }
        return changed
    }
    func hooksPresent(_ home: URL) -> Bool {
        let settings = home.appendingPathComponent("settings.json")
        return IntegrationsStore.promptCommands.allSatisfy {
            IntegrationsStore.settingsCarryPromptHook(settings, hook: $0)
        }
    }

    // MARK: - The filter: exactly the config homes, never anything under them

    // FSEvents is asked at directory granularity, so an event names the folder. That folder is a
    // provider config home, one of the busiest directories on the machine: every running session
    // writes through `projects/`, and `.claude.json` is rewritten constantly. Accepting a
    // subdirectory would turn ordinary typing into a stream of wake-ups for a file nobody touched.
    let watched = ["/Users/u/.claude", "/Users/u/.claude2"]
    check("the watched directory itself is interesting",
          settingsEventIsInteresting(path: "/Users/u/.claude", watching: watched))
    check("…and so is the same path with the trailing slash FSEvents adds",
          settingsEventIsInteresting(path: "/Users/u/.claude/", watching: watched))
    check("a busy subdirectory under it is not",
          !settingsEventIsInteresting(path: "/Users/u/.claude/projects", watching: watched)
              && !settingsEventIsInteresting(path: "/Users/u/.claude/projects/geo",
                                             watching: watched))
    check("nor is a sibling nobody registered in",
          !settingsEventIsInteresting(path: "/Users/u/.claude3", watching: watched))
    check("…including one whose name merely starts the same way",
          !settingsEventIsInteresting(path: "/Users/u/.claude22", watching: watched))
    check("with nothing to watch, nothing is interesting",
          !settingsEventIsInteresting(path: "/Users/u/.claude", watching: []))

    // MARK: - Where to watch, read off the manifest

    // The manifest is the right source for this one question, unlike for "is it installed" below:
    // it asks WHERE, and a file we once registered in is worth watching whether or not the entry is
    // in it right now - which is precisely the case this feature exists for.
    let manifest = tmp.appendingPathComponent("heal-manifest.json")
    let recorded: [String: Any] = [
        "claudeSwitchHook": ["paths": ["/Users/u/.claude/settings.json"]],
        "claudeModelHook": ["paths": ["/Users/u/.claude/settings.json",
                                      "/Users/u/.claude2/settings.json"]],
    ]
    try JSONSerialization.data(withJSONObject: recorded).write(to: manifest)
    let directories = IntegrationsStore.watchedSettingsDirectories(manifest: manifest)
        .map(\.path)
    check("every settings file a hook was registered in is watched, by its directory",
          Set(directories) == Set(["/Users/u/.claude", "/Users/u/.claude2"]))
    check("…and one file recorded under both commands is watched once, not twice",
          directories.count == 2)
    check("no manifest at all means nothing to watch, which the caller reads as fail-open",
          IntegrationsStore.watchedSettingsDirectories(
            manifest: tmp.appendingPathComponent("heal-absent.json")).isEmpty)

    // MARK: - THE TERMINATION GUARD

    let healthy = try makeHome("healthy", skill: currentSkill)
    installAll(healthy)
    let healthySkill = [IntegrationsStore.claudeSkillFile(inHome: healthy)]
    check("a freshly synced home really does carry both hooks", hooksPresent(healthy))
    check("…and needs no healing, which is what ends the write-event-write cycle",
          !IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy]))

    // Now the failure this feature exists for: something rewrites settings.json and our entry goes
    // with it. The command files are untouched - they live elsewhere - so nothing else notices.
    try "{}".write(to: healthy.appendingPathComponent("settings.json"), atomically: true,
                   encoding: .utf8)
    check("a wiped settings.json is noticed", !hooksPresent(healthy)
              && IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill,
                                                    population: [healthy]))
    check("…and re-running the sync puts the hooks back",
          installAll(healthy) && hooksPresent(healthy))
    // THE PROPERTY THAT MATTERS: the repair's own write must not buy another repair. Asserted twice
    // over, because they are two different claims - the gate says no, and the sync itself reports
    // that it changed nothing.
    check("the repair's own write does not ask for another repair",
          !IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy]))
    check("…and a sync run anyway reports no change, so a chain has nothing to carry",
          !installAll(healthy))

    // A user's own entries in that file survive the repair: the sync only ever touches the one hook
    // whose command runs our subcommand (IntegrationsPromptCommand.swift).
    let settingsFile = healthy.appendingPathComponent("settings.json")
    var document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)))
        as? [String: Any] ?? [:]
    document["theme"] = "dark"
    try JSONSerialization.data(withJSONObject: document).write(to: settingsFile)
    _ = installAll(healthy)
    let afterRepair = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)))
        as? [String: Any] ?? [:]
    check("a repair leaves everything in that file that is not ours exactly as it was",
          afterRepair["theme"] as? String == "dark" && hooksPresent(healthy))

    // MARK: - THE UNINSTALL GUARD

    // Absence of the SKILL.md is what says "the user does not want this here": it is what the
    // uninstall removes, and it is read off the DISK rather than off the manifest, which records
    // what was installed once and not what is wanted now.
    let removed = try makeHome("removed", skill: nil)
    let removedSkill = [IntegrationsStore.claudeSkillFile(inHome: removed)]
    check("a home with no skill has no hooks either, by construction", !hooksPresent(removed))
    check("…and is left that way: an uninstall is an instruction, not a fault to repair",
          !IntegrationsStore.hooksNeedHealing(skillFiles: removedSkill, population: [removed]))
    // A skills/tally that belongs to somebody else is the same answer for a different reason: it was
    // never ours, so there is nothing of ours to put back.
    let foreign = try makeHome("foreign", skill: "---\nname: someone-elses\n---\nnot ours")
    check("a foreign skills/tally is not read as an install of ours",
          !IntegrationsStore.hooksNeedHealing(
            skillFiles: [IntegrationsStore.claudeSkillFile(inHome: foreign)],
            population: [foreign]))
    // And the two guards do not shadow each other: a home that IS ours, next to one that is not,
    // still gets its own hooks back.
    check("an installed home beside an uninstalled one is still healed",
          IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill + removedSkill,
                                             population: [healthy, removed]) == false)
    try "{}".write(to: settingsFile, atomically: true, encoding: .utf8)
    check("…and once ITS hooks go, the pair is healed on the installed one's account",
          IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill + removedSkill,
                                             population: [healthy, removed]))
}
