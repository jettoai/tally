import Foundation

enum HarnessInstallation {
    static func installations(in root: String) -> [HarnessManifest] {
        (try? FileManager.default.contentsOfDirectory(atPath: root))?.sorted().compactMap {
            try? HarnessIO.loadManifest(root + "/" + $0 + "/manifest.json")
        } ?? []
    }

    static func recordedLocation(_ requested: HarnessLocation) -> HarnessLocation {
        if HarnessIO.exists(requested.manifestPath) { return requested }
        // A repointed hooks symlink is drift, not proof that the prior receipt disappeared.
        return installations(in: requested.stateRoot).first {
            let old = $0.location
            return old.scope == requested.scope && old.sourceHome == requested.sourceHome
                && old.targetHome == requested.targetHome && old.project == requested.project
                && old.sharedSkills == requested.sharedSkills
        }?.location ?? requested
    }

    static func status(_ requested: HarnessLocation) throws -> [String: Any] {
        let location = recordedLocation(requested)
        guard HarnessIO.exists(location.manifestPath) else {
            let plan = try HarnessInventory.plan(location)
            return ["state": "not-installed", "plan": try HarnessIO.object(HarnessIO.encode(plan)),
                    "nativeTrust": "not-evaluated"]
        }
        let manifest = try HarnessIO.loadManifest(location.manifestPath)
        let changes = try HarnessObservation.changes(manifest)
        return ["state": manifest.phase != "installed" ? "incomplete" : changes.isEmpty ? "installed" : "drift",
                "manifest": location.manifestPath, "scope": location.scope,
                "source": location.sourceRoot, "target": location.targetRoot,
                "protocolCandidates": manifest.hooks.filter { $0.disposition == "protocol-candidate" }.count,
                "needsAdaptation": manifest.hooks.filter { $0.disposition != "protocol-candidate" }.count,
                "changes": changes, "nativeTrust": "verify-in-codex-hooks",
                "meaning": "Registration and observation only; not a behavioral certificate."]
    }

    static func install(_ plan: HarnessPlan, executable: String, confirmGitVisible: Bool = false) throws -> HarnessManifest {
        let location = recordedLocation(plan.location)
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw HarnessError("Install the Tally command line tool first.")
        }
        guard plan.conflicts.isEmpty else { throw HarnessError(plan.conflicts.joined(separator: "\n")) }
        guard plan.projectGitVisible.isEmpty || confirmGitVisible else {
            throw HarnessError("Review these git-visible paths, then use --confirm-git-visible with install:\n"
                + plan.projectGitVisible.joined(separator: "\n"))
        }
        return try HarnessIO.locked(location.stateRoot) {
            if HarnessIO.exists(location.manifestPath) {
                let existing = try HarnessIO.loadManifest(location.manifestPath)
                guard existing.phase == "installed", try HarnessObservation.changes(existing).isEmpty else {
                    throw HarnessError("Review the drift, remove this installation, then install the new plan and trust its definitions.")
                }
                return existing
            }
            let fresh = try HarnessInventory.plan(location)
            guard fresh.hooks == plan.hooks, fresh.links == plan.links, fresh.conflicts.isEmpty,
                  fresh.projectGitVisible == plan.projectGitVisible else {
                throw HarnessError("Source or target changed since preview. Inspect the new plan.")
            }
            var documents: [String: (Data?, [String: Any])] = [:]
            var registrations: [HarnessRegistration] = []
            func register(path: String, event: String, matcher: String, command: String, timeout: Double) throws {
                let command = HarnessInventory.commandMarker + command
                if documents[path] == nil {
                    try HarnessIO.rejectSymlink(path)
                    let original = try HarnessIO.data(path)
                    documents[path] = (original, try HarnessIO.object(original ?? Data("{}".utf8)))
                }
                var document = documents[path]!.1
                guard document["hooks"] == nil || document["hooks"] is [String: Any] else { throw HarnessError("Invalid target hooks object.") }
                var hooks = document["hooks"] as? [String: Any] ?? [:]
                guard hooks[event] == nil || hooks[event] is [[String: Any]] else { throw HarnessError("Invalid target hook event.") }
                var groups = hooks[event] as? [[String: Any]] ?? []
                let handler: [String: Any] = ["type": "command", "command": command, "timeout": Int(ceil(timeout))]
                let group: [String: Any] = ["matcher": matcher, "hooks": [handler]]
                groups.append(group); hooks[event] = groups; document["hooks"] = hooks
                documents[path]!.1 = document
                registrations.append(HarnessRegistration(provider: path == location.targetConfig ? "codex" : "claude",
                    path: path, event: event, command: command,
                    definitionHash: try HarnessInventory.definition(event: event, group: group, handler: handler)))
            }
            let prefix = [executable, "codex-hook", "--manifest", location.manifestPath].map(HarnessIO.quote).joined(separator: " ")
            for entry in plan.bridgeable {
                try register(path: location.targetConfig, event: entry.event, matcher: entry.matcher,
                    command: prefix + " --entry " + HarnessIO.quote(entry.id), timeout: entry.timeout + 5)
            }
            try register(path: location.targetConfig, event: "SessionStart", matcher: "",
                         command: prefix + " --entry lifecycle", timeout: 15)
            var changes: [(String, String, Data?, Data)] = []
            for (path, value) in documents.sorted(by: { $0.key < $1.key }) {
                changes.append((path, "hooks", value.0, try HarnessIO.json(value.1)))
            }
            let instructionsPath = HarnessIO.canonical(location.targetInstructions)
            if instructionsPath != HarnessIO.canonical(location.sourceInstructions) {
                let original = try HarnessIO.data(instructionsPath)
                guard let text = String(data: original ?? Data(), encoding: .utf8),
                      !text.contains(HarnessSkill.begin), !text.contains(HarnessSkill.end) else {
                    throw HarnessError("Existing AGENTS.md is not UTF-8 or has unowned Tally markers.")
                }
                changes.append((instructionsPath, "instructions", original,
                    Data((text + HarnessSkill.block(source: location.sourceInstructions)).utf8)))
            }
            let skill = location.targetSkills + "/tally-harness/SKILL.md", skillData = Data(HarnessSkill.text.utf8)
            let existingSkill = try HarnessIO.data(skill)
            if existingSkill != nil && existingSkill != skillData { throw HarnessError("A different tally-harness skill already exists.") }
            changes.append((skill, "shared-skill", existingSkill, skillData))
            let backupDirectory = location.directory + "/backups/" + UUID().uuidString
            try HarnessIO.makeDirectory(backupDirectory)
            var manifest = HarnessManifest(phase: "installing", location: location, executable: executable,
                hooks: plan.hooks, registrations: registrations, files: [], links: plan.links, observations: [:])
            for (index, item) in changes.enumerated() {
                try HarnessIO.rejectSymlink(item.0)
                guard try HarnessIO.data(item.0) == item.2 else { throw HarnessError("Target changed before installation.") }
                let backup = item.2 == nil ? nil : backupDirectory + "/" + String(index)
                if let backup, let data = item.2 { try HarnessIO.replace(backup, expected: nil, with: data) }
                manifest.files.append(HarnessFileReceipt(path: item.0, kind: item.1,
                    beforeHash: item.2.map(HarnessIO.hash), afterHash: HarnessIO.hash(item.3), backup: backup))
            }
            try HarnessIO.replace(location.manifestPath, expected: nil, with: HarnessIO.encode(manifest))
            do {
                for (path, _, original, replacement) in changes where original != replacement {
                    try HarnessIO.replace(path, expected: original, with: replacement)
                }
                for link in plan.links {
                    if HarnessIO.exists(link.target), HarnessIO.canonical(link.target) == HarnessIO.canonical(link.source) { continue }
                    guard !HarnessIO.exists(link.target) else { throw HarnessError("Skill target changed during installation.") }
                    try HarnessIO.makeDirectory(URL(fileURLWithPath: link.target).deletingLastPathComponent().path)
                    try FileManager.default.createSymbolicLink(atPath: link.target, withDestinationPath: link.source)
                }
                manifest.observations = try HarnessObservation.capture(location)
                manifest.phase = "installed"
                try HarnessIO.replace(location.manifestPath, expected: HarnessIO.data(location.manifestPath), with: HarnessIO.encode(manifest))
                return manifest
            } catch {
                // A partial manifest remains a retry/removal receipt, never an installed status.
                throw HarnessError("Installation is incomplete. Run Remove to undo recorded changes. " + error.localizedDescription)
            }
        }
    }

    static func remove(_ requested: HarnessLocation) throws -> [String: Any] {
        let location = recordedLocation(requested)
        return try HarnessIO.locked(location.stateRoot) {
            guard HarnessIO.exists(location.manifestPath) else { return ["state": "not-installed"] }
            var manifest = try HarnessIO.loadManifest(location.manifestPath)
            manifest.phase = "removing"
            try HarnessIO.replace(location.manifestPath, expected: HarnessIO.data(location.manifestPath), with: HarnessIO.encode(manifest))
            var failures: [String] = []
            let otherFiles = installations(in: location.stateRoot).filter { $0.location.identifier != location.identifier }
                .flatMap(\.files).map(\.path) + (try HarnessTools.skillPaths(in: location.stateRoot))
            for file in manifest.files {
                do {
                    if file.kind == "shared-skill", otherFiles.contains(file.path) { continue }
                    try removeFile(file, manifest: manifest)
                } catch { failures.append(error.localizedDescription) }
            }
            let otherLinks = installations(in: location.stateRoot).filter { $0.location.identifier != location.identifier }
                .flatMap(\.links).map(\.target)
            for link in manifest.links where !otherLinks.contains(link.target) {
                do {
                    if !HarnessIO.exists(link.target) { continue }
                    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.target)) != nil,
                          HarnessIO.canonical(link.target) == HarnessIO.canonical(link.source) else {
                        throw HarnessError("Skill link changed; preserved \(link.target)")
                    }
                    try FileManager.default.removeItem(atPath: link.target)
                } catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { throw HarnessError("Removal is incomplete; receipt retained.\n" + failures.joined(separator: "\n")) }
            // Retain backups and historical approvals for inspection, but revoke the runtime manifest.
            let retired = location.directory + "/removed-" + UUID().uuidString + ".json"
            try HarnessIO.replace(retired, expected: nil, with: HarnessIO.encode(manifest))
            try HarnessIO.replace(location.manifestPath, expected: HarnessIO.data(location.manifestPath), with: nil)
            return ["state": "removed", "receipt": retired]
        }
    }

    private static func removeFile(_ file: HarnessFileReceipt, manifest: HarnessManifest) throws {
        try HarnessIO.rejectSymlink(file.path)
        guard let current = try HarnessIO.data(file.path) else { return }
        let currentHash = HarnessIO.hash(current)
        if file.kind != "shared-skill", currentHash == file.beforeHash { return }
        var original: Data?
        if let backup = file.backup {
            original = try HarnessIO.data(backup)
            guard original.map(HarnessIO.hash) == file.beforeHash else { throw HarnessError("Backup fingerprint mismatch.") }
        }
        if file.kind == "shared-skill" {
            guard currentHash == file.afterHash else { throw HarnessError("Modified product skill was preserved: \(file.path)") }
            try HarnessIO.replace(file.path, expected: current, with: nil)
            let directory = URL(fileURLWithPath: file.path).deletingLastPathComponent().path
            if (try? FileManager.default.contentsOfDirectory(atPath: directory).isEmpty) == true {
                try? FileManager.default.removeItem(atPath: directory)
            }
        } else if file.kind == "hooks" {
            let result = try removingRegistrations(from: HarnessIO.object(current), path: file.path, registrations: manifest.registrations)
            // Restore exact bytes only when no foreign change happened since installation.
            try HarnessIO.replace(file.path, expected: current,
                                  with: currentHash == file.afterHash ? original : HarnessIO.json(result))
        } else if file.kind == "instructions" {
            guard let text = String(data: current, encoding: .utf8) else { throw HarnessError("AGENTS.md is no longer UTF-8.") }
            let expectedBlock = HarnessSkill.block(source: manifest.location.sourceInstructions)
            if text.contains(HarnessSkill.begin) && !text.contains(expectedBlock) {
                throw HarnessError("Modified instruction block was preserved: \(file.path)")
            }
            let stripped = try HarnessSkill.strip(text)
            try HarnessIO.replace(file.path, expected: current,
                with: currentHash == file.afterHash ? original : Data(stripped.utf8))
        }
    }

    static func removingRegistrations(from document: [String: Any], path: String,
                                      registrations: [HarnessRegistration]) throws -> [String: Any] {
        var result = document
        guard var hooks = document["hooks"] as? [String: Any] else { throw HarnessError("Hook structure changed; preserved \(path)") }
        for registration in registrations where registration.path == path {
            guard var groups = hooks[registration.event] as? [[String: Any]] else { continue }
            for index in groups.indices {
                guard let handlers = groups[index]["hooks"] as? [[String: Any]] else { throw HarnessError("Hook group structure changed.") }
                var retained: [[String: Any]] = []
                for handler in handlers {
                    if handler["command"] as? String == registration.command {
                        guard try HarnessInventory.definition(event: registration.event, group: groups[index], handler: handler) == registration.definitionHash else {
                            throw HarnessError("Modified Tally hook was preserved: \(path)")
                        }
                    } else { retained.append(handler) }
                }
                groups[index]["hooks"] = retained // Keep indices of unrelated native trust entries.
            }
            hooks[registration.event] = groups
        }
        result["hooks"] = hooks
        return result
    }
}
