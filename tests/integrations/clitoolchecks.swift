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

    // MARK: A fresh Mac with no /usr/local/bin (B-3748)

    // The press used to end in the system's own sentence, "The file "tally" doesn't exist.", over
    // the Settings page. Everything here runs in this suite's temporary directory against a fake
    // executor: no password window, and nothing under /usr/local/bin.
    typealias Store = IntegrationsStore
    final class Calls: @unchecked Sendable { var list: [(Store.CLIElevatedAction, String)] = [] }
    let fresh = dir.appendingPathComponent("fresh-mac")
    try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
    let bundled = fresh.appendingPathComponent("Tally.app-helper-tally")
    try "#!/bin/sh\n".write(to: bundled, atomically: true, encoding: .utf8)

    // (a) The original failure, and that it is recognised as the administrator's to fix.
    let noBin = fresh.appendingPathComponent("usr-local-bin/tally")
    var noBinError: NSError?
    do { try Store.linkCLIDirectly(at: noBin, to: bundled) } catch { noBinError = error as NSError }
    check("a missing folder fails the plain link with Foundation's no-such-file error",
          noBinError?.domain == NSCocoaErrorDomain && noBinError?.code == NSFileNoSuchFileError)
    check("…which is the one the administrator prompt answers, and the only one",
          noBinError.flatMap { Store.linkNeedsElevation($0) } == .folderMissing)
    let readOnly = fresh.appendingPathComponent("read-only")
    try fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
    let staleLink = readOnly.appendingPathComponent("tally")
    try fm.createSymbolicLink(at: staleLink, withDestinationURL: fresh.appendingPathComponent("old-app"))
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
    var readOnlyError: NSError?
    do { try Store.linkCLIDirectly(at: staleLink, to: bundled) } catch { readOnlyError = error as NSError }
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
    check("a link we cannot replace in a folder we cannot write is the administrator's too",
          readOnlyError.flatMap { Store.linkNeedsElevation($0) } == .notWritable)
    var notADirError: NSError?
    do { try Store.linkCLIDirectly(at: bundled.appendingPathComponent("tally"), to: bundled) }
    catch { notADirError = error as NSError }
    check("anything else (a regular file where the folder should be) keeps the plain error",
          notADirError != nil && Store.linkNeedsElevation(notADirError!) == nil)

    // (b) After the fix: the administrator step makes the folder and the link.
    let calls = Calls()
    let building = Store.CLIElevator { action, prompt in
        calls.list.append((action, prompt))
        if case let .link(directory, target, link) = action {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        }
        return .done
    }
    check("the elevated install links the tool and reports success",
          Store.linkCLIElevated(at: noBin, to: bundled, block: .folderMissing, elevator: building) == .succeeded
              && (try? fm.destinationOfSymbolicLink(atPath: noBin.path)) == bundled.path)
    check("…asked exactly once, about our temporary paths only, with the folder-missing prompt",
          calls.list.count == 1
              && calls.list[0].0 == .link(directory: noBin.deletingLastPathComponent().path,
                                          target: bundled.path, link: noBin.path)
              && calls.list[0].0 != .unlink(link: noBin.path)
              && noBin.path.hasPrefix(dir.path)
              && calls.list[0].1 == L("Tally needs to create the /usr/local/bin folder and link the tally command into it."))
    check("…and a success has nothing to say",
          Store.cliInstallMessage(.succeeded, target: bundled, link: noBin) == nil)
    let readOnlyCalls = Calls()
    _ = Store.linkCLIElevated(at: noBin, to: bundled, block: .notWritable,
                              elevator: Store.CLIElevator { action, prompt in
                                  readOnlyCalls.list.append((action, prompt)); return .cancelled })
    check("a folder that exists but is not ours to write gets the other prompt",
          readOnlyCalls.list.first?.1 == L("Tally needs administrator rights to link the tally command into /usr/local/bin."))
    let liar = noBin.deletingLastPathComponent().appendingPathComponent("liar")
    check("an executor that says done while no link exists is a failure: the disk is believed",
          Store.linkCLIElevated(at: liar, to: bundled, block: .notWritable,
                                elevator: Store.CLIElevator { _, _ in .done }) == .failed)

    // (c) The password window was cancelled, (d) the privileged step failed.
    let cancelled = Store.linkCLIElevated(at: liar, to: bundled, block: .folderMissing,
                                          elevator: Store.CLIElevator { _, _ in .cancelled })
    let cancelMessage = Store.cliInstallMessage(cancelled, target: bundled, link: liar) ?? ""
    let systemSentence = noBinError?.localizedDescription ?? "?"
    check("a cancelled password window is reported as cancelled",
          cancelled == .cancelled)
    check("…in plain words plus the Terminal command, not in the system's sentence",
          cancelMessage == String(format: L("The command line tool was not installed because the administrator password request was cancelled. Press Install to try again, or run this in Terminal: %@"),
                                  Store.manualInstallCommand(target: bundled, link: liar))
              && cancelMessage.contains("sudo mkdir -p") && cancelMessage.contains(bundled.path)
              && !cancelMessage.contains(systemSentence))
    let failedOutcome = Store.linkCLIElevated(at: liar, to: bundled, block: .folderMissing,
                                              elevator: Store.CLIElevator { _, _ in .failed("execution error: boom (3)") })
    let failMessage = Store.cliInstallMessage(failedOutcome, target: bundled, link: liar) ?? ""
    check("a failed privileged step is reported as failed",
          failedOutcome == .failed)
    check("…with the command to run, and none of the executor's detail on screen",
          failMessage == String(format: L("The command line tool could not be installed with administrator rights. Run this in Terminal to install it: %@"),
                                Store.manualInstallCommand(target: bundled, link: liar))
              && !failMessage.contains("boom") && !failMessage.contains(systemSentence))

    // (e) osascript's verdict is read off its error number: the sentence is in the user's language.
    check("exit 0 is done",
          Store.elevationResult(exitCode: 0, stderr: "") == .done)
    check("error -128 is a cancel in any language",
          Store.elevationResult(exitCode: 1, stderr: "0:17: execution error: 使用者取消操作。 (-128)") == .cancelled
              && Store.elevationResult(exitCode: 1, stderr: "execution error: User canceled. (-128)") == .cancelled)
    check("any other error is a failure carrying its text for the log",
          Store.elevationResult(exitCode: 1, stderr: "execution error: boom (3)\n") == .failed("execution error: boom (3)"))

    // (f) The command the banner tells people to type has to survive their paths.
    let awkward = URL(fileURLWithPath: "/Applications/My Apps/Tally's.app/tally")
    check("a path with a space and an apostrophe is quoted as one shell word",
          Store.manualInstallCommand(target: awkward)
              == "sudo mkdir -p /usr/local/bin && sudo ln -sf '/Applications/My Apps/Tally'\\''s.app/tally' /usr/local/bin/tally")

    // (j) Somebody else's `tally` at the link path is never replaced, as root least of all.
    let strangerDir = fresh.appendingPathComponent("stranger")
    try fm.createDirectory(at: strangerDir, withIntermediateDirectories: true)
    let stranger = strangerDir.appendingPathComponent("tally")
    let strangerBody = "#!/bin/sh\necho somebody else's tally\n"
    try strangerBody.write(to: stranger, atomically: true, encoding: .utf8)
    let strangerCalls = Calls()
    let strangerOutcome = Store.linkCLIElevated(at: stranger, to: bundled, block: .notWritable,
                                                elevator: Store.CLIElevator { action, prompt in
                                                    strangerCalls.list.append((action, prompt)); return .done })
    let foreignMessage = Store.cliInstallMessage(strangerOutcome, target: bundled, link: stranger) ?? ""
    check("a regular file at the link path stops the elevated install before any password window",
          strangerOutcome == .foreignFile && strangerCalls.list.isEmpty)
    check("…and the other program's file is still there, byte for byte",
          (try? String(contentsOf: stranger, encoding: .utf8)) == strangerBody
              && (try? fm.destinationOfSymbolicLink(atPath: stranger.path)) == nil)
    check("…the banner says it was left alone and gives the next step: look at it, move it aside, press Install",
          foreignMessage == String(format: L("Another program already has a file named tally in /usr/local/bin. Tally did not touch it, so the command line tool was not installed. To see what it is, run “%@” in Terminal. If you do not need it, move it aside with “%@”; if a file named tally.old is already there, Terminal asks before replacing it. Then press Install."),
                                   "ls -l \(stranger.path)", "sudo mv -i \(stranger.path) \(stranger.path).old")
              && foreignMessage.contains("ls -l ") && foreignMessage.contains("sudo mv -i ") && !foreignMessage.contains("sudo mv /usr/local")
              && foreignMessage.contains("tally.old")
              && !foreignMessage.contains("ln -sf") && !foreignMessage.contains("sudo rm") && !foreignMessage.contains("boom"))
    check("a file that appears after that look is caught by the guard's verdict, not believed away",
          Store.linkCLIElevated(at: liar, to: bundled, block: .notWritable,
                                elevator: Store.CLIElevator { _, _ in .foreignFile }) == .foreignFile
              && Store.elevationResult(exitCode: 1, stderr: "7:66: execution error: \(Store.foreignFileMarker) (3)") == .foreignFile)

    // The guard itself is shell, so it is run as shell: the exact script the administrator would
    // run, handed to /bin/sh as the same argument list, against files in this directory.
    func runScript(_ script: String, _ args: [String]) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh"] + args
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "\(error)") }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }
    let guarded = runScript(Store.linkScript, [strangerDir.path, bundled.path, stranger.path])
    check("the privileged script refuses a regular file with status 3 and the marker the parser reads",
          guarded.status == 3 && guarded.stderr.contains(Store.foreignFileMarker)
              && Store.elevationResult(exitCode: 1, stderr: guarded.stderr) == .foreignFile)
    check("…and leaves it untouched",
          (try? String(contentsOf: stranger, encoding: .utf8)) == strangerBody)
    let scriptFolder = fresh.appendingPathComponent("script-new/bin")
    let scriptLink = scriptFolder.appendingPathComponent("tally")
    check("the same script makes a missing folder and the link",
          runScript(Store.linkScript, [scriptFolder.path, bundled.path, scriptLink.path]).status == 0
              && (try? fm.destinationOfSymbolicLink(atPath: scriptLink.path)) == bundled.path)
    let movedApp = fresh.appendingPathComponent("moved-app-tally")
    check("…and replaces a symlink of ours, which is the reinstall",
          { _ = try? fm.removeItem(atPath: scriptLink.path)
              _ = try? fm.createSymbolicLink(at: scriptLink, withDestinationURL: movedApp)
              return runScript(Store.linkScript, [scriptFolder.path, bundled.path, scriptLink.path]).status == 0
                  && (try? fm.destinationOfSymbolicLink(atPath: scriptLink.path)) == bundled.path }())
    check("a dangling symlink is ours too, not a file in the way",
          { _ = try? fm.removeItem(atPath: scriptLink.path)
              _ = try? fm.createSymbolicLink(at: scriptLink, withDestinationURL: fresh.appendingPathComponent("gone"))
              return runScript(Store.linkScript, [scriptFolder.path, bundled.path, scriptLink.path]).status == 0 }())
    check("the removal script takes a symlink and never a regular file",
          runScript(Store.unlinkScript, [scriptLink.path]).status == 0
              && (try? fm.destinationOfSymbolicLink(atPath: scriptLink.path)) == nil
              && runScript(Store.unlinkScript, [stranger.path]).status == 0
              && (try? String(contentsOf: stranger, encoding: .utf8)) == strangerBody)

    // (i) Remove over a folder only the administrator can write.
    let unlinkCalls = Calls()
    let unlinker = Store.CLIElevator { action, prompt in
        unlinkCalls.list.append((action, prompt))
        if case let .unlink(link) = action { try? FileManager.default.removeItem(atPath: link) }
        return .done
    }
    try fm.createSymbolicLink(at: liar, withDestinationURL: bundled)
    check("the elevated removal takes the link away and reports success",
          Store.unlinkCLIElevated(at: liar, elevator: unlinker) == .succeeded
              && (try? fm.destinationOfSymbolicLink(atPath: liar.path)) == nil
              && unlinkCalls.list.count == 1 && unlinkCalls.list[0].0 == .unlink(link: liar.path))
    try fm.createSymbolicLink(at: liar, withDestinationURL: bundled)
    check("a removal that left the link in place is a failure whatever the executor said",
          Store.unlinkCLIElevated(at: liar, elevator: Store.CLIElevator { _, _ in .done }) == .failed)
    let removeMessage = Store.cliRemoveMessage(.cancelled, link: liar) ?? ""
    let removeFailMessage = Store.cliRemoveMessage(.failed, link: liar) ?? ""
    check("…and a refused removal names the command, not the system's sentence",
          removeMessage.contains("sudo rm") && removeMessage.contains(liar.path)
              && Store.cliRemoveMessage(.succeeded, link: liar) == nil)
    check("…a cancelled password window and a failed one each say why, and both say what to do next",
          removeMessage.contains("password request was cancelled") && removeMessage.contains("Press Remove")
              && removeFailMessage.contains("could not remove it without administrator rights")
              && removeFailMessage.contains("Press Remove") && removeFailMessage.contains("sudo rm")
              && removeMessage != removeFailMessage)

    // (g) Every sentence the user can read is in the catalogue, in every language Tally ships.
    let newKeys = [
        "Tally needs to create the /usr/local/bin folder and link the tally command into it.",
        "Tally needs administrator rights to link the tally command into /usr/local/bin.",
        "Tally needs administrator rights to remove the tally command from /usr/local/bin.",
        "The command line tool was not installed because the administrator password request was cancelled. Press Install to try again, or run this in Terminal: %@",
        "The command line tool could not be installed with administrator rights. Run this in Terminal to install it: %@",
        "The command line tool was not removed because the administrator password request was cancelled. Press Remove to try again, or run this in Terminal: %@",
        "The command line tool was not removed because Tally could not remove it without administrator rights. Press Remove to try again, or run this in Terminal: %@",
        "Another program already has a file named tally in /usr/local/bin. Tally did not touch it, so the command line tool was not installed. To see what it is, run “%@” in Terminal. If you do not need it, move it aside with “%@”; if a file named tally.old is already there, Terminal asks before replacing it. Then press Install.",
    ]
    let strings = catalogue?["strings"] as? [String: Any] ?? [:]
    check("the administrator-prompt sentences are translated into every shipped language",
          newKeys.allSatisfy { key in
              let loc = ((strings[key] as? [String: Any])?["localizations"] as? [String: Any]) ?? [:]
              return ["zh-Hant", "zh-Hans", "ja", "ko", "tr"].allSatisfy { loc[$0] != nil }
          })

    // (h) The shape of the privileged command and of the press.
    check("paths and the prompt reach AppleScript as argv, never spliced into its source",
          store.contains("quoted form of (item 1 of argv)") && store.contains("last item of argv")
              && !store.contains("ln -sfh \\(") && !store.contains("mkdir -p \\(directory"))
    check("a failure that is not the administrator's keeps the plain sentence, and the other one does not",
          store.contains("guard let block = Self.linkNeedsElevation(error) else { throw error }"))
    // (k) `-TallyCLIInstallPreview`: the four failure banners on the page without a password window.
    let tool = "/Applications/Tally.app/Contents/Helpers/tally"
    let previews = ["cancelled", "failed", "foreign", "remove-failed"].map { Store.cliInstallPreviewMessage($0) }
    check("each preview name has a banner, and each banner is a different one",
          previews.allSatisfy { $0 != nil } && Set(previews.compactMap { $0 }).count == 4)
    check("the cancelled and failed previews are the real banners over the release app's tool",
          previews[0] == Store.cliInstallMessage(.cancelled, target: URL(fileURLWithPath: tool))
              && previews[1] == Store.cliInstallMessage(.failed, target: URL(fileURLWithPath: tool))
              && previews[0]?.contains(tool) == true)
    check("the foreign-file and remove previews are the real ones, with their commands or lack of one",
          previews[2] == Store.cliInstallMessage(.foreignFile, target: URL(fileURLWithPath: tool))
              && previews[2]?.contains("ln -sf") == false && previews[2]?.contains("ls -l /usr/local/bin/tally") == true
              && previews[3]?.contains("sudo rm /usr/local/bin/tally") == true)
    check("an unknown preview name shows nothing", Store.cliInstallPreviewMessage("boom") == nil)
    let pane = settings
    let paneSplit = pane.components(separatedBy: "    #else\n")
    check("the preview flag is read only in the Debug branch, behind the dev-or-demo gate",
          paneSplit.count == 2
              && paneSplit[0].contains("value(\"TallyCLIInstallPreview\")")
              && paneSplit[0].contains("guard DemoUsage.isActive || BuildVariant.isDev else { return nil }"))
    check("a release build compiles the preview to nil",
          paneSplit.count == 2
              && paneSplit[1].contains("static var cliInstallPreview: String? { nil }")
              && !paneSplit[1].contains("TallyCLIInstallPreview"))
    let capture = (try? String(contentsOf: root.appendingPathComponent("Tally/Core/CaptureLaunch.swift"),
                               encoding: .utf8)) ?? ""
    check("the flag is registered with the capture family",
          capture.contains("\"TallyCLIInstallPreview\""))
    check("Install all hands the rest of the set to the install, so they wait for the link",
          settings.contains("installCLITool(followedBy: Array(missing.dropFirst()))"))

    // (m) B-3749 P4: a failed install keeps its banner through Install all's follow-ups, which clear
    // the error line on their way in. Driven through the shared store; refresh() only reads.
    let live = IntegrationsStore.shared
    live.lastError = nil
    live.settleCLIInstall(failure: NSError(domain: "tally", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "link failed",
    ]), followUps: [{ live.lastError = nil }])
    check("a failed install still shows its error after a follow-up that clears the line",
          live.lastError == "link failed")
    live.lastError = nil
    live.settleCLIInstall(failure: nil, followUps: [])
    check("a successful install leaves the error line empty", live.lastError == nil)

    // (n) B-4197: the failure banner is remembered as the CLI's own, so a later refresh can take back
    // that text (and only that text) once the link exists. refresh() reads the real disk, so the
    // clearing is asserted as source and the remembering by driving the store.
    live.settleCLIInstall(failure: NSError(domain: "tally", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "link failed",
    ]), followUps: [])
    check("a failed install remembers its banner text as the CLI install's own",
          live.cliInstallErrorText == "link failed")
    live.lastError = nil
    live.cliInstallErrorText = nil
    let storeMain = (try? String(contentsOf: root.appendingPathComponent(
        "Tally/Stores/IntegrationsStore.swift"), encoding: .utf8)) ?? ""
    check("refresh clears the CLI install banner only when the link exists and the line still says it",
          storeMain.contains("if let text = cliInstallErrorText, cliToolStatus == .installed {")
              && storeMain.contains("if lastError == text { lastError = nil }"))
    check("the page looks again when it comes up and when the app returns to the front while shown",
          settings.contains("NSApplication.didBecomeActiveNotification")
              && settings.contains(".onChange(of: section) { if section == .integrations { integrations.refresh() } }")
              && settings.contains(".onAppear { integrations.refresh() }"))
    let harnessRow = (try? String(contentsOf: root.appendingPathComponent("Tally/Views/SettingsCodexHarness.swift"),
                                  encoding: .utf8)) ?? ""
    check("the Harness row inspects again on the same return to the front",
          harnessRow.contains("NSApplication.didBecomeActiveNotification") && harnessRow.contains("if active { harness.inspect() }"))

    // (o) B-4195: the password sentence is asked of the folder BEFORE the press, off the main thread.
    let probe = tmp.appendingPathComponent("probe-bin")
    try fm.createDirectory(at: probe, withIntermediateDirectories: true)
    check("a writable folder needs no administrator", Store.expectedLinkBlock(directory: probe) == nil)
    check("a folder that is not there needs one",
          Store.expectedLinkBlock(directory: tmp.appendingPathComponent("no-such-bin")) != nil)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: probe.path)
    check("a folder this user cannot write needs one",
          Store.expectedLinkBlock(directory: probe) != nil)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
    check("the page says it only while the tool is not installed and the folder needs the password",
          settings.contains("let asksPassword = cliStatus != .installed")
              && settings.contains("integrations.cliNeedsAdministrator")
              && settings.contains("if asksPassword {"))
    check("the probe runs detached, never on the main thread",
          storeMain.contains("await Task.detached { Self.expectedLinkBlock() != nil }.value"))

    // (p) B-4196: what the hover says is what Install all does.
    let wholeSet = settings.components(separatedBy: "private func allIntegrationEntries").last?
        .components(separatedBy: "private func installAllActions").first ?? ""
    check("Install all's set leaves out the shared harness, as its hover says",
          !wholeSet.isEmpty && !wholeSet.contains("SharedHarness"))
    check("…and the hover names both rows left out, each of which says so on its own row",
          settings.contains("except Shared harness and Harness tools, which each have their own Install button")
              && settings.contains("Not part of Install all. Use this row's Install button.")
              && harnessRow.contains("Not part of Install all. Use this row's Install button."))
}
