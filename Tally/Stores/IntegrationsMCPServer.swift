import Foundation

// The MCP server half of the native pickers: the registration that lets Claude Code start
// `tally mcp-serve`, and the judgement about whether this machine's Claude Code can use it at all.
//
// WHERE A SERVER REGISTRATION ACTUALLY GOES, measured rather than assumed (probe T0-2, 2026-08-07):
// `settings.json` has an `mcpServers` key and Claude Code DOES NOT READ IT - a server declared
// there is never spawned, with no error anywhere. The user-scope registration it does read is the
// top level of `.claude.json`, one per config dir.
//
// That file is not settings.json, and the difference decides how this is written:
//
//   - IT IS NOT SHARED. Config homes symlink settings.json to share one harness, but `.claude.json`
//     carries `oauthAccount` and is deliberately per-account (TrustSeed.swift states why). So this
//     is written PER HOME, never per settings group, and a home that is missed is not a cosmetic
//     gap: the pickers are silently dead on that account while every other account has them, which
//     the user experiences as "sometimes it asks and sometimes it does not".
//   - IT IS REWRITTEN CONSTANTLY, by every running session. A read-modify-write over it is
//     therefore a race, and the defence is that it happens almost never: the edit returns nil when
//     the entry is already what it should be, so a write occurs on install and on an app move, not
//     on every launch and not on every heal.
extension IntegrationsStore {
    /// Where the manifest records the state files a registration was written into.
    nonisolated static let mcpServerManifest = "claudeMCPServer"

    /// The registration itself: run this app's bundled CLI with the one subcommand.
    ///
    /// The absolute path to the bundled helper, exactly as the hook entries use, and for the same
    /// reason: it works whether or not `/usr/local/bin/tally` was ever installed, and an app that
    /// moves is repaired by the sync rewriting this value.
    nonisolated static func mcpServerEntry(_ binary: URL) -> [String: Any] {
        ["type": "stdio", "command": binary.path, "args": [mcpServeCommand], "env": [:]]
    }

    /// The state document with our server registered, or nil when nothing needs to change.
    ///
    /// Pure, and conservative in the same direction as the settings surgery: an `mcpServers` value
    /// of an unexpected SHAPE returns nil, because the only safe edit to a document we cannot read
    /// is none. Servers belonging to anyone else come out the far side untouched.
    nonisolated static func stateRegisteringMCPServer(_ state: [String: Any],
                                                      entry: [String: Any]) -> [String: Any]? {
        var servers: [String: Any]
        switch state["mcpServers"] {
        case nil: servers = [:]
        case let existing as [String: Any]: servers = existing
        default: return nil
        }
        if let current = servers[tallyMCPServerName] as? [String: Any],
           NSDictionary(dictionary: current).isEqual(to: entry) { return nil }
        servers[tallyMCPServerName] = entry
        var merged = state
        merged["mcpServers"] = servers
        return merged
    }

    /// The same document without it, or nil when it was not there. The `mcpServers` block itself
    /// goes when ours was the only server in it, exactly as the hook removal empties its containers.
    nonisolated static func stateWithoutMCPServer(_ state: [String: Any]) -> [String: Any]? {
        guard var servers = state["mcpServers"] as? [String: Any],
              servers[tallyMCPServerName] != nil else { return nil }
        servers.removeValue(forKey: tallyMCPServerName)
        var merged = state
        if servers.isEmpty {
            merged.removeValue(forKey: "mcpServers")
        } else {
            merged["mcpServers"] = servers
        }
        return merged
    }

    /// Read `.claude.json`, apply `edit`, write it back atomically. True when the file changed; an
    /// edit that returns nil is a no-op, which is how idempotence is expressed here.
    ///
    /// The same refusal as `editSettings`, and it matters more here: this document is another
    /// program's, it is large, and it holds the account's identity. Bytes that exist and do not
    /// parse are left exactly as they are rather than replaced by a document containing only the
    /// key being registered. An ABSENT file is a fresh document, because a config home prepared for
    /// an account that has not run Claude Code yet has none, and it must still get the pickers.
    ///
    /// Key order is not preserved (JSON round trip). Claude Code rewrites this file itself
    /// constantly, so it is machine-managed on both sides.
    static func editClaudeState(_ file: URL,
                                _ edit: ([String: Any]) -> [String: Any]?) throws -> Bool {
        let target = file.resolvingSymlinksInPath()
        func unreadable() -> Error {
            NSError(domain: "tally", code: 6, userInfo: [
                NSLocalizedDescriptionKey: L("Could not read .claude.json, so it was left untouched"),
            ])
        }
        var state: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: target.path) {
            guard let data = try? Data(contentsOf: target) else { throw unreadable() }
            if !data.isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { throw unreadable() }
                state = parsed
            }
        }
        guard let merged = edit(state) else { return false }
        let out = try JSONSerialization.data(withJSONObject: merged,
                                             options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: target, options: .atomic)
        return true
    }

    static func upsertMCPServer(in file: URL, binary: URL) throws -> Bool {
        try editClaudeState(file) { stateRegisteringMCPServer($0, entry: mcpServerEntry(binary)) }
    }

    @discardableResult
    static func removeMCPServer(in file: URL) throws -> Bool {
        try editClaudeState(file) { stateWithoutMCPServer($0) }
    }

    /// Whether that file registers OUR server, at THIS app's path.
    ///
    /// Exact rather than "an entry named tally is there", the same condition the hook entries are
    /// judged by: a registration pointing at a bundle that has moved spawns nothing, so every
    /// `/tally-account` falls back to the backstop while the file reads as installed.
    nonisolated static func mcpServerIsRegistered(_ file: URL, binary: URL) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = (state["mcpServers"] as? [String: Any])?[tallyMCPServerName]
                as? [String: Any] else { return false }
        return NSDictionary(dictionary: entry).isEqual(to: mcpServerEntry(binary))
    }

    /// What one sync of the server registration came to. A result rather than a throw, because one
    /// home that cannot be written must not stop the next.
    struct MCPServerSync {
        var changed = false
        /// The state files holding, or possibly still holding, our registration. What the manifest
        /// records, so an uninstall can always reach what an install left - including a file the
        /// write failed on.
        var files: [URL] = []
        var error: String?
    }

    /// Register (or withdraw) the server in every home, one file each.
    ///
    /// `nativePicker` false is a WITHDRAWAL rather than a skip: the gate can go from yes to no when
    /// a user downgrades Claude Code, and a registration left behind would start a server for hooks
    /// that are no longer written in the tool shape - a process per session, doing nothing.
    static func syncMCPServer(inHomes homes: [URL], binary: URL,
                              nativePicker: Bool) -> MCPServerSync {
        var result = MCPServerSync()
        for home in homes {
            let file = claudeStateFile(forConfigDir: home)
            do {
                if nativePicker {
                    result.changed = try upsertMCPServer(in: file, binary: binary) || result.changed
                    result.files.append(file)
                } else if try removeMCPServer(in: file) {
                    result.changed = true
                }
            } catch {
                result.error = result.error ?? error.localizedDescription
                // The file could not be acted on, so whatever is in it is still in it: recorded
                // deliberately, or an uninstall would walk past a registration we wrote.
                result.files.append(file)
            }
        }
        return result
    }

    // MARK: - Whether this machine's Claude Code can use any of it

    /// The string a Claude Code that understands the hook type carries in its binary.
    nonisolated static let mcpHookTypeToken = "mcp_tool"

    /// Whether the installed Claude Code understands an `mcp_tool` hook.
    ///
    /// READ, NEVER RUN. This repo does not probe `claude -p` to learn what a build supports
    /// (Snapshot.swift states the rule, and the CLI's own model-source order was established the
    /// same way): a probe costs a session, a token refresh and a transcript, and it is the user's
    /// quota being spent. So the binary is searched for the token, mapped rather than loaded, and
    /// the answer is remembered for the life of the process.
    ///
    /// WHAT IT BUYS, since the pair is registered with a backstop either way: an older Claude Code
    /// meeting a hook `type` it does not know may reject the ENTRY holding it, which would take the
    /// backstop down with it and leave the command answered by a model turn. The gate keeps those
    /// machines on exactly the registration they have today.
    ///
    /// A binary that cannot be found or read answers NO, which is the direction that changes
    /// nothing: the commands keep the shape they have had all along.
    nonisolated static func claudeSupportsMCPHooks(binary: String?) -> Bool {
        guard let binary,
              let data = try? Data(contentsOf: URL(fileURLWithPath: binary),
                                   options: [.mappedIfSafe]) else { return false }
        return data.range(of: Data(mcpHookTypeToken.utf8)) != nil
    }

    /// The same answer for this machine, asked once. Cached because the search walks a few hundred
    /// megabytes and both the sync and the self-heal gate need it - and because they must never
    /// disagree: a sync that registered the pair while the heal expected the old shape would repair
    /// a file that was already correct, on every filesystem event, forever.
    ///
    /// A Claude Code upgraded WHILE the app runs is therefore seen at the next launch rather than
    /// at once, which is the same latency every other integration repair has.
    static var nativePickerIsSupported: Bool {
        if let remembered = nativePickerSupportCache { return remembered }
        let answer = claudeSupportsMCPHooks(binary: CLIRunner.resolve("claude"))
        nativePickerSupportCache = answer
        return answer
    }

    private static var nativePickerSupportCache: Bool?
}
