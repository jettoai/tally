import Foundation

// `/tally-switch` and the prompt hook behind it: the command file's prose, the file surgery either
// half needs, and the settings.json merge. Split from main.swift for file size.
//
// The hook is what makes the feature worth having (a named account moves without waking a model),
// but the risk lives in the other half: the merge writes into settings.json, which is the user's
// entire harness configuration and, on shared setups, one physical file behind several accounts.
// So most of what is asserted below is what comes out UNCHANGED.
@MainActor
func runSwitchCommandChecks(tmp: URL, skill currentSkill: String) throws {
    // MARK: /tally-switch - the command file, which is the FALLBACK half of the feature.
    //
    // The hook answers a named account without waking a model at all; this file is what runs when
    // it did not (not registered, shell execution off, or no account named). So it has to stand
    // alone, and it has to describe the hook rather than assume it.
    let command = IntegrationsStore.switchCommandMarkdown()
    let commandProse = command.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    check("command carries the version marker",
          command.contains(IntegrationsStore.switchCommandMarker))
    check("the command marker moves with the skill's version, since they ship together",
          IntegrationsStore.switchCommandMarker == "tally-command v\(IntegrationsStore.skillVersion)")
    check("command carries no em dash", !command.contains("\u{2014}"))
    check("command declares its argument hint and the tools it needs",
          command.contains("argument-hint: [account name]")
              && command.contains("allowed-tools: Bash(tally:*), AskUserQuestion"))
    // Spelled as it must be RUN. `$ARGUMENTS` is the whole rest of the typed line, quoted because
    // account labels contain spaces ("Claude 4").
    check("command queues the move with what the user typed",
          command.contains("tally switch \"$ARGUMENTS\""))
    check("command reads the fleet before offering a choice", command.contains("tally status"))
    check("command asks with the picker rather than choosing",
          commandProse.contains("Ask with AskUserQuestion, one option per Claude account")
              && commandProse.contains("Do not pick for the user"))
    check("…with headroom on every option and the best one recommended first",
          commandProse.contains("its three remaining windows as the description")
              && commandProse.contains("most headroom first and mark it Recommended"))
    check("command explains the free path it is standing in for",
          commandProse.contains("without waking a model at all"))
    check("command relays the timing, which is the thing a user gets wrong",
          commandProse.contains("The move happens when this turn ENDS"))
    check("…and that a non-zero exit means nothing was queued",
          commandProse.contains("A non-zero exit means nothing was queued"))

    // Command-file surgery: the same rules the skill file gets, because it lands in the same
    // user-owned tree. A file that is not ours is never touched, in either direction.
    let commandHome = tmp.appendingPathComponent("home-a")
    let commandFile = IntegrationsStore.switchCommandFile(inHome: commandHome)
    check("the command file lands where Claude Code looks for it",
          commandFile.path == commandHome.appendingPathComponent("commands/tally-switch.md").path)
    check("the home is read back off a skill path, which is what pairs the two",
          IntegrationsStore.claudeHome(
            ofSkillFile: commandHome.appendingPathComponent("skills/tally/SKILL.md")).path
              == commandHome.path)
    check("fresh command install writes the file",
          try IntegrationsStore.upsertSwitchCommand(in: commandFile) == true
              && FileManager.default.fileExists(atPath: commandFile.path))
    check("re-installing the command is idempotent",
          try IntegrationsStore.upsertSwitchCommand(in: commandFile) == false)
    let staleCommand = command.replacingOccurrences(
        of: IntegrationsStore.switchCommandMarker, with: "tally-command v0")
    try staleCommand.write(to: commandFile, atomically: true, encoding: .utf8)
    check("an older command file is upgraded in place",
          try IntegrationsStore.upsertSwitchCommand(in: commandFile) == true
              && String(contentsOf: commandFile, encoding: .utf8) == command)
    try IntegrationsStore.removeSwitchCommand(in: commandFile)
    check("remove deletes the command and its emptied folder",
          !FileManager.default.fileExists(atPath: commandFile.path)
              && !FileManager.default.fileExists(
                atPath: commandFile.deletingLastPathComponent().path))

    let userCommand = "---\ndescription: my own switcher\n---\nmine"
    try FileManager.default.createDirectory(at: commandFile.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try userCommand.write(to: commandFile, atomically: true, encoding: .utf8)
    var refusedCommand = false
    do { _ = try IntegrationsStore.upsertSwitchCommand(in: commandFile) } catch {
        refusedCommand = true
    }
    let afterCommandRefusal = try String(contentsOf: commandFile, encoding: .utf8)
    check("a user's own tally-switch.md is never clobbered",
          refusedCommand && afterCommandRefusal == userCommand)
    try IntegrationsStore.removeSwitchCommand(in: commandFile)
    check("remove leaves a foreign command untouched",
          try String(contentsOf: commandFile, encoding: .utf8) == userCommand)

    // MARK: the hook registration - one entry in a file that is the user's whole harness.
    //
    // settings.json holds their model, permissions, other hooks, everything. The merge below is
    // the only part of Tally that writes into it wholesale, so what is asserted here is mostly the
    // NEGATIVE: what comes out unchanged.
    let helper = URL(fileURLWithPath: "/Applications/Tally.app/Contents/Helpers/tally")
    let hookCommand = IntegrationsStore.switchHookCommand(helper)
    check("the registration quotes the binary path and names the subcommand",
          hookCommand == "\"/Applications/Tally.app/Contents/Helpers/tally\" hook-switch")
    func expansion(_ settings: [String: Any]) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?["UserPromptExpansion"] as? [[String: Any]]) ?? []
    }
    func commands(_ settings: [String: Any]) -> [String] {
        expansion(settings).flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }
    let registered = IntegrationsStore.settingsRegisteringSwitchHook([:], command: hookCommand)
    check("an empty settings file gets exactly one entry, matched on the command name",
          registered.map(expansion)?.count == 1
              && expansion(registered ?? [:]).first?["matcher"] as? String == "tally-switch")
    check("…running our subcommand", commands(registered ?? [:]) == [hookCommand])
    check("re-registering the same thing changes nothing",
          IntegrationsStore.settingsRegisteringSwitchHook(registered ?? [:],
                                                          command: hookCommand) == nil)

    // The conservative case, and the reason this is a merge rather than a write: a real harness.
    let harness: [String: Any] = [
        "model": "opusplan",
        "permissions": ["allow": ["Bash(git:*)"]],
        "hooks": [
            "PreToolUse": [["matcher": "Bash",
                            "hooks": [["type": "command", "command": "guard.sh"]]]],
            "UserPromptExpansion": [["matcher": "their-command",
                                     "hooks": [["type": "command", "command": "theirs.sh"]]]],
        ],
    ]
    guard let merged = IntegrationsStore.settingsRegisteringSwitchHook(harness,
                                                                      command: hookCommand)
    else { fatalError("registering into a populated harness must produce a document") }
    check("every unrelated key survives the merge",
          merged["model"] as? String == "opusplan"
              && ((merged["permissions"] as? [String: Any])?["allow"] as? [String]) == ["Bash(git:*)"])
    check("other hook events survive it",
          ((merged["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.count == 1)
    check("another slash command's own expansion hook survives it, and stays first",
          expansion(merged).count == 2
              && expansion(merged).first?["matcher"] as? String == "their-command")
    check("…and ours is the one that was added", commands(merged).contains(hookCommand))

    // The app moved (dragged elsewhere, or replaced by an update): the entry is ours, its path is
    // stale, and it is REWRITTEN in place rather than duplicated - two entries would run the hook
    // twice, one of them pointing at a binary that is gone.
    let moved = IntegrationsStore.switchHookCommand(
        URL(fileURLWithPath: "/Users/x/Applications/Tally.app/Contents/Helpers/tally"))
    guard let repaired = IntegrationsStore.settingsRegisteringSwitchHook(merged, command: moved)
    else { fatalError("a stale binary path must be rewritten") }
    check("a moved app rewrites our entry instead of adding a second one",
          expansion(repaired).count == 2 && commands(repaired) == ["theirs.sh", moved])

    // Removal takes ours out and nothing else, then unwinds the keys it created.
    guard let stripped = IntegrationsStore.settingsWithoutSwitchHook(repaired) else {
        fatalError("removing a registered hook must produce a document")
    }
    check("removal takes ours and leaves theirs", commands(stripped) == ["theirs.sh"])
    check("…and does not touch the rest of the file", stripped["model"] as? String == "opusplan")
    check("removing what is not there changes nothing",
          IntegrationsStore.settingsWithoutSwitchHook(stripped) == nil)
    let onlyOurs = IntegrationsStore.settingsRegisteringSwitchHook([:], command: hookCommand) ?? [:]
    let emptied = IntegrationsStore.settingsWithoutSwitchHook(onlyOurs)
    check("uninstalling returns the file to the shape it had, keys and all",
          emptied != nil && emptied?.isEmpty == true)
    let withOther = IntegrationsStore.settingsRegisteringSwitchHook(
        ["hooks": ["PreToolUse": [["matcher": "Bash",
                                   "hooks": [["type": "command", "command": "guard.sh"]]]]]],
        command: hookCommand) ?? [:]
    let keptOther = IntegrationsStore.settingsWithoutSwitchHook(withOther)
    check("…but a hooks block with other events in it stays",
          ((keptOther?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.count == 1
              && (keptOther?["hooks"] as? [String: Any])?["UserPromptExpansion"] == nil)

    // A document whose SHAPE is unreadable is not merged into: the only safe edit to something we
    // cannot parse is none. (A user could have `hooks` as a string, or a future Claude Code could
    // change the event's shape entirely.)
    check("a hooks value of an unexpected shape is left alone",
          IntegrationsStore.settingsRegisteringSwitchHook(["hooks": "yes"],
                                                          command: hookCommand) == nil)
    check("an event list of an unexpected shape is too",
          IntegrationsStore.settingsRegisteringSwitchHook(
            ["hooks": ["UserPromptExpansion": "yes"]], command: hookCommand) == nil)

    // MARK: the same merge through the file, where the damage would be done.
    let settingsFile = tmp.appendingPathComponent("hook-home/settings.json")
    check("registering into a home with no settings.json creates one",
          try IntegrationsStore.upsertSwitchHook(in: settingsFile, command: hookCommand) == true
              && IntegrationsStore.settingsCarrySwitchHook(settingsFile))
    check("registering again writes nothing",
          try IntegrationsStore.upsertSwitchHook(in: settingsFile, command: hookCommand) == false)
    check("removing it takes the file back",
          try IntegrationsStore.removeSwitchHook(in: settingsFile) == true
              && !IntegrationsStore.settingsCarrySwitchHook(settingsFile))
    check("removing it twice writes nothing",
          try IntegrationsStore.removeSwitchHook(in: settingsFile) == false)

    // The failure that would cost a user their configuration: a settings.json that does not parse
    // (a truncated write, a hand edit gone wrong). Reading it as an empty document and writing our
    // one entry over it is the one thing that must never happen, so it is refused and reported.
    // Truncated rather than trailing-comma on purpose: Foundation's parser accepts a trailing comma
    // (verified 2026-08-06), so that fixture would have tested nothing.
    let brokenSettings = tmp.appendingPathComponent("broken-home/settings.json")
    let brokenText = "{\n  \"model\": \"opusplan\",\n  \"hooks\": {\n"   // truncated: not JSON
    try FileManager.default.createDirectory(at: brokenSettings.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try brokenText.write(to: brokenSettings, atomically: true, encoding: .utf8)
    var refusedBroken = false
    do { _ = try IntegrationsStore.upsertSwitchHook(in: brokenSettings, command: hookCommand) }
    catch { refusedBroken = true }
    var afterRefusedWrite = try String(contentsOf: brokenSettings, encoding: .utf8)
    check("an unparseable settings.json is refused, not rewritten",
          refusedBroken && afterRefusedWrite == brokenText)
    var refusedBrokenRemoval = false
    do { _ = try IntegrationsStore.removeSwitchHook(in: brokenSettings) } catch {
        refusedBrokenRemoval = true
    }
    afterRefusedWrite = try String(contentsOf: brokenSettings, encoding: .utf8)
    check("…and uninstalling will not eat it either",
          refusedBrokenRemoval && afterRefusedWrite == brokenText)
    check("a settings.json with no hook of ours reads as not carrying one",
          !IntegrationsStore.settingsCarrySwitchHook(brokenSettings))

    // MARK: detection - an install from an older app has the skill and neither of these.
    let pairHome = tmp.appendingPathComponent("pair-home")
    let pairSkill = pairHome.appendingPathComponent("skills/tally/SKILL.md")
    try FileManager.default.createDirectory(at: pairSkill.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try currentSkill.write(to: pairSkill, atomically: true, encoding: .utf8)
    check("a skill with no command file beside it is not current",
          !IntegrationsStore.switchCommandIsCurrent(forSkillFiles: [pairSkill]))
    _ = try IntegrationsStore.upsertSwitchCommand(
        in: IntegrationsStore.switchCommandFile(inHome: pairHome))
    check("…nor with the command but no hook registered",
          !IntegrationsStore.switchCommandIsCurrent(forSkillFiles: [pairSkill]))
    _ = try IntegrationsStore.upsertSwitchHook(
        in: pairHome.appendingPathComponent("settings.json"), command: hookCommand)
    check("with both, the install is current",
          IntegrationsStore.switchCommandIsCurrent(forSkillFiles: [pairSkill]))
    try staleCommand.write(to: IntegrationsStore.switchCommandFile(inHome: pairHome),
                           atomically: true, encoding: .utf8)
    check("an older command file drops it back out of current",
          !IntegrationsStore.switchCommandIsCurrent(forSkillFiles: [pairSkill]))

    // MARK: the shared settings.json - a symlink, which is how this machine is actually set up.
    //
    // `tally add` links every extra account's config at the main account's, settings.json included,
    // so one harness serves all of them. An atomic write replaces the path it is given: writing to
    // the LINK would replace the link with a regular file and sever that sharing silently, leaving
    // the other accounts on a copy that no longer follows the user's edits.
    let sharedHome = tmp.appendingPathComponent("shared-real")
    let sharedSettings = sharedHome.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["model": "opusplan"]).write(to: sharedSettings)
    let linkedHome = tmp.appendingPathComponent("shared-link")
    try FileManager.default.createDirectory(at: linkedHome, withIntermediateDirectories: true)
    let linkedSettings = linkedHome.appendingPathComponent("settings.json")
    try FileManager.default.createSymbolicLink(at: linkedSettings,
                                               withDestinationURL: sharedSettings)
    check("registering through a symlink writes the file it points at",
          try IntegrationsStore.upsertSwitchHook(in: linkedSettings, command: hookCommand) == true
              && IntegrationsStore.settingsCarrySwitchHook(sharedSettings))
    check("…and leaves the link a link, which is the sharing itself",
          (try? FileManager.default.destinationOfSymbolicLink(atPath: linkedSettings.path))
              == sharedSettings.path)
    let sharedAfter = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sharedSettings)))
        as? [String: Any] ?? [:]
    check("…with the settings the file already held", sharedAfter["model"] as? String == "opusplan")
    // The second account pointing at the same file: one physical document, so it is already done.
    check("a second home sharing that file writes nothing",
          try IntegrationsStore.upsertSwitchHook(in: sharedSettings, command: hookCommand) == false)
    check("uninstalling through the link takes the hook out, still without severing it",
          try IntegrationsStore.removeSwitchHook(in: linkedSettings) == true
              && !IntegrationsStore.settingsCarrySwitchHook(sharedSettings)
              && (try? FileManager.default.destinationOfSymbolicLink(atPath: linkedSettings.path))
                  == sharedSettings.path)

    // Present and unreadable is not absent. This arrives through a different door than the parse
    // failure above and costs the same thing: a file rewritten without its contents ever being seen.
    let lockedSettings = tmp.appendingPathComponent("locked-home/settings.json")
    let lockedText = "{\n  \"model\": \"opusplan\"\n}\n"
    try FileManager.default.createDirectory(at: lockedSettings.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try lockedText.write(to: lockedSettings, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedSettings.path)
    var refusedLocked = false
    do { _ = try IntegrationsStore.upsertSwitchHook(in: lockedSettings, command: hookCommand) }
    catch { refusedLocked = true }
    try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: lockedSettings.path)
    let lockedAfter = try String(contentsOf: lockedSettings, encoding: .utf8)
    check("a settings.json that exists but cannot be read is refused, not rewritten",
          refusedLocked && lockedAfter == lockedText)

    // MARK: whose entry is it - the identity that decides what may be rewritten and deleted.
    //
    // Ownership is the matcher AND the subcommand as its own trailing word. A substring test (what
    // this was) hands a user's own `my-hook-switcher` to Tally: replaced on install, deleted on
    // uninstall, and nothing anywhere says why their hook stopped running.
    let lookalikes: [String: Any] = ["hooks": ["UserPromptExpansion": [
        ["matcher": "my-switcher",
         "hooks": [["type": "command", "command": "/usr/local/bin/my-hook-switcher"]]],
        ["matcher": "tally-switch",
         "hooks": [["type": "command", "command": "/usr/local/bin/their-own-wrapper.sh"]]],
    ]]]
    let lookalikeFile = tmp.appendingPathComponent("lookalike-home/settings.json")
    try FileManager.default.createDirectory(at: lookalikeFile.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: lookalikes).write(to: lookalikeFile)
    check("a hook that merely contains our subcommand is not ours",
          !IntegrationsStore.settingsCarrySwitchHook(lookalikeFile))
    guard let beside = IntegrationsStore.settingsRegisteringSwitchHook(lookalikes,
                                                                      command: hookCommand)
    else { fatalError("registering beside look-alike entries must produce a document") }
    check("…so ours is added beside them rather than replacing one",
          commands(beside) == ["/usr/local/bin/my-hook-switcher",
                               "/usr/local/bin/their-own-wrapper.sh", hookCommand])
    check("…and uninstalling deletes only ours",
          IntegrationsStore.settingsWithoutSwitchHook(beside).map(commands)
              == ["/usr/local/bin/my-hook-switcher", "/usr/local/bin/their-own-wrapper.sh"])
    check("a look-alike file on its own has nothing of ours to remove",
          IntegrationsStore.settingsWithoutSwitchHook(lookalikes) == nil)

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
    let refusedHome = IntegrationsStore.syncSwitchCommand(inHome: ownedHome,
                                                          hookCommand: hookCommand)
    check("a foreign command file stops the hook being registered",
          refusedHome.error != nil && refusedHome.settings == nil && refusedHome.command == nil)
    check("…so that home's settings.json is never even created",
          !FileManager.default.fileExists(
            atPath: ownedHome.appendingPathComponent("settings.json").path))
    check("…and their command file is exactly as they left it",
          try String(contentsOf: ownedCommand, encoding: .utf8) == userCommand)

    let cleanHome = tmp.appendingPathComponent("clean-home")
    let installed = IntegrationsStore.syncSwitchCommand(inHome: cleanHome,
                                                        hookCommand: hookCommand)
    check("a clean home gets both halves, and says so",
          installed.error == nil && installed.changed
              && installed.command == IntegrationsStore.switchCommandFile(inHome: cleanHome)
              && installed.settings == cleanHome.appendingPathComponent("settings.json"))
    check("…and a second pass changes nothing",
          IntegrationsStore.syncSwitchCommand(inHome: cleanHome,
                                              hookCommand: hookCommand).changed == false)
}
