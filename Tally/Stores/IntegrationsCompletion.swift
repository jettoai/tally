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

    /// The word in the script's header that says a file on disk came out of this binary. Ownership
    /// is asked before every write and before every delete, so a `_tally` somebody else wrote (a
    /// package manager's, a hand-rolled one) is left exactly as it is.
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

    /// Whether a `_tally` on disk is one of ours. Both halves are required: the tag alone is in
    /// every completion for this command anybody could write, and the marker alone could appear in
    /// a file that is not a completion at all.
    static func completionFileIsOurs(_ content: String) -> Bool {
        content.hasPrefix("#compdef tally\n") && content.contains(completionMarker)
    }

    /// Whether to write the completion, given what is at that path.
    ///
    /// - `existing` nil: nothing is there. A first install writes; an absence where we HAVE
    ///   installed before is somebody having deleted the file, which is the only way to say no to
    ///   this (there is no button of its own), and it is respected. An Install press says otherwise
    ///   by passing `installedBefore: false`.
    /// - not ours: never touched, at any time, for any reason.
    /// - `script` nil: the binary has not been asked yet. Answering "yes, ours and possibly stale"
    ///   here is what lets the launch-time pass skip the process spawn in every case where the
    ///   answer cannot depend on the script's contents.
    static func completionWriteIsWanted(existing: String?, installedBefore: Bool,
                                        script: String?) -> Bool {
        guard let existing else { return !installedBefore }
        guard completionFileIsOurs(existing) else { return false }
        guard let script else { return true }
        return existing != script
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
    var cliToolCaption: String {
        let base = L("Links the tally command into /usr/local/bin so any terminal can use it.")
        guard cliToolStatus == .installed, !completionInstalled else { return base }
        return base + " "
            + L("Tab completion was not installed here; add it with: tally completion zsh > \"${fpath[1]}/_tally\"")
    }

    // MARK: The two moments it happens

    /// Put the completion beside the command, or leave the machine exactly as it is.
    ///
    /// - Parameter explicit: an Install press, which writes even where the launch-time pass would
    ///   read an absent file as a deliberate delete.
    ///
    /// EVERY FAILURE IS SILENT, on purpose. A completion is a convenience attached to an install
    /// that has already succeeded, so an unwritable directory must not surface as an error under the
    /// row that says the command line tool is installed, which it is. What the user gets instead is
    /// the row's own sentence with the hand-install line in it.
    func installCompletion(explicit: Bool) async {
        guard !BuildVariant.isUnshipped else { return }
        let recorded = Self.manifestPaths(Self.completionManifest).first
        // A recorded path is preferred over a fresh choice, so a file already installed keeps being
        // rewritten where it is; a directory that has since gone (a Homebrew prefix removed) sends
        // the choice back to whatever the machine has now.
        let recordedDirectory = recorded
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        var directory = recordedDirectory
        if directory == nil { directory = await Self.resolveCompletionDirectory() }
        guard let directory else { return }
        let file = URL(fileURLWithPath: directory).appendingPathComponent(Self.completionFileName)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        let installedBefore = recorded != nil && !explicit
        // Asked without the script first: the spawn below is worth avoiding on every launch where
        // nothing it could say would change the answer.
        guard Self.completionWriteIsWanted(existing: existing, installedBefore: installedBefore,
                                           script: nil),
              let script = await Self.completionScript() else { return }
        if Self.completionWriteIsWanted(existing: existing, installedBefore: installedBefore,
                                        script: script) {
            do { try Self.writeCompletion(script, to: file) } catch { return }
        }
        // Recorded even when nothing was written, because the record carries the app version this
        // file was last reconciled against: without the stamp moving, every launch after an update
        // would spawn the CLI again to be told the same thing.
        recordManifest(Self.completionManifest, paths: [file.path])
        refresh()
    }

    /// Take it away with the command it completes. Only what the manifest records, and only if the
    /// bytes are still ours: a file somebody replaced in the meantime is theirs now.
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
    /// all: same app version, file still there, nothing to do.
    func autoUpdateCompletion() async {
        guard !BuildVariant.isUnshipped, cliToolStatus == .installed else { return }
        if let recorded = Self.manifestPaths(Self.completionManifest).first,
           Self.manifestVersion(Self.completionManifest) == (BuildVariant.version ?? "dev"),
           FileManager.default.fileExists(atPath: recorded) {
            return
        }
        await installCompletion(explicit: false)
    }
}
