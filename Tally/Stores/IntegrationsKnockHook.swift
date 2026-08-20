import Foundation

// THE ONE THING TALLY KNOWS AND A RUNNING CONVERSATION CANNOT SEE: that the account under it is
// about to run out.
//
// The supervisor has always been able to say it, and until now it could only say it by TYPING into
// the session's terminal - which it may not do while that session is mid-turn, at the exact moment
// the sentence is worth having (TallyCLI/QuotaKnock.swift argues the whole of it). Claude Code will
// carry it instead: a hook may hand the model context, so the supervisor files the sentence in a
// small file and the session's own `UserPromptSubmit` and `PostToolUse` hooks deliver it on the next
// prompt or tool call, without a turn being spent and without a keystroke being typed.
//
// TWO EVENTS AND NOT A THIRD. `Stop` accepts context too and CONTINUES THE CONVERSATION when it is
// given any, which would spend a model turn to deliver a warning about spending model turns
// (`quotaKnockHookEvents` holds the measurement and the reference).
//
// THE SURGERY RULES ARE THE SUBAGENT HOOKS', one file over, and they are not optional here either:
// settings.json is the user's own file, shared by symlink across accounts on some setups, and it
// holds their whole harness. Every write is a read-modify-write over the parsed document touching
// exactly the hooks whose command runs OUR subcommand, and Claude Code runs EVERY hook registered
// under an event, so ours simply stands beside anything the user already has.
//
// TWO EVENTS, ONE ROW, for the reason the roster's three are one row: they are one feature, and a
// user with only one of them registered would be told about a drought whenever they next happen to
// submit a prompt, which for a busy session can be an hour late. So the status word is judged over
// both together, the supervisor refuses to use the channel unless both are there
// (`quotaKnockHookRegistered`), and the repair is the same press.
extension IntegrationsStore {
    /// The registered command for one event, and the provenance marker with it: removal and
    /// detection only ever touch a hook whose command line ends in our subcommand and that event.
    ///
    /// BOTH READ OUT OF THE CLI's OWN CONTRACT (TallyCLI/QuotaKnockHookContract.swift, compiled by
    /// this target too) rather than spelled again here. The three readers of these strings are in
    /// two processes - this pane writes them, the supervisor looks for them, the CLI answers to
    /// them - and a drift between any two of them fails silently in a way no measurement of the
    /// finished settings.json can see.
    nonisolated static func knockHookCommand(_ event: String) -> String {
        quotaKnockHookCommand(event)
    }

    nonisolated static func knockHookMarker(_ event: String) -> String {
        quotaKnockHookMarker(event)
    }

    private static func isOurKnockHook(_ hook: [String: Any], event: String) -> Bool {
        (hook["command"] as? String)?.hasSuffix(knockHookMarker(event)) == true
    }

    private static func holdsOurKnockHook(_ entry: [String: Any], event: String) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { isOurKnockHook($0, event: event) }
    }

    /// The whole entry we register for one event: our one hook, under no matcher at all.
    ///
    /// NO MATCHER, deliberately, and for both events. `UserPromptSubmit` has no matcher support at
    /// all (one is silently ignored there), and on `PostToolUse` a matcher would narrow the delivery
    /// to certain tools for no reason: the sentence is owed to the conversation rather than to
    /// anything a particular tool did, so every tool call is an equally good moment to hand it over.
    ///
    /// AN ENTRY OF ITS OWN ALL THE SAME, because an entry is where a matcher would live if the user
    /// gave theirs one: putting ours into their entry would put their hook under our filter, in a
    /// file we are only supposed to be adding one line to.
    static func knockHookEntry(command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command]]]
    }

    /// Whether an entry of ours is the CURRENT registration. An install pointing at an older command
    /// answers false here and true to `holdsOurKnockHook`, which is exactly the difference between
    /// "installed" and "installed correctly".
    private static func isCurrentKnockEntry(_ entry: [String: Any], command: String) -> Bool {
        NSDictionary(dictionary: entry).isEqual(to: knockHookEntry(command: command))
    }

    /// The settings document with our hook for one event registered, or nil when nothing needs to
    /// change.
    ///
    /// Pure, so the property that matters can be asserted without a home directory: everything that
    /// is not our hook comes out the other side untouched. Conservative in both directions - a
    /// `hooks` value, or an event list, of an unexpected SHAPE also returns nil, because the only
    /// safe edit to a document we cannot read is none.
    ///
    /// EXACTLY ONE REGISTRATION OF OURS COMES OUT, wherever the file had them. Our own writes make
    /// at most one, but this file is rewritten by things that know nothing about Tally (a dotfiles
    /// merge, two config homes folded into one, a hand edit), and Claude Code runs every copy - so a
    /// duplicate would hand the model the same sentence twice, or run a binary that has moved.
    static func settingsRegisteringKnockHook(_ settings: [String: Any], event: String,
                                             command: String) -> [String: Any]? {
        var hooks: [String: Any]
        switch settings["hooks"] {
        case nil: hooks = [:]
        case let existing as [String: Any]: hooks = existing
        default: return nil
        }
        let entries: [[String: Any]]
        switch hooks[event] {
        case nil: entries = []
        case let existing as [[String: Any]]: entries = existing
        default: return nil
        }
        let ourEntry = knockHookEntry(command: command)
        var changed = false
        var placed = false
        var kept: [[String: Any]] = []
        for entry in entries {
            guard holdsOurKnockHook(entry, event: event) else { kept.append(entry); continue }
            let theirs = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurKnockHook($0, event: event) }
            if theirs.isEmpty {
                // An entry that was ours alone becomes the current registration IN PLACE, which is
                // how an install pointing at an old path is upgraded rather than doubled. A second
                // such entry is a duplicate and simply goes.
                if placed { changed = true; continue }
                placed = true
                if !isCurrentKnockEntry(entry, command: command) { changed = true }
                kept.append(ourEntry)
            } else {
                // Shared with the user. Ours comes out and theirs stays exactly where it was,
                // matcher included; ours is placed in an entry of its own (`knockHookEntry` says
                // why it may not simply join theirs).
                var trimmed = entry
                trimmed["hooks"] = theirs
                kept.append(trimmed)
                changed = true
            }
        }
        if !placed {
            // A fresh entry holding only ours. Deliberately not merged into an entry the user wrote
            // themselves: that entry is theirs, and adding to it is still editing it.
            kept.append(ourEntry)
            changed = true
        }
        guard changed else { return nil }
        hooks[event] = kept
        var merged = settings
        merged["hooks"] = hooks
        return merged
    }

    /// The settings document without our hook for one event, or nil when there was none. It takes
    /// out the one hook, then every container left empty by its going: the entry, the event, the
    /// `hooks` block. Anything a user put beside it survives at every level.
    static func settingsWithoutKnockHook(_ settings: [String: Any],
                                         event: String) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return nil }
        var kept: [[String: Any]] = []
        var removed = false
        for entry in entries {
            guard holdsOurKnockHook(entry, event: event) else { kept.append(entry); continue }
            removed = true
            let remaining = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurKnockHook($0, event: event) }
            guard !remaining.isEmpty else { continue }
            var trimmed = entry
            trimmed["hooks"] = remaining
            kept.append(trimmed)
        }
        guard removed else { return nil }
        if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        var merged = settings
        if hooks.isEmpty { merged.removeValue(forKey: "hooks") } else { merged["hooks"] = hooks }
        return merged
    }

    /// One edit per event over the same file. EVERY EVENT IS ATTEMPTED WHATEVER ANY OTHER ONE DID,
    /// so a document that refuses one write does not leave the rest unregistered - a half-written
    /// pair is a channel the supervisor will not use at all - and the first failure is what the
    /// caller hears about.
    private static func editKnockHooks(in file: URL,
                                       _ edit: (String, [String: Any]) -> [String: Any]?) throws {
        var failure: Error?
        for event in quotaKnockHookEvents {
            do { _ = try editSettings(file) { edit(event, $0) } } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    static func upsertKnockHooks(in file: URL) throws {
        try editKnockHooks(in: file) { event, settings in
            settingsRegisteringKnockHook(settings, event: event, command: knockHookCommand(event))
        }
    }

    static func removeKnockHooks(in file: URL) throws {
        try editKnockHooks(in: file) { event, settings in
            settingsWithoutKnockHook(settings, event: event)
        }
    }

    /// One removal pass, and WHAT THE MANIFEST MUST SAY AFTER IT: the paths still carrying our hooks
    /// (nil when the pass finished), plus the first failure. The manifest is a RETRY LIST for the
    /// reason the notification hook's own pass states in full - it is the only record that a
    /// settings.json the discovery can no longer see was ever written to, so what was cleared leaves
    /// and what threw stays.
    static func removeKnockHooks(from files: [URL]) -> (remembered: [String]?, failure: Error?) {
        var remembered: [String] = []
        var failure: Error?
        for file in files {
            do { try removeKnockHooks(in: file) } catch {
                failure = failure ?? error
                remembered.append(file.path)
            }
        }
        return (remembered.isEmpty ? nil : remembered, failure)
    }

    /// Whether a settings.json carries both of our hooks, regardless of the path they point at. What
    /// detection asks (an entry that is stale is still installed; the launch sync repairs the path
    /// silently), which is also what keeps a dev build from reporting the release app's install as
    /// broken because the two bundles sit in different places.
    static func settingsCarryKnockHooks(_ file: URL) -> Bool {
        let entries = knockHookEntries(file)
        return quotaKnockHookEvents.allSatisfy { event in
            (entries[event] ?? []).contains { holdsOurKnockHook($0, event: event) }
        }
    }

    /// Whether a settings.json still has a registration of ours to answer for: EITHER of the two,
    /// rather than both. PRESENT AND UNREADABLE IS NOT ABSENT, which is the rule every write into
    /// this file is under (`editSettings`) and the reason this predicate is separate from the one
    /// above: a removal pass remembers exactly the files it threw on, and answering "nothing here"
    /// out of bytes nobody could parse would drop the row to "not installed", take the Remove press
    /// off it, and leave the retry list with nothing that will ever act on it. A file that is not
    /// there, or is empty, has nothing of ours: that is a home that has GONE.
    static func settingsMayCarryKnockHooks(_ file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let data = try? Data(contentsOf: file) else { return true }   // there, and unreadable
        guard !data.isEmpty else { return false }
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return true }
        let hooks = settings["hooks"] as? [String: Any]
        return quotaKnockHookEvents.contains { event in
            ((hooks?[event] as? [[String: Any]]) ?? []).contains {
                holdsOurKnockHook($0, event: event)
            }
        }
    }

    /// Whether every one of this file's registrations is the CURRENT one rather than merely present.
    /// Read as the difference between "installed" and "installed correctly": an entry pointing at a
    /// command this build no longer answers to is a hook that runs and delivers nothing.
    static func settingsCarryCurrentKnockHooks(_ file: URL) -> Bool {
        let entries = knockHookEntries(file)
        return quotaKnockHookEvents.allSatisfy { event in
            (entries[event] ?? []).contains {
                isCurrentKnockEntry($0, command: knockHookCommand(event))
            }
        }
    }

    /// Every entry under each of our two events, read once. One parse per file rather than one per
    /// event, since both predicates above ask about both.
    private static func knockHookEntries(_ file: URL) -> [String: [[String: Any]]] {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return [:] }
        var found: [String: [[String: Any]]] = [:]
        for event in quotaKnockHookEvents { found[event] = hooks[event] as? [[String: Any]] ?? [] }
        return found
    }

    /// The manifest component this registration is recorded under, in ONE place: written by the
    /// install as bookkeeping and read by the removal as provenance, so a second spelling would mean
    /// the removal looked up an entry nothing had ever written.
    nonisolated static let knockHookManifest = "claudeKnockHooks"

    /// Every settings.json this registration could be in: the homes discovered now, plus every path
    /// the manifest remembers. The union is what makes a logged-out account reachable at all.
    static func knockHookSettingsFiles() -> [URL] {
        notificationHookSettingsFiles(discovered: claudeSettingsFiles(),
                                      remembered: manifestPaths(knockHookManifest))
    }

    /// What the STATUS is judged over: the union above with one filter on its second half, on the
    /// asymmetry `notificationHookPopulation` argues in full - a discovered home counts whatever its
    /// file says, a remembered path counts only while it still has something of ours on it.
    static func knockHookPopulation(discovered: [URL], remembered: [String]) -> [URL] {
        hookPopulation(discovered: discovered, remembered: remembered,
                       mayCarry: settingsMayCarryKnockHooks)
    }

    static func detectKnockHooks() -> Status {
        detectKnockHooks(discovered: claudeSettingsFiles(),
                         remembered: manifestPaths(knockHookManifest))
    }

    /// The same judgement over a given population, pure so it can be asserted without logged-in
    /// homes on whichever machine runs the assertions.
    static func detectKnockHooks(discovered: [URL], remembered: [String]) -> Status {
        let files = knockHookPopulation(discovered: discovered, remembered: remembered)
        guard !files.isEmpty else { return .notInstalled }
        let outstanding = files.filter { settingsMayCarryKnockHooks($0) }.count
        guard outstanding > 0 else { return .notInstalled }
        let ours = files.filter { settingsCarryKnockHooks($0) }.count
        guard ours == files.count else { return .broken(L("Not installed for every account")) }
        let current = files.filter { settingsCarryCurrentKnockHooks($0) }.count
        return current == files.count ? .installed : .broken(L("Older version installed"))
    }

    func installKnockHooks() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            let files = Self.claudeSettingsFiles()
            for file in files { try Self.upsertKnockHooks(in: file) }
            // The union with what is already recorded, never a rewrite of it, for the reason
            // `notificationHookManifestPaths` states: this press may be the one AFTER a removal that
            // could not finish, and the paths it could not finish are the retry list.
            recordManifest(Self.knockHookManifest,
                           paths: Self.notificationHookManifestPaths(
                               installed: files,
                               remembered: Self.manifestPaths(Self.knockHookManifest)))
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func removeKnockHooks() {
        guard guardNotDev() else { return }
        lastError = nil
        let pass = Self.removeKnockHooks(from: Self.knockHookSettingsFiles())
        recordManifest(Self.knockHookManifest, paths: pass.remembered)
        // AND THE PRESS IS REMEMBERED, because nothing else about it is. This removal takes the
        // hooks out of settings.json and the entry out of the manifest, which leaves a later launch
        // unable to tell a row somebody removed on purpose from one that was never installed - and
        // that launch installs the second (IntegrationsAutoFollow.swift). Recorded here rather than
        // at the button so that every press reaches it: the row's Remove, "Remove all", and the
        // notice's own Undo are all this one function.
        recordAutoFollowHandled(Self.knockHookManifest)
        lastError = pass.failure?.localizedDescription
        refresh()
    }
}
