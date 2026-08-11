import Foundation

// The tab completion that arrives with the command, because a completion nobody installs completes
// nothing.
//
// `tally completion zsh` prints the script, and printing it was the whole of the feature: it asked
// the one person who already knew about it to redirect it into a directory they had to know the
// name of. So the install that puts `tally` on the PATH puts the completion beside it, the uninstall
// takes it away again, and an app update rewrites it, because a script and the binary it questions
// have to be of one version (Completion.swift says why).
//
// WRITTEN INTO A SITE-FUNCTIONS DIRECTORY, AND NOWHERE ELSE. This never edits a shell profile: the
// shim's PATH line is a marked block precisely because a user's own file is theirs, and a completion
// needs no such edit - a file dropped into a site-functions directory that is on the fpath is picked
// up by the next `compinit` with nothing else said, and which of the two prefixes that is gets asked
// rather than assumed (`completionDirectory`). If neither exists, or neither is writable, this does
// nothing at all: no privilege prompt, no sudo, no error dialog. The Settings row says the
// completion is not there and gives the one line that installs it by hand, which is exactly the
// state of the world before this file existed.
extension IntegrationsStore {
    // MARK: What and where

    /// The file name zsh autoloads a completion for `tally` from: the `#compdef tally` tag inside
    /// the script and this name are the two halves of the same registration.
    nonisolated static let completionFileName = "_tally"

    /// The manifest component, so the uninstall deletes what THIS app wrote and nothing else.
    nonisolated static let completionManifest = "cliCompletion"

    /// The word in the script's header that says a file on disk came out of THIS BINARY - which is
    /// not the same as saying it was put there by this app, because the binary prints the script to
    /// anybody who runs `tally completion zsh`. What it is actually good for is noticing that a file
    /// we did record has since been replaced by somebody else's (`completionFileIsOurs`); the
    /// manifest is what says whose the file is.
    nonisolated static let completionMarker = "tally-completion"

    /// Where a zsh completion belongs on this machine, Homebrew's prefix first.
    ///
    /// BOTH ARE CANDIDATES, NEITHER IS AN ASSUMPTION: which one a shell actually searches is asked
    /// rather than guessed (`defaultZshFpath`), and the answer ranks them (`completionDirectory`).
    nonisolated static let completionDirectoryCandidates = [
        "/opt/homebrew/share/zsh/site-functions",
        "/usr/local/share/zsh/site-functions",
    ]

    /// The directory to write into: one that exists and that this process can write, preferring one
    /// a default zsh already searches.
    ///
    /// TWO RANKS RATHER THAN ONE TEST, because the two ways of being wrong here are not the same
    /// size. A directory a default zsh searches is the one that needs nothing else said, so it wins;
    /// but the fpath answer comes from /bin/zsh, and a machine whose login shell is Homebrew's zsh
    /// has its OWN default fpath that this process cannot ask about without running that user's
    /// startup files. Refusing to write anywhere in that case would make the feature a no-op on
    /// exactly the machines that have the most completions installed, so a usable candidate that no
    /// searched one beats is still taken. Homebrew's prefix leads both ranks, because on a machine
    /// that has it, that is where every other command's completion lives.
    ///
    /// WRITABILITY IS PART OF THE CHOICE, not something discovered by the write failing: a
    /// root-owned Homebrew prefix would otherwise take the answer and then throw, leaving the
    /// perfectly good second candidate untried. Nil means there is nowhere to put this, which is a
    /// perfectly ordinary answer on a machine with no Homebrew and no `/usr/local`: the row then
    /// says so rather than the app inventing a directory and adding a line to a shell profile to
    /// make zsh look at it.
    ///
    /// Pure, with both facts about the filesystem handed in, so the choice is testable without
    /// owning either directory.
    static func completionDirectory(candidates: [String] = completionDirectoryCandidates,
                                    fpath: [String],
                                    isDirectory: (String) -> Bool,
                                    isWritable: (String) -> Bool) -> String? {
        let usable = candidates.filter { isDirectory($0) && isWritable($0) }
        return usable.first { fpath.contains($0) } ?? usable.first
    }

    /// The directories a zsh started with no configuration searches for completions.
    ///
    /// ASKED OF ZSH ITSELF rather than derived from a table here, for the reason every other reader
    /// in this app asks the thing it is about: the default fpath depends on which zsh is at
    /// /bin/zsh, on its version, and on how it was built. `-f` skips every startup file, so what
    /// comes back is the default rather than this user's assembled one; FPATH is removed from the
    /// child's environment for the same reason, since an inherited value would answer for whoever
    /// launched this app rather than for the shell they will type in.
    static func defaultZshFpath() async -> [String] {
        guard let out = await CLIRunner.run("/bin/zsh",
                                            arguments: ["-f", "-c", "print -rl -- $fpath"],
                                            environment: ["FPATH": nil],
                                            timeout: 10), out.exitCode == 0 else { return [] }
        return out.stdout.split(separator: "\n").map(String.init)
    }

    /// The directory this machine's completion goes in, or nil.
    static func resolveCompletionDirectory() async -> String? {
        let fm = FileManager.default
        let fpath = await defaultZshFpath()
        return completionDirectory(fpath: fpath, isDirectory: { path in
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }, isWritable: { fm.isWritableFile(atPath: $0) })
    }

    /// The script, ASKED OF THE BINARY THAT WILL ANSWER IT. The completion questions the `tally` it
    /// completes (`tally completion data accounts …`), so the two have to be of one version; taking
    /// the text from the binary this install links to makes that true by construction rather than by
    /// a version constant somebody has to remember to bump.
    static func completionScript() async -> String? {
        guard FileManager.default.isExecutableFile(atPath: bundledCLIURL.path) else { return nil }
        guard let out = await CLIRunner.run(bundledCLIURL.path,
                                            arguments: ["completion", "zsh"],
                                            timeout: 10),
              out.exitCode == 0, !out.stdout.isEmpty else { return nil }
        return out.stdout
    }

    // MARK: Whose file is this, and does it need writing

    /// Whether a `_tally` on disk still has the SHAPE of the script this app writes.
    ///
    /// NOT A PROOF OF OWNERSHIP, and reading it as one was a defect: `tally completion zsh` prints
    /// this marker to anybody who asks, so a Homebrew formula shipping that output, or a user who
    /// once ran the line in the row's own caption, has a file that answers yes here. Ownership is
    /// what the MANIFEST records, and nothing else (`completionMayBeWritten`); this question is only
    /// ever asked about a file the manifest ALREADY names, where it answers a different one: has the
    /// file we wrote since been replaced by somebody else's (review, 2026-08-11).
    static func completionFileIsOurs(_ content: String) -> Bool {
        content.hasPrefix("#compdef tally\n") && content.contains(completionMarker)
    }

    /// Whether this app may put its script at that path.
    ///
    /// THE MANIFEST IS THE ONLY TITLE DEED. `ownedHere` is "this exact path is in our manifest",
    /// which is written in one place only: after a write of ours succeeded. So the rule the whole
    /// feature rests on holds by construction - a file this app never wrote is never written over
    /// and never deleted, however much it looks like ours.
    ///
    /// - `existing` nil: nothing is there. A first install writes; an absence where we DO hold the
    ///   path is somebody having deleted the file, which is the only way to say no to this (there is
    ///   no button of its own), and it is respected until an Install press says otherwise.
    /// - `existing` present and not ours to hold: left alone at any time, for any reason, INCLUDING
    ///   an Install press. The row's caption then offers a hand-install line that refuses it too.
    /// - `existing` present, ours to hold, but no longer our shape: somebody replaced our file with
    ///   theirs. It is theirs now, so it is left alone as well - and, having never been rewritten,
    ///   never re-recorded either.
    static func completionMayBeWritten(existing: String?, ownedHere: Bool, explicit: Bool) -> Bool {
        guard let existing else { return explicit || !ownedHere }
        return ownedHere && completionFileIsOurs(existing)
    }

    /// Whether the `tally` on the PATH is one THIS app put there.
    ///
    /// `detectCLITool` answers a different question - is there a symlink whose target exists - and
    /// a Homebrew install answers yes to it, so using it as the launch-time gate had the app writing
    /// into a shared directory for a user who never pressed anything of ours (review, 2026-08-11).
    ///
    /// TWO PROOFS, EITHER WILL DO. The link pointing at the CLI inside this bundle is the direct
    /// one; the manifest naming the link is the one that survives the app moving, which changes
    /// `bundledCLIURL` under a link we really did make. Neither is satisfied by a package manager's.
    static func cliToolIsOurs(recorded: [String], destination: String?, bundled: String,
                              link: String) -> Bool {
        guard let destination else { return false }     // a real file, or nothing at all
        return destination == bundled || recorded.contains(link)
    }

    /// `cliToolIsOurs` for this machine.
    static func cliToolIsAppManaged() -> Bool {
        cliToolIsOurs(recorded: manifestPaths(cliToolManifest),
                      destination: try? FileManager.default
                          .destinationOfSymbolicLink(atPath: cliSymlinkURL.path),
                      bundled: bundledCLIURL.path,
                      link: cliSymlinkURL.path)
    }

    /// Whether the launch-time pass has anything to look at, which is the gate that keeps the steady
    /// state free of processes.
    ///
    /// The stamp moves on every reconciliation, INCLUDING one that decided this app owns nothing
    /// here (`recorded` empty). That case is a machine whose `_tally` belongs to somebody else, and
    /// without a stamp of its own it would send every single launch back to ask the CLI for a script
    /// it is never going to write.
    static func completionNeedsReconciling(stamp: String?, version: String, recorded: [String],
                                           exists: (String) -> Bool) -> Bool {
        guard stamp == version else { return true }
        return recorded.contains { !exists($0) }
    }

    /// The version stamp the manifest already records for a component, which is what makes an app
    /// update the moment to look at this file again (`recordManifest` writes it on every install).
    static func manifestVersion(_ component: String, manifest url: URL = manifestURL) -> String? {
        let manifest = (try? JSONSerialization.jsonObject(
            with: (try? Data(contentsOf: url)) ?? Data())) as? [String: Any]
        return (manifest?[component] as? [String: Any])?["appVersion"] as? String
    }

    /// Whether a completion for this command is present at all: what we recorded, plus the places
    /// somebody installing by hand would have put it.
    ///
    /// DELIBERATELY WIDER THAN THE REMOVAL BELOW, and the asymmetry is the point. The question here
    /// is "does this user have completion", so a file they installed themselves answers it; the
    /// question on removal is "what did WE put outside the bundle", which only the manifest answers.
    static func detectCompletion() -> Bool {
        let paths = manifestPaths(completionManifest)
            + completionDirectoryCandidates.map { "\($0)/\(completionFileName)" }
        return paths.contains { path in
            (try? String(contentsOfFile: path, encoding: .utf8)).map(completionFileIsOurs) == true
        }
    }

    // MARK: Writing and removing

    /// Writes the script. Returns true when the file changed, so callers can stay quiet otherwise.
    @discardableResult
    static func writeCompletion(_ script: String, to file: URL) throws -> Bool {
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing == script {
            return false
        }
        try script.write(to: file, atomically: true, encoding: .utf8)
        // An atomic write creates a new file, so its mode is whatever the process umask allows:
        // this one is read by every shell on the machine, including other users' logins.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: file.path)
        return true
    }

    /// Deletes a completion file, and only one we wrote. Returns whether anything was removed.
    @discardableResult
    static func removeCompletionFile(at file: URL) throws -> Bool {
        guard let content = try? String(contentsOf: file, encoding: .utf8),
              completionFileIsOurs(content) else { return false }
        try FileManager.default.removeItem(at: file)
        return true
    }

    /// The Settings caption for the command line tool row.
    ///
    /// The completion has no row of its own, so this is where it gets mentioned, and only where it
    /// is missing: a machine with no writable site-functions directory is the ordinary case this
    /// cannot serve, and saying nothing there would leave a feature that silently did not
    /// happen. Composed here rather than in the view because the sentence is about what this store
    /// installs, and the view already asks it what is installed.
    ///
    /// THE LINE IT OFFERS REFUSES A FILE THAT IS ALREADY THERE, because the commonest reason this
    /// sentence is on screen at all is that one is: a plain `>` truncates whatever a package manager
    /// or the user put at that path, and truncates it BEFORE `tally completion zsh` has run, so a
    /// binary that then fails leaves an empty file where a working completion used to be (review,
    /// 2026-08-11). Written on one line with `L(` because a key split across lines is a key the
    /// interpolation lock cannot see (localizationchecks.swift).
    var cliToolCaption: String {
        let base = L("Links the tally command into /usr/local/bin so any terminal can use it.")
        guard cliToolStatus == .installed, !completionInstalled else { return base }
        return base + " "
            + L("Tab completion is not installed here; add it with: [[ -e \"${fpath[1]}/_tally\" ]] || tally completion zsh > \"${fpath[1]}/_tally\"")
    }

    // MARK: The two moments it happens

    /// Put the completion beside the command, or leave the machine exactly as it is.
    ///
    /// - Parameter explicit: an Install press, which writes even where the launch-time pass would
    ///   read an absent file as a deliberate delete.
    ///
    /// ONLY BESIDE A COMMAND THIS APP INSTALLED. The gate is `cliToolIsAppManaged`, not "is there a
    /// tally on the PATH": a Homebrew tally passes the second and nobody pressed anything of ours.
    ///
    /// EVERY FAILURE IS SILENT, on purpose. A completion is a convenience attached to an install
    /// that has already succeeded, so an unwritable directory must not surface as an error under the
    /// row that says the command line tool is installed, which it is. What the user gets instead is
    /// the row's own sentence with the hand-install line in it.
    func installCompletion(explicit: Bool) async {
        guard !BuildVariant.isUnshipped, Self.cliToolIsAppManaged() else { return }
        let recorded = Self.manifestPaths(Self.completionManifest)
        // A recorded path is preferred over a fresh choice, so a file already installed keeps being
        // rewritten where it is; a directory that has since gone (a Homebrew prefix removed) sends
        // the choice back to whatever the machine has now.
        let recordedDirectory = recorded.first
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        var directory = recordedDirectory
        if directory == nil { directory = await Self.resolveCompletionDirectory() }
        guard let directory else { return }
        let file = URL(fileURLWithPath: directory).appendingPathComponent(Self.completionFileName)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        let ownedHere = recorded.contains(file.path)
        guard Self.completionMayBeWritten(existing: existing, ownedHere: ownedHere,
                                          explicit: explicit) else {
            // Somebody else's file, and it stays somebody else's: the stamp moves so no later launch
            // asks about it again, and the record claims NO path, so the uninstall below has nothing
            // of theirs to delete. The two go together - a stamp with a path in it would be this
            // app taking title to a file it never wrote (review, 2026-08-11).
            if !ownedHere { recordManifest(Self.completionManifest, paths: []) }
            refresh()
            return
        }
        guard let script = await Self.completionScript() else { return }
        // ASKED AGAIN AFTER THE LAST AWAIT, and nothing between here and the write may suspend. The
        // press that starts this hands the main actor back twice while it waits on child processes,
        // and a Remove pressed in that window found no manifest to delete from and then watched this
        // task put the completion back beside a command that was gone (review, 2026-08-11). The same
        // predicate that decides whether to start decides whether to finish: after a Remove the
        // symlink is not there, so it answers no.
        guard !Task.isCancelled, Self.cliToolIsAppManaged() else { return }
        if existing != script {
            do { try Self.writeCompletion(script, to: file) } catch { return }
        }
        // Recorded even when nothing was written, because the record carries the app version this
        // file was last reconciled against: without the stamp moving, every launch after an update
        // would spawn the CLI again to be told the same thing. Only reachable for a path this app
        // has just written or wrote before, which is what makes the manifest a title deed.
        recordManifest(Self.completionManifest, paths: [file.path])
        refresh()
    }

    /// Take it away with the command it completes. Only what the manifest records - which is only
    /// ever a path this app wrote - and only if the bytes are still ours: a file somebody replaced
    /// in the meantime is theirs now.
    func removeCompletion() {
        guard !BuildVariant.isUnshipped else { return }
        for path in Self.manifestPaths(Self.completionManifest) {
            _ = try? Self.removeCompletionFile(at: URL(fileURLWithPath: path))
        }
        recordManifest(Self.completionManifest, paths: nil)
    }

    /// Launch-time upkeep: an app that updated itself ships a new CLI, and the script beside it asks
    /// that binary its questions, so the two move together. The same shape as `autoUpdateSkill`, and
    /// the same restraint: it never installs where nothing is installed, and never puts back a file
    /// somebody deleted.
    ///
    /// The version stamp is the gate, so the steady state costs two file reads and no process at
    /// all: same app version, everything we hold still there, nothing to do. Whether this app may
    /// write here at all is asked once, inside `installCompletion`, rather than twice with two
    /// spellings that could disagree.
    func autoUpdateCompletion() async {
        guard !BuildVariant.isUnshipped else { return }
        guard Self.completionNeedsReconciling(
            stamp: Self.manifestVersion(Self.completionManifest),
            version: BuildVariant.version ?? "dev",
            recorded: Self.manifestPaths(Self.completionManifest),
            exists: { FileManager.default.fileExists(atPath: $0) }) else { return }
        await installCompletion(explicit: false)
    }
}
