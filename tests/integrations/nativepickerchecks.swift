import Foundation

// The native picker registration: the pair of hooks that replaces the single command hook, the MCP
// server they call, and the gate that decides whether either is written at all.
//
// THE FRAGILE PART IS OWNERSHIP, and it is why this file exists. Every existing guarantee about
// settings.json was expressed through one question - "does this hook's command end in our
// subcommand" - and half of a registration now has no command in it at all. So the ownership test,
// the collapse that keeps exactly one registration, the uninstall and the self-heal all had to
// change together, and each of them is a way to silently eat a user's own hook or to leave ours
// answering a command twice.

@MainActor
func runNativePickerChecks(tmp: URL, skill currentSkill: String) throws {
    let binary = URL(fileURLWithPath: "/Applications/Tally.app/Contents/Helpers/tally")
    let command = IntegrationsStore.modelPromptCommand
    let pair = IntegrationsStore.promptHookEntries(binary, command: command, nativePicker: true)
    let plain = IntegrationsStore.promptHookEntries(binary, command: command, nativePicker: false)

    // MARK: - The two shapes

    check("the native registration is a tool call and a backstop, in that order",
          pair.count == 2 && pair[0]["type"] as? String == "mcp_tool"
              && pair[1]["type"] as? String == "command")
    check("the tool hook names Tally's server and this command's tool",
          pair[0]["server"] as? String == "tally" && pair[0]["tool"] as? String == "pick_model")
    // The literals, verbatim: an unrecognised variable is substituted with the EMPTY STRING, which
    // is indistinguishable from a command typed bare, so a misspelling here would open the picker
    // on every invocation with nothing anywhere to say why.
    check("…and passes through every variable, spelled the way Claude Code substitutes them",
          pair[0]["input"] as? [String: String] == ["command_name": "${command_name}",
                                                    "command_args": "${command_args}",
                                                    "session_id": "${session_id}",
                                                    "cwd": "${cwd}",
                                                    "transcript_path": "${transcript_path}"])
    // A dialog waits on a PERSON. The default would cancel the picker while they were reading it.
    check("…and is given a person's patience rather than a program's",
          pair[0]["timeout"] as? Int == 300)
    check("the backstop runs this command's own subcommand under the flag",
          pair[1]["command"] as? String
              == "\"\(binary.path)\" hook-model \(promptHookBackstopFlag)")
    // The gate's whole promise: a machine that cannot use the pair keeps exactly what it has today.
    check("without the picker it is the single plain command, byte for byte what shipped before",
          plain.count == 1
              && plain[0]["command"] as? String
                  == IntegrationsStore.promptHookCommand(binary, command: command))

    // MARK: - Whose hook is whose

    /// Every hook a settings document holds on the prompt event, entry order preserved.
    func hooks(in settings: [String: Any]) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[IntegrationsStore.promptHookEvent]
            as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }
    /// Registering into an empty document is the cheapest way to ask what this code claims as ours:
    /// what it leaves behind is exactly what it recognises.
    func hooksAfterRegistering(_ existing: [[String: Any]],
                               placing: [[String: Any]]) -> [[String: Any]] {
        let settings: [String: Any] = existing.isEmpty ? [:] : [
            "hooks": [IntegrationsStore.promptHookEvent: [
                ["matcher": command.name, "hooks": existing],
            ]],
        ]
        return hooks(in: IntegrationsStore.settingsRegisteringPromptHook(settings, hooks: placing,
                                                                        hook: command) ?? settings)
    }
    /// A JSON document read back off disk, or an empty one when it cannot be.
    func stateDocument(_ file: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return parsed
    }

    // Somebody else's MCP server may perfectly well offer a tool called `pick_model`, and somebody
    // else's script may perfectly well be called `my-hook-model-thing`. Neither is ours to rewrite.
    let foreign: [[String: Any]] = [
        ["type": "mcp_tool", "server": "someone-else", "tool": "pick_model"],
        ["type": "mcp_tool", "server": "tally", "tool": "pick_lunch"],
        ["type": "command", "command": "/usr/local/bin/my-hook-model-wrapper"],
    ]
    let afterForeign = hooksAfterRegistering(foreign, placing: pair)
    check("a tool hook on another server is not ours",
          afterForeign.contains { $0["server"] as? String == "someone-else" })
    check("…nor is one of ours pointing at a tool this command does not use",
          afterForeign.contains { $0["tool"] as? String == "pick_lunch" })
    check("…nor is a command that merely contains our subcommand in its name",
          afterForeign.contains { $0["command"] as? String == "/usr/local/bin/my-hook-model-wrapper" })
    check("…and ours is added beside all three rather than instead of them",
          afterForeign.count == foreign.count + pair.count)

    // THE UPGRADE PATH: an install made by the previous version holds the single plain command. The
    // pair lands WHERE THAT HOOK WAS, in the entry the user already had, rather than as a second
    // entry beside it - and a hook of theirs in the same entry keeps its place.
    let neighbour: [String: Any] = ["type": "command", "command": "/usr/local/bin/my-own-audit"]
    let upgraded = hooksAfterRegistering(plain + [neighbour], placing: pair)
    check("an install of the previous shape is upgraded in place",
          upgraded.count == 3 && upgraded[0]["type"] as? String == "mcp_tool"
              && upgraded[1]["command"] as? String == pair[1]["command"] as? String)
    check("…leaving the hook the user put beside it exactly where it was",
          upgraded[2]["command"] as? String == "/usr/local/bin/my-own-audit")
    check("…and the same registration applied again changes nothing",
          IntegrationsStore.settingsRegisteringPromptHook(
            ["hooks": [IntegrationsStore.promptHookEvent:
                        [["matcher": command.name, "hooks": pair]]]],
            hooks: pair, hook: command) == nil)
    // The reverse, which a Claude Code downgrade produces: the pair goes back to the one command.
    check("and a machine that loses the picker is put back to the plain command",
          hooksAfterRegistering(pair, placing: plain).count == 1)

    // Duplicates across the two shapes: the collapse keeps ONE set, not one of each.
    let duplicated = hooksAfterRegistering(pair + plain + pair, placing: pair)
    check("every copy of ours collapses to exactly one registration",
          IntegrationsStore.promptHooksMatch(duplicated, pair))

    // MARK: - Taking it back out

    let installed: [String: Any] = ["hooks": [IntegrationsStore.promptHookEvent: [
        ["matcher": command.name, "hooks": pair + [neighbour]],
    ]]]
    let leftovers = hooks(in: IntegrationsStore.settingsWithoutPromptHook(installed,
                                                                          hook: command) ?? [:])
    check("an uninstall takes BOTH halves out, not only the one with a command in it",
          leftovers.count == 1
              && leftovers[0]["command"] as? String == "/usr/local/bin/my-own-audit")

    // MARK: - The server those hooks call

    let state = tmp.appendingPathComponent("native-state/.claude.json")
    check("a fresh registration creates the file a new account has not written yet",
          try IntegrationsStore.upsertMCPServer(in: state, binary: binary)
              && IntegrationsStore.mcpServerIsRegistered(state, binary: binary))
    check("…and re-registering the same entry changes nothing",
          try IntegrationsStore.upsertMCPServer(in: state, binary: binary) == false)
    // The stale-path failure, which is invisible to a presence check: a registration naming a
    // bundle that has moved spawns nothing, so every prompt falls to the backstop while the file
    // reads as installed.
    let moved = URL(fileURLWithPath: "/Users/someone/Downloads/Tally.app/Contents/Helpers/tally")
    check("a registration naming another bundle is not this app's",
          !IntegrationsStore.mcpServerIsRegistered(state, binary: moved))
    check("…which the sync repairs by rewriting it",
          try IntegrationsStore.upsertMCPServer(in: state, binary: moved)
              && IntegrationsStore.mcpServerIsRegistered(state, binary: moved))

    // Everything in that file which is not ours survives, at both levels: another server beside
    // ours, and the account's own keys around them.
    var document = stateDocument(state)
    document["oauthAccount"] = ["emailAddress": "someone@example.com"]
    var servers = document["mcpServers"] as? [String: Any] ?? [:]
    servers["theirs"] = ["command": "/usr/local/bin/their-server"]
    document["mcpServers"] = servers
    try JSONSerialization.data(withJSONObject: document).write(to: state)
    check("removal takes ours and leaves theirs", try IntegrationsStore.removeMCPServer(in: state))
    let afterRemoval = stateDocument(state)
    check("…including the account's own identity, which this code has no business touching",
          (afterRemoval["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
              == "someone@example.com")
    check("…and their server is still registered",
          (afterRemoval["mcpServers"] as? [String: Any])?["theirs"] != nil)
    check("removing what is not there changes nothing",
          try IntegrationsStore.removeMCPServer(in: state) == false)
    // The block itself goes when ours was the only thing in it, exactly as the hook removal empties
    // its containers.
    let solo = tmp.appendingPathComponent("native-solo/.claude.json")
    _ = try IntegrationsStore.upsertMCPServer(in: solo, binary: binary)
    _ = try IntegrationsStore.removeMCPServer(in: solo)
    check("an mcpServers block left holding nothing goes with it",
          stateDocument(solo)["mcpServers"] == nil)

    // The refusal, which matters more here than in settings.json: this document is another
    // program's, it is large, and it carries the account's identity. Bytes that exist and do not
    // parse are left exactly as they are rather than replaced by a document holding only our key.
    let broken = tmp.appendingPathComponent("native-broken/.claude.json")
    try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try "{ not json".write(to: broken, atomically: true, encoding: .utf8)
    var refused = false
    do { _ = try IntegrationsStore.upsertMCPServer(in: broken, binary: binary) } catch {
        refused = true
    }
    let brokenAfter = try String(contentsOf: broken, encoding: .utf8)
    check("a state file that does not parse is refused, not rewritten",
          refused && brokenAfter == "{ not json")
    // And a shape inside it we cannot read is the same answer, decided without touching the disk.
    check("an mcpServers value of an unexpected shape is left alone",
          IntegrationsStore.stateRegisteringMCPServer(["mcpServers": "yes"],
                                                      entry: ["a": "b"]) == nil)

    // MARK: - The gate in front of all of it

    let fixtures = tmp.appendingPathComponent("native-binaries")
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    let modern = fixtures.appendingPathComponent("claude-modern")
    let ancient = fixtures.appendingPathComponent("claude-ancient")
    try Data("...UserPromptExpansion...mcp_tool...".utf8).write(to: modern)
    try Data("...UserPromptExpansion...command...".utf8).write(to: ancient)
    check("a Claude Code carrying the hook type in its binary can use the pickers",
          IntegrationsStore.claudeSupportsMCPHooks(binary: modern.path))
    check("…and one that does not, cannot",
          !IntegrationsStore.claudeSupportsMCPHooks(binary: ancient.path))
    check("a Claude Code that cannot be found answers no, which changes nothing on that machine",
          !IntegrationsStore.claudeSupportsMCPHooks(binary: nil)
              && !IntegrationsStore.claudeSupportsMCPHooks(
                binary: fixtures.appendingPathComponent("absent").path))
    // The token searched for is the token WRITTEN, which is what makes the search mean anything: a
    // gate looking for one spelling while the registration used another would be a coin toss.
    check("the token the gate looks for is the hook type the registration writes",
          pair[0]["type"] as? String == IntegrationsStore.mcpHookTypeToken)

    // MARK: - Healing the pair, and the server beside it

    let home = tmp.appendingPathComponent("native-home")
    let skillFile = IntegrationsStore.claudeSkillFile(inHome: home)
    try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try currentSkill.write(to: skillFile, atomically: true, encoding: .utf8)
    @discardableResult
    func install(_ nativePicker: Bool) -> Bool {
        var changed = false
        for one in IntegrationsStore.promptCommands {
            let result = IntegrationsStore.syncPromptCommand(
                inHomes: [home],
                hooks: IntegrationsStore.promptHookEntries(binary, command: one,
                                                           nativePicker: nativePicker),
                command: one)
            changed = result.changed || changed
        }
        let servers = IntegrationsStore.syncMCPServer(inHomes: [home], binary: binary,
                                                      nativePicker: nativePicker)
        return servers.changed || changed
    }
    func needsHealing(_ nativePicker: Bool) -> Bool {
        IntegrationsStore.hooksNeedHealing(skillFiles: [skillFile], population: [home],
                                           binary: binary, nativePicker: nativePicker)
    }
    install(true)
    check("a freshly synced home carries the pair and needs no healing", !needsHealing(true))
    check("…and the server the hooks call is registered in its own file",
          IntegrationsStore.mcpServerIsRegistered(
            claudeStateFile(forConfigDir: home), binary: binary))
    check("…which is `.claude.json`, not the settings file the hooks live in",
          claudeStateFile(forConfigDir: home).lastPathComponent == ".claude.json")

    // THE FAILURE A COMMAND-LINE COMPARISON COULD NOT SEE: the tool hook goes and the backstop
    // stays. Every command line in the file is correct, and the picker is dead.
    let settingsFile = home.appendingPathComponent("settings.json")
    var damaged = stateDocument(settingsFile)
    var block = damaged["hooks"] as? [String: Any] ?? [:]
    let entries = block[IntegrationsStore.promptHookEvent] as? [[String: Any]] ?? []
    block[IntegrationsStore.promptHookEvent] = entries.map { entry -> [String: Any] in
        var trimmed = entry
        trimmed["hooks"] = (entry["hooks"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String != "mcp_tool" }
        return trimmed
    }
    damaged["hooks"] = block
    try JSONSerialization.data(withJSONObject: damaged).write(to: settingsFile)
    check("a registration missing its tool half is damage, though every command in it is right",
          needsHealing(true))
    check("…which the repair puts back", install(true) && !needsHealing(true))

    // THE OTHER HALF, in the other file: the hooks are all present and correct, and the server they
    // call is gone. Invisible from settings.json, and the symptom is one account showing a picker
    // while another answers as text.
    try IntegrationsStore.removeMCPServer(in: claudeStateFile(forConfigDir: home))
    check("a missing server is damage even with every hook in place", needsHealing(true))
    check("…which the repair puts back too", install(true) && !needsHealing(true))

    // The gate answering NO is a withdrawal rather than a skip: a downgrade leaves a registration
    // that starts a server for hooks nobody writes in the tool shape any more.
    check("with the picker gone the pair itself is damage", needsHealing(false))
    install(false)
    check("…and the repair writes the plain command back and withdraws the server",
          !needsHealing(false)
              && !IntegrationsStore.mcpServerIsRegistered(claudeStateFile(forConfigDir: home),
                                                          binary: binary))
    check("…and settles, which is what ends the write-event-write cycle", !install(false))
}
