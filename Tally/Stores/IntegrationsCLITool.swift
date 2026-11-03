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
        /// has always read it as installed. `cliToolIsAppManaged` is the stricter title deed (our own
        /// bundle, or the manifest plus our signature on what the link points at) and is what the
        /// completion install gates on; using it here
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

    /// - Parameter followUps: what "Install all" wants to run after this one. They need the link to
    ///   exist (`guardCLIDeliverable`), so on a machine that has to ask for the administrator's
    ///   password first they wait for the answer instead of running into a link not yet made.
    func installCLITool(followedBy followUps: [() -> Void] = []) {
        guard guardNotDev() else { return }
        guard cliElevationTask == nil else { return }   // the password window is already up
        lastError = nil
        do {
            guard FileManager.default.fileExists(atPath: Self.bundledCLIURL.path) else {
                throw NSError(domain: "tally", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("This build does not bundle the CLI"),
                ])
            }
            do {
                try Self.linkCLIDirectly(to: Self.bundledCLIURL)
            } catch {
                // A fresh Mac has no /usr/local/bin, and Foundation reports that as "The file
                // "tally" doesn't exist." (B-3748). Ask the system for the administrator instead.
                guard let block = Self.linkNeedsElevation(error) else { throw error }
                startElevatedInstall(block: block, followUps: followUps)
                return
            }
            finishCLIInstall()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        followUps.forEach { $0() }
    }

    private func finishCLIInstall() {
        recordManifest(Self.cliToolManifest, paths: [Self.cliSymlinkURL.path])
        // Tab completion goes in with the command, not through a button of its own: it is the
        // same integration, and one nobody knows to ask for (IntegrationsCompletion.swift).
        // Detached from the press because it asks two processes for their answers; the link
        // above is already installed and the row already says so. HELD, so the Remove button
        // can call it off - it is still running long after this press returns.
        completionTask = Task { await installCompletion(explicit: true) }
    }

    private func startElevatedInstall(block: CLILinkBlock, followUps: [() -> Void]) {
        let target = Self.bundledCLIURL
        cliElevationTask = Task {
            let outcome = await Task.detached { Self.linkCLIElevated(to: target, block: block) }.value
            cliElevationTask = nil
            if outcome == .succeeded { finishCLIInstall() }
            refresh()
            followUps.forEach { $0() }
            // After the follow-ups, which clear the error line on their way in.
            if let message = Self.cliInstallMessage(outcome, target: target) { lastError = message }
        }
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
        guard cliElevationTask == nil else { return }
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
            // The link an elevated install made sits in a folder only the administrator can write.
            if Self.linkNeedsElevation(error) == .notWritable {
                startElevatedRemoval()
                return
            }
            lastError = error.localizedDescription
        }
        refresh()
    }

    private func startElevatedRemoval() {
        cliElevationTask = Task {
            let outcome = await Task.detached { Self.unlinkCLIElevated() }.value
            cliElevationTask = nil
            if outcome == .succeeded {
                recordManifest(Self.cliToolManifest, paths: nil)
            } else {
                lastError = Self.cliRemoveMessage(outcome)
            }
            refresh()
        }
    }
}

// MARK: - The administrator prompt (B-3748)
//
// A Mac that never ran Homebrew has no /usr/local/bin, and `/usr/local` belongs to root, so the
// plain `createSymbolicLink` above cannot make it. The VS Code "install 'code' command" answer is
// the one used here: try the plain way, and only when the failure is of that kind ask the system
// for the administrator's password, once, from the press. The link cannot move to a folder of the
// user's own: the status line and the Codex hooks write `/usr/local/bin/tally` into settings.
extension IntegrationsStore {
    /// Why the plain link could not be made, which is what the password window says.
    enum CLILinkBlock: Equatable { case folderMissing, notWritable }
    /// What the privileged step reported. The detail of a failure is for logs, never for the screen.
    /// `foreignFile`: the guard in `linkScript` found a file of somebody else's at the link path.
    enum CLIElevationResult: Equatable { case done, cancelled, foreignFile, failed(String) }
    enum CLIElevatedAction: Equatable {
        case link(directory: String, target: String, link: String)
        case unlink(link: String)
    }
    /// What the user is told about, after the disk has been asked rather than the executor.
    enum CLIElevatedOutcome: Equatable { case succeeded, cancelled, foreignFile, failed }

    /// The privileged step, injectable so the suite never raises a password window.
    struct CLIElevator: Sendable {
        let run: @Sendable (_ action: CLIElevatedAction, _ prompt: String) -> CLIElevationResult
        static let administratorPrompt = CLIElevator { IntegrationsStore.runOsascript($0, $1) }
    }

    /// The plain way, exactly as the install always did it.
    nonisolated static func linkCLIDirectly(at link: URL = cliSymlinkURL, to target: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// nil when the failure is not one an administrator would fix. A link already in the way that
    /// could not be removed surfaces as "exists" from the create that follows it.
    nonisolated static func linkNeedsElevation(_ error: Error) -> CLILinkBlock? {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)
            .flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
        if posix == ENOENT { return .folderMissing }
        if posix == EACCES || posix == EPERM || posix == EEXIST { return .notWritable }
        guard ns.domain == NSCocoaErrorDomain else { return nil }
        switch ns.code {
        case NSFileNoSuchFileError: return .folderMissing
        case NSFileWriteNoPermissionError, NSFileWriteFileExistsError: return .notWritable
        default: return nil
        }
    }

    /// Makes the folder and the link as the administrator, then trusts the disk over the executor.
    nonisolated static func linkCLIElevated(at link: URL = cliSymlinkURL, to target: URL,
                                            block: CLILinkBlock,
                                            elevator: CLIElevator = .administratorPrompt) -> CLIElevatedOutcome {
        // As root, `ln -sf` would replace a program somebody else put at this path; the plain way
        // never did that from a folder it could not write. Asked before the password window opens,
        // and asked again inside the privileged script (`linkScript`) against a change in between.
        let fm = FileManager.default
        if fm.fileExists(atPath: link.path), (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil {
            return .foreignFile
        }
        let prompt = block == .folderMissing
            ? L("Tally needs to create the /usr/local/bin folder and link the tally command into it.")
            : L("Tally needs administrator rights to link the tally command into /usr/local/bin.")
        let action = CLIElevatedAction.link(directory: link.deletingLastPathComponent().path,
                                            target: target.path, link: link.path)
        switch elevator.run(action, prompt) {
        case .cancelled: return .cancelled
        case .foreignFile: return .foreignFile
        case .failed: return .failed
        case .done:
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path
                ? .succeeded : .failed
        }
    }

    /// Takes the link away as the administrator. Only ever a symlink (`[ -L ]`), like the plain way.
    nonisolated static func unlinkCLIElevated(at link: URL = cliSymlinkURL,
                                              elevator: CLIElevator = .administratorPrompt) -> CLIElevatedOutcome {
        let prompt = L("Tally needs administrator rights to remove the tally command from /usr/local/bin.")
        switch elevator.run(.unlink(link: link.path), prompt) {
        case .cancelled: return .cancelled
        case .foreignFile, .failed: return .failed
        case .done:
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil
                ? .succeeded : .failed
        }
    }

    /// The banner for an install that did not happen: plain words and the command to run instead,
    /// never the system's own message.
    nonisolated static func cliInstallMessage(_ outcome: CLIElevatedOutcome, target: URL,
                                              link: URL = cliSymlinkURL) -> String? {
        let command = manualInstallCommand(target: target, link: link)
        switch outcome {
        case .succeeded:
            return nil
        case .foreignFile:
            // No command here: the only one that would work replaces the other program.
            return L("Another program already has a file named tally in /usr/local/bin. Tally left it alone, so the command line tool was not installed.")
        case .cancelled:
            return String(format: L("The command line tool was not installed because the administrator password request was cancelled. Press Install to try again, or run this in Terminal: %@"), command)
        case .failed:
            return String(format: L("The command line tool could not be installed with administrator rights. Run this in Terminal to install it: %@"), command)
        }
    }

    nonisolated static func cliRemoveMessage(_ outcome: CLIElevatedOutcome, link: URL = cliSymlinkURL) -> String? {
        guard outcome != .succeeded else { return nil }
        return String(format: L("The command line tool was not removed. Run this in Terminal to remove it: %@"),
                      "sudo rm \(shellWord(link.path))")
    }

    /// The banner for `-TallyCLIInstallPreview <cancelled|failed|foreign|remove-failed>`
    /// (IntegrationsCapture), so each can be looked at without a password window. The same
    /// functions the real outcomes go through, on the path a release app has the tool at.
    nonisolated static func cliInstallPreviewMessage(_ name: String) -> String? {
        let tool = URL(fileURLWithPath: "/Applications/Tally.app")
            .appendingPathComponent(BuildVariant.bundledCLIRelativePath)
        switch name {
        case "cancelled": return cliInstallMessage(.cancelled, target: tool)
        case "failed": return cliInstallMessage(.failed, target: tool)
        case "foreign": return cliInstallMessage(.foreignFile, target: tool)
        case "remove-failed": return cliRemoveMessage(.failed)
        default: return nil
        }
    }

    nonisolated static func manualInstallCommand(target: URL, link: URL = cliSymlinkURL) -> String {
        "sudo mkdir -p \(shellWord(link.deletingLastPathComponent().path)) && sudo ln -sf "
            + "\(shellWord(target.path)) \(shellWord(link.path))"
    }

    /// A path as one shell word: bare when it needs no quoting, single-quoted otherwise.
    nonisolated static func shellWord(_ path: String) -> String {
        let plain = path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// osascript reports a cancelled password window as error -128; its message is in the user's
    /// language, so the number is what is read.
    nonisolated static func elevationResult(exitCode: Int32, stderr: String) -> CLIElevationResult {
        if exitCode == 0 { return .done }
        if stderr.contains("(-128)") { return .cancelled }
        if stderr.contains(foreignFileMarker) { return .foreignFile }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the administrator runs, as `sh -c <script> sh <dir> <target> <link>`. Never replaces a
    /// file that is not a symlink: a program of somebody else's at that path is left as it is.
    nonisolated static let foreignFileMarker = "tally-foreign-file"
    nonisolated static let linkScript = """
        if [ -e "$3" ] && [ ! -L "$3" ]; then echo \(foreignFileMarker) >&2; exit 3; fi; \
        /bin/mkdir -p "$1" && /bin/ln -sfh "$2" "$3"
        """
    nonisolated static let unlinkScript = #"if [ -L "$1" ]; then /bin/rm "$1"; fi"#

    /// Paths and the prompt travel as argv and are quoted by AppleScript itself, so no path can
    /// break out of the command. Waits as long as the user takes at the password window.
    nonisolated static func runOsascript(_ action: CLIElevatedAction, _ prompt: String) -> CLIElevationResult {
        let script: String
        let paths: [String]
        switch action {
        case let .link(directory, target, link):
            script = linkScript
            paths = [directory, target, link]
        case let .unlink(link):
            script = unlinkScript
            paths = [link]
        }
        // argv = [script, path..., prompt]; the AppleScript source holds none of it.
        let words = (2...paths.count + 1).map { "quoted form of (item \($0) of argv)" }
            .joined(separator: " & \" \" & ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv",
                             "-e", "do shell script \"/bin/sh -c \" & quoted form of (item 1 of argv) & \" sh \" & \(words) with prompt (last item of argv) with administrator privileges",
                             "-e", "end run", script] + paths + [prompt]
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do { try process.run() } catch { return .failed("osascript did not start: \(error)") }
        let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return elevationResult(exitCode: process.terminationStatus, stderr: text)
    }
}
