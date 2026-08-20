import Foundation

// The two hooks that carry the advisory quota knock into a session's own context
// (IntegrationsKnockHook.swift): the entries Tally adds to a user's settings.json so Claude Code can
// hand the model a sentence the supervisor filed, instead of that sentence having to be typed into a
// terminal the session is busy drawing into.
//
// Everything asserted here is about the SURGERY rather than the feature: settings.json is the user's
// own file, holding their whole harness, so what has to hold is that nothing but our own entries is
// ever touched - on install, on re-install, and on the way back out. What the channel then MEANS is
// asserted in the supervisor suite (knockchannelchecks.swift, knockhookchecks.swift), which is where
// the rules live.
@MainActor
func runKnockHookChecks(tmp: URL) throws {
    let settings = tmp.appendingPathComponent("knock-settings.json")

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

    // THE EVENTS ARE THE CLI's, read out of the one contract both targets compile: this pane writes
    // the marker, the supervisor looks for it before it stops typing, and the CLI answers to it, so
    // a second spelling anywhere fails silently in one of three ways.
    check("the row registers exactly the events the CLI delivers on",
          quotaKnockHookEvents == ["UserPromptSubmit", "PostToolUse"])
    check("…and `Stop` is not one of them, because context given there continues the conversation",
          !quotaKnockHookEvents.contains("Stop"))
    check("…each naming its own event on the command line, through the public path",
          IntegrationsStore.knockHookCommand("PostToolUse")
              == "/usr/local/bin/tally hook-knock PostToolUse")

    // ONE PRESS REGISTERS BOTH, because they are one feature: with only one of them the supervisor
    // refuses the channel outright (`quotaKnockHookRegistered`), so half an install is no install.
    try IntegrationsStore.upsertKnockHooks(in: settings)
    check("one install registers both events a knock can be delivered on",
          quotaKnockHookEvents.allSatisfy {
              commands($0) == [IntegrationsStore.knockHookCommand($0)]
          })
    // NO MATCHER. `UserPromptSubmit` has no matcher support at all, and on `PostToolUse` one would
    // narrow the delivery to certain tools for no reason: every tool call is an equally good moment.
    check("…under no matcher, so every prompt and every tool call can carry it",
          (((document()["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]) ?? [])
              .allSatisfy { $0["matcher"] == nil })
    check("detection sees the whole set", IntegrationsStore.settingsCarryKnockHooks(settings)
              && IntegrationsStore.settingsCarryCurrentKnockHooks(settings))
    // And the supervisor's own reading of the very same document, which is the one that decides
    // whether anything is ever filed: the two ends have to agree about one file.
    check("…and so does the supervisor, reading the same file for the same marker",
          quotaKnockHookRegistered(settings: document()))
    check("re-installing changes nothing",
          try IntegrationsStore.editSettings(settings) {
              IntegrationsStore.settingsRegisteringKnockHook(
                  $0, event: "PostToolUse",
                  command: IntegrationsStore.knockHookCommand("PostToolUse"))
          } == false)

    // ONE OF TWO IS NOT INSTALLED, which is the state a busy session would hear about a drought an
    // hour late in, so it has to read as broken rather than as installed.
    _ = try IntegrationsStore.editSettings(settings) {
        IntegrationsStore.settingsWithoutKnockHook($0, event: "PostToolUse")
    }
    check("a set with one event missing is not an install",
          !IntegrationsStore.settingsCarryKnockHooks(settings))
    check("…and the supervisor will not file for it either",
          !quotaKnockHookRegistered(settings: document()))
    check("…though the file still has something of ours to answer for",
          IntegrationsStore.settingsMayCarryKnockHooks(settings))
    try IntegrationsStore.removeKnockHooks(in: settings)
    check("removing takes every empty container with it", document()["hooks"] == nil)
    check("…and a file with nothing of ours reads as nothing of ours",
          !IntegrationsStore.settingsMayCarryKnockHooks(settings))

    // THE HOOK BESIDE OURS IS THE WHOLE POINT of these events being arrays: Claude Code runs every
    // entry registered under one, so ours stands beside a user's own rather than replacing it - and
    // theirs has to survive both our install and our uninstall, matcher included.
    try write(["hooks": ["PostToolUse": [["matcher": "Bash",
                                          "hooks": [["type": "command",
                                                     "command": "~/bin/my-audit-log"]]]]]])
    try IntegrationsStore.upsertKnockHooks(in: settings)
    check("a user's own hook on the same event keeps running beside ours",
          commands("PostToolUse")
              == ["~/bin/my-audit-log", IntegrationsStore.knockHookCommand("PostToolUse")])
    check("…in their own entry, under their own matcher",
          (((document()["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]) ?? [])
              .first?["matcher"] as? String == "Bash")
    try IntegrationsStore.removeKnockHooks(in: settings)
    check("…and survives the uninstall untouched",
          commands("PostToolUse") == ["~/bin/my-audit-log"])

    // A SUFFIX RATHER THAN A SUBSTRING: a user's own program whose name merely ends the same way is
    // not ours to rewrite or to delete.
    try write(["hooks": ["UserPromptSubmit": [["hooks": [["type": "command",
                                                          "command": "/opt/bin/my-hook-knock "
                                                              + "UserPromptSubmit"]]]]]])
    try IntegrationsStore.upsertKnockHooks(in: settings)
    check("a program whose name merely contains ours is not ours",
          commands("UserPromptSubmit")
              == ["/opt/bin/my-hook-knock UserPromptSubmit",
                  IntegrationsStore.knockHookCommand("UserPromptSubmit")])
    try IntegrationsStore.removeKnockHooks(in: settings)
    check("…and is left alone on the way out",
          commands("UserPromptSubmit") == ["/opt/bin/my-hook-knock UserPromptSubmit"])

    // EXACTLY ONE REGISTRATION OF OURS COMES OUT, wherever the file had them: this document is
    // rewritten by things that know nothing about Tally, and Claude Code runs every copy - so a
    // stale duplicate would hand the model the same sentence twice.
    let stale = "/Volumes/Old/Tally.app/Contents/Helpers/tally hook-knock PostToolUse"
    try write(["hooks": ["PostToolUse": [["hooks": [["type": "command", "command": stale]]],
                                         ["hooks": [["type": "command", "command": stale]]]]]])
    try IntegrationsStore.upsertKnockHooks(in: settings)
    check("two copies of ours are merged into one, at the first one's place",
          commands("PostToolUse") == [IntegrationsStore.knockHookCommand("PostToolUse")])

    // A DOCUMENT THIS CANNOT READ IS LEFT EXACTLY AS IT IS, at every level: the only safe edit to a
    // shape we do not understand is none.
    try write(["hooks": ["PostToolUse": "not an array"]])
    check("an event list of an unexpected shape is refused rather than replaced",
          IntegrationsStore.settingsRegisteringKnockHook(document(), event: "PostToolUse",
                                                         command: "x") == nil
              && IntegrationsStore.settingsWithoutKnockHook(document(),
                                                            event: "PostToolUse") == nil)
    try write(["hooks": "not an object"])
    check("…and so is a hooks block of one",
          IntegrationsStore.settingsRegisteringKnockHook(document(), event: "PostToolUse",
                                                         command: "x") == nil)

    // THE POPULATION AND THE RETRY LIST, on the asymmetry the notification hook argues in full: a
    // home discovered now counts whatever its file says, a path only the manifest remembers counts
    // while it still has something of ours on it.
    let gone = tmp.appendingPathComponent("knock-signed-out-account.json")
    try IntegrationsStore.upsertKnockHooks(in: gone)
    check("a remembered path still carrying our hooks stays in the population",
          IntegrationsStore.knockHookPopulation(discovered: [], remembered: [gone.path]) == [gone])
    check("…and its state is what the status is judged on",
          IntegrationsStore.detectKnockHooks(discovered: [], remembered: [gone.path]) == .installed)
    try IntegrationsStore.removeKnockHooks(in: gone)
    check("…while a home that has gone drags nothing down with it",
          IntegrationsStore.knockHookPopulation(discovered: [], remembered: [gone.path]).isEmpty
              && IntegrationsStore.detectKnockHooks(discovered: [], remembered: [gone.path])
                  == .notInstalled)
    // Installed in one account and not the other is the state "Install all" exists to repair, and it
    // has to be visible as something other than "installed".
    let one = tmp.appendingPathComponent("knock-account-one.json")
    let two = tmp.appendingPathComponent("knock-account-two.json")
    try IntegrationsStore.upsertKnockHooks(in: one)
    check("a set present for one account and not the next reads as broken",
          IntegrationsStore.detectKnockHooks(discovered: [one, two], remembered: [])
              == .broken(L("Not installed for every account")))
    // An entry pointing at a command this build no longer answers to is a hook that runs and
    // delivers nothing, which is the difference between installed and installed CORRECTLY.
    try write(["hooks": Dictionary(uniqueKeysWithValues: quotaKnockHookEvents.map {
        ($0, [["hooks": [["type": "command", "command": "/Volumes/Old/tally hook-knock \($0)"]]]])
    })])
    check("a registration pointing at a binary that moved is present but not current",
          IntegrationsStore.settingsCarryKnockHooks(settings)
              && !IntegrationsStore.settingsCarryCurrentKnockHooks(settings)
              && IntegrationsStore.detectKnockHooks(discovered: [settings], remembered: [])
                  == .broken(L("Older version installed")))
    try IntegrationsStore.upsertKnockHooks(in: settings)
    check("…and one press repairs it in place",
          IntegrationsStore.settingsCarryCurrentKnockHooks(settings)
              && commands("PostToolUse") == [IntegrationsStore.knockHookCommand("PostToolUse")])

    // The manifest key is written by the install and read by the removal as provenance, so a second
    // spelling would mean the removal looked up an entry nothing had ever written. Its own key, not
    // the subagent hooks', or one Remove press would take the other feature out with it.
    check("this registration has a manifest key of its own",
          IntegrationsStore.knockHookManifest == "claudeKnockHooks"
              && IntegrationsStore.knockHookManifest != IntegrationsStore.agentHookManifest)
}
