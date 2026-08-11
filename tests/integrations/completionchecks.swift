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

    // MARK: When a write is wanted.

    let other = script + "\n# a version this app did not print\n"
    check("nothing there and nothing installed before is a first install",
          IntegrationsStore.completionWriteIsWanted(existing: nil, installedBefore: false,
                                                    script: script))
    // The only way to say no to this: there is no button of its own, so a deleted file is the
    // statement, and putting it back within a launch would be a watchdog overriding a person.
    check("nothing there where we DID install is a deliberate delete, and is left alone",
          !IntegrationsStore.completionWriteIsWanted(existing: nil, installedBefore: true,
                                                     script: script))
    // The Install press is what says otherwise, and it says it by passing the flag: asserted on the
    // call site, since which press this is cannot be seen from inside the pure function.
    let installer = (try? String(contentsOf: root.appendingPathComponent(
        "Tally/Stores/IntegrationsCompletion.swift"), encoding: .utf8)) ?? ""
    check("an Install press writes even where a launch would read a delete",
          installer.contains("let installedBefore = recorded != nil && !explicit"))
    check("a file that is not ours is never written over",
          !IntegrationsStore.completionWriteIsWanted(existing: "#compdef tally\n# theirs\n",
                                                     installedBefore: false, script: script))
    check("ours and current is left exactly as it is",
          !IntegrationsStore.completionWriteIsWanted(existing: script, installedBefore: true,
                                                     script: script))
    check("ours and out of date is rewritten",
          IntegrationsStore.completionWriteIsWanted(existing: other, installedBefore: true,
                                                    script: script))
    // The spawn-avoiding first pass: with no script in hand, ours is "possibly stale, go and ask",
    // and every other case is answered without asking anybody anything.
    check("ours with the script not yet asked for is a reason to ask",
          IntegrationsStore.completionWriteIsWanted(existing: script, installedBefore: true,
                                                    script: nil))
    check("…while somebody else's file needs no question asked",
          !IntegrationsStore.completionWriteIsWanted(existing: "#compdef tally\n# theirs\n",
                                                     installedBefore: true, script: nil))

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
