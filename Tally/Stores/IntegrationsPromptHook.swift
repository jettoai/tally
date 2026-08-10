import Foundation

// The HOOK half of a slash command: the `UserPromptExpansion` entry in a user's settings.json that
// answers `/tally` before any model is woken, and the surgery that puts it there and takes it back
// out. Split from IntegrationsPromptCommand.swift on file size; the command file it falls back to,
// the sync that installs the pair and the uninstall that removes it are all still in that file, and
// the descriptor is in its own.
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

    /// The same command line as the BACKSTOP beside a tool call: it answers only when the native
    /// picker is not there to (PromptHookBackstop.swift makes the judgement).
    nonisolated static func promptBackstopCommand(_ binary: URL, command: PromptCommand) -> String {
        "\(promptHookCommand(binary, command: command)) \(promptHookBackstopFlag)"
    }

    /// How long a tool hook may take. A dialog waits on a PERSON, so the number is a person's
    /// patience rather than a program's.
    ///
    /// SIX HOURS, AND THE PREVIOUS VALUE WAS A CLIFF. This was 300 seconds, written to sound
    /// generous and never measured against anyone actually using it - and Claude Code's own default
    /// for an `mcp_tool` hook is 600, so the "generous" number HALVED it. Measured 2026-08-07:
    /// Albert left the account dialog open for about 36 minutes while reading the figures and
    /// taking screenshots; at 300 seconds the hook was cancelled, the expansion was let through,
    /// and the command file reached a model running opus at xhigh, which spent roughly 1,700 output
    /// tokens thinking about it. The whole feature exists to make that turn not happen.
    ///
    /// Reading a dialog and thinking about it is not a stall, so the number has to be past any
    /// plausible dwell rather than merely above the last one measured. It is still bounded, and the
    /// bound is the only thing on the other side: a tool call that wedges with no dialog on screen
    /// holds the prompt until this expires. The person's own way out is the dialog's Escape, which
    /// costs nothing and is instant (`mcpNothingChanged`, MCPPicker.swift) - the timeout was never
    /// the exit and must not be treated as one.
    nonisolated static let mcpHookTimeout = 21_600

    /// The hooks one command's entry must hold, in order.
    ///
    /// TWO OF THEM WHEN THE NATIVE PICKER IS AVAILABLE, and the pair is the design rather than a
    /// belt-and-braces habit. The `mcp_tool` hook raises the dialog; the command hook is the
    /// fallback for every machine and moment the dialog cannot happen - a session older than the
    /// registration, a server that failed to start, a Claude Code that skipped the tool. It is
    /// CONDITIONAL for a measured reason (probe C2, 2026-08-07): hooks run in parallel and the
    /// first decision wins, so an unconditional second hook beats the dialog every time and leaves
    /// it drawn over an answered prompt.
    ///
    /// Without the picker it is the single plain command, byte for byte what every install has had
    /// since the hooks shipped: the gate's whole promise is that those machines do not change.
    nonisolated static func promptHookEntries(_ binary: URL, command: PromptCommand,
                                              nativePicker: Bool) -> [[String: Any]] {
        guard nativePicker else {
            return [["type": "command", "command": promptHookCommand(binary, command: command)]]
        }
        return [
            ["type": mcpHookTypeToken, "server": tallyMCPServerName,
             "tool": command.mcpTool.rawValue, "input": promptHookInputBlock(),
             "timeout": mcpHookTimeout],
            ["type": "command", "command": promptBackstopCommand(binary, command: command)],
        ]
    }

    /// Whether two lists of hooks are the same, entry by entry and field by field.
    nonisolated static func promptHooksMatch(_ one: [[String: Any]],
                                             _ other: [[String: Any]]) -> Bool {
        one.count == other.count
            && zip(one, other).allSatisfy { NSDictionary(dictionary: $0).isEqual(to: $1) }
    }

    /// Provenance, and the ONLY hook this code may rewrite or delete.
    ///
    /// TWO SHAPES ANSWER TO IT, because one registration now has two of them. A tool hook is ours
    /// when it calls OUR server's tool for THIS command; a command hook is ours when it ends in our
    /// subcommand as its own word, with or without the backstop flag after it.
    ///
    /// The command half is a suffix rather than a substring, and that half is load-bearing: a
    /// user's `/usr/local/bin/my-hook-switcher` contains "hook-switch", and treating it as ours
    /// would silently replace their hook with a Tally registration and delete it on uninstall. The
    /// tool half is exact on both fields for the same reason - somebody else's MCP server may
    /// perfectly well offer a tool called `pick_model`.
    ///
    /// AND WHAT IT USED TO BE, which is what makes a merge cleanable. An entry written before two
    /// commands became one runs the old subcommand and calls the old tool, and is ours by exactly
    /// the same reasoning as one written yesterday (`PromptCommand.formerHookMarkers`).
    private static func isOurHook(_ hook: [String: Any], command: PromptCommand) -> Bool {
        if hook["type"] as? String == mcpHookTypeToken {
            let tools = ([command.mcpTool] + command.formerTools).map(\.rawValue)
            return hook["server"] as? String == tallyMCPServerName
                && tools.contains(hook["tool"] as? String ?? "")
        }
        guard let line = hook["command"] as? String else { return false }
        // The flag is stripped before the marker is looked for, so one rule covers both command
        // shapes: a backstop entry left by a newer app is still ours to an older one, and an entry
        // written before the flag existed is still ours to this one.
        let bare = line.hasSuffix(" \(promptHookBackstopFlag)")
            ? String(line.dropLast(promptHookBackstopFlag.count + 1)) : line
        return ([command.hookMarker] + command.formerHookMarkers).contains {
            bare.hasSuffix(" \($0)")
        }
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
    static func settingsRegisteringPromptHook(_ settings: [String: Any], hooks ours: [[String: Any]],
                                              hook: PromptCommand) -> [String: Any]? {
        var hooks: [String: Any]
        switch settings["hooks"] {
        case nil: hooks = [:]
        case let existing as [String: Any]: hooks = existing
        default: return nil
        }
        let entries: [[String: Any]]
        switch hooks[promptHookEvent] {
        case nil: entries = []
        case let existing as [[String: Any]]: entries = existing
        default: return nil
        }
        // EXACTLY ONE REGISTRATION OF OURS COMES OUT OF THIS, wherever the file had them. Our own
        // writes make at most one (a fresh entry is appended only when none is there), but the file
        // this edits is rewritten by things that know nothing about Tally - a dotfiles merge, two
        // config homes folded into one, a hand edit - and any of them can leave a second copy.
        //
        // Both halves of that matter, and the second is the one that is easy to miss. Claude Code
        // runs ALL the hooks that match, so a STALE duplicate answers `/tally-account` with "No such
        // file or directory" beside the good one; but rewriting each copy to the current command
        // instead of merging them just makes the duplicate work, and then the command runs TWICE on
        // every prompt - two answers, two writes - while the self-heal reads every copy as correct
        // and never has anything left to say (codex review of e7fe1a0).
        //
        // What is NOT collapsed is anything that is not ours: a hook a user put beside ours stays in
        // the entry it is in, in the order they had it. An entry left holding nothing but the
        // duplicate we took out goes, exactly as the uninstall treats one that was ours alone.
        //
        // "One registration" now means one SET rather than one hook (`promptHookEntries`), and the
        // whole set lands where the first of ours was: a file holding the old single command hook
        // gains the tool hook in its place, in the entry the user already had it in, rather than a
        // second entry appearing beside the first.
        var changed = false
        var placed = false
        var kept: [[String: Any]] = []
        for entry in entries {
            guard holdsOurHook(entry, command: hook) else { kept.append(entry); continue }
            let before = entry["hooks"] as? [[String: Any]] ?? []
            var rebuilt: [[String: Any]] = []
            for slot in before {
                guard isOurHook(slot, command: hook) else { rebuilt.append(slot); continue }
                guard !placed else { continue }   // a second copy of ours: it goes
                placed = true
                rebuilt.append(contentsOf: ours)
            }
            if !promptHooksMatch(rebuilt, before) { changed = true }
            guard !rebuilt.isEmpty else { continue }
            var trimmed = entry
            trimmed["hooks"] = rebuilt
            kept.append(trimmed)
        }
        if !placed {
            // A fresh entry holding only ours. Deliberately not merged into an entry the user wrote
            // themselves: that entry is theirs, and adding to it is still editing it.
            kept.append(["matcher": hook.name, "hooks": ours])
            changed = true
        }
        guard changed else { return nil }
        hooks[promptHookEvent] = kept
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

    static func upsertPromptHook(in file: URL, hooks: [[String: Any]],
                                 hook: PromptCommand) throws -> Bool {
        try editSettings(file) { settingsRegisteringPromptHook($0, hooks: hooks, hook: hook) }
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

    /// EVERY hook of ours this file actually holds, in the order the file holds them.
    ///
    /// The question `settingsCarryPromptHook` deliberately does not ask, and it has to be asked
    /// somewhere: an entry can be present and point at a binary that is not there any more, which
    /// on a user's machine is not a subtle failure - every `/tally-account` answers "No such file or
    /// directory" and falls through to a model turn, spending exactly the tokens the hook exists to
    /// save.
    ///
    /// Plural because one file can hold more than one registration of ours (see the upsert), and the
    /// stale one is the one that costs the turn. Reading only the first says "all is well" while the
    /// second copy is doing the damage. WHOLE HOOKS rather than command lines, because half of one
    /// registration has no command line at all now: a tool hook that names the wrong server is
    /// exactly as broken as a command hook naming a binary that moved, and only the full entry says
    /// so.
    static func registeredPromptHooks(_ file: URL, hook: PromptCommand) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (settings["hooks"] as? [String: Any])?[promptHookEvent]
                as? [[String: Any]] else { return [] }
        return entries.filter { holdsOurHook($0, command: hook) }
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
            .filter { isOurHook($0, command: hook) }
    }

    /// The command lines among them, for the surfaces that ask what will actually be RUN.
    static func registeredPromptHookCommands(_ file: URL, hook: PromptCommand) -> [String] {
        registeredPromptHooks(file, hook: hook).compactMap { $0["command"] as? String }
    }
}
