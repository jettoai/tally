import Foundation

// What a RENAME does to an install that is already on disk, which is the one change that leaves a
// working install of ours answering to a name nobody is offered any more. Two fixtures: the clean
// migration, and the one whose cleanup failed and left the uninstall to answer for it. Split from
// switchcommandchecks.swift on file size.
//
// Its own reader for the hook array, deliberately: these fixtures assert on what SURVIVES a
// migration, so they read the document the same way the neighbouring checks do without borrowing a
// closure from them.
private func expansion(_ settings: [String: Any]) -> [[String: Any]] {
    ((settings["hooks"] as? [String: Any])?["UserPromptExpansion"] as? [[String: Any]]) ?? []
}

private func commands(_ settings: [String: Any]) -> [String] {
    expansion(settings).flatMap { entry in
        (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }
}

@MainActor
func runRenameChecks(tmp: URL, hookCommand: String) throws {
    // MARK: THE RENAME - a home that was set up when this command was called `/tally-switch`.
    //
    // A rename is the one change that leaves a working install of OURS pointing at a name nobody is
    // offered any more: the old command file still answers if it is typed, and the old hook entry
    // still intercepts it. Nothing else in this machinery will ever clear them, because every other
    // question it asks is about the CURRENT name. So the sync carries the former names and takes
    // them out, and this is the fixture that proves a home comes out the other side holding exactly
    // one of each.
    let oldHome = tmp.appendingPathComponent("renamed-home")
    let oldCommandFile = IntegrationsStore.promptCommandFile(inHome: oldHome, named: "tally-switch")
    try FileManager.default.createDirectory(at: oldCommandFile.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    // Written the way the old app wrote it: our marker, our subcommand, the old name.
    try IntegrationsStore.switchCommandMarkdown()
        .write(to: oldCommandFile, atomically: true, encoding: .utf8)
    let oldSettings = oldHome.appendingPathComponent("settings.json")
    let oldRegistration: [String: Any] = ["hooks": ["UserPromptExpansion": [
        ["matcher": "tally-switch", "hooks": [["type": "command", "command": hookCommand]]],
        ["matcher": "someone-elses", "hooks": [["type": "command", "command": "their-hook.sh"]]],
    ]]]
    try JSONSerialization.data(withJSONObject: oldRegistration).write(to: oldSettings)

    let renamed = IntegrationsStore.syncSwitchCommand(inHomes: [oldHome], hookCommand: hookCommand)
    check("the rename sync reports that something changed", renamed.changed && renamed.error == nil)
    check("the file under the old name is gone",
          !FileManager.default.fileExists(atPath: oldCommandFile.path))
    check("…and the new one is in its place",
          (try? String(contentsOf: IntegrationsStore.switchCommandFile(inHome: oldHome),
                       encoding: .utf8))?.contains(IntegrationsStore.switchCommandMarker) == true)
    let migrated = (try? JSONSerialization.jsonObject(with: Data(contentsOf: oldSettings)))
        as? [String: Any] ?? [:]
    let matchers = expansion(migrated).compactMap { $0["matcher"] as? String }
    check("the hook entry under the old name is gone, the new one is there, once",
          matchers.filter { $0 == "tally-switch" }.isEmpty
              && matchers.filter { $0 == "tally" }.count == 1)
    check("…and the user's own entry beside it is untouched",
          matchers.contains("someone-elses") && commands(migrated).contains("their-hook.sh"))
    check("no orphan is left in the commands folder",
          (try? FileManager.default.contentsOfDirectory(
              atPath: oldCommandFile.deletingLastPathComponent().path)) == ["tally.md"])
    // Idempotent: the second launch has nothing left to migrate, so it must not report a change
    // (which is what would make every launch rewrite settings.json for nobody).
    check("a second sync over the migrated home changes nothing",
          !IntegrationsStore.syncSwitchCommand(inHomes: [oldHome],
                                               hookCommand: hookCommand).changed)

    // MARK: A RENAME CLEANUP THAT FAILED - and the uninstall that has to answer for it.
    //
    // The sync deletes the old file and the old entry, and either delete can fail: an immutable
    // file, an ACL, a folder that was read-only for a minute. The install carries on regardless,
    // which is right (an orphan is a smaller problem than a command that never got written), so
    // what is left is a home holding BOTH spellings while the manifest, keyed by component rather
    // than by name, records only the new one. If the uninstall knew the current name alone, then
    // the day the user fixes the permission would be the day the last thing that could ever remove
    // those artifacts is gone: the app that knows the former name has just been taken away.
    //
    // The failure is made real rather than mocked. An immutable file cannot be unlinked and an
    // immutable settings.json cannot be replaced, while the folder around them stays writable - so
    // the new command file still installs, which is exactly the reported shape.
    let stuckHome = tmp.appendingPathComponent("cleanup-failed-home")
    let stuckOld = IntegrationsStore.promptCommandFile(inHome: stuckHome, named: "tally-switch")
    let stuckNew = IntegrationsStore.switchCommandFile(inHome: stuckHome)
    let stuckSettings = stuckHome.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: stuckOld.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try IntegrationsStore.switchCommandMarkdown()
        .write(to: stuckOld, atomically: true, encoding: .utf8)
    try JSONSerialization.data(withJSONObject: oldRegistration).write(to: stuckSettings)
    for path in [stuckOld.path, stuckSettings.path] {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
    }
    let stuck = IntegrationsStore.syncSwitchCommand(inHomes: [stuckHome], hookCommand: hookCommand)
    check("a rename cleanup that cannot be done is reported", stuck.error != nil)
    check("…and does not stop the new name from installing",
          (try? String(contentsOf: stuckNew, encoding: .utf8))?
              .contains(IntegrationsStore.switchCommandMarker) == true)
    check("…so the old file is still on disk", FileManager.default.fileExists(atPath: stuckOld.path))
    let stuckState = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stuckSettings)))
        as? [String: Any] ?? [:]
    check("…as is the entry under the old name",
          expansion(stuckState).compactMap { $0["matcher"] as? String }.contains("tally-switch"))
    // The manifest angle, which is why the uninstall cannot lean on it: what this sync hands back
    // to be recorded names the new spelling only. The old path is not in it and never will be.
    check("…while what the sync reports for the manifest names the new spelling alone",
          stuck.commands == [stuckNew])

    // The user fixes the permission, and then uninstalls. Both halves have to go, under both names.
    for path in [stuckOld.path, stuckSettings.path] {
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path)
    }
    try IntegrationsStore.removePromptCommandEveryName(in: stuckNew,
                                                       command: IntegrationsStore.switchCommand)
    _ = try IntegrationsStore.removePromptHookEveryName(in: stuckSettings,
                                                        hook: IntegrationsStore.switchCommand)
    check("the uninstall takes the file the failed rename left behind",
          !FileManager.default.fileExists(atPath: stuckOld.path)
              && !FileManager.default.fileExists(atPath: stuckNew.path))
    let uninstalled = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stuckSettings)))
        as? [String: Any] ?? [:]
    let leftMatchers = expansion(uninstalled).compactMap { $0["matcher"] as? String }
    check("…and the entry it left under the old name", !leftMatchers.contains("tally-switch"))
    check("…without taking the user's own entry with it",
          leftMatchers == ["someone-elses"] && commands(uninstalled) == ["their-hook.sh"])
}
