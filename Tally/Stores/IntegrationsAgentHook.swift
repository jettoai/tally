import Foundation

// THE OTHER THING CLAUDE CODE KNOWS AND TALLY CANNOT SEE: how many subagents a session has working.
//
// A subagent is a conversation inside a process rather than a process, so the machine cannot be
// asked - a Claude Code answering one turn and a Claude Code driving six agents look identical in
// the process table. Claude Code fires `SubagentStart` and `SubagentStop` as they come and go, and
// puts a `background_tasks` roll call on the events that end a turn, so the app registers all three
// per Claude account and the CLI folds them into the session's roster (TallyCLI/AgentRoster.swift).
//
// THE SURGERY RULES ARE THE NOTIFICATION HOOK'S, one file over, and they are not optional here
// either: settings.json is the user's own file, shared by symlink across accounts on some setups,
// and it holds their whole harness. Every write is a read-modify-write over the parsed document
// touching exactly the hooks whose command runs OUR subcommand, and Claude Code runs EVERY hook
// registered under an event, so ours simply stands beside anything the user already has.
//
// THREE EVENTS, ONE ROW. They are one feature - the count on a card - and a user who installed the
// edges without the roll call would have a number that drifts, which is precisely the state the
// roster refuses to draw. So the status word is judged over all three together: any of them missing
// anywhere is `broken`, and the repair is the same press.
extension IntegrationsStore {
    /// The registered command for one event, and the provenance marker with it: removal and
    /// detection only ever touch a hook whose command line ends in our subcommand and that event.
    /// Through the public path, like the hooks beside it, because that is the one that survives the
    /// app bundle moving.
    nonisolated static func agentHookCommand(_ event: String) -> String {
        "/usr/local/bin/tally hook-agents \(event)"
    }

    /// The subcommand and its event as their own words. A SUFFIX RATHER THAN A SUBSTRING, load
    /// bearing for the reason `isOurHook` gives one file over: a user's own
    /// `/opt/bin/my-hook-agents Stop` would contain this string, and treating it as ours would
    /// silently replace their hook and delete it on uninstall.
    nonisolated static func agentHookMarker(_ event: String) -> String {
        " hook-agents \(event)"
    }

    private static func isOurAgentHook(_ hook: [String: Any], event: String) -> Bool {
        (hook["command"] as? String)?.hasSuffix(agentHookMarker(event)) == true
    }

    private static func holdsOurAgentHook(_ entry: [String: Any], event: String) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { isOurAgentHook($0, event: event) }
    }

    /// The whole entry we register for one event: our one hook, under no matcher at all.
    ///
    /// NO MATCHER, deliberately, and it is the opposite decision from the notification hook's for
    /// the opposite reason. That one asks for six of nine notification types and has to say so;
    /// these three events have no sub-kinds to filter, so a matcher would be a field that says
    /// nothing and one more thing for a future Claude Code to stop honouring.
    ///
    /// AN ENTRY OF ITS OWN ALL THE SAME, because an entry is where a matcher would live if the user
    /// gave theirs one: putting ours into their entry would put their hook under our filter, in a
    /// file we are only supposed to be adding one line to.
    static func agentHookEntry(command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command]]]
    }

    /// Whether an entry of ours is the CURRENT registration. An install pointing at an older
    /// command answers false here and true to `holdsOurAgentHook`, which is exactly the difference
    /// between "installed" and "installed correctly".
    private static func isCurrentAgentEntry(_ entry: [String: Any], command: String) -> Bool {
        NSDictionary(dictionary: entry).isEqual(to: agentHookEntry(command: command))
    }

    /// The settings document with our hook for one event registered, or nil when nothing needs to
    /// change.
    ///
    /// Pure, so the property that matters can be asserted without a home directory: everything that
    /// is not our hook comes out the other side untouched. Conservative in both directions - a
    /// `hooks` value, or an event list, of an unexpected SHAPE also returns nil, because the only
    /// safe edit to a document we cannot read is none.
    ///
    /// EXACTLY ONE REGISTRATION OF OURS COMES OUT, wherever the file had them, for the reason the
    /// prompt hook's upsert states at length: our own writes make at most one, but this file is
    /// rewritten by things that know nothing about Tally (a dotfiles merge, two config homes folded
    /// into one, a hand edit), and Claude Code runs every copy - so a duplicate would count one
    /// subagent's start twice, or run a binary that has moved.
    static func settingsRegisteringAgentHook(_ settings: [String: Any], event: String,
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
        let ourEntry = agentHookEntry(command: command)
        var changed = false
        var placed = false
        var kept: [[String: Any]] = []
        for entry in entries {
            guard holdsOurAgentHook(entry, event: event) else { kept.append(entry); continue }
            let theirs = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurAgentHook($0, event: event) }
            if theirs.isEmpty {
                // An entry that was ours alone becomes the current registration IN PLACE, which is
                // how an install pointing at an old path is upgraded rather than doubled. A second
                // such entry is a duplicate and simply goes.
                if placed { changed = true; continue }
                placed = true
                if !isCurrentAgentEntry(entry, command: command) { changed = true }
                kept.append(ourEntry)
            } else {
                // Shared with the user. Ours comes out and theirs stays exactly where it was,
                // matcher included; ours is placed in an entry of its own (`agentHookEntry` says
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
    static func settingsWithoutAgentHook(_ settings: [String: Any],
                                         event: String) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return nil }
        var kept: [[String: Any]] = []
        var removed = false
        for entry in entries {
            guard holdsOurAgentHook(entry, event: event) else { kept.append(entry); continue }
            removed = true
            let remaining = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurAgentHook($0, event: event) }
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
    /// set is the drifting count the roster refuses to draw - and the first failure is what the
    /// caller hears about.
    private static func editAgentHooks(in file: URL,
                                       _ edit: (String, [String: Any]) -> [String: Any]?) throws {
        var failure: Error?
        for event in AgentRosterEvent.events {
            do { _ = try editSettings(file) { edit(event, $0) } } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// Register all three in one file.
    static func upsertAgentHooks(in file: URL) throws {
        try editAgentHooks(in: file) { event, settings in
            settingsRegisteringAgentHook(settings, event: event, command: agentHookCommand(event))
        }
    }

    static func removeAgentHooks(in file: URL) throws {
        try editAgentHooks(in: file) { event, settings in
            settingsWithoutAgentHook(settings, event: event)
        }
    }

    /// One removal pass, and WHAT THE MANIFEST MUST SAY AFTER IT: the paths still carrying our
    /// hooks (nil when the pass finished), plus the first failure. The manifest is a RETRY LIST for
    /// the reason the notification hook's own pass states in full - it is the only record that a
    /// settings.json the discovery can no longer see was ever written to, so what was cleared
    /// leaves and what threw stays.
    static func removeAgentHooks(from files: [URL]) -> (remembered: [String]?, failure: Error?) {
        var remembered: [String] = []
        var failure: Error?
        for file in files {
            do { try removeAgentHooks(in: file) } catch {
                failure = failure ?? error
                remembered.append(file.path)
            }
        }
        return (remembered.isEmpty ? nil : remembered, failure)
    }

    /// Whether a settings.json carries every one of our three hooks, regardless of the path they
    /// point at. What detection asks (an entry that is stale is still installed; the launch sync
    /// repairs the path silently), which is also what keeps a dev build from reporting the release
    /// app's install as broken because the two bundles sit in different places.
    static func settingsCarryAgentHooks(_ file: URL) -> Bool {
        let entries = agentHookEntries(file)
        return AgentRosterEvent.events.allSatisfy { event in
            (entries[event] ?? []).contains { holdsOurAgentHook($0, event: event) }
        }
    }

    /// Whether a settings.json still has a registration of ours to answer for: ANY of the three,
    /// rather than all of them. PRESENT AND UNREADABLE IS NOT ABSENT, which is the rule every write
    /// into this file is under (`editSettings`) and the reason this predicate is separate from the
    /// one above: a removal pass remembers exactly the files it threw on, and answering "nothing
    /// here" out of bytes nobody could parse would drop the row to "not installed", take the Remove
    /// press off it, and leave the retry list with nothing that will ever act on it. A file that is
    /// not there, or is empty, has nothing of ours: that is a home that has GONE.
    static func settingsMayCarryAgentHooks(_ file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let data = try? Data(contentsOf: file) else { return true }   // there, and unreadable
        guard !data.isEmpty else { return false }
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return true }
        let hooks = settings["hooks"] as? [String: Any]
        return AgentRosterEvent.events.contains { event in
            ((hooks?[event] as? [[String: Any]]) ?? []).contains {
                holdsOurAgentHook($0, event: event)
            }
        }
    }

    /// Whether every one of this file's registrations is the CURRENT one rather than merely
    /// present. Read as the difference between "installed" and "installed correctly": an entry
    /// pointing at a command this build no longer answers to is a hook that runs and does nothing.
    static func settingsCarryCurrentAgentHooks(_ file: URL) -> Bool {
        let entries = agentHookEntries(file)
        return AgentRosterEvent.events.allSatisfy { event in
            (entries[event] ?? []).contains {
                isCurrentAgentEntry($0, command: agentHookCommand(event))
            }
        }
    }

    /// Every entry under each of our three events, read once. One parse per file rather than one
    /// per event, since both predicates above ask about all three.
    private static func agentHookEntries(_ file: URL) -> [String: [[String: Any]]] {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return [:] }
        var found: [String: [[String: Any]]] = [:]
        for event in AgentRosterEvent.events { found[event] = hooks[event] as? [[String: Any]] ?? [] }
        return found
    }

    /// The manifest component this registration is recorded under, in ONE place: written by the
    /// install as bookkeeping and read by the removal as provenance, so a second spelling would
    /// mean the removal looked up an entry nothing had ever written.
    nonisolated static let agentHookManifest = "claudeAgentHooks"

    /// Every settings.json this registration could be in: the homes discovered now, plus every path
    /// the manifest remembers. The union is what makes a logged-out account reachable at all -
    /// `claudeSettingsFiles()` answers with the homes logged in TODAY, and the hook Tally wrote
    /// into a home signed out since install stays there after the user pressed Remove.
    static func agentHookSettingsFiles() -> [URL] {
        notificationHookSettingsFiles(discovered: claudeSettingsFiles(),
                                      remembered: manifestPaths(agentHookManifest))
    }

    /// What the STATUS is judged over: the union above with one filter on its second half, on the
    /// asymmetry `notificationHookPopulation` argues in full - a discovered home counts whatever
    /// its file says, a remembered path counts only while it still has something of ours on it.
    static func agentHookPopulation(discovered: [URL], remembered: [String]) -> [URL] {
        hookPopulation(discovered: discovered, remembered: remembered,
                       mayCarry: settingsMayCarryAgentHooks)
    }

    static func detectAgentHooks() -> Status {
        detectAgentHooks(discovered: claudeSettingsFiles(),
                         remembered: manifestPaths(agentHookManifest))
    }

    /// The same judgement over a given population, pure so it can be asserted without logged-in
    /// homes on whichever machine runs the assertions.
    static func detectAgentHooks(discovered: [URL], remembered: [String]) -> Status {
        let files = agentHookPopulation(discovered: discovered, remembered: remembered)
        guard !files.isEmpty else { return .notInstalled }
        let outstanding = files.filter { settingsMayCarryAgentHooks($0) }.count
        guard outstanding > 0 else { return .notInstalled }
        let ours = files.filter { settingsCarryAgentHooks($0) }.count
        guard ours == files.count else { return .broken(L("Not installed for every account")) }
        let current = files.filter { settingsCarryCurrentAgentHooks($0) }.count
        return current == files.count ? .installed : .broken(L("Older version installed"))
    }

    func installAgentHooks() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            let files = Self.claudeSettingsFiles()
            for file in files { try Self.upsertAgentHooks(in: file) }
            // The union with what is already recorded, never a rewrite of it, for the reason
            // `notificationHookManifestPaths` states: this press may be the one AFTER a removal
            // that could not finish, and the paths it could not finish are the retry list.
            recordManifest(Self.agentHookManifest,
                           paths: Self.notificationHookManifestPaths(
                               installed: files,
                               remembered: Self.manifestPaths(Self.agentHookManifest)))
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func removeAgentHooks() {
        guard guardNotDev() else { return }
        lastError = nil
        let pass = Self.removeAgentHooks(from: Self.agentHookSettingsFiles())
        recordManifest(Self.agentHookManifest, paths: pass.remembered)
        lastError = pass.failure?.localizedDescription
        refresh()
    }
}
