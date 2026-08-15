import Foundation

// The three subagent hooks behind the session card's agent count (IntegrationsAgentHook.swift): the
// entries Tally adds to a user's settings.json so Claude Code can say how many agents are working
// under a session, which nothing on the machine can see from outside the process.
//
// Everything asserted here is about the SURGERY rather than the feature: settings.json is the
// user's own file, holding their whole harness, so what has to hold is that nothing but our own
// entries is ever touched - on install, on re-install, and on the way back out. What the roster
// then MEANS is asserted in the supervisor suite (agentrosterchecks.swift), which is where the
// rules live.
@MainActor
func runAgentHookChecks(tmp: URL) throws {
    let settings = tmp.appendingPathComponent("agent-settings.json")

    func document() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
    }
    func commands(_ event: String) -> [String] {
        (((document()["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }
    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: settings)
    }

    // ONE PRESS REGISTERS ALL THREE, because they are one feature: the two edges without the roll
    // call is a count that drifts, and the roster refuses to draw exactly that.
    try IntegrationsStore.upsertAgentHooks(in: settings)
    check("one install registers every event the roster is folded from",
          AgentRosterEvent.events.allSatisfy {
              commands($0) == [IntegrationsStore.agentHookCommand($0)]
          })
    // The event is an ARGUMENT rather than three subcommands, so each registration says which of
    // the three it answers for and the CLI needs one entry point.
    check("…each naming its own event on the command line",
          IntegrationsStore.agentHookCommand("Stop")
              == "/usr/local/bin/tally hook-agents Stop")
    // NO MATCHER, unlike the notification hook beside it: these events have no sub-kinds to filter,
    // and a field that says nothing is one more thing for a later Claude Code to stop honouring.
    check("…under no matcher, since there is nothing to filter",
          (((document()["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) ?? [])
              .allSatisfy { $0["matcher"] == nil })
    check("detection sees the whole set", IntegrationsStore.settingsCarryAgentHooks(settings)
              && IntegrationsStore.settingsCarryCurrentAgentHooks(settings))
    check("re-installing changes nothing",
          try IntegrationsStore.editSettings(settings) {
              IntegrationsStore.settingsRegisteringAgentHook($0, event: "Stop",
                                                             command: IntegrationsStore
                                                                 .agentHookCommand("Stop"))
          } == false)
    // ONE OF THREE IS NOT INSTALLED. The edges without the boundary is precisely the state whose
    // count drifts, so it has to read as broken rather than as installed.
    try IntegrationsStore.editSettings(settings) {
        IntegrationsStore.settingsWithoutAgentHook($0, event: "Stop")
    }
    check("a set with one event missing is not an install",
          !IntegrationsStore.settingsCarryAgentHooks(settings))
    check("…though the file still has something of ours to answer for",
          IntegrationsStore.settingsMayCarryAgentHooks(settings))
    try IntegrationsStore.removeAgentHooks(in: settings)
    check("removing takes every empty container with it", document()["hooks"] == nil)
    check("…and a file with nothing of ours reads as nothing of ours",
          !IntegrationsStore.settingsMayCarryAgentHooks(settings))

    // THE HOOK BESIDE OURS IS THE WHOLE POINT of these events being arrays: Claude Code runs every
    // entry registered under one, so ours stands beside a user's own rather than replacing it - and
    // theirs has to survive both our install and our uninstall, matcher included.
    try write(["hooks": ["SubagentStop": [["matcher": "mine",
                                           "hooks": [["type": "command",
                                                      "command": "~/bin/my-agent-logger"]]]]]])
    try IntegrationsStore.upsertAgentHooks(in: settings)
    check("a user's own hook on the same event keeps running beside ours",
          commands("SubagentStop")
              == ["~/bin/my-agent-logger", IntegrationsStore.agentHookCommand("SubagentStop")])
    check("…in their own entry, under their own matcher",
          (((document()["hooks"] as? [String: Any])?["SubagentStop"] as? [[String: Any]]) ?? [])
              .first?["matcher"] as? String == "mine")
    try IntegrationsStore.removeAgentHooks(in: settings)
    check("…and survives the uninstall untouched", commands("SubagentStop") == ["~/bin/my-agent-logger"])

    // A SUFFIX RATHER THAN A SUBSTRING: a user's own program whose name merely ends the same way is
    // not ours to rewrite or to delete.
    try write(["hooks": ["Stop": [["hooks": [["type": "command",
                                              "command": "/opt/bin/my-hook-agents Stop"]]]]]])
    try IntegrationsStore.upsertAgentHooks(in: settings)
    check("a program whose name merely contains ours is not ours",
          commands("Stop") == ["/opt/bin/my-hook-agents Stop",
                               IntegrationsStore.agentHookCommand("Stop")])
    try IntegrationsStore.removeAgentHooks(in: settings)
    check("…and is left alone on the way out", commands("Stop") == ["/opt/bin/my-hook-agents Stop"])

    // EXACTLY ONE REGISTRATION OF OURS COMES OUT, wherever the file had them: this document is
    // rewritten by things that know nothing about Tally, and Claude Code runs every copy - so a
    // stale duplicate would count one subagent's start twice.
    let stale = "/Volumes/Old/Tally.app/Contents/Resources/tally hook-agents SubagentStart"
    try write(["hooks": ["SubagentStart": [["hooks": [["type": "command", "command": stale]]],
                                           ["hooks": [["type": "command", "command": stale]]]]]])
    try IntegrationsStore.upsertAgentHooks(in: settings)
    check("two copies of ours are merged into one, at the first one's place",
          commands("SubagentStart") == [IntegrationsStore.agentHookCommand("SubagentStart")])

    // A DOCUMENT THIS CANNOT READ IS LEFT EXACTLY AS IT IS, at every level: the only safe edit to a
    // shape we do not understand is none.
    try write(["hooks": ["Stop": "not an array"]])
    check("an event list of an unexpected shape is refused rather than replaced",
          IntegrationsStore.settingsRegisteringAgentHook(document(), event: "Stop",
                                                         command: "x") == nil
              && IntegrationsStore.settingsWithoutAgentHook(document(), event: "Stop") == nil)
    try write(["hooks": "not an object"])
    check("…and so is a hooks block of one",
          IntegrationsStore.settingsRegisteringAgentHook(document(), event: "Stop",
                                                         command: "x") == nil)

    // THE POPULATION AND THE RETRY LIST, on the asymmetry the notification hook argues in full: a
    // home discovered now counts whatever its file says, a path only the manifest remembers counts
    // while it still has something of ours on it.
    let gone = tmp.appendingPathComponent("signed-out-account.json")
    try IntegrationsStore.upsertAgentHooks(in: gone)
    check("a remembered path still carrying our hooks stays in the population",
          IntegrationsStore.agentHookPopulation(discovered: [], remembered: [gone.path])
              == [gone])
    check("…and its state is what the status is judged on",
          IntegrationsStore.detectAgentHooks(discovered: [], remembered: [gone.path])
              == .installed)
    try IntegrationsStore.removeAgentHooks(in: gone)
    check("…while a home that has gone drags nothing down with it",
          IntegrationsStore.agentHookPopulation(discovered: [], remembered: [gone.path]).isEmpty
              && IntegrationsStore.detectAgentHooks(discovered: [], remembered: [gone.path])
                  == .notInstalled)
    // Installed in one account and not the other is the state "Install all" exists to repair, and
    // it has to be visible as something other than "installed".
    let one = tmp.appendingPathComponent("account-one.json")
    let two = tmp.appendingPathComponent("account-two.json")
    try IntegrationsStore.upsertAgentHooks(in: one)
    check("a set present for one account and not the next reads as broken",
          IntegrationsStore.detectAgentHooks(discovered: [one, two], remembered: [])
              == .broken(L("Not installed for every account")))
    // An entry pointing at a command this build no longer answers to is a hook that runs and does
    // nothing, which is the difference between installed and installed CORRECTLY.
    try write(["hooks": Dictionary(uniqueKeysWithValues: AgentRosterEvent.events.map {
        ($0, [["hooks": [["type": "command", "command": "/Volumes/Old/tally hook-agents \($0)"]]]])
    })])
    check("a registration pointing at a binary that moved is present but not current",
          IntegrationsStore.settingsCarryAgentHooks(settings)
              && !IntegrationsStore.settingsCarryCurrentAgentHooks(settings)
              && IntegrationsStore.detectAgentHooks(discovered: [settings], remembered: [])
                  == .broken(L("Older version installed")))
    try IntegrationsStore.upsertAgentHooks(in: settings)
    check("…and one press repairs it in place",
          IntegrationsStore.settingsCarryCurrentAgentHooks(settings)
              && commands("Stop") == [IntegrationsStore.agentHookCommand("Stop")])
}
