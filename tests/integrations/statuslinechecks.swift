import Foundation

// Tally's status line in a user's settings.json: the wrap that keeps THEIR status line running, the
// self-heal that survives Tally being deleted, and the two refusals that keep a file we could not
// read from being rewritten. Split from main.swift for file size.
@MainActor
func runStatusLineChecks(tmp: URL) throws {
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

    // The write that would cost a user their whole harness. Registering a status line into a
    // settings.json that does not parse (a truncated write, a hand edit gone wrong) must REFUSE:
    // reading it as an empty document and writing our one key over it replaces everything they
    // have, and the file it would eat is precisely the one already in trouble. Truncated rather
    // than trailing-comma on purpose - Foundation's parser accepts a trailing comma (verified
    // 2026-08-06), so that fixture would have asserted nothing.
    let brokenStatus = tmp.appendingPathComponent("broken-status.json")
    let brokenStatusText = "{\n  \"model\": \"opusplan\",\n  \"statusLine\": {\n"
    try brokenStatusText.write(to: brokenStatus, atomically: true, encoding: .utf8)
    var refusedStatus = false
    do { _ = try IntegrationsStore.upsertStatusLine(in: brokenStatus, command: ours) } catch {
        refusedStatus = true
    }
    let afterBrokenStatus = try String(contentsOf: brokenStatus, encoding: .utf8)
    check("an unparseable settings.json is refused, not restarted from an empty document",
          refusedStatus && afterBrokenStatus == brokenStatusText)
    // Removal goes through the same channel, so it refuses the same file the same way. Pinned as a
    // pair: neither direction may rewrite a file it could not read.
    var refusedStatusRemoval = false
    do { _ = try IntegrationsStore.removeStatusLine(in: brokenStatus, command: ours) } catch {
        refusedStatusRemoval = true
    }
    let afterBrokenRemoval = try String(contentsOf: brokenStatus, encoding: .utf8)
    check("…and uninstalling refuses it too, rather than reporting a removal that never happened",
          refusedStatusRemoval && afterBrokenRemoval == brokenStatusText)

    // The shared settings.json, from the status line's side. `tally add` symlinks every extra
    // account's settings at the main account's, and an atomic write replaces the path it is given:
    // writing to the LINK severs the sharing. Both directions have to write the target.
    let statusReal = tmp.appendingPathComponent("status-real/settings.json")
    try FileManager.default.createDirectory(at: statusReal.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
        "model": "opusplan", "statusLine": ["type": "command", "command": custom],
    ]).write(to: statusReal)
    let statusLink = tmp.appendingPathComponent("status-link/settings.json")
    try FileManager.default.createDirectory(at: statusLink.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: statusLink, withDestinationURL: statusReal)
    func linkedStatusCommand() -> String? {
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: statusReal)))
            as? [String: Any]
        return (json?["statusLine"] as? [String: Any])?["command"] as? String
    }
    _ = try IntegrationsStore.upsertStatusLine(in: statusLink, command: ours)
    check("registering a status line through a symlink writes the file it points at",
          linkedStatusCommand()?.hasPrefix("\(ours) --wrap ") == true)
    check("…and leaves the link a link",
          (try? FileManager.default.destinationOfSymbolicLink(atPath: statusLink.path))
              == statusReal.path)
    _ = try IntegrationsStore.removeStatusLine(in: statusLink, command: ours)
    check("removing through the symlink restores their command in the shared file",
          linkedStatusCommand() == custom)
    check("…without severing the link on the way out",
          (try? FileManager.default.destinationOfSymbolicLink(atPath: statusLink.path))
              == statusReal.path)
}
