import Foundation

// Putting the prompt hooks back when something takes them out (IntegrationsSelfHeal.swift).
//
// The hooks live in settings.json, which is the user's whole harness configuration and is rewritten
// by things that know nothing about Tally: another tool's config sync, a restore from a dotfiles
// repo, an editor saving a stale buffer. Until the app watched that file the only repair was
// relaunching it, because the sync runs once at launch - and in between, `/tally-account` and
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

    // MARK: - The manifest path is the one it was REGISTERED THROUGH, not where the file lives

    // On a shared setup one physical settings.json stands behind several homes by symlink, and the
    // manifest records the path the registration was made through. FSEvents reports a write where
    // the file PHYSICALLY is, so watching the symlink's own directory is watching a place the write
    // never appears: the self-heal would be deaf on exactly the machines it was written for
    // (review of 212e25d).
    let physical = tmp.appendingPathComponent("heal-physical")
    let linked = tmp.appendingPathComponent("heal-linked")
    try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    try "{}".write(to: physical.appendingPathComponent("settings.json"), atomically: true,
                   encoding: .utf8)
    try? FileManager.default.removeItem(at: linked.appendingPathComponent("settings.json"))
    try FileManager.default.createSymbolicLink(
        at: linked.appendingPathComponent("settings.json"),
        withDestinationURL: physical.appendingPathComponent("settings.json"))
    let linkManifest = tmp.appendingPathComponent("heal-link-manifest.json")
    try JSONSerialization.data(withJSONObject: [
        "claudeSwitchHook": ["paths": [linked.appendingPathComponent("settings.json").path]],
    ]).write(to: linkManifest)
    let resolved = IntegrationsStore.watchedSettingsDirectories(manifest: linkManifest).map(\.path)
    check("a settings path recorded through a symlink is watched where the file really is",
          resolved.contains(physical.resolvingSymlinksInPath().path))
    // AND WHERE THE LINK ITSELF SITS, which is not the same event and not a special case of it.
    // Rewriting the CONTENT writes through the link and lands in the resolved parent; REPLACING the
    // file writes a temporary and renames it over the path it was given, which replaces the symlink
    // and lands in the logical one. That second shape is the ordinary atomic save an editor or a
    // dotfiles tool performs, and watching only the resolved parent was deaf to it
    // (review of 3af8d67).
    check("…and where the link that names it sits, because an atomic replace lands there",
          resolved.contains(linked.resolvingSymlinksInPath().path))
    check("…which is two directories for one recorded path, not one", resolved.count == 2)
    // Two homes, one physical file: the shared target is watched once, and each home's own
    // directory once, so nothing is watched twice.
    try JSONSerialization.data(withJSONObject: [
        "claudeSwitchHook": ["paths": [linked.appendingPathComponent("settings.json").path]],
        "claudeModelHook": ["paths": [physical.appendingPathComponent("settings.json").path]],
    ]).write(to: linkManifest)
    check("two homes sharing one physical file add no duplicate directories",
          Set(IntegrationsStore.watchedSettingsDirectories(manifest: linkManifest).map(\.path))
              == Set([physical.resolvingSymlinksInPath().path,
                      linked.resolvingSymlinksInPath().path]))
    // On an ordinary machine, where nothing is linked, the two collapse to one.
    let plainManifest = tmp.appendingPathComponent("heal-plain-manifest.json")
    try JSONSerialization.data(withJSONObject: [
        "claudeSwitchHook": ["paths": [physical.appendingPathComponent("settings.json").path]],
    ]).write(to: plainManifest)
    check("with nothing linked at all, the two parents are one directory",
          IntegrationsStore.watchedSettingsDirectories(manifest: plainManifest).map(\.path)
              == [physical.resolvingSymlinksInPath().path])

    // MARK: - Re-pointing the watcher when the manifest moves

    // WITHOUT THIS, A FIRST INSTALL HAS NO SELF-HEAL. At launch the manifest names no directories,
    // so nothing is watched; the user then presses Install in Settings and the repair does not
    // exist until the app is next started. First-time users are the ones most likely to need it and
    // the least likely to know it is missing (review of 212e25d).
    let dirA = URL(fileURLWithPath: "/Users/u/.claude")
    let dirB = URL(fileURLWithPath: "/Users/u/.claude2")
    check("an install, which is nothing becoming something, restarts the watcher",
          IntegrationsStore.settingsWatcherNeedsRestart(current: [], desired: [dirA]))
    check("an uninstall, which is the reverse, stops it",
          IntegrationsStore.settingsWatcherNeedsRestart(current: [dirA], desired: []))
    check("a new account's config dir arriving is the same event",
          IntegrationsStore.settingsWatcherNeedsRestart(current: [dirA], desired: [dirA, dirB]))
    // A live FSEvents stream is not free to rebuild, and the repair's OWN manifest write goes
    // through the same call: an unchanged set has to be a no-op or every heal churns the stream
    // that noticed the damage.
    check("an unchanged set changes nothing",
          !IntegrationsStore.settingsWatcherNeedsRestart(current: [dirA, dirB],
                                                         desired: [dirA, dirB]))
    check("…and neither does the same set in another order, the manifest promising none",
          !IntegrationsStore.settingsWatcherNeedsRestart(current: [dirA, dirB],
                                                         desired: [dirB, dirA]))

    // MARK: - THE TERMINATION GUARD

    let healthy = try makeHome("healthy", skill: currentSkill)
    installAll(healthy)
    let healthySkill = [IntegrationsStore.claudeSkillFile(inHome: healthy)]
    check("a freshly synced home really does carry both hooks", hooksPresent(healthy))
    check("…and needs no healing, which is what ends the write-event-write cycle",
          !IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy], binary: binary))

    // Now the failure this feature exists for: something rewrites settings.json and our entry goes
    // with it. The command files are untouched - they live elsewhere - so nothing else notices.
    try "{}".write(to: healthy.appendingPathComponent("settings.json"), atomically: true,
                   encoding: .utf8)
    check("a wiped settings.json is noticed", !hooksPresent(healthy)
              && IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill,
                                                    population: [healthy], binary: binary))
    check("…and re-running the sync puts the hooks back",
          installAll(healthy) && hooksPresent(healthy))
    // THE PROPERTY THAT MATTERS: the repair's own write must not buy another repair. Asserted twice
    // over, because they are two different claims - the gate says no, and the sync itself reports
    // that it changed nothing.
    check("the repair's own write does not ask for another repair",
          !IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy], binary: binary))
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
          !IntegrationsStore.hooksNeedHealing(skillFiles: removedSkill, population: [removed], binary: binary))
    // A skills/tally that belongs to somebody else is the same answer for a different reason: it was
    // never ours, so there is nothing of ours to put back.
    let foreign = try makeHome("foreign", skill: "---\nname: someone-elses\n---\nnot ours")
    check("a foreign skills/tally is not read as an install of ours",
          !IntegrationsStore.hooksNeedHealing(
            skillFiles: [IntegrationsStore.claudeSkillFile(inHome: foreign)],
            population: [foreign], binary: binary))
    // And the two guards do not shadow each other: a home that IS ours, next to one that is not,
    // still gets its own hooks back.
    check("an installed home beside an uninstalled one is still healed",
          IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill + removedSkill,
                                             population: [healthy, removed],
                                             binary: binary) == false)
    try "{}".write(to: settingsFile, atomically: true, encoding: .utf8)
    check("…and once ITS hooks go, the pair is healed on the installed one's account",
          IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill + removedSkill,
                                             population: [healthy, removed], binary: binary))

    // MARK: - A HOOK THAT IS PRESENT AND POINTS AT THE WRONG BINARY
    //
    // The failure the presence check could not see, and the one that actually reached a user: a
    // Release build running out of a build tree synced itself into the shared config homes and
    // registered every hook at a path inside DerivedData, where no bundled CLI exists. Every entry
    // was present, so nothing needed healing; every `/tally-account` answered "No such file or
    // directory" and fell through to a model turn - which is exactly the cost the hook exists to
    // avoid, paid on every prompt, silently.
    _ = installAll(healthy)
    let stray = URL(fileURLWithPath: "/Users/someone/Library/Developer/Xcode/DerivedData/"
                    + "Tally-abc/Build/Products/Release/Tally.app/Contents/Helpers/tally")
    for command in IntegrationsStore.promptCommands {
        _ = try IntegrationsStore.upsertPromptHook(
            in: healthy.appendingPathComponent("settings.json"),
            command: IntegrationsStore.promptHookCommand(stray, command: command), hook: command)
    }
    check("an entry naming another app's binary is still PRESENT", hooksPresent(healthy))
    check("…and is nonetheless in need of healing",
          IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy],
                                             binary: binary))
    check("…which the sync repairs by rewriting the path",
          installAll(healthy)
              && IntegrationsStore.registeredPromptHookCommands(
                  healthy.appendingPathComponent("settings.json"),
                  hook: IntegrationsStore.promptCommands[0])
                  == [IntegrationsStore.promptHookCommand(binary,
                                                          command: IntegrationsStore.promptCommands[0])])
    // The repair must settle, exactly like the presence one: this gate runs on every settings write,
    // and a repair that still reads as damaged is a write-event-write loop by another name.
    check("…and once repaired asks for nothing further",
          !IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy],
                                              binary: binary))

    // MARK: - A SECOND REGISTRATION OF OURS IN THE SAME FILE
    //
    // Our own writes make at most one, but this file is rewritten by things that know nothing about
    // Tally, and a dotfiles merge or two config homes folded into one leaves a duplicate. Claude Code
    // runs EVERY hook that matches, so a stale copy beside a good one keeps answering
    // `/tally-account` with "No such file or directory" - the failure looking exactly like the one
    // above, while a check that reads the first entry only reports the file in good order.
    let duplicated = healthy.appendingPathComponent("settings.json")
    let firstCommand = IntegrationsStore.promptCommands[0]
    var withDuplicate = (try? JSONSerialization.jsonObject(with: Data(contentsOf: duplicated)))
        as? [String: Any] ?? [:]
    var hookBlock = withDuplicate["hooks"] as? [String: Any] ?? [:]
    var promptEntries = hookBlock[IntegrationsStore.promptHookEvent] as? [[String: Any]] ?? []
    // The duplicate carries a hook of the USER's in the same entry, which is what says the entry
    // must survive the collapse even though our copy in it does not.
    let neighbour: [String: Any] = ["type": "command", "command": "/usr/local/bin/my-own-audit"]
    promptEntries.append([
        "matcher": firstCommand.name,
        "hooks": [["type": "command",
                   "command": IntegrationsStore.promptHookCommand(stray, command: firstCommand)],
                  neighbour],
    ])
    hookBlock[IntegrationsStore.promptHookEvent] = promptEntries
    withDuplicate["hooks"] = hookBlock
    try JSONSerialization.data(withJSONObject: withDuplicate).write(to: duplicated)
    check("both registrations are read, not just the first",
          IntegrationsStore.registeredPromptHookCommands(duplicated, hook: firstCommand).count == 2)
    check("…so a stale one beside a good one is damage",
          IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy],
                                             binary: binary))
    _ = installAll(healthy)
    // ONE, not two both spelled correctly. Claude Code runs every hook that matches, so a repair
    // that fixed the duplicate instead of collapsing it would run the command twice on every
    // prompt - two answers, two writes - while reading as perfectly healthy from both faces.
    check("…which the repair collapses to exactly one registration",
          IntegrationsStore.registeredPromptHookCommands(duplicated, hook: firstCommand)
              == [IntegrationsStore.promptHookCommand(binary, command: firstCommand)])
    // And the user's hook in the entry the duplicate lived in is still there: what is collapsed is
    // ours, never the company it kept.
    let afterCollapse = (try? JSONSerialization.jsonObject(with: Data(contentsOf: duplicated)))
        as? [String: Any] ?? [:]
    let survivingHooks = ((afterCollapse["hooks"] as? [String: Any])?[IntegrationsStore.promptHookEvent]
        as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    check("…leaving a hook the user put beside it exactly where it was",
          survivingHooks.contains { $0["command"] as? String == "/usr/local/bin/my-own-audit" })
    // The pair that has to move together: detection reading every copy while the repair left them
    // all in place would report a file in good order that answers everything twice.
    check("…and settles, with nothing left for a second heal to do",
          !IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy],
                                              binary: binary) && !installAll(healthy))

    // THE DUPLICATE THAT IS NOT STALE, which is the one a "does any of them name the wrong binary"
    // check calls healthy: a dotfiles merge or two config homes folded into one leaves two entries
    // that BOTH name the current app. Nothing about the paths is wrong, so the watcher never reaches
    // the repair - and every `/tally-account` runs twice, two answers and two writes, forever
    // (codex review of 264f657). The count is therefore part of the health condition, not a detail
    // of it.
    let current = IntegrationsStore.promptHookCommand(binary, command: firstCommand)
    var withTwin = (try? JSONSerialization.jsonObject(with: Data(contentsOf: duplicated)))
        as? [String: Any] ?? [:]
    var twinBlock = withTwin["hooks"] as? [String: Any] ?? [:]
    var twinEntries = twinBlock[IntegrationsStore.promptHookEvent] as? [[String: Any]] ?? []
    twinEntries.append(["matcher": firstCommand.name,
                        "hooks": [["type": "command", "command": current]]])
    twinBlock[IntegrationsStore.promptHookEvent] = twinEntries
    withTwin["hooks"] = twinBlock
    try JSONSerialization.data(withJSONObject: withTwin).write(to: duplicated)
    check("two registrations both naming this very app are still two",
          IntegrationsStore.registeredPromptHookCommands(duplicated, hook: firstCommand)
              == [current, current])
    check("…which is damage, though not one of them names anything wrong",
          IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy],
                                             binary: binary))
    _ = installAll(healthy)
    check("…and the repair leaves exactly one of them",
          IntegrationsStore.registeredPromptHookCommands(duplicated, hook: firstCommand) == [current])
    check("…after which there is nothing left to ask about",
          !IntegrationsStore.hooksNeedHealing(skillFiles: healthySkill, population: [healthy],
                                              binary: binary) && !installAll(healthy))

    // MARK: - ASKED PER HOME, WRITTEN PER GROUP
    //
    // On a shared setup several homes stand in front of one physical settings.json. The sync groups
    // them by that file and writes the FIRST home's path; the heal check asks every home separately.
    // The two are the same question only because the write resolves the link before landing
    // (`editSettings`), so the second home reads back exactly what the group's one write wrote. If it
    // did not, a shared pair would answer "needs healing" on every filesystem event, forever.
    let shareA = try makeHome("share-a", skill: currentSkill)
    let shareB = try makeHome("share-b", skill: currentSkill)
    try "{}".write(to: shareA.appendingPathComponent("settings.json"), atomically: true,
                   encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        at: shareB.appendingPathComponent("settings.json"),
        withDestinationURL: shareA.appendingPathComponent("settings.json"))
    // The LINKED home first, because that is the order a discovery pass can hand over and it is the
    // one that can go wrong: the group's single write is aimed at a symlink, and an atomic save
    // aimed at a symlink replaces the LINK unless the path is resolved first. The physical home
    // would then never receive the hook while reading a file that no longer stands for it.
    for command in IntegrationsStore.promptCommands {
        _ = IntegrationsStore.syncPromptCommand(
            inHomes: [shareB, shareA],
            hookCommand: IntegrationsStore.promptHookCommand(binary, command: command),
            command: command)
    }
    let sharedSkills = [IntegrationsStore.claudeSkillFile(inHome: shareA),
                        IntegrationsStore.claudeSkillFile(inHome: shareB)]
    check("the other home of a shared pair reads the hook the group's one write put there",
          hooksPresent(shareA) && hooksPresent(shareB))
    check("…because the write resolved the link instead of landing on top of it",
          (try? FileManager.default.destinationOfSymbolicLink(
            atPath: shareB.appendingPathComponent("settings.json").path)) != nil)
    check("…so the pair settles instead of asking for a repair on every event",
          !IntegrationsStore.hooksNeedHealing(skillFiles: sharedSkills,
                                              population: [shareA, shareB], binary: binary))

    // MARK: - THE GATE IN FRONT OF ALL OF IT
    //
    // None of the above may run at all from a build tree. The dev variant was the only build that
    // knew to keep its hands off shared state, and a locally built RELEASE carries the release
    // bundle id, so nothing about it said so - which is how the stray path above got written.
    check("a Release built into DerivedData is a build tree",
          BuildVariant.isBuildProductsPath(
            "/Users/someone/Library/Developer/Xcode/DerivedData/Tally-abc/Build/Products/Release/Tally.app"))
    check("…and so is one under a custom derived-data location",
          BuildVariant.isBuildProductsPath("/tmp/ci-out/Build/Products/Debug/Tally.app"))
    check("an installed app is not",
          !BuildVariant.isBuildProductsPath("/Applications/Tally.app"))
    check("…nor is one a user keeps somewhere of their own",
          !BuildVariant.isBuildProductsPath("/Users/someone/Applications/Tally.app"))
    // THE ARCHIVE, which the release pipeline makes on every version and Xcode's Organizer launches
    // with a double click. It holds neither tail above - `build` is lowercase and there is no
    // `Build/Products` pair - so it read as an installed app while being a Release build with no
    // embedded CLI, one directory over from the failure this whole gate was written for.
    check("the archive the release pipeline builds is a build tree",
          BuildVariant.isBuildProductsPath(
            "/Users/someone/workspace/tally/build/Tally.xcarchive/Products/Applications/Tally.app"))
    check("…and so is one Xcode filed away in the Organizer",
          BuildVariant.isBuildProductsPath("/Users/someone/Library/Developer/Xcode/Archives/"
            + "2026-08-07/Tally 8-7-26, 10.02.xcarchive/Products/Applications/Tally.app"))
    // Case, because the tails are directory names a build setting can respell and the volume this
    // is built on is case-insensitive anyway: `build/products` names the same directory.
    check("…and a build products tail in another case is the same directory",
          BuildVariant.isBuildProductsPath("/tmp/out/build/products/Release/Tally.app"))
    check("while a folder that merely says products is not a build tree",
          !BuildVariant.isBuildProductsPath("/Users/someone/Products/Tally.app"))
    // The one a USER reaches rather than a developer: an app run straight out of the downloaded DMG,
    // never dragged to /Applications, is launched from a read-only translocated copy that exists for
    // that launch alone. It is a complete shipped bundle, embedded CLI included, so nothing else here
    // catches it - and the hooks it registers name a path that is gone by the next boot.
    check("a translocated launch, which is the DMG never dragged anywhere, is not an install",
          BuildVariant.isBuildProductsPath("/private/var/folders/qx/8k2m0000gn/T/AppTranslocation/"
            + "3F2A9C1E-4B7D-4E55-9A10-2C6D8B0F1E33/d/Tally.app"))

    // MARK: - THE MECHANISM BEHIND THE PATH TEST
    //
    // The paths above are the layouts somebody has already been bitten by, and `CONFIGURATION_BUILD_DIR`
    // alone can put a Release build anywhere at all - so the thing that actually distinguishes a
    // shipped app is asserted directly: the CLI is embedded by scripts/build-release.sh AFTER the
    // export, so a bundle without it never came out of the release pipeline, whatever its path says.
    let shipped = tmp.appendingPathComponent("bundle-shipped/Tally.app")
    try FileManager.default.createDirectory(
        at: shipped.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
    try Data().write(to: shipped.appendingPathComponent(BuildVariant.bundledCLIRelativePath))
    check("a bundle carrying the embedded CLI is one the release pipeline finished",
          BuildVariant.bundleCarriesCLI(shipped))
    let unfinished = tmp.appendingPathComponent("bundle-archive/Tally.app")
    try FileManager.default.createDirectory(
        at: unfinished.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    check("…and one that stopped at the export is not, however it is named or placed",
          !BuildVariant.bundleCarriesCLI(unfinished))
    // The check and the binary the hooks are registered with must name the SAME file, or the check
    // is about something else entirely.
    check("the embedded CLI the check looks for is the one the hooks are registered with",
          IntegrationsStore.bundledCLIURL.path.hasSuffix("/" + BuildVariant.bundledCLIRelativePath))
    // And the pipeline step the whole judgment leans on. Drop this from the release script and every
    // installed app quietly reads as unshipped, which is the one way this gate can misfire.
    let releaseScript = (try? String(contentsOfFile: "scripts/build-release.sh", encoding: .utf8)) ?? ""
    check("the release pipeline still embeds it, which is what makes absence mean anything",
          releaseScript.contains("$APP/" + BuildVariant.bundledCLIRelativePath))
    // The composition, on this very process: a bare executable in a temp directory is not the dev
    // app and not under a build products path, and is unshipped for the third reason alone.
    check("a process that is no finished app bundle at all is unshipped on that ground",
          !BuildVariant.isDev && !BuildVariant.bundlesCLI && BuildVariant.isUnshipped)

    // MARK: - THE GATE IN FRONT OF THE REST OF THE SHARED STATE
    //
    // The hooks were never the only thing a build tree could write. A Release built locally polls
    // the same accounts as the installed app and publishes over the same ~/.tally files, so the CLI
    // picks launch accounts from whichever of the two wrote last - and the dev flag, which is what
    // those writes were gated on, says nothing about a build wearing the release bundle id.
    func gateSource(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
    for file in ["Tally/Stores/UsageStore.swift", "Tally/Stores/UsageStorePublishing.swift",
                 "Tally/Stores/LaunchPolicyStore.swift", "Tally/Stores/IntegrationsSelfHeal.swift",
                 "Tally/Stores/KnownAccountsStore.swift", "Tally/Stores/LoginStatusStore.swift"] {
        let source = gateSource(file)
        check("\(file) gates its shared-state writes on the unshipped judgment",
              !source.isEmpty && source.contains("BuildVariant.isUnshipped")
                  && !source.contains("BuildVariant.isDev"))
    }
    // (The login alert's own gate is pinned the same way in tests/logincheck, beside the state
    // machine it dedups with.)
    //
    // AND THE EARLIEST WRITES IN A ROUND, named one by one. A gate anywhere in this file was not
    // enough: the reconciliation runs BEFORE the refresh loop's own gate and writes into the user's
    // config homes (the pending-add marker) and their ~/.claude.json (the onboarding note), so an
    // unshipped build had already edited the installed app's state by the time the round reached a
    // guard (codex review of e7fe1a0). Pinned by shape rather than by presence, because a second
    // gate elsewhere in the same file would satisfy the check above while this one was gone.
    let knownAccounts = gateSource("Tally/Stores/KnownAccountsStore.swift")
    check("the marker and onboarding writes are gated before the round can reach them",
          knownAccounts.contains("for account in discovered where !BuildVariant.isUnshipped {"))
    check("…and so is the memory of which accounts exist, whose defaults domain is the release app's",
          knownAccounts.contains("private func persist(_ accounts: [KnownAccount]) {\n"
            + "        guard !BuildVariant.isUnshipped else { return }"))
    check("…as is the identity memory the same round writes",
          gateSource("Tally/Stores/LoginStatusStore.swift").contains(
            "private func persistIdentities() {\n"
            + "        guard !BuildVariant.isUnshipped else { return }"))
}
