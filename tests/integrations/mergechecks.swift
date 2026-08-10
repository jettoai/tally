import Foundation

// WHAT THE MERGE DOES TO AN INSTALL THAT IS ALREADY ON DISK.
//
// `/tally-account` and `/tally-model` became `/tally`, and every machine that had the pair still has
// two command files, two hook entries and two tool registrations naming tools the new command does
// not call. Nothing else will ever come to clear them: every other question this machinery asks is
// about the CURRENT command, so an entry under a name nobody is offered any more would sit there
// intercepting a slash command for ever.
//
// A RENAME ALREADY HAD THIS PATH (renamechecks.swift), and a merge is the harder half of it: a
// renamed command keeps its subcommand, so the old entry is still recognisable by what it RUNS,
// while a merged one runs something new and calls a new tool. Both former spellings therefore
// travel with the command (`PromptCommand.formerHookMarkers`), and this is the fixture that proves
// a home comes out holding exactly one of everything.
private func expansion(_ settings: [String: Any]) -> [[String: Any]] {
    ((settings["hooks"] as? [String: Any])?["UserPromptExpansion"] as? [[String: Any]]) ?? []
}

@MainActor
func runMergeChecks(tmp: URL) throws {
    let binary = URL(fileURLWithPath: "/Applications/Tally.app/Contents/Helpers/tally")
    let command = IntegrationsStore.tallyPromptCommand
    let home = tmp.appendingPathComponent("merged-home")
    let commands = home.appendingPathComponent("commands")
    try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
    // The two files the old app wrote, carrying our marker so they are ours to take away.
    for name in ["tally-account", "tally-model"] {
        try "<!-- \(IntegrationsStore.promptCommandMarker), managed by Tally.app -->\n"
            .write(to: commands.appendingPathComponent("\(name).md"), atomically: true,
                   encoding: .utf8)
    }
    // The registration the old app wrote: one entry per command, each holding the pair of hooks it
    // shipped with (the tool call and its backstop), and a neighbour of the user's beside them.
    func oldEntry(_ name: String, marker: String, tool: String) -> [String: Any] {
        ["matcher": name, "hooks": [
            ["type": IntegrationsStore.mcpHookTypeToken, "server": tallyMCPServerName,
             "tool": tool, "input": promptHookInputBlock(),
             "timeout": IntegrationsStore.mcpHookTimeout],
            ["type": "command",
             "command": "\"\(binary.path)\" \(marker) \(promptHookBackstopFlag)"],
        ]]
    }
    let settings = home.appendingPathComponent("settings.json")
    try JSONSerialization.data(withJSONObject: ["hooks": ["UserPromptExpansion": [
        oldEntry("tally-account", marker: "hook-switch", tool: "pick_account"),
        oldEntry("tally-model", marker: "hook-model", tool: "pick_model"),
        ["matcher": "tally-account", "hooks": [["type": "command", "command": "mine.sh"]]],
    ]]]).write(to: settings)

    // THE OLD ENTRIES ARE RECOGNISED AS OURS, which is the predicate the whole migration rests on:
    // read as a stranger's, they would be left exactly where they are for ever. Asked the way the
    // cleanup asks it - by the name the entry is under - because that is the only way it is asked.
    let document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings)))
        as? [String: Any] ?? [:]
    check("an entry written before the merge is read as ours, by its old tool",
          IntegrationsStore.settingsWithoutPromptHook(document, hook: command,
                                                      matcher: "tally-model") != nil)
    check("…and by its old subcommand",
          IntegrationsStore.settingsWithoutPromptHook(document, hook: command,
                                                      matcher: "tally-account") != nil)
    check("…while a name we never answered to is left alone",
          IntegrationsStore.settingsWithoutPromptHook(document, hook: command,
                                                      matcher: "someone-elses") == nil)
    // AND THE SELF-HEAL IS WHAT RUNS THE MIGRATION on a machine that updated while the app was
    // closed: what is registered under the current name is nothing at all, which is the same answer
    // as "stale" and the same repair (`hooksNeedHealing`).
    let hooks = IntegrationsStore.promptHookEntries(binary, command: command, nativePicker: true)
    check("a home still holding the old pair reads as needing repair",
          !IntegrationsStore.promptHooksMatch(
            IntegrationsStore.registeredPromptHooks(settings, hook: command), hooks))

    let sync = IntegrationsStore.syncPromptCommand(inHomes: [home], hooks: hooks, command: command)
    check("the merge sync reports that something changed", sync.changed && sync.error == nil)

    let migrated = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings)))
        as? [String: Any] ?? [:]
    let matchers = expansion(migrated).compactMap { $0["matcher"] as? String }
    check("both old registrations are gone and one new one is there",
          matchers.filter { $0 == "tally" }.count == 1
              && !matchers.contains("tally-model"))
    // The neighbour's entry keeps its matcher, which happens to be an old name: what is ours is the
    // HOOK, never the entry around it, and a user's own hook under any name is not ours to move.
    check("…and the user's own hook is left where it was, under the name they gave it",
          expansion(migrated).contains { entry in
              entry["matcher"] as? String == "tally-account"
                  && (entry["hooks"] as? [[String: Any]] ?? [])
                      .compactMap { $0["command"] as? String } == ["mine.sh"]
          })
    check("the new registration is the pair this app writes",
          IntegrationsStore.promptHooksMatch(
            IntegrationsStore.registeredPromptHooks(settings, hook: command), hooks))
    check("both old command files are gone, and the new one is in their place",
          (try? FileManager.default.contentsOfDirectory(atPath: commands.path)) == ["tally.md"])

    // Idempotent: the launch after the migration has nothing left to do, which is what keeps the
    // self-heal from rewriting settings.json for nobody on every event it hears.
    check("a second sync over the migrated home changes nothing",
          !IntegrationsStore.syncPromptCommand(inHomes: [home], hooks: hooks,
                                               command: command).changed)

    // …and once it has run, it is in perfect health, which is what ends the write-event-write cycle.
    check("…and reads as healthy once the migration has run",
          IntegrationsStore.promptHooksMatch(
            IntegrationsStore.registeredPromptHooks(settings, hook: command), hooks))
}

// THE OTHER HALF OF THE SAME RELEASE: the skill's own folder.
//
// `/tally` was installed on every machine 0.44.0 reached and offered on none of them, because the
// skill sitting in `skills/tally` claims that name in the slash-command menu. The command file was
// perfect, the hook was registered, and the menu listed the skill under the name its frontmatter
// carries - so nothing about the install looked wrong from any surface the app has.
//
// What makes this its own fixture rather than a version check: the installs that need moving are
// ALREADY AT THE CURRENT VERSION. 0.44.0 wrote v16 into the folder that shadows the command, so the
// marker says "current" while the user has no command at all, and every mechanism this app has for
// travelling an edit is keyed on that marker. The move is keyed on the folder instead.
@MainActor
func runSkillFolderMoveChecks(tmp: URL) throws {
    let fm = FileManager.default
    func home(_ name: String, old: String? = nil, new: String? = nil) throws -> URL {
        let home = tmp.appendingPathComponent(name)
        for (file, text) in [(home.appendingPathComponent("skills/tally/SKILL.md"), old),
                             (IntegrationsStore.claudeSkillFile(inHome: home), new)] {
            guard let text else { continue }
            try fm.createDirectory(at: file.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return home
    }
    let current = IntegrationsStore.skillMarkdown()
    let theirs = "---\nname: tally\ndescription: my own thing\n---\nmine"

    // A home as 0.44.0 left it: our skill, at the current version, in the folder that took the
    // command away.
    let moved = try home("moved-home", old: current)
    let movedOld = moved.appendingPathComponent("skills/tally")
    let movedNow = IntegrationsStore.claudeSkillFile(inHome: moved)
    check("the skill's folder is not the slash command's name",
          movedNow.deletingLastPathComponent().lastPathComponent == "tally-quota"
              && IntegrationsStore.formerSkillFolderNames == ["tally"])
    let pass = IntegrationsStore.autoUpdateSkills(in: [movedNow])
    check("one pass moves an install that no version marker could have reached",
          pass.error == nil && pass.updated > 0 && pass.ours.map(\.path) == [movedNow.path])
    check("…the skill is at the folder Claude Code reads, with the text this build ships",
          (try? String(contentsOf: movedNow, encoding: .utf8)) == current)
    check("…and the old folder is gone entirely, not merely emptied",
          !fm.fileExists(atPath: movedOld.path))
    let second = IntegrationsStore.autoUpdateSkills(in: [movedNow])
    check("a second pass over a moved install changes nothing",
          second.updated == 0 && second.error == nil)

    // A SKILLS TREE SHARED BY TWO HOMES, which is the ordinary multi-account setup: one physical
    // folder, symlinked. The second spelling reaches a move that has already happened, so it must
    // find nothing to do rather than doing it twice or reporting a failure.
    let shared = try home("shared-home", old: current)
    let mirror = tmp.appendingPathComponent("mirror-home")
    try fm.createDirectory(at: mirror, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: mirror.appendingPathComponent("skills"),
                              withDestinationURL: shared.appendingPathComponent("skills"))
    let sharedPass = IntegrationsStore.autoUpdateSkills(
        in: [IntegrationsStore.claudeSkillFile(inHome: shared),
             IntegrationsStore.claudeSkillFile(inHome: mirror)])
    check("a shared skills tree is moved once and answers for both homes",
          sharedPass.error == nil && sharedPass.ours.count == 2
              && !fm.fileExists(atPath: shared.appendingPathComponent("skills/tally").path))
    check("…and the second home reads the moved skill through its own spelling",
          (try? String(contentsOf: IntegrationsStore.claudeSkillFile(inHome: mirror),
                       encoding: .utf8)) == current)

    // A SKILL OF THE USER'S under the old name. We no longer install there, which makes that name
    // theirs: it is never moved, never deleted, and never read as an install of ours.
    let stranger = try home("stranger-home", old: theirs)
    let strangerPass = IntegrationsStore.autoUpdateSkills(
        in: [IntegrationsStore.claudeSkillFile(inHome: stranger)])
    check("a user's own skill in the old folder is left exactly where it is",
          strangerPass.updated == 0 && strangerPass.ours.isEmpty && strangerPass.error == nil
              && (try? String(contentsOf: stranger.appendingPathComponent("skills/tally/SKILL.md"),
                              encoding: .utf8)) == theirs)
    check("…and nothing is installed beside it, because an absent skill stays absent",
          !fm.fileExists(atPath: IntegrationsStore.claudeSkillFile(inHome: stranger).path))

    // …while a file of theirs at the path we DO write to is the conflict the install has always
    // reported, named after the folder this app writes today.
    let occupied = try home("occupied-home", old: current, new: theirs)
    let blocked = IntegrationsStore.autoUpdateSkills(
        in: [IntegrationsStore.claudeSkillFile(inHome: occupied)])
    check("a stranger at the new path stops the move instead of clobbering them",
          blocked.error?.contains("skills/tally-quota") == true
              && (try? String(contentsOf: IntegrationsStore.claudeSkillFile(inHome: occupied),
                              encoding: .utf8)) == theirs)
    check("…and our install keeps standing where it is until the move can happen",
          (try? String(contentsOf: occupied.appendingPathComponent("skills/tally/SKILL.md"),
                       encoding: .utf8)) == current)

    // THE UNINSTALL reaches the old folder through the same call, which is what keeps a machine
    // that never got the move from keeping an orphan nothing is ever coming back for.
    let leftover = try home("leftover-home", old: current)
    check("clearing the former folders removes what is ours",
          try IntegrationsStore.clearFormerSkillFolders(
            besides: IntegrationsStore.claudeSkillFile(inHome: leftover))
              && !fm.fileExists(atPath: leftover.appendingPathComponent("skills/tally").path))
    check("…and reports nothing to do when there is nothing of ours there",
          try !IntegrationsStore.clearFormerSkillFolders(
            besides: IntegrationsStore.claudeSkillFile(inHome: stranger)))

    // And the manifest, which on every machine that has been through 0.44.0 records the old path:
    // read as a home rather than as a file, so the uninstall and the move both reach the install
    // Claude Code actually loads.
    check("a path recorded before the move names the install of today",
          IntegrationsStore.currentSkillFile(
            forRecordedPath: moved.appendingPathComponent("skills/tally/SKILL.md")).path
              == movedNow.path)
    check("…and a path already at the current folder is left as it is",
          IntegrationsStore.currentSkillFile(forRecordedPath: movedNow).path == movedNow.path)
}
