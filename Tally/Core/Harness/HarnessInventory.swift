import CoreFoundation
import Foundation

enum HarnessInventory {
    // A shell assignment works with both native hook schemas. This identifies an
    // adapter for inventory only; removal still requires an exact owned receipt.
    static let commandMarker = "TALLY_HARNESS_ENTRY=1 "
    static let events: Set<String> = ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse",
        "PreCompact", "PostCompact", "UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop"]

    // These existing integrations consume Claude session payloads. Recognize the
    // direct CLI forms written by their installers, including quoted app paths.
    // Classification does not authorize changing or removing the source entry.
    static func isClaudeIntegration(_ command: String) -> Bool {
        let executable = #"(?:tally|[^\s\"']*/tally|\"[^\"]*/tally\"|'[^']*/tally')"#
        let verb = #"hook-(?:agents|knock|artifact|notify|tally|switch|model)"#
        return command.range(of: #"^\s*"# + executable + #"\s+"# + verb + #"(?=\s|$)"#,
                             options: .regularExpression) != nil
    }

    static func definition(event: String, group: [String: Any], handler: [String: Any]) throws -> String {
        try HarnessIO.hash(HarnessIO.json(["event": event, "matcher": group["matcher"] ?? "", "handler": handler]))
    }

    static func matches(_ pattern: String, _ name: String) -> Bool {
        if pattern.isEmpty || pattern == "*" { return true }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func hooks(at path: String, document supplied: [String: Any]? = nil) throws -> [HarnessHook] {
        let document = try supplied ?? HarnessIO.document(path)
        guard document["hooks"] == nil || document["hooks"] is [String: Any] else {
            throw HarnessError("Invalid hooks object: \(path)")
        }
        var rows: [HarnessHook] = []
        for (event, value) in (document["hooks"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let groups = value as? [[String: Any]] else {
                throw HarnessError("Invalid hook groups for \(event): \(path)")
            }
            for (groupIndex, group) in groups.enumerated() {
                guard let handlers = group["hooks"] as? [[String: Any]],
                      group["matcher"] == nil || group["matcher"] is String else {
                    throw HarnessError("Invalid hook group in \(path)")
                }
                let matcher = group["matcher"] as? String ?? ""
                for (handlerIndex, handler) in handlers.enumerated() {
                    let hash = try definition(event: event, group: group, handler: handler)
                    let id = HarnessIO.hash(Data("\(path)\n\(event)\n\(groupIndex)\n\(handlerIndex)\n\(hash)".utf8))
                    let timeout = (handler["timeout"] as? NSNumber)?.doubleValue ?? 60
                    let reason: String
                    if (handler["command"] as? String)?.hasPrefix(commandMarker) == true {
                        reason = "Tally-managed entry; not bridged back into itself."
                    } else if let command = handler["command"] as? String, isClaudeIntegration(command) {
                        reason = "Tally Claude-specific integration; requires a provider-specific implementation."
                    } else if !events.contains(event) {
                        reason = "No supported event adapter."
                    } else if handler["type"] as? String != "command" {
                        reason = "Only command hooks have a protocol adapter."
                    } else if let command = handler["command"] as? String,
                              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !command.contains("\0") {
                        if handler["async"] as? Bool == true || handler["asyncRewake"] as? Bool == true {
                            reason = "Background hook scheduling requires separate adaptation."
                        } else if handler["timeout"] != nil && ((handler["timeout"] as? NSNumber) == nil
                            || CFGetTypeID(handler["timeout"] as! NSNumber) == CFBooleanGetTypeID()) {
                            reason = "Timeout must be a number."
                        } else if !timeout.isFinite || timeout <= 0 || timeout > 600 {
                            reason = "Timeout must be greater than zero and at most 600 seconds."
                        } else if !matcher.isEmpty && matcher != "*" && (try? NSRegularExpression(pattern: matcher)) == nil {
                            reason = "Matcher is not a supported regular expression."
                        } else if ["Stop", "UserPromptSubmit"].contains(event) && !["", "*"].contains(matcher) {
                            reason = "Codex ignores this event's matcher; automatic installation would widen it."
                        } else {
                            reason = "Protocol adapter available; hook behavior and native trust require verification."
                        }
                    } else {
                        reason = "Command must be a nonempty string without NUL bytes."
                    }
                    rows.append(HarnessHook(id: id, source: path, event: event, group: groupIndex,
                        handler: handlerIndex, matcher: matcher, definitionHash: hash, timeout: timeout,
                        disposition: reason.hasPrefix("Protocol adapter") ? "protocol-candidate" : "needs-adaptation",
                        reason: reason))
                }
            }
        }
        return rows
    }

    static func sourceHandler(_ entry: HarnessHook) throws -> [String: Any] {
        guard let handler = try resolveHandler(entry, knownDefinitions: []) else {
            throw HarnessError("Source hook was removed.")
        }
        return handler
    }

    static func resolveHandler(_ entry: HarnessHook, knownDefinitions: Set<String>) throws -> [String: Any]? {
        let document = try HarnessIO.document(entry.source)
        let current = try hooks(at: entry.source, document: document)
        let matches = current.filter { $0.event == entry.event && $0.definitionHash == entry.definitionHash }
        let selected = matches.first(where: { $0.group == entry.group && $0.handler == entry.handler })
            ?? (matches.count == 1 ? matches[0] : nil)
        if let selected, let groups = (document["hooks"] as? [String: Any])?[entry.event] as? [[String: Any]],
           let handlers = groups[selected.group]["hooks"] as? [[String: Any]] {
            return handlers[selected.handler]
        }
        if matches.isEmpty && Set(current.map(\.definitionHash)).isSubset(of: knownDefinitions) { return nil }
        throw HarnessError("Source hook definition changed. Review the harness plan before reinstalling.")
    }

    static func plan(_ location: HarnessLocation) throws -> HarnessPlan {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.sourceRoot, isDirectory: &directory), directory.boolValue else {
            throw HarnessError("The source configuration directory does not exist.")
        }
        guard !location.sourceConfigs.map(HarnessIO.canonical).contains(location.targetConfig) else {
            throw HarnessError("Source and target resolve to the same configuration file.")
        }
        let installations = HarnessInstallation.installations(in: location.stateRoot)
        let owned = installations.flatMap(\.registrations) + (try HarnessTools.registrations(in: location.stateRoot))
        let hooks = try location.sourceConfigs.flatMap { try self.hooks(at: $0) }.filter { row in
            !owned.contains { $0.path == row.source && $0.event == row.event && $0.definitionHash == row.definitionHash }
        }
        var links: [HarnessLink] = [], conflicts: [String] = [], notices = [
            "Command hooks only. Plugin and managed hooks are outside this settings-file inventory.",
            "New Codex definitions need review in /hooks. Installation does not establish trust or behavioral parity."
        ]
        if location.scope == "user", HarnessIO.exists(location.sourceRoot + "/settings.local.json") {
            notices.append("settings.local.json exists in the source home but is not part of the documented user settings inventory. Inspect its actual project-local scope separately.")
        }
        let sourceSkills = location.sourceRoot + "/skills"
        if FileManager.default.fileExists(atPath: sourceSkills) {
            for name in try FileManager.default.contentsOfDirectory(atPath: sourceSkills).sorted() {
                let source = sourceSkills + "/" + name, target = location.targetSkills + "/" + name
                guard !name.hasPrefix(".") else { continue }
                if name == "tally-harness" {
                    notices.append("The tally-harness name is reserved for the product workflow.")
                    continue
                }
                guard FileManager.default.fileExists(atPath: source + "/SKILL.md") else {
                    notices.append("Skill needs a readable SKILL.md: \(name)")
                    continue
                }
                if HarnessIO.exists(target) {
                    if HarnessIO.canonical(source) != HarnessIO.canonical(target) {
                        conflicts.append("A different skill already occupies \(target)")
                    } else if installations.flatMap(\.links).contains(where: { $0.target == target }) {
                        links.append(HarnessLink(source: source, target: target))
                    }
                } else {
                    links.append(HarnessLink(source: source, target: target))
                }
            }
        }
        if location.targetConfig != location.targetRoot + "/hooks.json" {
            notices.append("Shared hooks file: \(location.targetConfig). The link stays intact; inspect native trust in each Codex home.")
        }
        for path in [location.targetInstructions] {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
                if path == location.targetInstructions && HarnessIO.canonical(path) == HarnessIO.canonical(location.sourceInstructions) {
                    notices.append("AGENTS.md already links to the source. Tally will leave it intact and supply guidance through SessionStart.")
                } else { notices.append("Shared instruction file: \(HarnessIO.canonical(path)). The symbolic link stays intact.") }
            }
        }
        let skillPath = location.targetSkills + "/tally-harness/SKILL.md"
        let sharedOwned = try HarnessTools.skillPaths(in: location.stateRoot).contains(skillPath)
            || HarnessInstallation.installations(in: location.stateRoot).contains { manifest in
            manifest.files.contains { $0.path == skillPath && $0.kind == "shared-skill" }
        }
        if HarnessIO.exists(location.targetSkills + "/tally-harness") && !HarnessIO.exists(location.manifestPath) && !sharedOwned {
            conflicts.append("A tally-harness skill already exists without this installation's receipt.")
        }
        _ = try HarnessIO.document(location.targetConfig)
        let gitVisible = try HarnessProjectPaths.visible(location, links: links)
        return HarnessPlan(location: location, hooks: hooks, links: links, conflicts: conflicts,
                           notices: notices, projectGitVisible: gitVisible)
    }
}
