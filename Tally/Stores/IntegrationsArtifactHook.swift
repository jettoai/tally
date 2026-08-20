import Foundation

// THE LINK THAT IS DEAD BEFORE IT IS SENT, and the only thing on the machine that can see it coming.
//
// A page published by Claude Code's `Artifact` tool belongs to the Claude account that published it,
// and this app is what decides which account a session runs on. So a conversation on the wrong
// account publishes happily, finds its own page in a listing, and hands over a link that answers
// Page not found in the only browser that matters. Nothing in that sequence is visible to the
// session: the failure lands after the delivery, on the other side of a login
// (Tally/Core/ArtifactHookContract.swift argues the whole of it).
//
// So the user names the account they are signed into, and this row registers one `PreToolUse` hook
// per Claude account to hold a publish that would go out under a different one
// (TallyCLI/HookArtifact.swift answers it, and the refusal carries the way out).
//
// THE SURGERY RULES ARE THE OTHER HOOKS', one file over, and they are not optional here either:
// settings.json is the user's own file, shared by symlink across accounts on some setups, and it
// holds their whole harness. Every write is a read-modify-write over the parsed document touching
// exactly the hooks whose command runs OUR subcommand, and Claude Code runs EVERY hook registered
// under an event, so ours simply stands beside anything the user already has.
//
// ONE EVENT AND A MATCHER, which is what makes this row different from the three before it.
// `PreToolUse` fires for every tool call a session makes, and the only ones this can say anything
// about are the `Artifact` ones: without the matcher the hook would run on every Bash, Read and Edit
// in the session, several times a minute, to answer nothing.
extension IntegrationsStore {
    // The command this row registers and the marker it is recognised by are `artifactHookCommand`
    // and `artifactHookMarker`, read straight out of the contract both targets compile
    // (Tally/Core/ArtifactHookContract.swift) rather than spelled again here: the writer and the
    // answerer are in two processes, and a drift between them fails silently in both directions.

    private static func isOurArtifactHook(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.hasSuffix(artifactHookMarker) == true
    }

    private static func holdsOurArtifactHook(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { isOurArtifactHook($0) }
    }

    /// The whole entry we register: our one hook, under the `Artifact` matcher.
    ///
    /// THE MATCHER IS THE FEATURE HERE, unlike on the events the other rows register under. It is
    /// what stops a hook that has an opinion about exactly one tool from being run on every tool
    /// call in the session, and it is spelled from the same constant the CLI checks the payload's
    /// `tool_name` against, so the filter and the judgement can never disagree about which tool this
    /// is about.
    ///
    /// AN ENTRY OF ITS OWN, because an entry is where a matcher lives: putting ours into a user's
    /// entry would put their hook under our filter, or ours under theirs, in a file we are only
    /// supposed to be adding one line to.
    static func artifactHookEntry(command: String) -> [String: Any] {
        ["matcher": artifactHookToolName,
         "hooks": [["type": "command", "command": command]]]
    }

    /// Whether an entry of ours is the CURRENT registration. An install pointing at an older command,
    /// or written under a different matcher by an older version, answers false here and true to
    /// `holdsOurArtifactHook`, which is exactly the difference between "installed" and "installed
    /// correctly".
    private static func isCurrentArtifactEntry(_ entry: [String: Any], command: String) -> Bool {
        NSDictionary(dictionary: entry).isEqual(to: artifactHookEntry(command: command))
    }

    /// The settings document with our hook registered, or nil when nothing needs to change.
    ///
    /// Pure, so the property that matters can be asserted without a home directory: everything that
    /// is not our hook comes out the other side untouched. Conservative in both directions - a
    /// `hooks` value, or an event list, of an unexpected SHAPE also returns nil, because the only
    /// safe edit to a document we cannot read is none.
    ///
    /// EXACTLY ONE REGISTRATION OF OURS COMES OUT, wherever the file had them. Our own writes make at
    /// most one, but this file is rewritten by things that know nothing about Tally (a dotfiles
    /// merge, two config homes folded into one, a hand edit), and Claude Code runs every copy - so a
    /// duplicate would deny the same publish twice, or run a binary that has moved.
    static func settingsRegisteringArtifactHook(_ settings: [String: Any],
                                                command: String) -> [String: Any]? {
        var hooks: [String: Any]
        switch settings["hooks"] {
        case nil: hooks = [:]
        case let existing as [String: Any]: hooks = existing
        default: return nil
        }
        let entries: [[String: Any]]
        switch hooks[artifactHookEvent] {
        case nil: entries = []
        case let existing as [[String: Any]]: entries = existing
        default: return nil
        }
        let ourEntry = artifactHookEntry(command: command)
        var changed = false
        var placed = false
        var kept: [[String: Any]] = []
        for entry in entries {
            guard holdsOurArtifactHook(entry) else { kept.append(entry); continue }
            let theirs = (entry["hooks"] as? [[String: Any]] ?? []).filter { !isOurArtifactHook($0) }
            if theirs.isEmpty {
                // An entry that was ours alone becomes the current registration IN PLACE, which is
                // how an install pointing at an old path, or under a matcher an older version wrote,
                // is upgraded rather than doubled. A second such entry is a duplicate and simply
                // goes.
                if placed { changed = true; continue }
                placed = true
                if !isCurrentArtifactEntry(entry, command: command) { changed = true }
                kept.append(ourEntry)
            } else {
                // Shared with the user. Ours comes out and theirs stays exactly where it was,
                // matcher included; ours is placed in an entry of its own (`artifactHookEntry` says
                // why it may not simply join theirs).
                var trimmed = entry
                trimmed["hooks"] = theirs
                kept.append(trimmed)
                changed = true
            }
        }
        if !placed {
            kept.append(ourEntry)
            changed = true
        }
        guard changed else { return nil }
        hooks[artifactHookEvent] = kept
        var merged = settings
        merged["hooks"] = hooks
        return merged
    }

    /// The settings document without our hook, or nil when there was none. It takes out the one
    /// hook, then every container left empty by its going: the entry, the event, the `hooks` block.
    /// Anything a user put beside it survives at every level, matcher included.
    static func settingsWithoutArtifactHook(_ settings: [String: Any]) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[artifactHookEvent] as? [[String: Any]] else { return nil }
        var kept: [[String: Any]] = []
        var removed = false
        for entry in entries {
            guard holdsOurArtifactHook(entry) else { kept.append(entry); continue }
            removed = true
            let remaining = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurArtifactHook($0) }
            guard !remaining.isEmpty else { continue }
            var trimmed = entry
            trimmed["hooks"] = remaining
            kept.append(trimmed)
        }
        guard removed else { return nil }
        if kept.isEmpty { hooks.removeValue(forKey: artifactHookEvent) } else {
            hooks[artifactHookEvent] = kept
        }
        var merged = settings
        if hooks.isEmpty { merged.removeValue(forKey: "hooks") } else { merged["hooks"] = hooks }
        return merged
    }

    static func upsertArtifactHook(in file: URL) throws {
        _ = try editSettings(file) {
            settingsRegisteringArtifactHook($0, command: artifactHookCommand)
        }
    }

    static func removeArtifactHook(in file: URL) throws {
        _ = try editSettings(file) { settingsWithoutArtifactHook($0) }
    }

    /// One removal pass, and WHAT THE MANIFEST MUST SAY AFTER IT: the paths still carrying our hook
    /// (nil when the pass finished), plus the first failure. The manifest is a RETRY LIST for the
    /// reason the notification hook's own pass states in full - it is the only record that a
    /// settings.json the discovery can no longer see was ever written to, so what was cleared leaves
    /// and what threw stays.
    static func removeArtifactHook(from files: [URL]) -> (remembered: [String]?, failure: Error?) {
        var remembered: [String] = []
        var failure: Error?
        for file in files {
            do { try removeArtifactHook(in: file) } catch {
                failure = failure ?? error
                remembered.append(file.path)
            }
        }
        return (remembered.isEmpty ? nil : remembered, failure)
    }

    /// Whether a settings.json carries our hook, regardless of the path or matcher it carries it
    /// under. What detection asks (an entry that is stale is still installed), which is also what
    /// keeps a dev build from reporting the release app's install as broken because the two bundles
    /// sit in different places.
    static func settingsCarryArtifactHook(_ file: URL) -> Bool {
        artifactHookEntries(file).contains { holdsOurArtifactHook($0) }
    }

    /// Whether a settings.json still has a registration of ours to answer for. PRESENT AND
    /// UNREADABLE IS NOT ABSENT, which is the rule every write into this file is under
    /// (`editSettings`) and the reason this predicate is separate from the one above: a removal pass
    /// remembers exactly the files it threw on, and answering "nothing here" out of bytes nobody
    /// could parse would drop the row to "not installed", take the Remove press off it, and leave
    /// the retry list with nothing that will ever act on it. A file that is not there, or is empty,
    /// has nothing of ours: that is a home that has GONE.
    static func settingsMayCarryArtifactHook(_ file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let data = try? Data(contentsOf: file) else { return true }   // there, and unreadable
        guard !data.isEmpty else { return false }
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return true }
        let hooks = settings["hooks"] as? [String: Any]
        return ((hooks?[artifactHookEvent] as? [[String: Any]]) ?? [])
            .contains { holdsOurArtifactHook($0) }
    }

    /// Whether this file's registration is the CURRENT one rather than merely present. Read as the
    /// difference between "installed" and "installed correctly": an entry naming a command this
    /// build no longer answers to, or sitting under a matcher that no longer names the tool, is a
    /// hook that runs and decides nothing.
    static func settingsCarryCurrentArtifactHook(_ file: URL) -> Bool {
        artifactHookEntries(file).contains {
            isCurrentArtifactEntry($0, command: artifactHookCommand)
        }
    }

    /// Every entry under our event, read once. One parse per file rather than one per predicate.
    private static func artifactHookEntries(_ file: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return hooks[artifactHookEvent] as? [[String: Any]] ?? []
    }

    /// The manifest component this registration is recorded under, in ONE place: written by the
    /// install as bookkeeping and read by the removal as provenance, so a second spelling would mean
    /// the removal looked up an entry nothing had ever written.
    nonisolated static let artifactHookManifest = "claudeArtifactHook"

    /// Every settings.json this registration could be in: the homes discovered now, plus every path
    /// the manifest remembers. The union is what makes a logged-out account reachable at all.
    static func artifactHookSettingsFiles() -> [URL] {
        notificationHookSettingsFiles(discovered: claudeSettingsFiles(),
                                      remembered: manifestPaths(artifactHookManifest))
    }

    /// What the STATUS is judged over: the union above with one filter on its second half, on the
    /// asymmetry `notificationHookPopulation` argues in full - a discovered home counts whatever its
    /// file says, a remembered path counts only while it still has something of ours on it.
    static func artifactHookPopulation(discovered: [URL], remembered: [String]) -> [URL] {
        hookPopulation(discovered: discovered, remembered: remembered,
                       mayCarry: settingsMayCarryArtifactHook)
    }

    static func detectArtifactHook() -> Status {
        detectArtifactHook(discovered: claudeSettingsFiles(),
                           remembered: manifestPaths(artifactHookManifest))
    }

    /// The same judgement over a given population, pure so it can be asserted without logged-in
    /// homes on whichever machine runs the assertions.
    static func detectArtifactHook(discovered: [URL], remembered: [String]) -> Status {
        let files = artifactHookPopulation(discovered: discovered, remembered: remembered)
        guard !files.isEmpty else { return .notInstalled }
        let outstanding = files.filter { settingsMayCarryArtifactHook($0) }.count
        guard outstanding > 0 else { return .notInstalled }
        let ours = files.filter { settingsCarryArtifactHook($0) }.count
        guard ours == files.count else { return .broken(L("Not installed for every account")) }
        let current = files.filter { settingsCarryCurrentArtifactHook($0) }.count
        return current == files.count ? .installed : .broken(L("Older version installed"))
    }

    /// Which account a fresh install should name as the one the user publishes from, or nil to leave
    /// the setting alone.
    ///
    /// A SETTING NOBODY HAS CHOSEN MAKES THE HOOK INERT, which is why an install writes one. The CLI
    /// abstains when the state file names no account (it has nothing to compare against and this is
    /// a convenience rather than a gate), so a row installed and never visited would be a row that
    /// says Installed and does nothing at all.
    ///
    /// THE FIRST ACCOUNT, which is the main one: `ClaudeAccounts.discover()` yields `~/.claude`
    /// first and the numbered homes after it, and the panel draws them in that order. It is a guess,
    /// and it is the guess the refusal SHOWS: the sentence names the account it is holding the
    /// publish for, so a user whose browser is signed into another one reads the wrong name and
    /// changes it in the row's own picker.
    ///
    /// Pure, and nil for both ways of having nothing to do: a setting already chosen (never
    /// overwritten - it is the user's answer, and a reinstall is not a question) and a machine with
    /// no launchable Claude account to name.
    static func artifactAccountSeed(current: String?, homes: [String]) -> String? {
        guard current?.isEmpty ?? true else { return nil }
        return homes.first
    }

    func installArtifactHook() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            let files = Self.claudeSettingsFiles()
            for file in files { try Self.upsertArtifactHook(in: file) }
            // The union with what is already recorded, never a rewrite of it, for the reason
            // `notificationHookManifestPaths` states: this press may be the one AFTER a removal that
            // could not finish, and the paths it could not finish are the retry list.
            recordManifest(Self.artifactHookManifest,
                           paths: Self.notificationHookManifestPaths(
                               installed: files,
                               remembered: Self.manifestPaths(Self.artifactHookManifest)))
            // …and the setting the hook reads, seeded so the row means something the moment it goes
            // in (`artifactAccountSeed` states why an install writes one at all). After the
            // registration rather than before it: a write that failed leaves nothing named for a
            // hook that is not there.
            if let seed = Self.artifactAccountSeed(
                current: LaunchPolicyStore.shared.artifactAccount,
                homes: ClaudeAccounts.discover().compactMap(\.launchableHome)) {
                LaunchPolicyStore.shared.setArtifactAccount(seed)
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func removeArtifactHook() {
        guard guardNotDev() else { return }
        lastError = nil
        let pass = Self.removeArtifactHook(from: Self.artifactHookSettingsFiles())
        recordManifest(Self.artifactHookManifest, paths: pass.remembered)
        // AND THE PRESS IS REMEMBERED, because nothing else about it is: a later launch cannot
        // otherwise tell a row somebody removed on purpose from one that was never installed, and
        // that launch installs the second (IntegrationsAutoFollow.swift). Recorded here rather than
        // at the button so that every press reaches it: the row's Remove, "Remove all", and the
        // notice's own Undo are all this one function.
        recordAutoFollowHandled(Self.artifactHookManifest)
        // THE CHOSEN ACCOUNT STAYS. It is a setting rather than a side effect of the install, the
        // hook that reads it is gone either way, and a reinstall that had forgotten it would be a
        // row that quietly re-guesses an answer the user already gave.
        lastError = pass.failure?.localizedDescription
        refresh()
    }
}
