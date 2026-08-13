import Foundation

// The tab completion that goes in with the command line tool (IntegrationsCompletion.swift).
//
// WHAT IS ASSERTED HERE is everything about that install except the process spawns: which directory
// is chosen given what the machine has, whose file may be written or deleted, and when a write is
// wanted at all. The two spawns (asking zsh for its default fpath, asking the bundled CLI for the
// script) are the parts that need a machine rather than a fixture, and every decision they feed is
// a pure function above them for exactly that reason.
//
// NOTHING HERE WRITES OUTSIDE A TEMPORARY DIRECTORY. The real destinations are system-wide and
// shared with the user's own shell, so they are named only as strings to a pure chooser.
@MainActor
func runCompletionChecks(tmp: URL) throws {
    let fm = FileManager.default

    // MARK: The directory: usable first, and a searched one ahead of a merely usable one.

    let brew = IntegrationsStore.completionDirectoryCandidates[0]
    let local = IntegrationsStore.completionDirectoryCandidates[1]
    /// The chooser with both filesystem facts defaulted to yes, so each check names only the one it
    /// is about.
    func chosen(fpath: [String], isDirectory: (String) -> Bool = { _ in true },
                isWritable: (String) -> Bool = { _ in true }) -> String? {
        IntegrationsStore.completionDirectory(fpath: fpath, isDirectory: isDirectory,
                                              isWritable: isWritable)
    }
    check("the candidates are the two site-functions prefixes, Homebrew's first",
          brew == "/opt/homebrew/share/zsh/site-functions"
              && local == "/usr/local/share/zsh/site-functions"
              && IntegrationsStore.completionDirectoryCandidates.count == 2)
    check("with both on the fpath and both present, Homebrew's prefix wins",
          chosen(fpath: [brew, local]) == brew)
    // The machine this was written on: Homebrew is installed, so its directory EXISTS, but a zsh
    // started with no configuration does not search it - and one that IS searched is right there.
    check("a searched directory beats an unsearched one that also exists",
          chosen(fpath: [local]) == local)
    check("…and one that is searched but does not exist loses to one that does",
          chosen(fpath: [brew, local], isDirectory: { $0 == local }) == local)
    // The second rank, and the reason it exists: the fpath answer comes from /bin/zsh, so a machine
    // whose login shell is Homebrew's own zsh searches a directory this process never hears about.
    // Writing nothing there would make the feature a no-op on exactly those machines.
    check("with nothing searched, a usable candidate is still taken, Homebrew's first",
          chosen(fpath: ["/usr/share/zsh/site-functions"]) == brew)
    check("…and an fpath that could not be read at all is that same case",
          chosen(fpath: []) == brew)
    // Writability is part of the choice, not something the write discovers: a root-owned Homebrew
    // prefix must hand the answer on rather than take it and throw.
    check("an unwritable directory is passed over for one that can be written",
          chosen(fpath: [brew, local], isWritable: { $0 == local }) == local)
    check("nowhere to put it is an answer, not a guess",
          chosen(fpath: [brew, local], isDirectory: { _ in false }) == nil)
    check("…as is a pair of directories that are all there but none of them writable",
          chosen(fpath: [brew, local], isWritable: { _ in false }) == nil)

    // MARK: Whose file this is.

    // Read off the script the binary actually prints, so the marker cannot drift from it: this is
    // the source of the constant `tallyCompletionZsh`, which the CLI target compiles and this
    // harness does not (Completion.swift lives on the other side of the seam).
    let root = URL(fileURLWithPath: #filePath)          // tests/integrations/completionchecks.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = (try? String(contentsOf: root.appendingPathComponent("TallyCLI/Completion.swift"),
                              encoding: .utf8)) ?? ""
    let script: String = {
        guard let start = source.range(of: "let tallyCompletionZsh = #\"\"\"\n"),
              let end = source.range(of: "\n\"\"\"#", range: start.upperBound ..< source.endIndex)
        else { return "" }
        return String(source[start.upperBound ..< end.lowerBound]) + "\n"
    }()
    // The extractor's own sanity first: a marker that stopped matching would find nothing and let
    // every check below pass by saying nothing about anything.
    check("the completion script was really read off its source",
          script.hasPrefix("#compdef tally\n") && script.count > 2000)
    check("the script this binary prints is recognised as ours",
          IntegrationsStore.completionFileIsOurs(script))
    check("somebody else's completion for the same command is not",
          !IntegrationsStore.completionFileIsOurs("#compdef tally\n_arguments '*: :_files'\n"))
    check("…nor is a file that carries the marker without being one",
          !IntegrationsStore.completionFileIsOurs("# tally-completion notes\n#compdef tally\n"))
    check("…nor a completion for a command whose name starts the same way",
          !IntegrationsStore.completionFileIsOurs("#compdef tallyman\n# tally-completion\n"))

    // MARK: Whose CLI is on the PATH at all.
    //
    // The launch-time pass writes beside a command THIS app installed and no other. `detectCLITool`
    // cannot answer that - it asks whether a symlink's target exists, and a Homebrew tally says yes,
    // which had the app writing into a shared directory for somebody who never pressed anything of
    // ours (review, 2026-08-11).

    let link = "/usr/local/bin/tally"
    let bundled = "/Applications/Tally.app/Contents/Helpers/tally"
    check("a link pointing at the CLI inside this bundle is ours",
          IntegrationsStore.cliToolIsOurs(recorded: [], destination: bundled, bundled: bundled,
                                          link: link))
    check("…and one we recorded is ours even after the app moved out from under it",
          IntegrationsStore.cliToolIsOurs(recorded: [link],
                                          destination: "/Volumes/Old/Tally.app/Contents/Helpers/tally",
                                          bundled: bundled, link: link))
    check("a package manager's tally is not this app's, however installed it looks",
          !IntegrationsStore.cliToolIsOurs(recorded: [],
                                           destination: "/opt/homebrew/Cellar/tally/1.0/bin/tally",
                                           bundled: bundled, link: link))
    check("…and a record of some OTHER path does not make it ours either",
          !IntegrationsStore.cliToolIsOurs(recorded: ["/opt/homebrew/bin/tally"],
                                           destination: "/opt/homebrew/Cellar/tally/1.0/bin/tally",
                                           bundled: bundled, link: link))
    check("…nor does a real file somebody put there, which is no symlink at all",
          !IntegrationsStore.cliToolIsOurs(recorded: [link], destination: nil, bundled: bundled,
                                           link: link))
    let installer = (try? String(contentsOf: root.appendingPathComponent(
        "Tally/Stores/IntegrationsCompletion.swift"), encoding: .utf8)) ?? ""
    // Asked in ONE place, which is the place both entrances go through: a second gate in
    // `autoUpdateCompletion` would be a second spelling of the same rule, free to drift from it.
    check("the install refuses outright to work beside a CLI this app did not put there",
          installer.contains(
              "guard !BuildVariant.isUnshipped, Self.cliToolIsAppManaged() else { return }"))

    // MARK: Whose file this is - the manifest, and nothing else.
    //
    // The marker is in the script the binary PRINTS, so a Homebrew formula shipping that output, or
    // a user who ran the line the row itself offers, has a byte-identical file. Reading the marker as
    // ownership meant recording their path and deleting their file on uninstall (review, 2026-08-11).

    let other = script + "\n# a version this app did not print\n"
    let theirsByHand = script       // the official output, installed by somebody who is not us
    check("a byte-identical file we never recorded is still not ours to write over",
          !IntegrationsStore.completionMayBeWritten(existing: theirsByHand, ownedHere: false,
                                                    explicit: false))
    check("…not even on an Install press, which is the one thing that overrides a deletion",
          !IntegrationsStore.completionMayBeWritten(existing: theirsByHand, ownedHere: false,
                                                    explicit: true))
    check("…and it looks exactly like ours, which is why the marker cannot be the deed",
          IntegrationsStore.completionFileIsOurs(theirsByHand))
    check("a path we recorded, still carrying our shape, is rewritten",
          IntegrationsStore.completionMayBeWritten(existing: other, ownedHere: true,
                                                   explicit: false))
    check("…and one we recorded that somebody has since replaced is left alone",
          !IntegrationsStore.completionMayBeWritten(existing: "#compdef tally\n# theirs now\n",
                                                    ownedHere: true, explicit: false))
    check("nothing there and nothing of ours recorded is a first install",
          IntegrationsStore.completionMayBeWritten(existing: nil, ownedHere: false, explicit: false))
    // The only way to say no to this: there is no button of its own, so a deleted file is the
    // statement, and putting it back within a launch would be a watchdog overriding a person.
    check("nothing there where we DO hold the path is a deliberate delete, and is left alone",
          !IntegrationsStore.completionMayBeWritten(existing: nil, ownedHere: true, explicit: false))
    check("…which an Install press, and only an Install press, overrides",
          IntegrationsStore.completionMayBeWritten(existing: nil, ownedHere: true, explicit: true))
    // The hard constraint, asserted where it is kept: a path reaches the manifest only after this
    // app was allowed to write it, and the branch that walks away from somebody else's file stamps
    // the reconciliation while claiming no path at all.
    check("the write, and the record that follows it, are behind that one question",
          installer.contains("guard Self.completionMayBeWritten(existing: existing, ownedHere: ownedHere,"))
    check("…and a file that is not ours is stamped without a path being claimed",
          installer.contains("if !ownedHere { recordManifest(Self.completionManifest, paths: []) }"))
    check("…with the deed itself read off the manifest, path by path",
          installer.contains("let ownedHere = recorded.contains(file.path)"))

    // MARK: The race between an Install still running and a Remove pressed on top of it.
    //
    // The install hands the main actor back twice while it waits on child processes. A Remove in
    // that window deleted nothing (no manifest yet) and then watched the install put the completion
    // back beside a command that was gone (review, 2026-08-11). Structural, so it is asserted
    // structurally: the same question is asked again after the last await, and nothing between that
    // question and the write may suspend.
    let installBody = installer.components(separatedBy: "func installCompletion").last ?? ""
    let lastAwait = installBody.range(of: "await Self.completionScript()")
    let recheck = installBody.range(of: "guard !Task.isCancelled, Self.cliToolIsAppManaged() else { return }")
    let write = installBody.range(of: "try Self.writeCompletion(script, to: file)")
    check("the body of the install was really found, and all three landmarks in it",
          !installBody.isEmpty && lastAwait != nil && recheck != nil && write != nil)
    if let lastAwait, let recheck, let write {
        check("the write is guarded again after the last await, so a Remove pressed meanwhile wins",
              lastAwait.upperBound < recheck.lowerBound && recheck.upperBound < write.lowerBound)
        check("…and nothing between that guard and the write can hand the actor to anybody else",
              !installBody[recheck.upperBound ..< write.lowerBound].contains("await"))
    }
    // The two presses this task hangs off live with the command they install (clitoolchecks.swift).
    let store = (try? String(contentsOf: root.appendingPathComponent(
        "Tally/Stores/IntegrationsCLITool.swift"), encoding: .utf8)) ?? ""
    check("the install is held rather than let go, so there is something to call off",
          store.contains("completionTask = Task { await installCompletion(explicit: true) }"))
    check("…and Remove calls it off before it takes the command away",
          store.contains("completionTask?.cancel()"))

    // MARK: The launch-time gate, which has to cost nothing in the steady state.

    check("a machine that has never been reconciled is looked at",
          IntegrationsStore.completionNeedsReconciling(stamp: nil, version: "1.2", recorded: [],
                                                       exists: { _ in true }))
    check("…and so is one stamped by an older app, because its CLI is newer than its script",
          IntegrationsStore.completionNeedsReconciling(stamp: "1.1", version: "1.2", recorded: [],
                                                       exists: { _ in true }))
    check("the current stamp over a file we still hold is the steady state: no reads, no processes",
          !IntegrationsStore.completionNeedsReconciling(stamp: "1.2", version: "1.2",
                                                        recorded: ["\(brew)/_tally"],
                                                        exists: { _ in true }))
    // The case the stamp exists for: somebody else owns the `_tally` here, so there is nothing to
    // maintain - and without a stamp of its own every launch would go and ask the CLI about it.
    check("…and so is the current stamp over nothing at all, which is a file that is not ours",
          !IntegrationsStore.completionNeedsReconciling(stamp: "1.2", version: "1.2", recorded: [],
                                                        exists: { _ in false }))
    check("a file we hold that has gone missing is looked at again",
          IntegrationsStore.completionNeedsReconciling(stamp: "1.2", version: "1.2",
                                                       recorded: ["\(brew)/_tally"],
                                                       exists: { _ in false }))

    // MARK: The line the row offers when this could not be done for them.

    let manualInstall = "Tab completion is not installed here; add it with: "
        + "[[ -e \"${fpath[1]}/_tally\" ]] || tally completion zsh > \"${fpath[1]}/_tally\""
    check("the hand-install line the caption shows is this one, spelled the same way",
          installer.contains(
              "L(\"" + manualInstall.replacingOccurrences(of: "\"", with: "\\\"") + "\")"))
    // The reason it is not a bare redirect: the commonest reason this sentence is on screen is that
    // a file IS there, and `>` truncates it - before the command that would refill it has even run.
    check("…refusing a file that is already there rather than truncating it",
          manualInstall.contains("[[ -e \"${fpath[1]}/_tally\" ]] ||"))
    check("…and never offering the redirect on its own",
          !installer.contains("add it with: tally completion zsh >"))
    // Four translations, the same list `AppLocaleSupported` names in the supervisor suite: a string
    // that reaches a person in English on a Japanese machine is a missing translation nobody notices.
    let catalogue = (try? Data(contentsOf: root.appendingPathComponent(
        "Tally/Resources/Localizable.xcstrings")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let strings = catalogue?["strings"] as? [String: Any] ?? [:]
    check("the string catalogue is readable from this suite", !strings.isEmpty)
    let localizations = ((strings[manualInstall] as? [String: Any])?["localizations"]
        as? [String: Any]) ?? [:]
    let shipped = ["zh-Hant", "zh-Hans", "ja", "ko"]
    check("…and the sentence is in it, in every language Tally ships",
          shipped.allSatisfy { localizations[$0] != nil })
    check("…with the line they are told to run carried through each of them",
          shipped.allSatisfy { language in
              let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
              return (unit?["value"] as? String)?.contains("[[ -e \"${fpath[1]}/_tally\" ]] ||") == true
          })

    // MARK: Writing and removing, in a directory of this test's own.

    let dir = tmp.appendingPathComponent("site-functions")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent(IntegrationsStore.completionFileName)
    check("the file is the name zsh autoloads from", file.lastPathComponent == "_tally")
    check("a first write reports the change", try IntegrationsStore.writeCompletion(script, to: file))
    check("…and puts the script there byte for byte",
          (try String(contentsOf: file, encoding: .utf8)) == script)
    let mode = (try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
    check("…readable by every shell on the machine, not just this user", mode == 0o644)
    check("writing the same script again changes nothing",
          try IntegrationsStore.writeCompletion(script, to: file) == false)
    check("a newer script replaces it", try IntegrationsStore.writeCompletion(other, to: file))

    check("removal takes away a file we wrote", try IntegrationsStore.removeCompletionFile(at: file))
    check("…and it is gone", !fm.fileExists(atPath: file.path))
    check("removing what is not there is not an error",
          try IntegrationsStore.removeCompletionFile(at: file) == false)
    let theirs = "#compdef tally\n# hand-rolled, years old\n"
    try theirs.write(to: file, atomically: true, encoding: .utf8)
    check("a completion somebody else wrote survives our uninstall",
          try IntegrationsStore.removeCompletionFile(at: file) == false
              && (try String(contentsOf: file, encoding: .utf8)) == theirs)
}
