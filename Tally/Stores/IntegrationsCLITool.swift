import Foundation

// The `tally` command itself: a symlink at /usr/local/bin onto the CLI inside the app bundle (the
// VS Code "install 'code' command" pattern), with tab completion going in beside it
// (IntegrationsCompletion.swift).
//
// THE ONE PATH IN THIS WHOLE SET THAT IS SHARED WITH THE REST OF THE MACHINE. Every other
// integration writes files of its own, in directories only it and the user's harness care about, so
// "is it installed" and "is it ours" are the same question there. Here they are not: `tally` is a
// name, and another program may already hold it. So what is at that path is asked as a shape rather
// than as a yes or no (`CLIToolPresence`), and the answer gates the row's Remove button AND the
// removal underneath it - a press offered under the word Remove used to delete a file this app
// never wrote (codex review, 2026-08-13).
extension IntegrationsStore {
    /// What is at `/usr/local/bin/tally`, asked once and read twice: the word the row carries, and
    /// whether a Remove press is allowed to delete what is there.
    ///
    /// The status alone cannot answer the second question, because `broken` covers two situations
    /// that want opposite answers: a link of ours whose target has gone (Remove is exactly right)
    /// and a regular file somebody else put at that path (Remove would delete a stranger's
    /// program). So both readers ask this instead, off ONE look at the filesystem, and the badge
    /// and the buttons can never disagree about what is there.
    enum CLIToolPresence: Equatable {
        /// Nothing at that path.
        case absent
        /// A symlink, which is the only shape this integration ever installs - and the only one it
        /// takes away. The destination comes with it because a link whose target has gone is still
        /// ours to remove; that is the state Reinstall repairs.
        ///
        /// Deliberately the same judgement the row's word is made on, symlink-ness and no more: a
        /// link a package manager made to its own `tally` is read as ours here, exactly as the row
        /// has always read it as installed. `cliToolIsAppManaged` is the stricter title deed (the
        /// manifest, or our own bundle) and is what the completion install gates on; using it here
        /// would let the row say "Installed" over a button that refuses, which is a worse lie than
        /// the one it would fix.
        case link(destination: String)
        /// A regular file (or a directory) at that path: somebody else's, and never deleted.
        case foreignFile

        /// Whether a Remove press may act on this. The guard is in `removeCLISymlink`; this is the
        /// same answer the row asks for, so it can leave the button off in the first place.
        var mayBeRemoved: Bool { if case .link = self { return true }; return false }
    }

    /// What is at the CLI path. Takes the path so the answer can be asserted against a test's own
    /// file rather than against the one directory this machine's users keep their programs in.
    static func detectCLIToolPresence(at url: URL = cliSymlinkURL) -> CLIToolPresence {
        let fm = FileManager.default
        // The link is asked for FIRST, because `fileExists` follows symlinks: a link of ours whose
        // target has gone answers no to it, and reading that as "nothing there" would drop the row
        // to not-installed over a dangling link still sitting on the PATH.
        if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            return .link(destination: destination)
        }
        return fm.fileExists(atPath: url.path) ? .foreignFile : .absent
    }

    /// The row's word for one presence. Pure, so what the buttons do about it is assertable.
    static func detectCLITool(_ presence: CLIToolPresence) -> Status {
        switch presence {
        case .absent:
            return .notInstalled
        case .foreignFile:
            return .broken(L("Not a symlink Tally manages"))   // a real file someone else put there
        case let .link(destination):
            return FileManager.default.fileExists(atPath: destination)
                ? .installed
                : .broken(L("Link target is missing"))
        }
    }

    /// The bundled CLI binary (Contents/Helpers/tally, embedded by the release pipeline).
    /// Internal (not private): the `/tally-account` hook is registered with an absolute path to it,
    /// so it works whether or not the /usr/local/bin link was ever installed.
    static var bundledCLIURL: URL {
        Bundle.main.bundleURL.appendingPathComponent(BuildVariant.bundledCLIRelativePath)
    }

    func installCLITool() {
        guard guardNotDev() else { return }
        lastError = nil
        let fm = FileManager.default
        do {
            guard fm.fileExists(atPath: Self.bundledCLIURL.path) else {
                throw NSError(domain: "tally", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("This build does not bundle the CLI"),
                ])
            }
            try? fm.removeItem(at: Self.cliSymlinkURL)
            try fm.createSymbolicLink(at: Self.cliSymlinkURL, withDestinationURL: Self.bundledCLIURL)
            recordManifest(Self.cliToolManifest, paths: [Self.cliSymlinkURL.path])
            // Tab completion goes in with the command, not through a button of its own: it is the
            // same integration, and one nobody knows to ask for (IntegrationsCompletion.swift).
            // Detached from the press because it asks two processes for their answers; the link
            // above is already installed and the row already says so. HELD, so the Remove button
            // can call it off - it is still running long after this press returns.
            completionTask = Task { await installCompletion(explicit: true) }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Takes the CLI link away, and REFUSES TO TAKE ANYTHING ELSE AWAY. Returns false when there
    /// was nothing of ours at that path, which is not an error: an absent link is a removal already
    /// done, and a regular file there is somebody else's program.
    ///
    /// Over the path it is handed, so the refusal can be asserted against a file on a test's own
    /// disk. This is the guard that matters, because it is where the deletion actually happens: the
    /// row leaving the button off is the courtesy, and a button that is off is one press of a stale
    /// view away from being on.
    @discardableResult
    static func removeCLISymlink(at url: URL = cliSymlinkURL) throws -> Bool {
        guard detectCLIToolPresence(at: url).mayBeRemoved else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    func removeCLITool() {
        guard guardNotDev() else { return }
        lastError = nil
        // WHOSE FILE IT IS, BEFORE ANYTHING IS TOUCHED. A row reads broken for two unlike reasons,
        // and one of them is a `tally` somebody else installed at that path: uninstalling Tally is
        // not a licence to delete another program. The refusal is out loud, because a Remove press
        // that does nothing and says nothing reads as a removal that happened - the row would go on
        // saying broken with no explanation anywhere on screen.
        //
        // Asked of the disk rather than of `cliToolPresence`, which is as old as the last refresh:
        // the file this press is about may have been replaced since the row was drawn.
        guard Self.detectCLIToolPresence() != .foreignFile else {
            lastError = L("/usr/local/bin/tally is not a symlink Tally installed, so nothing was removed.")
            refresh()
            return
        }
        do {
            // The install this press is undoing may still be in flight: it waits on two child
            // processes, so a Remove pressed straight after an Install arrives while that task is
            // suspended. Cancelling is the polite half; the half that actually holds is the task
            // re-asking whether the CLI is still ours before it writes, which this whole block
            // answers for, being one synchronous run of the main actor (IntegrationsCompletion.swift).
            completionTask?.cancel()
            removeCompletion()
            try Self.removeCLISymlink()
            recordManifest(Self.cliToolManifest, paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
