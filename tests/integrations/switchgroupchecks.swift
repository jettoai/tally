import Foundation

// Which homes one settings.json speaks for, and therefore whose `/tally-switch` a hook registered
// in it would intercept. Split from switchcommandchecks.swift for file size.
//
// Every assertion here is about a GROUP rather than a file: homes that share a settings.json by
// symlink, homes the skill dedup drops but whose commands folder is their own, and a home that was
// Tally's to manage until the user wrote their own command file.
@MainActor
func runSwitchGroupChecks(tmp: URL, skill currentSkill: String) throws {
    let hookCommand = IntegrationsStore.switchHookCommand(
        URL(fileURLWithPath: "/Applications/Tally.app/Contents/Helpers/tally"))
    /// A command file that is not ours, in the shape a user would actually write.
    let userCommand = "---\ndescription: my own switcher\n---\nmine"

    // MARK: one home at a time - and the order that keeps a user's own command file running.
    //
    // The hook exits 2, which STOPS the expansion. Registering it next to a commands/tally-switch.md
    // that belongs to the user would take their command away: it would never run again, and nothing
    // would say why. So a home whose command file is not ours is left entirely alone.
    let ownedHome = tmp.appendingPathComponent("owned-home")
    let ownedCommand = IntegrationsStore.switchCommandFile(inHome: ownedHome)
    try FileManager.default.createDirectory(at: ownedCommand.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try userCommand.write(to: ownedCommand, atomically: true, encoding: .utf8)
    let refusedHome = IntegrationsStore.syncSwitchCommand(inHomes: [ownedHome],
                                                          hookCommand: hookCommand)
    check("a foreign command file stops the hook being registered",
          refusedHome.error != nil && refusedHome.settings == nil && refusedHome.commands.isEmpty)
    check("…so that home's settings.json is never even created",
          !FileManager.default.fileExists(
            atPath: ownedHome.appendingPathComponent("settings.json").path))
    check("…and their command file is exactly as they left it",
          try String(contentsOf: ownedCommand, encoding: .utf8) == userCommand)

    let cleanHome = tmp.appendingPathComponent("clean-home")
    let installed = IntegrationsStore.syncSwitchCommand(inHomes: [cleanHome],
                                                        hookCommand: hookCommand)
    check("a clean home gets both halves, and says so",
          installed.error == nil && installed.changed
              && installed.commands == [IntegrationsStore.switchCommandFile(inHome: cleanHome)]
              && installed.settings == cleanHome.appendingPathComponent("settings.json"))
    check("…and a second pass changes nothing",
          IntegrationsStore.syncSwitchCommand(inHomes: [cleanHome],
                                              hookCommand: hookCommand).changed == false)

    // MARK: the group, which is what a shared settings.json makes the homes into.
    //
    // Home A keeps its own commands/tally-switch.md; home B is clean; both read ONE settings.json
    // through a symlink. The hook lives in that file, so registering it "for B" registers it for A
    // as well and takes A's command away. The group is therefore judged whole.
    let groupSettings = tmp.appendingPathComponent("group-shared/settings.json")
    try FileManager.default.createDirectory(at: groupSettings.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["model": "opusplan"]).write(to: groupSettings)
    func groupHome(_ name: String, ownsCommand: Bool) throws -> URL {
        let home = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("settings.json"), withDestinationURL: groupSettings)
        if ownsCommand {
            let file = IntegrationsStore.switchCommandFile(inHome: home)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try userCommand.write(to: file, atomically: true, encoding: .utf8)
        }
        return home
    }
    let ownerHome = try groupHome("group-owner", ownsCommand: true)
    let neighbourHome = try groupHome("group-neighbour", ownsCommand: false)
    let group = IntegrationsStore.syncSwitchCommand(inHomes: [neighbourHome, ownerHome],
                                                    hookCommand: hookCommand)
    check("one home's own command file keeps the hook out of the settings they share",
          group.settings == nil && group.error != nil
              && !IntegrationsStore.settingsCarrySwitchHook(groupSettings))
    // The other half of the answer, and the deliberate one: the clean home still gets a working
    // /tally-switch, just the model-turn one. Withholding it would punish it for its neighbour.
    check("…while the clean home still gets its command file",
          group.commands == [IntegrationsStore.switchCommandFile(inHome: neighbourHome)])
    check("…and the owner's file is untouched",
          try String(contentsOf: IntegrationsStore.switchCommandFile(inHome: ownerHome),
                     encoding: .utf8) == userCommand)
    check("…and their shared settings file is untouched",
          ((try? JSONSerialization.jsonObject(with: Data(contentsOf: groupSettings)))
            as? [String: Any])?.count == 1)
    // With nobody's own command in it, the same group installs once for all of them.
    let cleanGroup = IntegrationsStore.syncSwitchCommand(
        inHomes: [try groupHome("group-a", ownsCommand: false),
                  try groupHome("group-b", ownsCommand: false)],
        hookCommand: hookCommand)
    check("a group with no foreign command gets one registration for all of it",
          cleanGroup.error == nil && cleanGroup.commands.count == 2
              && IntegrationsStore.settingsCarrySwitchHook(groupSettings))
    check("…written to the shared file, with the link still a link",
          (try? FileManager.default.destinationOfSymbolicLink(
            atPath: tmp.appendingPathComponent("group-a/settings.json").path))
              == groupSettings.path)

    // MARK: the answer changing under a registration that is already there.
    //
    // A home Tally manages today can stop being one tomorrow: the user writes their own
    // commands/tally-switch.md. The hook we left behind goes on intercepting the very command they
    // just took back, and nothing about a later sync would have noticed - it used to return early.
    let turnedHome = tmp.appendingPathComponent("turned-home")
    let turnedSettings = turnedHome.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: turnedHome, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["model": "opusplan"]).write(to: turnedSettings)
    let whileClean = IntegrationsStore.syncSwitchCommand(inHomes: [turnedHome],
                                                         hookCommand: hookCommand)
    check("the hook goes in while the home is clean",
          whileClean.settings == turnedSettings
              && IntegrationsStore.settingsCarrySwitchHook(turnedSettings))
    try userCommand.write(to: IntegrationsStore.switchCommandFile(inHome: turnedHome),
                          atomically: true, encoding: .utf8)
    let afterTurn = IntegrationsStore.syncSwitchCommand(inHomes: [turnedHome],
                                                        hookCommand: hookCommand)
    check("the user taking the command file back takes the hook out with it",
          afterTurn.changed && afterTurn.settings == nil
              && !IntegrationsStore.settingsCarrySwitchHook(turnedSettings))
    check("…and the stand-down touches nothing else in their settings",
          ((try? JSONSerialization.jsonObject(with: Data(contentsOf: turnedSettings)))
            as? [String: Any])?.count == 1)
    check("…and their command file is what they wrote",
          try String(contentsOf: IntegrationsStore.switchCommandFile(inHome: turnedHome),
                     encoding: .utf8) == userCommand)
    check("…and a third pass has nothing left to do",
          IntegrationsStore.syncSwitchCommand(inHomes: [turnedHome],
                                              hookCommand: hookCommand).changed == false)

    // A stand-down that cannot be written keeps the file TRACKED. Forgetting it would strand the
    // hook: still interposed, and no longer in the manifest an uninstall reads.
    let stuckHome = tmp.appendingPathComponent("stuck-home")
    let stuckSettings = stuckHome.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: stuckHome, withIntermediateDirectories: true)
    _ = IntegrationsStore.syncSwitchCommand(inHomes: [stuckHome], hookCommand: hookCommand)
    try userCommand.write(to: IntegrationsStore.switchCommandFile(inHome: stuckHome),
                          atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: stuckSettings.path)
    let stuck = IntegrationsStore.syncSwitchCommand(inHomes: [stuckHome], hookCommand: hookCommand)
    try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: stuckSettings.path)
    check("a stand-down that cannot be written keeps the settings file tracked",
          stuck.settings == stuckSettings && stuck.error != nil)
    check("…because the hook really is still in there",
          IntegrationsStore.settingsCarrySwitchHook(stuckSettings))

    // MARK: the population, which is not the deduplicated skill list.
    //
    // `claudeSkillFiles()` deduplicates by physical SKILL.md, so home B - whose skills tree is
    // symlinked at A's - never appears in it. B's commands folder is its own, though, and the
    // `/tally-switch` in it is B's. Asking the ownership question about A alone answers it for
    // both, and the hook lands in the settings they share.
    let popA = tmp.appendingPathComponent("pop-a")
    let popB = tmp.appendingPathComponent("pop-b")
    let popSkill = IntegrationsStore.claudeSkillFile(inHome: popA)
    let popSettings = popA.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: popSkill.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try currentSkill.write(to: popSkill, atomically: true, encoding: .utf8)
    try JSONSerialization.data(withJSONObject: ["model": "opusplan"]).write(to: popSettings)
    let popBSkill = IntegrationsStore.claudeSkillFile(inHome: popB)
    try FileManager.default.createDirectory(at: popBSkill.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: popBSkill, withDestinationURL: popSkill)
    try FileManager.default.createSymbolicLink(at: popB.appendingPathComponent("settings.json"),
                                               withDestinationURL: popSettings)
    let popBCommand = IntegrationsStore.switchCommandFile(inHome: popB)
    try FileManager.default.createDirectory(at: popBCommand.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try userCommand.write(to: popBCommand, atomically: true, encoding: .utf8)
    // What a deduplicated skill list looks like: A only, because B's SKILL.md is the same file.
    let deduplicated = [popSkill]
    check("the home the dedup dropped is found through the population",
          IntegrationsStore.homesCarrying(deduplicated, population: [popA, popB]).map(\.path)
              == [popA.path, popB.path])
    check("…and without it, the group is one home short",
          IntegrationsStore.homesCarrying(deduplicated, population: [popA]).map(\.path)
              == [popA.path])
    let popGroup = IntegrationsStore.syncSwitchCommand(
        inHomes: IntegrationsStore.homesCarrying(deduplicated, population: [popA, popB]),
        hookCommand: hookCommand)
    check("so the dropped home's own command file keeps the hook out of the shared settings",
          popGroup.settings == nil && !IntegrationsStore.settingsCarrySwitchHook(popSettings))
    check("…while its neighbour still gets a command file",
          popGroup.commands == [IntegrationsStore.switchCommandFile(inHome: popA)])
    check("…and the dropped home's own file is untouched",
          try String(contentsOf: popBCommand, encoding: .utf8) == userCommand)
    // An account that logged out since install is not in the population any more, and its SKILL.md
    // is still on disk: named files are kept whatever the population says.
    check("a home named by the files survives a population that has forgotten it",
          IntegrationsStore.homesCarrying(deduplicated, population: []).map(\.path) == [popA.path])
}
