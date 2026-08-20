import Foundation

// The hook that holds an Artifact publish going out under the wrong account
// (IntegrationsArtifactHook.swift): the entry Tally adds to a user's settings.json so Claude Code can
// ask this app, before the page exists, whether the link it is about to make will open for the
// person who asked for it.
//
// Everything asserted here is about the SURGERY rather than the feature: settings.json is the user's
// own file, holding their whole harness, so what has to hold is that nothing but our own entry is
// ever touched, on install, on re-install, and on the way back out. What the guard then DECIDES is
// asserted in its own suite (tests/artifacthook), which compiles the CLI half.
//
// AND ONE THING NO OTHER ROW HERE HAS: a matcher. `PreToolUse` fires on every tool call a session
// makes, so the matcher is what keeps a hook with an opinion about one tool from being run on all of
// them, and it is spelled from the same constant the CLI checks the payload against.
@MainActor
func runArtifactHookChecks(tmp: URL) throws {
    let settings = tmp.appendingPathComponent("artifact-settings.json")
    let event = artifactHookEvent

    func document() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
    }
    func entries(_ event: String = artifactHookEvent) -> [[String: Any]] {
        ((document()["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
    }
    func commands(_ event: String = artifactHookEvent) -> [String] {
        entries(event).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }
    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: settings)
    }

    // THE SPELLINGS ARE THE CLI's, read out of the one contract both targets compile: this pane
    // writes the command and the matcher, and the CLI answers to the subcommand and checks the tool
    // name again out of the payload.
    check("the row registers the subcommand the CLI answers to",
          artifactHookCommand == "/usr/local/bin/tally hook-artifact"
              && artifactHookCommand.hasSuffix(artifactHookMarker))
    // The same public path the deliverability test asks about, which is what makes the auto-follow
    // gate below true of THIS command rather than only of the quota knock's.
    check("…through the public path that test asks whether anything can run at",
          artifactHookCommand.hasPrefix(quotaKnockHookCLIPath + " "))
    check("…on the event a permission decision may be given on", event == "PreToolUse")

    // MARK: one install, one entry, one matcher

    try IntegrationsStore.upsertArtifactHook(in: settings)
    check("one install registers exactly one hook",
          commands() == [artifactHookCommand])
    check("…under the Artifact matcher, so it does not run on every tool call in the session",
          entries().allSatisfy { $0["matcher"] as? String == artifactHookToolName })
    check("…named as the CLI names the tool it judges", artifactHookToolName == "Artifact")
    check("detection sees it", IntegrationsStore.settingsCarryArtifactHook(settings)
              && IntegrationsStore.settingsCarryCurrentArtifactHook(settings))
    check("re-installing changes nothing",
          try IntegrationsStore.editSettings(settings) {
              IntegrationsStore.settingsRegisteringArtifactHook(
                  $0, command: artifactHookCommand)
          } == false)

    // MARK: what a registration pointing somewhere else is

    // An install from an older bundle, or from a build whose matcher spelling has moved: it IS
    // installed (so the row still offers Remove, and a dev build does not report the release app's
    // install as broken) and it is NOT current, which is what the launch sync repairs.
    try write(["hooks": [event: [["matcher": "Artifact",
                                 "hooks": [["type": "command",
                                            "command": "/opt/homebrew/bin/tally hook-artifact"]]]]]])
    check("an entry naming another path is installed but not current",
          IntegrationsStore.settingsCarryArtifactHook(settings)
              && !IntegrationsStore.settingsCarryCurrentArtifactHook(settings))
    try IntegrationsStore.upsertArtifactHook(in: settings)
    check("…and is upgraded IN PLACE rather than doubled",
          commands() == [artifactHookCommand] && entries().count == 1)
    // The same, one field over: ours, on the right command, under a matcher that no longer names the
    // tool. A hook Claude Code runs on everything, or on nothing, depending which way it drifted.
    try write(["hooks": [event: [["matcher": "Write",
                                 "hooks": [["type": "command",
                                            "command": artifactHookCommand]]]]]])
    check("an entry of ours under the wrong matcher is not current either",
          IntegrationsStore.settingsCarryArtifactHook(settings)
              && !IntegrationsStore.settingsCarryCurrentArtifactHook(settings))
    try IntegrationsStore.upsertArtifactHook(in: settings)
    check("…and the install corrects the matcher",
          entries().count == 1 && entries().first?["matcher"] as? String == artifactHookToolName)

    // MARK: the user's own file

    // Their hooks on the same event, one under a matcher of their own and one under ours. Both have
    // to survive, and ours may not end up under either of their filters.
    let theirs: [String: Any] = ["type": "command", "command": "/opt/bin/lint-my-writes"]
    let sharing: [String: Any] = ["type": "command", "command": "/opt/bin/watch-artifacts"]
    try write(["hooks": [event: [["matcher": "Write", "hooks": [theirs]],
                                 ["matcher": artifactHookToolName,
                                  "hooks": [sharing,
                                            ["type": "command", "command": artifactHookCommand]]]],
                         "PostToolUse": [["hooks": [["type": "command",
                                                     "command": "/usr/local/bin/tally hook-knock PostToolUse"]]]]],
               "statusLine": ["type": "command", "command": "/opt/bin/my-status-line"]])
    try IntegrationsStore.upsertArtifactHook(in: settings)
    check("a hook the user registered under their own matcher is untouched",
          entries().contains { $0["matcher"] as? String == "Write"
              && ($0["hooks"] as? [[String: Any]])?.count == 1 })
    check("…and one sharing our matcher keeps its matcher and loses only our line",
          entries().contains { entry in
              entry["matcher"] as? String == artifactHookToolName
                  && (entry["hooks"] as? [[String: Any]] ?? []).count == 1
                  && (entry["hooks"] as? [[String: Any]] ?? [])
                      .allSatisfy { $0["command"] as? String == "/opt/bin/watch-artifacts" }
          })
    check("…while ours stands in an entry of its own",
          entries().contains { NSDictionary(dictionary: $0).isEqual(
              to: IntegrationsStore.artifactHookEntry(
                  command: artifactHookCommand)) })
    check("another event's hooks are not this row's business",
          commands("PostToolUse") == ["/usr/local/bin/tally hook-knock PostToolUse"])
    check("…and neither is anything else in the document",
          (document()["statusLine"] as? [String: Any])?["command"] as? String
              == "/opt/bin/my-status-line")

    // DUPLICATES COLLAPSE. Our own writes make at most one, but this file is rewritten by things
    // that know nothing about Tally, and Claude Code runs every copy: two of ours means the same
    // publish judged twice, or a second binary that has moved.
    let ourEntry = IntegrationsStore.artifactHookEntry(
        command: artifactHookCommand)
    try write(["hooks": [event: [ourEntry, ourEntry, ["matcher": "Write", "hooks": [theirs]]]]])
    try IntegrationsStore.upsertArtifactHook(in: settings)
    check("two copies of ours become one",
          commands().filter { $0 == artifactHookCommand }.count == 1)
    check("…and the user's entry beside them is still there", commands().count == 2)

    // A DOCUMENT WE CANNOT READ IS NOT EDITED. Conservative in both directions: an unexpected shape
    // anywhere on the path to our entry means no write at all.
    check("a hooks block of the wrong shape is left alone",
          IntegrationsStore.settingsRegisteringArtifactHook(["hooks": "surprise"],
                                                            command: artifactHookCommand) == nil)
    check("…and so is an event list of the wrong shape",
          IntegrationsStore.settingsRegisteringArtifactHook(["hooks": [event: "surprise"]],
                                                            command: artifactHookCommand) == nil)
    check("a fresh document gains exactly our entry",
          (IntegrationsStore.settingsRegisteringArtifactHook([:], command: artifactHookCommand)
              .flatMap { ($0["hooks"] as? [String: Any])?[event] as? [[String: Any]] })
              .map { $0.count == 1 } == true)

    // MARK: the way back out

    try write(["hooks": [event: [ourEntry, ["matcher": "Write", "hooks": [theirs]]],
                         "PostToolUse": [["hooks": [["type": "command", "command": "/opt/bin/x"]]]]]])
    try IntegrationsStore.removeArtifactHook(in: settings)
    check("removal takes ours and leaves theirs", commands() == ["/opt/bin/lint-my-writes"])
    check("…and leaves the other event alone", commands("PostToolUse") == ["/opt/bin/x"])
    check("…and a file with nothing of ours reads as nothing of ours",
          !IntegrationsStore.settingsMayCarryArtifactHook(settings))
    try write(["hooks": [event: [ourEntry]]])
    try IntegrationsStore.removeArtifactHook(in: settings)
    check("removing the last one takes every empty container with it", document()["hooks"] == nil)
    check("removing nothing is not a write",
          try IntegrationsStore.editSettings(settings) {
              IntegrationsStore.settingsWithoutArtifactHook($0)
          } == false)

    // PRESENT AND UNREADABLE IS NOT ABSENT: the removal pass remembers the files it threw on, and a
    // row that read those as "nothing here" would drop to not installed and take the only press that
    // can ever clear them off it.
    try Data("{ not json".utf8).write(to: settings)
    check("a settings.json nobody can parse still has something to answer for",
          IntegrationsStore.settingsMayCarryArtifactHook(settings))
    try Data().write(to: settings)
    check("…while an empty one has not", !IntegrationsStore.settingsMayCarryArtifactHook(settings))

    // MARK: the word the row shows

    let carrying = tmp.appendingPathComponent("artifact-carrying.json")
    let empty = tmp.appendingPathComponent("artifact-empty.json")
    try JSONSerialization.data(withJSONObject: ["hooks": [event: [ourEntry]]]).write(to: carrying)
    try JSONSerialization.data(withJSONObject: [:] as [String: Any]).write(to: empty)
    check("a home with the current registration reads installed",
          IntegrationsStore.detectArtifactHook(discovered: [carrying], remembered: []) == .installed)
    check("one account out of two is not an install",
          IntegrationsStore.detectArtifactHook(discovered: [carrying, empty], remembered: [])
              == .broken(L("Not installed for every account")))
    check("no homes at all is nothing to report",
          IntegrationsStore.detectArtifactHook(discovered: [], remembered: []) == .notInstalled)
    check("…as is a home that carries none of it",
          IntegrationsStore.detectArtifactHook(discovered: [empty], remembered: []) == .notInstalled)
    let stale = tmp.appendingPathComponent("artifact-stale.json")
    try JSONSerialization.data(withJSONObject: ["hooks": [event: [
        ["matcher": "Artifact", "hooks": [["type": "command",
                                           "command": "/opt/homebrew/bin/tally hook-artifact"]]],
    ]]]).write(to: stale)
    check("an older registration is present and wrong rather than absent",
          IntegrationsStore.detectArtifactHook(discovered: [stale], remembered: [])
              == .broken(L("Older version installed")))
    // A remembered path counts only while it still has something of ours on it: that list is where a
    // logged-out account's settings.json is reached from, and a cleared one must not hold the row
    // open forever.
    check("a remembered path with nothing of ours no longer counts",
          IntegrationsStore.artifactHookPopulation(discovered: [], remembered: [empty.path]).isEmpty)
    check("…while one still carrying it does",
          IntegrationsStore.artifactHookPopulation(discovered: [],
                                                   remembered: [carrying.path]) == [carrying])

    // MARK: the setting the hook reads

    // A ROW THAT SAYS INSTALLED AND DOES NOTHING is what an install without this would be: the CLI
    // abstains when no account is named, because it is a convenience rather than a gate.
    check("a fresh install names the first account, which is the main one",
          IntegrationsStore.artifactAccountSeed(current: nil,
                                                homes: ["/Users/x/.claude", "/Users/x/.claude2"])
              == "/Users/x/.claude")
    check("…and never overwrites an answer the user has already given",
          IntegrationsStore.artifactAccountSeed(current: "/Users/x/.claude3",
                                                homes: ["/Users/x/.claude"]) == nil)
    check("…while an empty stored value is not an answer",
          IntegrationsStore.artifactAccountSeed(current: "", homes: ["/Users/x/.claude"])
              == "/Users/x/.claude")
    check("…and a machine with no launchable account is left alone",
          IntegrationsStore.artifactAccountSeed(current: nil, homes: []) == nil)
}
