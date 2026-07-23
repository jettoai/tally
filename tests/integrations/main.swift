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

    try? FileManager.default.removeItem(at: tmp)
}
print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
