import Foundation

// THE ONE THING CLAUDE CODE KNOWS AND TALLY CANNOT SEE: that a session is waiting on its user.
//
// Claude Code fires its `Notification` event exactly when it wants somebody - a permission request,
// a prompt left unanswered long enough for it to say so - and nothing the supervisor can measure
// separates that from a finished turn (UserNotice.swift carries the reasoning). So the app
// registers one command hook per Claude account, and the CLI leaves the event for that session's
// supervisor.
//
// THE SURGERY RULES ARE THE PROMPT HOOK'S, and they are not optional here either: settings.json is
// the user's own file, shared by symlink across accounts on some setups, and it holds their whole
// harness. So every write is a read-modify-write over the parsed document touching exactly the one
// hook whose command runs OUR subcommand. This event's array is unlike the status line's single
// value in the one way that matters: Claude Code runs EVERY hook registered under it, so ours can
// simply stand beside anything the user already has and there is nothing to wrap or restore.
extension IntegrationsStore {
    nonisolated static let notificationHookEvent = "Notification"

    /// The registered command, and the provenance marker with it: removal and detection only ever
    /// touch a hook whose command line ends in this subcommand. Through the public path, like the
    /// status line beside it, because that is the one that survives the app bundle moving.
    nonisolated static let notificationHookCommand = "/usr/local/bin/tally hook-notify claude"

    /// The subcommand as its own word. A SUFFIX RATHER THAN A SUBSTRING, and that is load-bearing
    /// for the reason `isOurHook` gives one file over: a user's own `/opt/bin/my-hook-notify` would
    /// contain this string, and treating it as ours would silently replace their hook and delete it
    /// on uninstall.
    nonisolated static let notificationHookMarker = " hook-notify claude"

    private static func isOurNotificationHook(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.hasSuffix(notificationHookMarker) == true
    }

    private static func holdsOurNotificationHook(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { isOurNotificationHook($0) }
    }

    /// The whole entry we register: our matcher and our one hook.
    ///
    /// AN ENTRY OF ITS OWN, ALWAYS, and that is a correctness rule rather than tidiness. The
    /// matcher belongs to the ENTRY, not to the hook inside it, so putting ours beside a user's
    /// hook would impose our five-type filter on THEIR hook - silently stopping it from firing for
    /// the four types we filter out, in a file we are only supposed to be adding one line to.
    /// Ours therefore always stands alone, and anything of theirs stays in the entry it was in
    /// (with whatever matcher they gave it).
    static func notificationHookEntry(command: String) -> [String: Any] {
        ["matcher": notificationHookMatcher,
         "hooks": [["type": "command", "command": command]]]
    }

    /// Whether an entry of ours is the CURRENT registration, matcher and all. An install from
    /// before the matcher existed answers false here and true to `holdsOurNotificationHook`, which
    /// is exactly the difference between "installed" and "installed correctly".
    private static func isCurrentNotificationEntry(_ entry: [String: Any],
                                                   command: String) -> Bool {
        NSDictionary(dictionary: entry).isEqual(to: notificationHookEntry(command: command))
    }

    /// The settings document with our hook registered, or nil when nothing needs to change.
    ///
    /// Pure, so the property that matters can be asserted without a home directory: everything that
    /// is not our hook comes out the other side untouched. Conservative in both directions - a
    /// `hooks` value, or an event list, of an unexpected SHAPE also returns nil, because the only
    /// safe edit to a document we cannot read is none.
    ///
    /// EXACTLY ONE REGISTRATION OF OURS COMES OUT, wherever the file had them, for the reason the
    /// prompt hook's upsert states at length: our own writes make at most one, but this file is
    /// rewritten by things that know nothing about Tally (a dotfiles merge, two config homes folded
    /// into one, a hand edit), and Claude Code runs every copy - so a stale duplicate would leave
    /// an event for a supervisor twice, or once from a binary that has moved.
    static func settingsRegisteringNotificationHook(_ settings: [String: Any],
                                                    command: String) -> [String: Any]? {
        var hooks: [String: Any]
        switch settings["hooks"] {
        case nil: hooks = [:]
        case let existing as [String: Any]: hooks = existing
        default: return nil
        }
        let entries: [[String: Any]]
        switch hooks[notificationHookEvent] {
        case nil: entries = []
        case let existing as [[String: Any]]: entries = existing
        default: return nil
        }
        let ourEntry = notificationHookEntry(command: command)
        var changed = false
        var placed = false
        var kept: [[String: Any]] = []
        for entry in entries {
            guard holdsOurNotificationHook(entry) else { kept.append(entry); continue }
            let theirs = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurNotificationHook($0) }
            if theirs.isEmpty {
                // An entry that was ours alone: it becomes the current registration in place, which
                // is how a matcher-less install from an older app is UPGRADED rather than doubled.
                // A second such entry is a duplicate and simply goes.
                if placed { changed = true; continue }
                placed = true
                if !isCurrentNotificationEntry(entry, command: command) { changed = true }
                kept.append(ourEntry)
            } else {
                // Shared with the user. Our hook comes out and theirs stays exactly where it was,
                // matcher included; ours is placed in an entry of its own (`notificationHookEntry`
                // says why it may not simply join theirs).
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
        hooks[notificationHookEvent] = kept
        var merged = settings
        merged["hooks"] = hooks
        return merged
    }

    /// The settings document without our hook, or nil when there was none. It takes out the one
    /// hook, then every container left empty by its going: the entry, the event, the `hooks` block.
    /// Anything a user put beside it survives at every level.
    static func settingsWithoutNotificationHook(_ settings: [String: Any]) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[notificationHookEvent] as? [[String: Any]] else { return nil }
        var kept: [[String: Any]] = []
        var removed = false
        for entry in entries {
            guard holdsOurNotificationHook(entry) else { kept.append(entry); continue }
            removed = true
            let remaining = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurNotificationHook($0) }
            guard !remaining.isEmpty else { continue }
            var trimmed = entry
            trimmed["hooks"] = remaining
            kept.append(trimmed)
        }
        guard removed else { return nil }
        if kept.isEmpty { hooks.removeValue(forKey: notificationHookEvent) } else {
            hooks[notificationHookEvent] = kept
        }
        var merged = settings
        if hooks.isEmpty { merged.removeValue(forKey: "hooks") } else { merged["hooks"] = hooks }
        return merged
    }

    static func upsertNotificationHook(in file: URL, command: String) throws -> Bool {
        try editSettings(file) { settingsRegisteringNotificationHook($0, command: command) }
    }

    @discardableResult
    static func removeNotificationHook(in file: URL) throws -> Bool {
        try editSettings(file) { settingsWithoutNotificationHook($0) }
    }

    /// Whether a settings.json carries our hook at all. What DETECTION asks, deliberately ignoring
    /// which path the command points at: an entry that is stale is still installed, and the install
    /// repairs the path in place - the same distinction the prompt hook draws, and what stops a dev
    /// build from reporting the release app's registration as broken.
    static func settingsCarryNotificationHook(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (settings["hooks"] as? [String: Any])?[notificationHookEvent]
                as? [[String: Any]] else { return false }
        return entries.contains { holdsOurNotificationHook($0) }
    }

    /// Whether this file's registration is the CURRENT one rather than merely present. Read as the
    /// difference between "installed" and "installed correctly": an entry written before the
    /// matcher existed fires our hook for all nine notification types, four of which are not waits
    /// at all, so it is a live source of false red dots rather than a cosmetic lag.
    static func settingsCarryCurrentNotificationHook(_ file: URL, command: String) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (settings["hooks"] as? [String: Any])?[notificationHookEvent]
                as? [[String: Any]] else { return false }
        return entries.contains { isCurrentNotificationEntry($0, command: command) }
    }

    static func detectNotificationHook() -> Status {
        let files = claudeSettingsFiles()
        guard !files.isEmpty else { return .notInstalled }
        let ours = files.filter { settingsCarryNotificationHook($0) }.count
        if ours == 0 { return .notInstalled }
        guard ours == files.count else { return .broken(L("Not installed for every account")) }
        // Installed everywhere, but at least one of them predates the matcher. Reported as broken
        // rather than as installed so the row offers the repair and "Install all" performs it: the
        // registration works, it simply asks Claude Code for four kinds of event that are not waits.
        // Same word the shim uses for the same situation one integration over.
        let current = files.filter {
            settingsCarryCurrentNotificationHook($0, command: notificationHookCommand)
        }.count
        return current == files.count ? .installed : .broken(L("Older version installed"))
    }

    func installNotificationHook() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            let files = Self.claudeSettingsFiles()
            for file in files {
                _ = try Self.upsertNotificationHook(in: file,
                                                    command: Self.notificationHookCommand)
            }
            recordManifest("claudeNotificationHook", paths: files.isEmpty ? nil : files.map(\.path))
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func removeNotificationHook() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            for file in Self.claudeSettingsFiles() {
                try Self.removeNotificationHook(in: file)
            }
            recordManifest("claudeNotificationHook", paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
