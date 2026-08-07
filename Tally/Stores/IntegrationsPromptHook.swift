import Foundation

// The HOOK half of a slash command: the `UserPromptExpansion` entry in a user's settings.json that
// answers `/tally-account` and `/tally-model` before any model is woken, and the surgery that puts
// it there and takes it back out. Split from IntegrationsPromptCommand.swift on file size; the
// command file it falls back to, the sync that installs the pair and the uninstall that removes it
// are all still in that file, and the descriptors are in their own.
//
// settings.json is the user's own file, shared by symlink across accounts on some setups, and it
// holds their whole harness. So every write here is read-modify-write over the parsed document,
// touching exactly one array entry: the one whose command runs OUR subcommand. Anything a user put
// beside it comes out the far side unchanged, at every level - the hook, the entry, the event.
extension IntegrationsStore {
    /// The hook event Claude Code fires when a slash command is typed, before a model runs.
    nonisolated static let promptHookEvent = "UserPromptExpansion"

    /// Quoted, because the release app lives at a fixed path but a dev build does not, and app
    /// bundle paths may contain spaces.
    nonisolated static func promptHookCommand(_ binary: URL, command: PromptCommand) -> String {
        "\"\(binary.path)\" \(command.hookMarker)"
    }

    /// Provenance, and the ONLY entry this code may rewrite or delete: it fires for OUR command and
    /// ends in our subcommand as its own word.
    ///
    /// Both halves are load-bearing, and the second is why this is a suffix rather than a substring
    /// (which is what it was): a user's `/usr/local/bin/my-hook-switcher` contains "hook-switch",
    /// and treating it as ours would silently replace their hook with a Tally registration and
    /// delete it on uninstall. Two conditions cost one line and mean an accident has to be
    /// deliberate.
    private static func isOurHook(_ hook: [String: Any], command: PromptCommand) -> Bool {
        ((hook["command"] as? String)?.hasSuffix(" \(command.hookMarker)")) == true
    }

    /// An entry that HOLDS our hook. Ownership stops here: what may be rewritten or deleted is the
    /// single hook above, never the entry around it.
    ///
    /// The distinction is the whole point. One entry's `hooks` array can hold several commands, all
    /// firing for the same slash command, and a user is free to put their own beside Tally's.
    /// Replacing the ENTRY (which is what this did) took the neighbours with it: overwritten on an
    /// update, deleted on uninstall, with nothing anywhere to say where they went.
    private static func holdsOurHook(_ entry: [String: Any], command: PromptCommand,
                                     matcher: String? = nil) -> Bool {
        guard entry["matcher"] as? String == (matcher ?? command.name) else { return false }
        return (entry["hooks"] as? [[String: Any]] ?? []).contains { isOurHook($0, command: command) }
    }

    /// The settings document with our hook registered, or nil when nothing needs to change.
    ///
    /// Pure, so the one property that matters can be tested without a home directory: everything
    /// that is not our entry comes out the other side untouched. Conservative in both directions -
    /// a `hooks` value, or an event list, of an unexpected SHAPE also returns nil, because the only
    /// safe edit to a document we cannot read is none.
    static func settingsRegisteringPromptHook(_ settings: [String: Any], command hookCommand: String,
                                              hook: PromptCommand) -> [String: Any]? {
        var hooks: [String: Any]
        switch settings["hooks"] {
        case nil: hooks = [:]
        case let existing as [String: Any]: hooks = existing
        default: return nil
        }
        var entries: [[String: Any]]
        switch hooks[promptHookEvent] {
        case nil: entries = []
        case let existing as [[String: Any]]: entries = existing
        default: return nil
        }
        let ours: [String: Any] = ["type": "command", "command": hookCommand]
        // EVERY registration of ours in the file, not the first one found. Our own writes make at
        // most one (a fresh entry is appended only when none is there), but the file this edits is
        // rewritten by things that know nothing about Tally - a dotfiles merge, two config homes
        // folded into one, a hand edit - and any of them can leave a second copy. Claude Code runs
        // ALL the hooks that match, so a stale duplicate goes on answering `/tally-account` with
        // "No such file or directory" while the repaired one beside it works.
        //
        // The check face reads the same way (`registeredPromptHookCommands`), and they have to move
        // together: detection that sees every copy while the repair fixes one would report damage
        // that no amount of repairing settles.
        var changed = false
        var found = false
        for index in entries.indices where holdsOurHook(entries[index], command: hook) {
            found = true
            // Our hook, in place, with whatever else the user put in that entry left exactly where
            // it is and in the order they had it.
            var inner = entries[index]["hooks"] as? [[String: Any]] ?? []
            for slot in inner.indices where isOurHook(inner[slot], command: hook) {
                if NSDictionary(dictionary: inner[slot]).isEqual(to: ours) { continue }
                inner[slot] = ours
                changed = true
            }
            entries[index]["hooks"] = inner
        }
        if !found {
            // A fresh entry holding only ours. Deliberately not merged into an entry the user wrote
            // themselves: that entry is theirs, and adding to it is still editing it.
            entries.append(["matcher": hook.name, "hooks": [ours]])
            changed = true
        }
        guard changed else { return nil }
        hooks[promptHookEvent] = entries
        var merged = settings
        merged["hooks"] = hooks
        return merged
    }

    /// The settings document without our hook, or nil when there was none. It takes out the one
    /// hook, then every container that is left empty by its going: the entry, the event, the
    /// `hooks` block. Anything a user put beside it survives at every level.
    /// - Parameter matcher: which name to take out, defaulting to the one the command answers to
    ///   now. A former name is passed here by the rename cleanup, and it is the ONLY difference
    ///   between the two: an entry under either name is ours by the same test, because the
    ///   subcommand behind it never changed.
    static func settingsWithoutPromptHook(_ settings: [String: Any], hook: PromptCommand,
                                          matcher: String? = nil) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[promptHookEvent] as? [[String: Any]] else { return nil }
        var kept: [[String: Any]] = []
        var removed = false
        for entry in entries {
            guard holdsOurHook(entry, command: hook, matcher: matcher) else { kept.append(entry); continue }
            removed = true
            let remaining = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurHook($0, command: hook) }
            // An entry that was ours alone goes; one the user shared with us keeps its own hooks.
            guard !remaining.isEmpty else { continue }
            var trimmed = entry
            trimmed["hooks"] = remaining
            kept.append(trimmed)
        }
        guard removed else { return nil }
        if kept.isEmpty { hooks.removeValue(forKey: promptHookEvent) } else {
            hooks[promptHookEvent] = kept
        }
        var merged = settings
        if hooks.isEmpty { merged.removeValue(forKey: "hooks") } else { merged["hooks"] = hooks }
        return merged
    }

    static func upsertPromptHook(in file: URL, command: String, hook: PromptCommand) throws -> Bool {
        try editSettings(file) { settingsRegisteringPromptHook($0, command: command, hook: hook) }
    }

    static func removePromptHook(in file: URL, hook: PromptCommand,
                                 matcher: String? = nil) throws -> Bool {
        try editSettings(file) { settingsWithoutPromptHook($0, hook: hook, matcher: matcher) }
    }

    /// The registration side of `removePromptCommandEveryName`, for the same reason: an entry under
    /// a former name whose cleanup failed at sync time is still ours, still intercepts a command
    /// nobody is offered, and this is the last pass that will ever look for it.
    static func removePromptHookEveryName(in file: URL, hook: PromptCommand) throws -> Bool {
        var changed = false
        var failure: Error?
        for matcher in [hook.name] + hook.formerNames {
            do { changed = try removePromptHook(in: file, hook: hook, matcher: matcher) || changed }
            catch { failure = failure ?? error }
        }
        if let failure { throw failure }
        return changed
    }

    /// Whether a settings.json carries our hook at all, regardless of the path it points at. What
    /// detection asks (an entry that is stale is still installed; the launch sync repairs the path
    /// silently), which is also what keeps a dev build from reporting the release app's install as
    /// broken because the two bundles sit in different places.
    static func settingsCarryPromptHook(_ file: URL, hook: PromptCommand) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (settings["hooks"] as? [String: Any])?[promptHookEvent]
                as? [[String: Any]] else { return false }
        return entries.contains { holdsOurHook($0, command: hook) }
    }

    /// EVERY command line our hooks in this file actually run, in the order the file holds them.
    ///
    /// The question `settingsCarryPromptHook` deliberately does not ask, and it has to be asked
    /// somewhere: an entry can be present and point at a binary that is not there any more, which
    /// on a user's machine is not a subtle failure - every `/tally-account` answers "No such file or
    /// directory" and falls through to a model turn, spending exactly the tokens the hook exists to
    /// save.
    ///
    /// Plural because one file can hold more than one registration of ours (see the upsert), and the
    /// stale one is the one that costs the turn. Reading only the first says "all is well" while the
    /// second copy is doing the damage.
    static func registeredPromptHookCommands(_ file: URL, hook: PromptCommand) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (settings["hooks"] as? [String: Any])?[promptHookEvent]
                as? [[String: Any]] else { return [] }
        return entries.filter { holdsOurHook($0, command: hook) }
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
            .compactMap { $0["command"] as? String }
            .filter { $0.hasSuffix(" \(hook.hookMarker)") }
    }
}
