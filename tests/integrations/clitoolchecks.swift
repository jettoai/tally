import Foundation

// The command line tool row, and the one question a status word cannot answer: WHOSE FILE IS AT
// /usr/local/bin/tally (IntegrationsCLITool.swift).
//
// `tally` is a name, not a claim. That directory is shared with everything else on the machine, so
// the path this integration installs into is one another program may already hold - and the row
// reads a stranger's file there as broken, which is true and is not a licence to delete it. Remove
// used to be an unconditional `removeItem`, so the press offered under that word took away a file
// this app never wrote (codex review, 2026-08-13).
//
// NOTHING HERE TOUCHES /usr/local/bin. Every assertion is made against links and files in this
// suite's own temporary directory, which is what taking the path as an argument is for.
@MainActor
func runCLIToolChecks(tmp: URL) throws {
    let fm = FileManager.default
    let dir = tmp.appendingPathComponent("clitool")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    // MARK: What is there, and what the row says about it.

    let absent = dir.appendingPathComponent("nothing")
    let absentPresence = IntegrationsStore.detectCLIToolPresence(at: absent)
    check("nothing at the path is nothing to remove",
          absentPresence == .absent && !absentPresence.mayBeRemoved
              && IntegrationsStore.detectCLITool(absentPresence) == .notInstalled)

    // Somebody else's program, under the name this integration also wants.
    let foreign = dir.appendingPathComponent("foreign-tally")
    let theirs = "#!/bin/sh\n# a tally that is not ours\necho hello\n"
    try theirs.write(to: foreign, atomically: true, encoding: .utf8)
    let foreignPresence = IntegrationsStore.detectCLIToolPresence(at: foreign)
    check("a regular file at the path is somebody else's", foreignPresence == .foreignFile)
    check("…which the row still calls broken, because ours is not installed",
          IntegrationsStore.detectCLITool(foreignPresence)
              == .broken("Not a symlink Tally manages"))
    check("…and the status alone would offer a Remove press over it",
          IntegrationsStore.detectCLITool(foreignPresence).offersRemoval)
    check("…which is exactly the press the presence takes back off the row",
          !foreignPresence.mayBeRemoved)

    // Ours: a symlink, whatever it points at.
    let target = dir.appendingPathComponent("bundled-tally")
    try "#!/bin/sh\n".write(to: target, atomically: true, encoding: .utf8)
    let link = dir.appendingPathComponent("ours")
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    check("a symlink is the shape this integration installs",
          IntegrationsStore.detectCLIToolPresence(at: link) == .link(destination: target.path)
              && IntegrationsStore.detectCLIToolPresence(at: link).mayBeRemoved)
    check("…and with its target in place the row reads installed",
          IntegrationsStore.detectCLITool(IntegrationsStore.detectCLIToolPresence(at: link))
              == .installed)

    // A link whose target has gone: broken, and STILL ours - that is the state Reinstall repairs
    // and the one Remove has to keep offering. `fileExists` follows symlinks and answers no here,
    // which is why the link is asked for before the file is.
    let dangling = dir.appendingPathComponent("dangling")
    try fm.createSymbolicLink(at: dangling,
                              withDestinationURL: dir.appendingPathComponent("app-that-moved"))
    let danglingPresence = IntegrationsStore.detectCLIToolPresence(at: dangling)
    check("a link whose target has gone is still ours to take away",
          danglingPresence.mayBeRemoved)
    check("…and reads broken for the reason that repairs it",
          IntegrationsStore.detectCLITool(danglingPresence) == .broken("Link target is missing"))

    // MARK: The removal itself, which is where the deletion happens.

    check("a Remove over somebody else's file removes nothing",
          try IntegrationsStore.removeCLISymlink(at: foreign) == false)
    check("…and the file is still there, byte for byte",
          (try? String(contentsOf: foreign, encoding: .utf8)) == theirs)
    check("a Remove over our own link takes it away",
          try IntegrationsStore.removeCLISymlink(at: link) == true)
    check("…and the link is gone", !fm.fileExists(atPath: link.path)
        && (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil)
    check("…while what it pointed at is untouched: a link is not its target",
          fm.fileExists(atPath: target.path))
    check("a dangling link of ours comes out too, which is the retry the row offers",
          try IntegrationsStore.removeCLISymlink(at: dangling) == true)
    check("removing what is not there is not an error",
          try IntegrationsStore.removeCLISymlink(at: absent) == false)

    // MARK: And the refusal is spoken, in every language Tally ships.

    // A press that deletes nothing and says nothing reads as a removal that happened: the row goes
    // on saying broken with no explanation anywhere on screen.
    let root = URL(fileURLWithPath: #filePath)          // tests/integrations/clitoolchecks.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let store = (try? String(contentsOf: root.appendingPathComponent(
        "Tally/Stores/IntegrationsCLITool.swift"), encoding: .utf8)) ?? ""
    let refusal = "/usr/local/bin/tally is not a symlink Tally installed, so nothing was removed."
    check("the store source is readable from this suite", !store.isEmpty)
    check("the refusal sets an error rather than returning quietly",
          store.contains("lastError = L(\"\(refusal)\")"))
    let catalogue = (try? Data(contentsOf: root.appendingPathComponent(
        "Tally/Resources/Localizable.xcstrings")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let localizations = (((catalogue?["strings"] as? [String: Any])?[refusal]
        as? [String: Any])?["localizations"] as? [String: Any]) ?? [:]
    check("…and that sentence is in the catalogue, in every language Tally ships",
          ["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { localizations[$0] != nil })

    // MARK: The row, which is the half a user sees.

    // The store refuses whatever the view does, but a button offered and then refused is a worse
    // row than one that never offered it: the press has to be off the screen as well as off.
    // The pane moved into a file of its own when SettingsView.swift reached the repo's 500-line cap,
    // the way the Display pane did before it.
    let settings = (try? String(contentsOf: root.appendingPathComponent(
        "Tally/Views/SettingsIntegrationsPane.swift"), encoding: .utf8)) ?? ""
    check("the settings source is readable from this suite", !settings.isEmpty)
    check("the Remove button needs the status AND the row's ownership answer",
          settings.contains("if status.offersRemoval, removable {"))
    check("…and the command line tool is the row that hands the second one in",
          settings.contains("removable: integrations.cliToolPresence.mayBeRemoved"))
}
