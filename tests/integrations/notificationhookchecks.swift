import Foundation

// The `Notification` hook behind the session board (IntegrationsNotificationHook.swift): the one
// entry Tally adds to a user's settings.json so Claude Code can say a session is waiting on them.
//
// Everything asserted here is about the SURGERY rather than the feature: settings.json is the
// user's own file, holding their whole harness, so what has to hold is that nothing but our own
// entry is ever touched - on install, on re-install, and on the way back out.
@MainActor
func runNotificationHookChecks(tmp: URL) throws {
    let ours = IntegrationsStore.notificationHookCommand
    let settings = tmp.appendingPathComponent("notify-settings.json")

    func document() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
    }
    func entries() -> [[String: Any]] {
        ((document()["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]]) ?? []
    }
    func commands() -> [String] {
        entries().flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }
    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: settings)
    }

    check("a missing settings file gets the registration",
          try IntegrationsStore.upsertNotificationHook(in: settings, command: ours)
              && commands() == [ours])
    // THE MATCHER IS THE MAIN FILTER. Claude Code fires `Notification` for nine kinds of thing and
    // only five of them are waits; without this, every background agent that FINISHED
    // (`agent_completed`) would arrive here and stand as a red dot until somebody typed.
    check("…asking only for the notifications that are waits",
          entries().first?["matcher"] as? String == notificationHookMatcher)
    check("…which is the five waiting types and none of the settled four",
          waitingNotificationTypes.allSatisfy { notificationHookMatcher.contains($0) }
              && !settledNotificationTypes.contains { notificationHookMatcher.contains($0) })
    check("re-installing changes nothing",
          try IntegrationsStore.upsertNotificationHook(in: settings, command: ours) == false)
    check("…and detection sees it", IntegrationsStore.settingsCarryNotificationHook(settings))
    check("removing it takes the whole empty container with it",
          try IntegrationsStore.removeNotificationHook(in: settings)
              && document()["hooks"] == nil)
    check("removing what is not there is a no-op rather than a rewrite",
          try IntegrationsStore.removeNotificationHook(in: settings) == false)

    // THE HOOK BESIDE OURS IS THE WHOLE POINT of this event being an array: Claude Code runs every
    // entry registered under it, so ours stands beside a user's own rather than replacing it - and
    // theirs has to survive both our install and our uninstall.
    try write(["hooks": ["Notification": [["hooks": [["type": "command",
                                                      "command": "~/bin/my-notifier"]]]]]])
    _ = try IntegrationsStore.upsertNotificationHook(in: settings, command: ours)
    check("a user's own Notification hook keeps running beside ours",
          commands() == ["~/bin/my-notifier", ours])
    try IntegrationsStore.removeNotificationHook(in: settings)
    check("…and survives the uninstall untouched", commands() == ["~/bin/my-notifier"])

    // PROVENANCE IS A SUFFIX, NOT A SUBSTRING, and both halves of that need a fixture that can
    // tell them apart. Treating either of these as ours would silently rewrite a user's hook on
    // install and delete it on uninstall.
    //
    //   - the marker inside a LONGER WORD (`my-hook-notify`), which a substring test also rejects
    //   - the marker as a word but NOT at the end (`… hook-notify claude --their-flag`), which a
    //     substring test accepts and a suffix test does not. This is the one that discriminates,
    //     and the suite had only the first until a mutant walked out through the gap.
    try write(["hooks": ["Notification": [["hooks": [
        ["type": "command", "command": "/opt/bin/my-hook-notify claude-wrapper"],
        ["type": "command", "command": "/opt/bin/watcher hook-notify claude --their-flag"],
    ]]]]])
    check("a command that merely CONTAINS our subcommand is not ours",
          !IntegrationsStore.settingsCarryNotificationHook(settings))
    _ = try IntegrationsStore.upsertNotificationHook(in: settings, command: ours)
    check("…so ours is added beside them rather than over either",
          commands() == ["/opt/bin/my-hook-notify claude-wrapper",
                         "/opt/bin/watcher hook-notify claude --their-flag", ours])

    // OURS SHARING AN ENTRY WITH THEIRS, which is what a hand edit or a merge leaves behind, and
    // the case that separates "take our HOOK out" from "take the ENTRY out": with our copy gone the
    // entry still holds theirs, so the entry stays and only our line goes.
    try write(["hooks": ["Notification": [["hooks": [
        ["type": "command", "command": ours],
        ["type": "command", "command": "~/bin/theirs"],
    ]]]]])
    try IntegrationsStore.removeNotificationHook(in: settings)
    check("uninstalling from an entry we share leaves their hook in it",
          commands() == ["~/bin/theirs"] && entries().count == 1)

    // A SECOND COPY OF OURS, which our own writes never make but a dotfiles merge, two config homes
    // folded into one, or a hand edit all can. Claude Code runs both, so a stale one would leave an
    // event twice or run a binary that has moved; exactly one comes out, whichever the file had.
    try write(["hooks": ["Notification": [
        ["hooks": [["type": "command", "command": "/old/path/tally hook-notify claude"]]],
        ["hooks": [["type": "command", "command": ours],
                   ["type": "command", "command": "~/bin/mine"]]],
    ]]])
    _ = try IntegrationsStore.upsertNotificationHook(in: settings, command: ours)
    check("duplicates of ours collapse to exactly one, at the first one's place",
          commands() == [ours, "~/bin/mine"])
    // The collapse takes OUR copy out of the second entry and leaves everything else where it
    // stood: the user's neighbour keeps its own entry rather than being folded into ours, which is
    // the same line the prompt hook draws between "the hook we may rewrite" and "the entry around
    // it". An entry left holding nothing at all would go; this one still holds theirs.
    check("…and the user's neighbour is still in the entry it was in",
          entries().count == 2
              && (entries().last?["hooks"] as? [[String: Any]])?.count == 1)
    // TWO ENTRIES THAT ARE OURS ALONE, which is the shape the collapse actually has to answer for:
    // above, the second copy shares its entry with a user hook and leaves by a different door, so
    // that fixture proves position rather than collapse (a mutant that kept every duplicate walked
    // straight through it). Claude Code runs both, so a stale one leaves the event twice, or once
    // from a binary that has moved.
    try write(["hooks": ["Notification": [
        ["matcher": notificationHookMatcher,
         "hooks": [["type": "command", "command": "/old/path/tally hook-notify claude"]]],
        ["matcher": notificationHookMatcher, "hooks": [["type": "command", "command": ours]]],
    ]]])
    _ = try IntegrationsStore.upsertNotificationHook(in: settings, command: ours)
    check("two solo entries of ours collapse to exactly one",
          entries().count == 1 && commands() == [ours])

    // AN INSTALL FROM BEFORE THE MATCHER is present but not current: it fires our hook for all
    // nine types, so it is a live source of false red dots rather than a cosmetic lag. It has to
    // read as installed (it is), fail the "current" test, and be UPGRADED IN PLACE rather than
    // doubled.
    try write(["hooks": ["Notification": [["hooks": [["type": "command", "command": ours]]]]]])
    check("a matcher-less registration still reads as installed",
          IntegrationsStore.settingsCarryNotificationHook(settings))
    check("…but not as the current one",
          !IntegrationsStore.settingsCarryCurrentNotificationHook(settings, command: ours))
    check("…and upgrading it adds the matcher rather than a second entry",
          try IntegrationsStore.upsertNotificationHook(in: settings, command: ours)
              && entries().count == 1
              && entries().first?["matcher"] as? String == notificationHookMatcher)
    check("…after which it is current, and idempotent again",
          try IntegrationsStore.settingsCarryCurrentNotificationHook(settings, command: ours)
              && IntegrationsStore.upsertNotificationHook(in: settings, command: ours) == false)

    // OUR MATCHER MUST NEVER LAND ON A USER'S HOOK. The matcher belongs to the ENTRY, so sharing
    // one with them would silently stop THEIR hook firing for the four types we filter out - in a
    // file we are only supposed to be adding a line to. Ours moves into an entry of its own and
    // theirs keeps the entry, and the matcher, it had.
    try write(["hooks": ["Notification": [["matcher": "auth_success",
                                           "hooks": [["type": "command", "command": ours],
                                                     ["type": "command", "command": "~/bin/theirs"]]]]]])
    _ = try IntegrationsStore.upsertNotificationHook(in: settings, command: ours)
    check("ours leaves an entry it shared rather than imposing our matcher on theirs",
          entries().count == 2
              && (entries().first?["hooks"] as? [[String: Any]])?.count == 1
              && entries().first?["matcher"] as? String == "auth_success")
    check("…and stands in an entry of its own with our matcher",
          entries().last?["matcher"] as? String == notificationHookMatcher
              && (entries().last?["hooks"] as? [[String: Any]])?.count == 1)
    check("…with their hook untouched", commands() == ["~/bin/theirs", ours])

    // A STALE PATH IS STILL OURS: the app bundle moves, and the registration is repaired in place
    // rather than duplicated. Detection deliberately ignores the path (an entry that is stale is
    // still installed), which is also what keeps a dev build from calling a release install broken.
    try write(["hooks": ["Notification": [["hooks": [
        ["type": "command", "command": "/Volumes/Old/tally hook-notify claude"],
    ]]]]])
    check("a registration pointing at a binary that moved still reads as installed",
          IntegrationsStore.settingsCarryNotificationHook(settings))
    check("…and is repaired in place rather than added beside",
          try IntegrationsStore.upsertNotificationHook(in: settings, command: ours)
              && commands() == [ours])

    // AN ACCOUNT THAT LOGGED OUT SINCE INSTALL. `claudeSettingsFiles()` answers with the homes
    // discoverable TODAY, so a home whose login is gone drops out of it - and the hook Tally wrote
    // there stays, calling a subcommand, after the user pressed Remove and was told it was gone.
    // The manifest is the only record that home was ever written to, which is why the removal takes
    // the union (the skill and the prompt hook already do, for this exact reason).
    let orphan = tmp.appendingPathComponent("logged-out-home-settings.json")
    try JSONSerialization.data(withJSONObject:
        ["hooks": ["Notification": [IntegrationsStore.notificationHookEntry(command: ours)]]])
        .write(to: orphan)
    // Asked of the pure join rather than of the live discovery, which would need logged-in homes on
    // whichever machine runs the assertions.
    let live = tmp.appendingPathComponent("live-home-settings.json")
    let union = IntegrationsStore.notificationHookSettingsFiles(
        discovered: [live], remembered: [orphan.path, live.path])
    check("the union reaches a path only the manifest remembers",
          union.map(\.lastPathComponent).contains(orphan.lastPathComponent))
    check("…keeps the discovered ones first", union.first?.path == live.path)
    check("…and counts one physical file once, however many ways it was named",
          union.count == 2)
    check("removing from a remembered path really takes the hook out",
          try IntegrationsStore.removeNotificationHook(in: orphan)
              && (((try? JSONSerialization.jsonObject(with: Data(contentsOf: orphan)))
                  as? [String: Any])?["hooks"]) == nil)
    check("the manifest component is spelled once, so the install and the removal agree",
          IntegrationsStore.notificationHookManifest == "claudeNotificationHook")

    // A REMOVAL PASS THAT FAILS HALFWAY, which is the case the manifest is a RETRY LIST for. The
    // record is the only thing that can lead a later press back to a settings.json the discovery
    // cannot see any more, so forgetting it because SOME OTHER file failed would strand the hook it
    // names: it stays on disk calling a subcommand, and nothing ever comes for it again.
    let cleared = tmp.appendingPathComponent("cleared-home-settings.json")
    try JSONSerialization.data(withJSONObject:
        ["hooks": ["Notification": [IntegrationsStore.notificationHookEntry(command: ours)]]])
        .write(to: cleared)
    // Bytes that are there and do not parse: the one document `editSettings` refuses to touch, so
    // this file goes through the pass without losing its hook - exactly the shape a home that has
    // become unreadable has.
    let refused = tmp.appendingPathComponent("unreadable-home-settings.json")
    try Data("{ this is not json".utf8).write(to: refused)
    let halfway = IntegrationsStore.removeNotificationHook(from: [cleared, refused])
    check("a removal that could not finish keeps the failed path, and only that one",
          halfway.remembered == [refused.path] && halfway.failure != nil)
    check("…while the file it did reach really lost the hook",
          (((try? JSONSerialization.jsonObject(with: Data(contentsOf: cleared)))
              as? [String: Any])?["hooks"]) == nil)
    check("…and the refused file was left exactly as it was",
          (try? String(contentsOf: refused, encoding: .utf8)) == "{ this is not json")
    // The other direction, which is the behaviour that must SURVIVE the fix: a pass where every
    // file was dealt with remembers nothing, so the manifest entry goes.
    let finished = IntegrationsStore.removeNotificationHook(from: [cleared])
    check("a pass that finished remembers nothing at all",
          finished.remembered == nil && finished.failure == nil)

    // AND THE PRESS THAT ACTS ON THE LIST HAS TO BE ON SCREEN, which is what the record is FOR.
    // Detection asked only the homes discovery can see, so the halfway pass above left the row
    // reading "not installed": Install and nothing else, over a settings.json that still calls our
    // subcommand - and the retry list underneath it that nothing could ever reach. The status is
    // judged over the same union the removal walks, so a file that will not parse is one still to
    // be dealt with rather than one with no hook in it.
    let stranded = IntegrationsStore.detectNotificationHook(discovered: [live],
                                                            remembered: [refused.path])
    check("a failed path the discovery cannot see keeps the row out of 'not installed'",
          stranded != .notInstalled)
    check("…so the Remove press that retries it is still offered", stranded.offersRemoval)
    // The manifest is not a truth source of its own. A remembered path whose file is clean says
    // exactly what it did before, or every completed uninstall would leave a row claiming a
    // registration that is not there any more.
    check("a remembered path with no hook left in it still reads as not installed",
          IntegrationsStore.detectNotificationHook(discovered: [live],
                                                   remembered: [cleared.path]) == .notInstalled)
    // Nor is a path it remembers a permanent accusation: a home that has GONE is not an account
    // missing its install, and counting it as one would hold a complete install at "needs
    // attention" forever, with no press that could ever clear it.
    let current = tmp.appendingPathComponent("current-home-settings.json")
    try JSONSerialization.data(withJSONObject:
        ["hooks": ["Notification": [IntegrationsStore.notificationHookEntry(command: ours)]]])
        .write(to: current)
    check("a remembered home that no longer exists leaves a complete install reading installed",
          IntegrationsStore.detectNotificationHook(
              discovered: [current],
              remembered: [current.path, tmp.appendingPathComponent("gone.json").path])
              == .installed)
    check("…and a discovered home with no hook anywhere still reads as not installed",
          IntegrationsStore.detectNotificationHook(discovered: [cleared], remembered: [])
              == .notInstalled)

    // AND THE TWO WAYS OF GETTING NO BYTES OUT OF A PATH ARE NOT THE SAME THING, which is the whole
    // of what the population's filter asks. A file that is not there is a home that has GONE; a
    // file that is there and will not open is one this process cannot read RIGHT NOW - a
    // permissions change, a volume that went away - and it may still be holding our hook. Answering
    // false for the second dropped it out of the population, which drops the row to "not
    // installed", which takes the Remove press off the only thing that could ever clear it.
    check("a path with nothing at it carries nothing of ours",
          !IntegrationsStore.settingsMayCarryNotificationHook(
              tmp.appendingPathComponent("no-such-home.json")))
    let empty = tmp.appendingPathComponent("empty-home-settings.json")
    try Data().write(to: empty)
    check("nor does an empty file: a fresh document has no registration in it",
          !IntegrationsStore.settingsMayCarryNotificationHook(empty))
    check("bytes that will not parse count as something still to be dealt with",
          IntegrationsStore.settingsMayCarryNotificationHook(refused))
    check("…while a document that parses and has no hook of ours does not",
          !IntegrationsStore.settingsMayCarryNotificationHook(cleared))
    let sealed = tmp.appendingPathComponent("unreadable-perms-settings.json")
    try JSONSerialization.data(withJSONObject:
        ["hooks": ["Notification": [IntegrationsStore.notificationHookEntry(command: ours)]]])
        .write(to: sealed)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
    if getuid() == 0 {
        // Root reads a mode-000 file regardless, so there is no unreadable file to make on this
        // machine. Named rather than silently passed: a skip that reports PASS is a check nobody
        // knows they lost.
        print("SKIP present-but-unreadable settings.json (running as root, which reads it anyway)")
    } else {
        check("a file that is there and cannot be read is NOT read as absent",
              IntegrationsStore.settingsMayCarryNotificationHook(sealed))
        check("…so the row keeps the Remove press that would retry it",
              IntegrationsStore.detectNotificationHook(discovered: [live],
                                                       remembered: [sealed.path]).offersRemoval)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sealed.path)

    // THE INSTALL MUST NOT FORGET IT EITHER, and Install is exactly the press a stranded row
    // offers. The manifest it writes is the union: what it has just registered PLUS the paths the
    // record already held. Writing only what is discoverable today dropped the failed one for good
    // - the hook stayed in a settings.json calling a subcommand, and nothing knew where it was.
    let recorded = IntegrationsStore.notificationHookManifestPaths(installed: [live],
                                                                   remembered: [refused.path])
    check("an install keeps the path a removal could not finish",
          recorded?.contains(refused.path) == true && recorded?.contains(live.path) == true)
    check("…counting one physical file once, however many ways it was named",
          IntegrationsStore.notificationHookManifestPaths(installed: [live],
                                                          remembered: [live.path])?.count == 1)
    check("…and an install with nothing at all to record clears the entry",
          IntegrationsStore.notificationHookManifestPaths(installed: [], remembered: []) == nil)

    // THE REFUSAL, which every write into this file is under: a document we cannot read is left
    // exactly as it is. The only safe edit to a shape nobody understands is none.
    check("a hooks block of the wrong shape is refused rather than replaced",
          IntegrationsStore.settingsRegisteringNotificationHook(["hooks": "yes"],
                                                                command: ours) == nil)
    check("…and so is an event list of the wrong shape",
          IntegrationsStore.settingsRegisteringNotificationHook(
              ["hooks": ["Notification": "yes"]], command: ours) == nil)
    // The other events in the same block belong to the user and are none of our business.
    let mixed: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": []]]]]
    let after = IntegrationsStore.settingsRegisteringNotificationHook(mixed, command: ours)
    check("registering ours leaves every other event untouched",
          (after?["hooks"] as? [String: Any])?["PreToolUse"] != nil)
}
