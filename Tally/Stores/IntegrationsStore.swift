import Foundation
import Observation

/// Everything Tally installs OUTSIDE its own bundle - tracked, visible, and one-click reversible.
///
/// Two components today:
/// - `cliTool`: the `/usr/local/bin/tally` symlink onto the bundled CLI (the VS Code
///   "install 'code' command" pattern).
/// - `codexShim`: a `codex` interposer at `~/.tally/bin/codex` plus a marked PATH block in
///   `~/.zshenv`, so bare `codex` invocations follow the app's launch policy.
///
/// Rules: installs are explicit buttons (never silent), every touched path is recorded in
/// `~/.tally/manifest.json`, and shell-file edits live inside `# >>> tally integration >>>`
/// markers so removal is a mechanical block strip that can never eat a user's own lines.
@MainActor
@Observable
final class IntegrationsStore {
    static let shared = IntegrationsStore()

    /// The settings-file watcher behind the prompt-hook self-heal (IntegrationsSelfHeal.swift).
    /// Stored here because an extension cannot hold one, and ignored by observation because nothing
    /// renders it: its whole output is a repair and the refresh that follows one.
    @ObservationIgnored var settingsWatcher: AccountDirWatcher?

    enum Status: Equatable {
        case installed
        case notInstalled
        /// Present but wrong (dangling symlink, missing PATH block, stale shim) - fix = reinstall.
        case broken(String)
    }

    // MARK: Paths

    /// A per-provider PATH interposer: bare `claude` / `codex` invocations follow the launch
    /// policy. Both shims share one bin dir and one PATH block.
    enum Shim: String, CaseIterable {
        case claude, codex
        var envKey: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
        var scriptURL: URL { IntegrationsStore.binDirURL.appendingPathComponent(rawValue) }
        var manifestKey: String { "\(rawValue)Shim" }
    }

    nonisolated static let binDirURL = UsageSnapshot.directory.appendingPathComponent("bin", isDirectory: true)
    nonisolated static let cliSymlinkURL = URL(fileURLWithPath: "/usr/local/bin/tally")
    nonisolated static let manifestURL = UsageSnapshot.directory.appendingPathComponent("manifest.json")
    nonisolated static let zshenvURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".zshenv")

    nonisolated static let blockBegin = "# >>> tally integration >>>"
    nonisolated static let blockEnd = "# <<< tally integration <<<"

    /// Bump when the shim script changes; the store flags older installs for reinstall.
    nonisolated static let shimVersion = 2

    /// The shim itself: ask `tally launch-dir` (which honours Off/Manual/Auto), then hand off to
    /// the first real binary on PATH that isn't this file. Pure bash, no dependencies; fail open.
    static func shimScript(_ shim: Shim) -> String {
        """
        #!/bin/bash
        # tally-shim v\(shimVersion): route bare `\(shim.rawValue)` through the Tally launch policy.
        # Managed by Tally.app (Settings → Integrations); safe to delete.
        # An explicitly exported \(shim.envKey) always wins; without Tally this passes straight through.
        set -u
        if [[ -z "${\(shim.envKey):-}" ]] && command -v tally > /dev/null 2>&1; then
          eval "$(tally launch-dir \(shim.rawValue) 2> /dev/null)" || true
        fi
        while IFS= read -r candidate; do
          [[ "$candidate" != "$HOME/.tally/bin/\(shim.rawValue)" ]] && exec "$candidate" "$@"
        done < <(which -a \(shim.rawValue))
        echo "tally-shim: real \(shim.rawValue) not found on PATH" >&2
        exit 127
        """
    }

    private(set) var cliToolStatus: Status = .notInstalled
    private(set) var shimStatuses: [Shim: Status] = [:]
    private(set) var statusLineStatus: Status = .notInstalled
    private(set) var skillStatus: Status = .notInstalled
    /// Set when an install/remove fails (e.g. /usr/local/bin not writable); shown inline.
    /// Setter internal (not private): the skill extension file writes it too.
    var lastError: String?

    private init() { refresh() }

    // MARK: Status

    func refresh() {
        cliToolStatus = Self.detectCLITool()
        shimStatuses = Dictionary(uniqueKeysWithValues: Shim.allCases.map { ($0, Self.detectShim($0)) })
        statusLineStatus = Self.detectStatusLine()
        skillStatus = Self.detectSkill()
    }

    func shimStatus(_ shim: Shim) -> Status { shimStatuses[shim] ?? .notInstalled }

    private static func detectCLITool() -> Status {
        let fm = FileManager.default
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: cliSymlinkURL.path) else {
            return fm.fileExists(atPath: cliSymlinkURL.path)
                ? .broken(L("Not a symlink Tally manages"))   // a real file someone else put there
                : .notInstalled
        }
        return fm.fileExists(atPath: destination)
            ? .installed
            : .broken(L("Link target is missing"))
    }

    private static func detectShim(_ shim: Shim) -> Status {
        // No script = not installed, full stop. The PATH block is SHARED between shims, so its
        // presence says nothing about THIS shim (installing codex alone must not make the claude
        // row read "broken").
        guard let script = try? String(contentsOf: shim.scriptURL, encoding: .utf8) else {
            return .notInstalled
        }
        let blockPresent = (try? String(contentsOf: zshenvURL, encoding: .utf8))?
            .contains(blockBegin) ?? false
        guard blockPresent else { return .broken(L("PATH entry is missing")) }
        return script.contains("tally-shim v\(shimVersion)")
            ? .installed
            : .broken(L("Older version installed"))
    }

    // MARK: Install / remove

    /// The dev variant never mutates shared system state (the /usr/local/bin link, shell
    /// profiles, claude settings): those integrations belong to the installed release app.
    /// UI-level disabling backs this up; this is the hard gate.
    /// Internal (not private): the skill extension file uses it too.
    func guardNotDev() -> Bool {
        guard BuildVariant.isDev else { return true }
        lastError = L("Integrations are managed by the installed release app.")
        return false
    }

    /// The bundled CLI binary (Contents/Helpers/tally, embedded by the release pipeline).
    /// Internal (not private): the `/tally-switch` hook is registered with an absolute path to it,
    /// so it works whether or not the /usr/local/bin link was ever installed.
    static var bundledCLIURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tally")
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
            recordManifest("cliTool", paths: [Self.cliSymlinkURL.path])
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func removeCLITool() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            try FileManager.default.removeItem(at: Self.cliSymlinkURL)
            recordManifest("cliTool", paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func installShim(_ shim: Shim) {
        guard guardNotDev() else { return }
        lastError = nil
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.binDirURL, withIntermediateDirectories: true)
            try Self.shimScript(shim).write(to: shim.scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.scriptURL.path)
            try Self.upsertBlock(in: Self.zshenvURL, body: "export PATH=\"$HOME/.tally/bin:$PATH\"")
            recordManifest(shim.manifestKey, paths: [shim.scriptURL.path, Self.zshenvURL.path])
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func removeShim(_ shim: Shim) {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            try? FileManager.default.removeItem(at: shim.scriptURL)
            // The PATH block serves every shim - strip it only when the last one is gone.
            let anyLeft = Shim.allCases.contains {
                FileManager.default.fileExists(atPath: $0.scriptURL.path)
            }
            if !anyLeft { try Self.stripBlock(in: Self.zshenvURL) }
            recordManifest(shim.manifestKey, paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    // MARK: Claude status line - "account · model" at the bottom of every claude session

    /// The registered command (provenance marker too: removal only touches an entry that IS
    /// this string). Depends on the CLI tool integration for the stable public path.
    nonisolated static let statusLineCommand = "/usr/local/bin/tally statusline claude"

    /// Every discovered claude config home, NOT deduplicated - the population, as opposed to the
    /// physical-file lists below it.
    ///
    /// Deduplication is right when the question is "which FILE do I write", and wrong when it is
    /// "whose file is this". Homes that share one settings.json, or one skills tree, still have
    /// their own commands folder: asking about the survivor of a dedup and answering for all of
    /// them is how a home's own `/tally-switch` gets taken over (IntegrationsSwitchCommand.swift).
    static func claudeHomes() -> [URL] {
        ClaudeAccounts.discover().compactMap { $0.launchHome.map { URL(fileURLWithPath: $0) } }
    }

    /// Where the skill lives inside one config home. (`claudeSkillFiles()` builds the same path for
    /// the discovered homes; folding it onto this is a follow-up, its file is held open elsewhere.)
    static func claudeSkillFile(inHome home: URL) -> URL {
        home.appendingPathComponent("skills/tally/SKILL.md")
    }

    /// One settings.json per discovered claude home, deduplicated by physical file (shared
    /// setups symlink the same settings everywhere - one edit must not be counted N times).
    /// Internal (not private): the skill's prompt hook is registered in the same files.
    static func claudeSettingsFiles() -> [URL] {
        var seen = Set<String>()
        return ClaudeAccounts.discover().compactMap { account -> URL? in
            guard let home = account.launchHome else { return nil }
            let url = URL(fileURLWithPath: home).appendingPathComponent("settings.json")
            return seen.insert(url.resolvingSymlinksInPath().path).inserted ? url : nil
        }
    }

    private static func detectStatusLine() -> Status {
        let files = claudeSettingsFiles()
        guard !files.isEmpty else { return .notInstalled }
        var ours = 0
        for file in files {
            let settings = (try? JSONSerialization.jsonObject(
                with: (try? Data(contentsOf: file)) ?? Data())) as? [String: Any]
            let command = (settings?["statusLine"] as? [String: Any])?["command"] as? String
            if command?.hasPrefix(statusLineCommand) == true { ours += 1 }
        }
        if ours == 0 { return .notInstalled }
        return ours == files.count ? .installed : .broken(L("Not installed for every account"))
    }

    func installStatusLine() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            let files = Self.claudeSettingsFiles()
            for file in files {
                _ = try Self.upsertStatusLine(in: file, command: Self.statusLineCommand)
            }
            recordManifest("claudeStatusLine", paths: files.isEmpty ? nil : files.map(\.path))
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func removeStatusLine() {
        guard guardNotDev() else { return }
        lastError = nil
        do {
            for file in Self.claudeSettingsFiles() {
                try Self.removeStatusLine(in: file, command: Self.statusLineCommand)
            }
            recordManifest("claudeStatusLine", paths: nil)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Reads settings.json, applies `edit`, and writes it back atomically. Returns true when the
    /// file changed; an edit that returns nil is a no-op, which is how idempotence is expressed.
    ///
    /// The refusal is the point, and it is why every write into this file goes through here: a file
    /// that EXISTS and does not parse is left exactly as it is and reported. Reading it as an empty
    /// document instead (a `try?` and a `?? [:]`) would replace a user's whole harness
    /// configuration with the one key being registered, and the file it would eat is precisely the
    /// one already in trouble. Internal for the unit tests - a mis-write here eats user
    /// configuration. JSON round-trip note: key order is not preserved (settings.json is
    /// machine-managed JSON; Claude Code does the same).
    ///
    /// It writes to the PHYSICAL file, which is not always the path it was handed: this machine's
    /// multi-account setup symlinks `~/.claudeN/settings.json` at the main account's file so one
    /// configuration serves every account. An atomic write replaces the path it is given, so
    /// writing to the link would replace the link with a regular file - severing exactly the
    /// sharing the user set up, silently, and leaving the other accounts on a copy that stops
    /// following their edits.
    static func editSettings(_ file: URL,
                             _ edit: ([String: Any]) -> [String: Any]?) throws -> Bool {
        let target = file.resolvingSymlinksInPath()
        /// The one refusal, reached through two doors: bytes that cannot be read, and bytes that
        /// do not parse. Both mean the same thing here, and cost the same thing if ignored.
        func unreadable() -> Error {
            NSError(domain: "tally", code: 5, userInfo: [
                NSLocalizedDescriptionKey: L("Could not read settings.json, so it was left untouched"),
            ])
        }
        var settings: [String: Any] = [:]
        // Present and unreadable is NOT absent. A permissions failure reaching the `?? [:]` path
        // would rewrite a file whose contents were never seen.
        if FileManager.default.fileExists(atPath: target.path) {
            guard let data = try? Data(contentsOf: target) else { throw unreadable() }
            // An empty file is a fresh document; only bytes that are there and do not parse are
            // the refusal.
            if !data.isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { throw unreadable() }
                settings = parsed
            }
        }
        guard let merged = edit(settings) else { return false }
        let out = try JSONSerialization.data(withJSONObject: merged,
                                             options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: target, options: .atomic)
        return true
    }

    /// Registers Tally's statusLine in one settings.json. A user's OWN status line is never
    /// clobbered: its command is carried inside ours as base64 (`--wrap <b64>` - no shell
    /// quoting minefield, exactly restorable), the CLI keeps running it and appends the
    /// account. Returns true when the file changed.
    static func upsertStatusLine(in file: URL, command: String) throws -> Bool {
        try editSettings(file) { settings in
            let existing = (settings["statusLine"] as? [String: Any])?["command"] as? String
            if existing?.hasPrefix(command) == true { return nil }   // already ours - idempotent
            var registered = command
            if let existing, !existing.isEmpty {
                // Self-healing: if the tally binary ever disappears WITHOUT a clean remove (app
                // dragged to the trash), the shell fallback decodes and runs the user's original
                // status line directly - their setup survives Tally's death untouched.
                let b64 = Data(existing.utf8).base64EncodedString()
                registered += " --wrap \(b64) 2>/dev/null || printf %s \(b64) | base64 -D | /bin/sh"
            }
            var merged = settings
            merged["statusLine"] = ["type": "command", "command": registered]
            return merged
        }
    }

    /// Reverses `upsertStatusLine` exactly: a wrapped registration restores the user's original
    /// command; a plain one removes the entry. Anything not ours is left untouched.
    ///
    /// Through `editSettings` like every other write into this file, which is what makes removal
    /// symlink-safe: it used to write the path it was handed, so uninstalling from a shared setup
    /// severed the link the install had just been careful to keep. Returns true when the file
    /// changed; a file that cannot be read now throws here as it does on install, rather than
    /// reporting a removal that never happened.
    @discardableResult
    static func removeStatusLine(in file: URL, command: String) throws -> Bool {
        try editSettings(file) { settings in
            guard let registered = (settings["statusLine"] as? [String: Any])?["command"] as? String,
                  registered.hasPrefix(command) else { return nil }
            var merged = settings
            let marker = " --wrap "
            if let range = registered.range(of: marker),
               let token = registered[range.upperBound...].split(separator: " ").first,
               let data = Data(base64Encoded: String(token)),
               let original = String(data: data, encoding: .utf8) {
                merged["statusLine"] = ["type": "command", "command": original]
            } else {
                merged.removeValue(forKey: "statusLine")
            }
            return merged
        }
    }

    // MARK: Marked shell-file block

    /// Replace (or append) the tally block. Anything outside the markers is preserved byte-for-byte.
    /// Internal (not private) so the block surgery is unit-testable - a mis-strip eats user config.
    static func upsertBlock(in file: URL, body: String) throws {
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let block = "\(blockBegin)\n\(body)\n\(blockEnd)"
        var content = try stripped(existing)
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        content += block + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    static func stripBlock(in file: URL) throws {
        guard let existing = try? String(contentsOf: file, encoding: .utf8) else { return }
        try stripped(existing).write(to: file, atomically: true, encoding: .utf8)
    }

    /// Content with every marker block removed. Throws if a block is half-open (never guess - a
    /// mis-strip could eat user lines).
    private static func stripped(_ content: String) throws -> String {
        var lines = content.components(separatedBy: "\n")
        while let begin = lines.firstIndex(of: blockBegin) {
            guard let end = lines[begin...].firstIndex(of: blockEnd) else {
                throw NSError(domain: "tally", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: L("Unclosed tally block in shell profile"),
                ])
            }
            lines.removeSubrange(begin ... end)
        }
        // Collapse the blank line the block removal may leave at the tail.
        while lines.count > 1, lines.last == "", lines[lines.count - 2] == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Manifest - provenance of everything installed outside the bundle

    /// Internal (not private): the skill extension file uses it too.
    func recordManifest(_ component: String, paths: [String]?) {
        var manifest = (try? JSONSerialization.jsonObject(
            with: (try? Data(contentsOf: Self.manifestURL)) ?? Data())) as? [String: Any] ?? [:]
        if let paths {
            manifest[component] = [
                "paths": paths,
                "installedAt": ISO8601DateFormatter().string(from: Date()),
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            ]
        } else {
            manifest.removeValue(forKey: component)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: UsageSnapshot.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.manifestURL, options: .atomic)
    }
}
