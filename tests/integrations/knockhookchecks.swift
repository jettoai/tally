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

    // jettoai/tally#5: AN ENTRY IS NOT AN INSTALL. Every hook row and the status line name
    // /usr/local/bin/tally; with nothing runnable there each one fails on every event, so the row
    // has to read as broken, and a press may not write the registration at all.
    let noCLI = quotaKnockCLIDeliverable(at: tmp.appendingPathComponent("knock-no-cli").path)
    let missing = IntegrationsStore.Status.broken(L("Install the command line tool first."))
    check("#5 a registration whose command cannot run reads as broken, not installed",
          !noCLI && IntegrationsStore.requiringCLI(.installed, cliDeliverable: noCLI) == missing)
    check("#5 ...an older install the same, since the CLI is the repair it needs first",
          IntegrationsStore.requiringCLI(.broken(L("Older version installed")),
                                         cliDeliverable: noCLI) == missing)
    check("#5 ...nothing on disk stays nothing on disk",
          IntegrationsStore.requiringCLI(.notInstalled, cliDeliverable: noCLI) == .notInstalled)
    check("#5 ...and with the CLI runnable nothing changes",
          IntegrationsStore.requiringCLI(.installed, cliDeliverable: true) == .installed)
    // The install presses and the refresh read machine state this harness cannot fake (the shared
    // /usr/local/bin path), so their wiring is read, the way autofollowchecks reads its gate.
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func source(_ name: String) -> String {
        (try? String(contentsOf: repo.appendingPathComponent("Tally/Stores/\(name).swift"),
                     encoding: .utf8)) ?? ""
    }
    check("#5 every hook row's status is judged through requiringCLI",
          source("IntegrationsStore").components(separatedBy: "= Self.requiringCLI(Self.detect")
              .count - 1 == 5)
    for (file, function) in [("IntegrationsStore", "installStatusLine"),
                             ("IntegrationsNotificationHook", "installNotificationHook"),
                             ("IntegrationsAgentHook", "installAgentHooks"),
                             ("IntegrationsKnockHook", "installKnockHooks")] {
        check("#5 \(function) refuses before writing while the CLI cannot run",
              source(file).contains(
                  "func \(function)() {\n        guard guardNotDev(), guardCLIDeliverable() else"))
    }

    // F7: THE CHROME-GAP FAILURE EVENT is a third registration of the same row, under a matcher,
    // and outside the supervisor's all-of question about the knock channel.
    func entries(_ event: String) -> [[String: Any]] {
        ((document()["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }
    try write(["hooks": Dictionary(uniqueKeysWithValues: quotaKnockHookEvents.map {
        ($0, [["hooks": [["type": "command", "command": IntegrationsStore.knockHookCommand($0)]]]])
    })])
    check("F7 settings holding only the quota pair still register the knock channel",
          quotaKnockHookRegistered(settings: document()))
    check("F7 …are present but not current, so the row offers the repair",
          IntegrationsStore.settingsCarryKnockHooks(settings)
              && !IntegrationsStore.settingsCarryCurrentKnockHooks(settings))
    try IntegrationsStore.upsertKnockHooks(in: settings)
    check("F7 the repair adds the failure event's hook, under the Chrome matcher",
          commands(chromeGapHookEvent) == [IntegrationsStore.knockHookCommand(chromeGapHookEvent)]
              && entries(chromeGapHookEvent).first?["matcher"] as? String
                  == "mcp__claude-in-chrome__.*")
    check("F7 …leaves the quota pair without a matcher, and reads current",
          quotaKnockHookEvents.allSatisfy { entries($0).allSatisfy { $0["matcher"] == nil } }
              && IntegrationsStore.settingsCarryCurrentKnockHooks(settings))
    check("F7 …and the knock channel's events are still exactly the two",
          quotaKnockHookEvents == ["UserPromptSubmit", "PostToolUse"]
              && quotaKnockHookRegistered(settings: document()))
    _ = try IntegrationsStore.editSettings(settings) {
        IntegrationsStore.settingsWithoutKnockHook(
            IntegrationsStore.settingsWithoutKnockHook($0, event: "UserPromptSubmit") ?? $0,
            event: "PostToolUse")
    }
    check("F7 a file left with only the failure hook still has something of ours",
          IntegrationsStore.settingsMayCarryKnockHooks(settings)
              && !quotaKnockHookRegistered(settings: document()))
    try IntegrationsStore.upsertKnockHooks(in: settings)
    try IntegrationsStore.removeKnockHooks(in: settings)
    check("F7 removal clears all three", document()["hooks"] == nil
              && !IntegrationsStore.settingsMayCarryKnockHooks(settings))

    // F8: THE LAUNCH UPKEEP. An older app's install (the quota pair only) is brought up to date
    // without a press; a file without our hooks and one already current are not written at all.
    func hookCommands(_ file: URL, _ event: String) -> [String] {
        let doc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        return (((doc?["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
    }
    let theirs: [String: Any] = ["matcher": "Bash",
                                 "hooks": [["type": "command", "command": "~/bin/my-audit-log"]]]
    let older = tmp.appendingPathComponent("knock-upkeep-older.json")
    var olderHooks: [String: Any] = Dictionary(uniqueKeysWithValues: quotaKnockHookEvents.map {
        ($0, [["hooks": [["type": "command", "command": IntegrationsStore.knockHookCommand($0)]]]])
    })
    olderHooks["PostToolUse"] = [theirs] + (olderHooks["PostToolUse"] as? [[String: Any]] ?? [])
    olderHooks[chromeGapHookEvent] = [theirs]
    try JSONSerialization.data(withJSONObject: ["hooks": olderHooks]).write(to: older)
    let bare = tmp.appendingPathComponent("knock-upkeep-bare.json")
    try JSONSerialization.data(withJSONObject: ["hooks": ["PostToolUse": [theirs]]]).write(to: bare)
    let absent = tmp.appendingPathComponent("knock-upkeep-absent.json")
    let current = tmp.appendingPathComponent("knock-upkeep-current.json")
    try IntegrationsStore.upsertKnockHooks(in: current)
    let bareBytes = try Data(contentsOf: bare)
    let currentBytes = try Data(contentsOf: current)
    check("F8 the upkeep picks exactly the older install",
          IntegrationsStore.knockHookFilesNeedingUpdate([older, bare, absent, current, older])
              == [older])
    let upkeep = IntegrationsStore.autoUpdateKnockHooks(in: [older, bare, absent, current])
    check("F8 …and rewrites only it, without error", upkeep.updated == [older] && upkeep.error == nil)
    let failureEntries = (((try? JSONSerialization.jsonObject(with: Data(contentsOf: older)))
        as? [String: Any])?["hooks"] as? [String: Any])?[chromeGapHookEvent] as? [[String: Any]] ?? []
    check("F8 the older install now carries all three, the third under the Chrome matcher",
          IntegrationsStore.settingsCarryCurrentKnockHooks(older)
              && failureEntries.contains { $0["matcher"] as? String == chromeGapHookMatcher })
    check("F8 the user's own hooks on the same events are kept",
          hookCommands(older, "PostToolUse")
              == ["~/bin/my-audit-log", IntegrationsStore.knockHookCommand("PostToolUse")]
              && hookCommands(older, chromeGapHookEvent)
                  == ["~/bin/my-audit-log", IntegrationsStore.knockHookCommand(chromeGapHookEvent)])
    check("F8 a file without our hooks is byte for byte untouched",
          (try? Data(contentsOf: bare)) == bareBytes)
    check("F8 a missing file is not created",
          !FileManager.default.fileExists(atPath: absent.path))
    check("F8 a current install is byte for byte untouched",
          (try? Data(contentsOf: current)) == currentBytes)
    let knockSource = (try? String(contentsOfFile: "Tally/Stores/IntegrationsKnockHook.swift",
                                   encoding: .utf8)) ?? ""
    let launch = (try? String(contentsOfFile: "Tally/App/AppDelegate.swift", encoding: .utf8)) ?? ""
    check("F8 the upkeep runs at launch, beside the skill's",
          launch.contains("IntegrationsStore.shared.autoUpdateSkill()")
              && launch.contains("IntegrationsStore.shared.autoUpdateKnockHooks()"))
    check("F8 …and never from a build nobody installed",
          knockSource.contains("func autoUpdateKnockHooks() {\n        guard !BuildVariant.isUnshipped"))

    // F9 (B-558): THE CHROME CALL BEFORE IT IS SENT is a fourth registration of the same row, under
    // the same matcher, and an install with only the first three is brought up to date at launch.
    check("F9 the row registers PreToolUse under the Chrome matcher",
          IntegrationsStore.knockHookEvents.contains(chromePreflightHookEvent)
              && chromePreflightHookEvent == "PreToolUse"
              && IntegrationsStore.knockHookMatcher(chromePreflightHookEvent) == "mcp__claude-in-chrome__.*")
    let threeEvent = tmp.appendingPathComponent("knock-upkeep-three.json")
    try JSONSerialization.data(withJSONObject: ["hooks": Dictionary(uniqueKeysWithValues:
        (quotaKnockHookEvents + [chromeGapHookEvent]).map { event -> (String, Any) in
            var entry: [String: Any] = ["hooks": [["type": "command",
                                                   "command": IntegrationsStore.knockHookCommand(event)]]]
            if event == chromeGapHookEvent { entry["matcher"] = chromeGapHookMatcher }
            return (event, [entry])
        })]).write(to: threeEvent)
    check("F9 a three-event install is picked by the launch upkeep",
          IntegrationsStore.knockHookFilesNeedingUpdate([threeEvent]) == [threeEvent])
    _ = IntegrationsStore.autoUpdateKnockHooks(in: [threeEvent])
    check("F9 …and comes out current, PreToolUse under the Chrome matcher",
          IntegrationsStore.settingsCarryCurrentKnockHooks(threeEvent)
              && (((try? JSONSerialization.jsonObject(with: Data(contentsOf: threeEvent))) as? [String: Any])
                  .flatMap { ($0["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] } ?? [])
                  .contains { $0["matcher"] as? String == chromeGapHookMatcher })

    // F10: COEXISTENCE with the retired Artifact PreToolUse hook in one settings.json, until the
    // launch pass has taken it out (IntegrationsArtifactHook.swift).
    let artifactEntry: [String: Any] = ["matcher": "Artifact",
                                        "hooks": [["type": "command",
                                                   "command": "/usr/local/bin/tally hook-artifact"]]]
    func preToolUse() -> [[String: Any]] { entries(chromePreflightHookEvent) }
    func artifactEntries() -> [[String: Any]] {
        preToolUse().filter { NSDictionary(dictionary: $0).isEqual(to: artifactEntry) }
    }
    try write(["hooks": ["PreToolUse": [artifactEntry]]])
    try IntegrationsStore.upsertKnockHooks(in: settings)
    check("F10 installing the knock row keeps the Artifact entry as it was",
          artifactEntries().count == 1 && preToolUse().count == 2)
    try IntegrationsStore.removeKnockHooks(in: settings)
    check("F10 removing the knock row keeps the Artifact entry as it was",
          artifactEntries().count == 1 && preToolUse().count == 1)
    try IntegrationsStore.upsertKnockHooks(in: settings)
    let knockPre = preToolUse().filter { !NSDictionary(dictionary: $0).isEqual(to: artifactEntry) }
    _ = try IntegrationsStore.editSettings(settings) { IntegrationsStore.settingsWithoutArtifactHook($0) }
    check("F10 removing the Artifact hook keeps the knock PreToolUse entry as it was",
          preToolUse().count == 1 && NSDictionary(dictionary: preToolUse()[0]).isEqual(to: knockPre[0]))
    try IntegrationsStore.removeKnockHooks(in: settings)

    // The manifest key is written by the install and read by the removal as provenance, so a second
    // spelling would mean the removal looked up an entry nothing had ever written. Its own key, not
    // the subagent hooks', or one Remove press would take the other feature out with it.
    check("this registration has a manifest key of its own",
          IntegrationsStore.knockHookManifest == "claudeKnockHooks"
              && IntegrationsStore.knockHookManifest != IntegrationsStore.agentHookManifest)
}
