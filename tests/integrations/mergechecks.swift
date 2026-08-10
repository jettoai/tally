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
