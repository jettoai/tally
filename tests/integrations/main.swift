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

    try? FileManager.default.removeItem(at: tmp)
}
print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
