import Foundation

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

try MainActor.assumeIsolated {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tally-test-\(UUID())")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let f = tmp.appendingPathComponent("zshenv")
    let body = "export PATH=\"$HOME/.tally/bin:$PATH\""
    let begin = IntegrationsStore.blockBegin, end = IntegrationsStore.blockEnd

    try IntegrationsStore.upsertBlock(in: f, body: body)
    var c = try String(contentsOf: f, encoding: .utf8)
    check("upsert into missing file creates exactly one block", c == "\(begin)\n\(body)\n\(end)\n")

    try IntegrationsStore.stripBlock(in: f)
    c = try String(contentsOf: f, encoding: .utf8)
    check("strip returns to empty", c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    let user = "# my stuff\nexport FOO=1\n\nalias x=y\n"
    try user.write(to: f, atomically: true, encoding: .utf8)
    try IntegrationsStore.upsertBlock(in: f, body: body)
    c = try String(contentsOf: f, encoding: .utf8)
    check("upsert appends after user content", c.hasPrefix(user) && c.contains(begin))
    try IntegrationsStore.stripBlock(in: f)
    c = try String(contentsOf: f, encoding: .utf8)
    check("strip preserves user content byte-for-byte", c == user)

    try IntegrationsStore.upsertBlock(in: f, body: body)
    try IntegrationsStore.upsertBlock(in: f, body: body)
    c = try String(contentsOf: f, encoding: .utf8)
    check("double upsert leaves one block", c.components(separatedBy: begin).count == 2)

    let halfOpen = "\(begin)\nhalf\n"
    try halfOpen.write(to: f, atomically: true, encoding: .utf8)
    var threw = false
    do { try IntegrationsStore.stripBlock(in: f) } catch { threw = true }
    c = try String(contentsOf: f, encoding: .utf8)
    check("unclosed block throws", threw)
    check("unclosed block leaves file untouched", c == halfOpen)

    let mid = "line1\n\(begin)\nX\n\(end)\nline2\n"
    try mid.write(to: f, atomically: true, encoding: .utf8)
    try IntegrationsStore.stripBlock(in: f)
    c = try String(contentsOf: f, encoding: .utf8)
    check("mid-file block strips cleanly", c == "line1\nline2\n")

    // MARK: statusLine surgery (settings.json) - wrap a custom command, restore it exactly.
    let ours = IntegrationsStore.statusLineCommand
    let settings = tmp.appendingPathComponent("settings.json")
    func readSettings() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
    }
    func statusCommand() -> String? {
        (readSettings()["statusLine"] as? [String: Any])?["command"] as? String
    }

    check("missing settings gets the plain registration",
          try IntegrationsStore.upsertStatusLine(in: settings, command: ours)
              && statusCommand() == ours)
    check("re-install is idempotent",
          try IntegrationsStore.upsertStatusLine(in: settings, command: ours) == false)
    try IntegrationsStore.removeStatusLine(in: settings, command: ours)
    check("removing the plain registration deletes the entry", statusCommand() == nil)

    let custom = "~/.claude/my-status.sh --fancy 'quoted arg'"
    let foreign: [String: Any] = ["model": "opusplan",
                                  "statusLine": ["type": "command", "command": custom]]
    try JSONSerialization.data(withJSONObject: foreign).write(to: settings)
    _ = try IntegrationsStore.upsertStatusLine(in: settings, command: ours)
    check("a custom status line is wrapped, not clobbered",
          statusCommand()?.hasPrefix("\(ours) --wrap ") == true)
    check("the wrap carries a self-heal fallback",
          statusCommand()?.contains("|| printf %s") == true)

    // Self-heal end to end: with the tally binary GONE (app trashed without a clean remove),
    // the registered shell line must still run the user's original status line.
    let echoOriginal: [String: Any] = ["statusLine": ["type": "command", "command": "echo healed"]]
    let healFile = tmp.appendingPathComponent("heal-settings.json")
    try JSONSerialization.data(withJSONObject: echoOriginal).write(to: healFile)
    _ = try IntegrationsStore.upsertStatusLine(in: healFile, command: "/nonexistent/tally statusline claude")
    let healCommand = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: healFile)))
        as? [String: Any])
        .flatMap { ($0["statusLine"] as? [String: Any])?["command"] as? String } ?? ""
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", healCommand]
    let healOut = Pipe()
    sh.standardOutput = healOut
    sh.standardError = FileHandle.nullDevice
    try sh.run()
    let healed = String(data: healOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    sh.waitUntilExit()
    check("without tally the fallback runs the original status line",
          healed?.trimmingCharacters(in: .whitespacesAndNewlines) == "healed")
    check("unrelated settings keys survive the wrap", readSettings()["model"] as? String == "opusplan")
    try IntegrationsStore.removeStatusLine(in: settings, command: ours)
    check("removal restores the custom command exactly", statusCommand() == custom)
    check("unrelated settings keys survive the restore", readSettings()["model"] as? String == "opusplan")

    try IntegrationsStore.removeStatusLine(in: settings, command: ours)
    check("removing over a foreign command leaves it untouched", statusCommand() == custom)

    // MARK: Claude Code skill surgery - install, refuse foreign files, remove cleanly.
    let skillFile = tmp.appendingPathComponent("skills/tally/SKILL.md")
    check("fresh skill install writes the file",
          try IntegrationsStore.upsertSkill(in: skillFile) == true
              && FileManager.default.fileExists(atPath: skillFile.path))
    let written = try String(contentsOf: skillFile, encoding: .utf8)
    check("installed skill carries the version marker",
          written.contains("tally-skill v\(IntegrationsStore.skillVersion)"))
    check("skill has frontmatter with a trigger description",
          written.hasPrefix("---\nname: tally-quota\n") && written.contains("description: "))
    check("re-install is idempotent", try IntegrationsStore.upsertSkill(in: skillFile) == false)

    let stale = written.replacingOccurrences(
        of: "tally-skill v\(IntegrationsStore.skillVersion)", with: "tally-skill v0")
    try stale.write(to: skillFile, atomically: true, encoding: .utf8)
    check("an older tally skill is upgraded in place",
          try IntegrationsStore.upsertSkill(in: skillFile) == true
              && String(contentsOf: skillFile, encoding: .utf8)
                  .contains("tally-skill v\(IntegrationsStore.skillVersion)"))

    try IntegrationsStore.removeSkill(in: skillFile)
    check("remove deletes the skill and its emptied folder",
          !FileManager.default.fileExists(atPath: skillFile.path)
              && !FileManager.default.fileExists(atPath: skillFile.deletingLastPathComponent().path))

    let userSkill = "---\nname: tally\ndescription: my own thing\n---\nmine"
    try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try userSkill.write(to: skillFile, atomically: true, encoding: .utf8)
    var refused = false
    do { _ = try IntegrationsStore.upsertSkill(in: skillFile) } catch { refused = true }
    var afterRefusal = try String(contentsOf: skillFile, encoding: .utf8)
    check("a user's own skills/tally is never clobbered", refused && afterRefusal == userSkill)
    try IntegrationsStore.removeSkill(in: skillFile)
    afterRefusal = try String(contentsOf: skillFile, encoding: .utf8)
    check("remove leaves a foreign skill untouched", afterRefusal == userSkill)

    // Unreadable is NOT absent: a file we cannot inspect must never be overwritten.
    let junk = Data([0xFF, 0xFE, 0xFA, 0x00, 0x81])   // not valid UTF-8
    try junk.write(to: skillFile)
    var refusedJunk = false
    do { _ = try IntegrationsStore.upsertSkill(in: skillFile) } catch { refusedJunk = true }
    let junkAfter = try Data(contentsOf: skillFile)
    check("an undecodable skills/tally is refused, not clobbered",
          refusedJunk && junkAfter == junk)

    // MARK: skill content - the v2 advisor guidance, and the repo-wide no-em-dash rule.
    let currentSkill = IntegrationsStore.skillMarkdown()
    check("skill is at version 2", IntegrationsStore.skillVersion == 2)
    check("skill teaches the advisor field", currentSkill.contains("advisor.<provider>"))
    check("skill spells out every verdict",
          currentSkill.contains("`collecting`") && currentSkill.contains("`addAccount`")
              && currentSkill.contains("`sufficient`"))
    check("skill points at the headline and the numbers behind it",
          currentSkill.contains("`headline`") && currentSkill.contains("demandPerWeek")
              && currentSkill.contains("starvedHoursPerWeek")
              && currentSkill.contains("daysOfData"))
    check("skill answers the capacity question from the advisor",
          currentSkill.contains("should I add an account"))
    check("skill carries no em dash", !currentSkill.contains("\u{2014}"))

    // MARK: auto-update - old installs follow the app, absent and foreign files never do.
    let autoDir = tmp.appendingPathComponent("auto")
    func autoFile(_ name: String, _ content: String) throws -> URL {
        let url = autoDir.appendingPathComponent("\(name)/SKILL.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    let oldSkill = currentSkill.replacingOccurrences(
        of: "tally-skill v\(IntegrationsStore.skillVersion)", with: "tally-skill v1")
    let oldFile = try autoFile("old", oldSkill)
    let currentFile = try autoFile("current", currentSkill)
    let foreignFile = try autoFile("foreign", userSkill)
    let orphanFile = try autoFile("orphan", oldSkill)
    let absentFile = autoDir.appendingPathComponent("absent/SKILL.md")   // never written

    let auto = IntegrationsStore.autoUpdateSkills(
        in: [oldFile, currentFile, absentFile, foreignFile, orphanFile])
    check("an older install is brought to the current version",
          try String(contentsOf: oldFile, encoding: .utf8) == currentSkill)
    check("an orphan on a manifest-only path is updated too",
          try String(contentsOf: orphanFile, encoding: .utf8) == currentSkill)
    check("only the outdated files count as updated", auto.updated == 2 && auto.error == nil)
    check("an absent skill is never installed",
          !FileManager.default.fileExists(atPath: absentFile.path))
    check("a foreign skills/tally is never overwritten",
          try String(contentsOf: foreignFile, encoding: .utf8) == userSkill)
    check("a current install is left alone",
          try String(contentsOf: currentFile, encoding: .utf8) == currentSkill)
    check("the manifest records our files only, absent and foreign excluded",
          auto.ours.map(\.path).sorted() == [oldFile, currentFile, orphanFile].map(\.path).sorted())
    check("a second pass changes nothing",
          IntegrationsStore.autoUpdateSkills(in: [oldFile, currentFile, orphanFile]).updated == 0)

    // A total failure (unwritable skills folder) must still surface: nothing gets recorded, but
    // the error travels back so `autoUpdateSkill` can put it in `lastError`. Asserted on the
    // return value rather than the store's property: reaching `lastError` means touching the
    // MainActor singleton, which would read and rewrite this machine's real claude homes.
    let lockedFile = try autoFile("locked", oldSkill)
    let lockedDir = lockedFile.deletingLastPathComponent().path
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDir)
    let locked = IntegrationsStore.autoUpdateSkills(in: [lockedFile])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDir)
    check("an update that cannot be written reports the failure",
          locked.updated == 0 && locked.error != nil)
    check("a failed update leaves the old file intact",
          try String(contentsOf: lockedFile, encoding: .utf8) == oldSkill)

    // The manifest is what makes a logged-out account's orphan reachable at all.
    let manifest = tmp.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: [
        "claudeSkill": ["paths": [orphanFile.path], "installedAt": "2026-01-01T00:00:00Z"],
    ]).write(to: manifest)
    check("manifest paths are read back for the install set",
          IntegrationsStore.manifestPaths("claudeSkill", manifest: manifest) == [orphanFile.path])
    check("a missing manifest yields no paths",
          IntegrationsStore.manifestPaths("claudeSkill",
                                          manifest: tmp.appendingPathComponent("nope.json")).isEmpty)

    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - Noticing a new account without polling for it

// `tally add` finishes a login and the app used to learn about it on the next timer tick (a minute
// at best, five by default). A filesystem watcher closes that gap, but the config dirs are among the
// busiest directories on the machine: `.claude.json` is rewritten constantly by every session and
// `projects/` is a shared symlink. So the event only ever buys a cheap local discovery pass, and
// only a discovery pass whose ANSWER differs buys a refresh. Both filters are asserted here, because
// getting either wrong turns typing into usage-API traffic.
let watchHome = "/Users/x"
check("a config dir is worth looking at",
      accountDirEventIsInteresting(path: "/Users/x/.claude3", home: watchHome))
check("so is something written inside one",
      accountDirEventIsInteresting(path: "/Users/x/.claude3/projects/foo", home: watchHome))
check("and a codex home too",
      accountDirEventIsInteresting(path: "/Users/x/.codex2", home: watchHome))
// The home directory ITSELF, which is how a brand new account actually arrives: at directory
// granularity, creating `~/.claude4` is reported as a change to `~`. Rejecting this meant missing a
// login outright, and every unit test still passed until a real stream was run against it.
check("the home directory itself is, because a new account arrives as a new entry in it",
      accountDirEventIsInteresting(path: "/Users/x", home: watchHome))
// And the shape a real stream actually delivers: trailing slashes, on both the parent and the dirs.
check("the home with the trailing slash FSEvents sends is the same answer",
      accountDirEventIsInteresting(path: "/Users/x/", home: watchHome))
check("a config dir with a trailing slash too",
      accountDirEventIsInteresting(path: "/Users/x/.claude3/", home: watchHome))
check("and a noisy subtree with one is still rejected",
      !accountDirEventIsInteresting(path: "/Users/x/workspace/proj/", home: watchHome))
check("a trailing slash on the home does not change the answer",
      accountDirEventIsInteresting(path: "/Users/x/.claude", home: "/Users/x/"))
// The traffic this exists to reject: the user's actual work.
check("a source tree is not", !accountDirEventIsInteresting(path: "/Users/x/workspace/tally",
                                                            home: watchHome))
check("nor a deep path inside one",
      !accountDirEventIsInteresting(path: "/Users/x/workspace/tally/TallyCLI/Snapshot.swift",
                                    home: watchHome))
// The prefix is the SAME one discovery enumerates on (`.claude` / `.codex`, ClaudeAccounts.discover
// and CodexAccounts.discover), which is what matters: a filter narrower than discovery could hide a
// directory discovery would have found. `.claudius` diverges at the seventh character, so both
// reject it; `.claude-work` is a config dir under any name the user picks, so both accept it.
check("a name that only looks similar is not a config dir",
      !accountDirEventIsInteresting(path: "/Users/x/.claudius", home: watchHome))
check("but a custom-suffixed config dir is, exactly as discovery treats it",
      accountDirEventIsInteresting(path: "/Users/x/.claude-work", home: watchHome))
check("nor anything outside the home entirely",
      !accountDirEventIsInteresting(path: "/tmp/.claude9", home: watchHome))

// The second filter: only an account appearing or disappearing is news.
func watched(_ ids: [String], home: String = "/h") -> [ProviderAccount] {
    ids.map { ProviderAccount(id: $0, providerID: "claude", label: $0, locator: [:],
                              launchHome: home + "/" + $0) }
}
check("a new account is a change", accountSetChanged(from: watched(["a"]), to: watched(["a", "b"])))
check("an account disappearing is too",
      accountSetChanged(from: watched(["a", "b"]), to: watched(["a"])))
check("the same set is not, however busy the dirs were",
      !accountSetChanged(from: watched(["a", "b"]), to: watched(["a", "b"])))
check("and order is not identity",
      !accountSetChanged(from: watched(["a", "b"]), to: watched(["b", "a"])))
check("an account whose launch home moved IS a change",
      accountSetChanged(from: watched(["a"]), to: watched(["a"], home: "/elsewhere")))
// Identity is the id and the launch home, and deliberately nothing else. Widening it to any field
// that changes for other reasons (a nickname edited in Settings, and one day a usage number if this
// type ever grows one) would spend a refresh on news the timer already covers.
var renamed = watched(["a"])
renamed[0].label = "a nickname the user just typed"
check("a renamed account is the same account", !accountSetChanged(from: watched(["a"]), to: renamed))
// Dormancy is the exception, because it is not a field that drifts: it flips when a credential
// appears or disappears, which is the one event this watcher exists to catch. A signed-out account
// comes back from the memory with the SAME id and the same home (KnownAccounts.swift), so without
// this the login landing read as no change at all and the "Login expired" chip stayed up until the
// next poll tick (codex review, 2026-08-03).
var dormant = watched(["a"])
dormant[0].isDormant = true
check("an account signing back in is a change, though its id and home never moved",
      accountSetChanged(from: dormant, to: watched(["a"])))
check("…and so is it signing out", accountSetChanged(from: watched(["a"]), to: dormant))
check("…while a dormant account that stays dormant is not",
      !accountSetChanged(from: dormant, to: dormant))
check("nothing to nothing is nothing", !accountSetChanged(from: [], to: []))
check("the first account ever found is a change", accountSetChanged(from: [], to: watched(["a"])))
print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
