import Foundation

struct HarnessToolsConfiguration: Codable, Equatable, Sendable {
    let claudeHomes: [String]
    let codexHomes: [String]
    let skillsRoot: String
    let stateRoot: String

    init(claudeHomes: [String], codexHomes: [String], skillsRoot: String, stateRoot: String) throws {
        let paths = claudeHomes + codexHomes + [skillsRoot, stateRoot]
        guard !claudeHomes.isEmpty, !codexHomes.isEmpty, paths.count <= 202,
              paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && !$0.contains("\n") }) else {
            throw HarnessError("Both providers need explicit absolute home paths.")
        }
        self.claudeHomes = Array(Set(claudeHomes.map(HarnessIO.canonical))).sorted()
        self.codexHomes = Array(Set(codexHomes.map(HarnessIO.canonical))).sorted()
        self.skillsRoot = HarnessIO.canonical(skillsRoot)
        self.stateRoot = HarnessIO.canonical(stateRoot)
    }

    var manifestPath: String { stateRoot + "/tools/manifest.json" }
    var skillPaths: [String] {
        Array(Set((claudeHomes.map { $0 + "/skills/tally-harness/SKILL.md" }
            + [skillsRoot + "/tally-harness/SKILL.md"]).map(HarnessIO.canonical))).sorted()
    }
    var configurations: [(provider: String, home: String, path: String)] {
        var seen: Set<String> = []
        return (claudeHomes.map { ("claude", $0, HarnessIO.canonical($0 + "/settings.json")) }
            + codexHomes.map { ("codex", $0, HarnessIO.canonical($0 + "/hooks.json")) })
            .filter { seen.insert($0.0 + ":" + $0.2).inserted }
    }
}

struct HarnessToolsReceipt: Codable {
    var schema = 1
    var phase: String
    let configuration: HarnessToolsConfiguration
    var files: [HarnessFileReceipt]
    var registrations: [HarnessRegistration]
}

/// One integration installs the same workflow in both providers without adapting a checkout.
enum HarnessTools {
    static func receipt(in root: String) throws -> HarnessToolsReceipt? {
        let path = root + "/tools/manifest.json"
        try HarnessIO.rejectSymlink(path)
        guard let data = try HarnessIO.data(path) else { return nil }
        let receipt = try JSONDecoder().decode(HarnessToolsReceipt.self, from: data)
        let config = receipt.configuration
        _ = try HarnessToolsConfiguration(claudeHomes: config.claudeHomes, codexHomes: config.codexHomes,
                                          skillsRoot: config.skillsRoot, stateRoot: config.stateRoot)
        guard receipt.schema == 1, config.manifestPath == path else { throw HarnessError("Invalid tools installation receipt.") }
        return receipt
    }

    static func skillPaths(in root: String) throws -> [String] {
        try receipt(in: root)?.files.filter { $0.kind == "tools-skill" }.map(\.path) ?? []
    }

    static func registrations(in root: String) throws -> [HarnessRegistration] {
        try receipt(in: root)?.registrations ?? []
    }

    static func status(_ configuration: HarnessToolsConfiguration) throws -> [String: Any] {
        guard let receipt = try receipt(in: configuration.stateRoot) else { return ["state": "not-installed"] }
        var changes: [String] = []
        if receipt.configuration != configuration { changes.append("Account homes changed.") }
        let expectedPaths = Set(configuration.skillPaths + configuration.configurations.map(\.path))
        if expectedPaths != Set(receipt.files.map(\.path)) { changes.append("Installation paths changed.") }
        for file in receipt.files {
            guard let data = try HarnessIO.data(file.path) else { changes.append(file.path); continue }
            if file.kind == "tools-skill" {
                if data != Data(HarnessSkill.text.utf8) { changes.append(file.path) }
            } else {
                let hooks = try HarnessInventory.hooks(at: file.path)
                for registration in receipt.registrations where registration.path == file.path {
                    if hooks.filter({ $0.event == registration.event && $0.definitionHash == registration.definitionHash }).count != 1 {
                        changes.append(file.path)
                    }
                }
            }
        }
        return ["state": receipt.phase == "installed" && changes.isEmpty ? "installed" : "incomplete",
                "changes": Array(Set(changes)).sorted(), "claudeHomes": configuration.claudeHomes,
                "codexHomes": configuration.codexHomes, "nativeTrust": "verify-in-codex-hooks"]
    }

    static func install(_ configuration: HarnessToolsConfiguration, executable: String) throws {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw HarnessError("Install the Tally command line tool first.")
        }
        try HarnessIO.locked(configuration.stateRoot) {
            if try receipt(in: configuration.stateRoot) != nil {
                guard try status(configuration)["state"] as? String == "installed" else {
                    throw HarnessError("Remove the previous tools installation before installing it again.")
                }
                return
            }
            let adapters = HarnessInstallation.installations(in: configuration.stateRoot)
            let ownedSkills = Set(adapters.flatMap(\.files).filter { $0.kind == "shared-skill" }.map(\.path))
            var writes: [(path: String, kind: String, before: Data?, after: Data)] = []
            for path in configuration.skillPaths {
                try HarnessIO.rejectSymlink(path)
                let original = try HarnessIO.data(path), replacement = Data(HarnessSkill.text.utf8)
                guard original == nil || (ownedSkills.contains(path) && original == replacement) else {
                    throw HarnessError("A different or unowned skill occupies \(path)")
                }
                writes.append((path, "tools-skill", original, replacement))
            }
            var registrations: [HarnessRegistration] = [], seenPaths: Set<String> = []
            for item in configuration.configurations {
                guard seenPaths.insert(item.path).inserted else {
                    throw HarnessError("Claude and Codex cannot share the same native configuration file.")
                }
                try HarnessIO.rejectSymlink(item.path)
                let original = try HarnessIO.data(item.path)
                var document = try HarnessIO.object(original ?? Data("{}".utf8))
                guard document["hooks"] == nil || document["hooks"] is [String: Any] else { throw HarnessError("Invalid native hooks object.") }
                var hooks = document["hooks"] as? [String: Any] ?? [:]
                let inbox = URL(fileURLWithPath: configuration.stateRoot).deletingLastPathComponent().path + "/inbox"
                let command = HarnessInventory.commandMarker + [executable, "inbox", "hook", "--provider", item.provider,
                    "--fallback-home", item.home, "--root", inbox].map(HarnessIO.quote).joined(separator: " ")
                for event in ["SessionStart", "Stop"] {
                    guard hooks[event] == nil || hooks[event] is [[String: Any]] else { throw HarnessError("Invalid native hook event.") }
                    let handler: [String: Any] = ["type": "command", "command": command, "timeout": 15]
                    let group: [String: Any] = ["matcher": "", "hooks": [handler]]
                    var groups = hooks[event] as? [[String: Any]] ?? []
                    groups.append(group); hooks[event] = groups
                    registrations.append(HarnessRegistration(provider: item.provider, path: item.path, event: event,
                        command: command, definitionHash: try HarnessInventory.definition(event: event, group: group, handler: handler)))
                }
                document["hooks"] = hooks
                writes.append((item.path, "hooks", original, try HarnessIO.json(document)))
            }
            var receipt = HarnessToolsReceipt(phase: "installing", configuration: configuration, files: [], registrations: registrations)
            let backups = configuration.stateRoot + "/tools/backups/" + UUID().uuidString
            for (index, write) in writes.enumerated() {
                guard try HarnessIO.data(write.path) == write.before else { throw HarnessError("Installation target changed.") }
                let backup = write.before == nil ? nil : backups + "/" + String(index)
                if let backup, let data = write.before { try HarnessIO.replace(backup, expected: nil, with: data) }
                receipt.files.append(HarnessFileReceipt(path: write.path, kind: write.kind,
                    beforeHash: write.before.map(HarnessIO.hash), afterHash: HarnessIO.hash(write.after), backup: backup))
            }
            try HarnessIO.replace(configuration.manifestPath, expected: nil, with: HarnessIO.encode(receipt))
            for write in writes where write.before != write.after {
                try HarnessIO.replace(write.path, expected: write.before, with: write.after)
            }
            receipt.phase = "installed"
            try HarnessIO.replace(configuration.manifestPath, expected: HarnessIO.data(configuration.manifestPath), with: HarnessIO.encode(receipt))
        }
    }

    static func remove(_ root: String) throws {
        try HarnessIO.locked(root) {
            guard var receipt = try receipt(in: root) else { return }
            let path = receipt.configuration.manifestPath
            receipt.phase = "removing"
            try HarnessIO.replace(path, expected: HarnessIO.data(path), with: HarnessIO.encode(receipt))
            let sharedSkills = Set(HarnessInstallation.installations(in: root).flatMap(\.files)
                .filter { $0.kind == "shared-skill" }.map(\.path))
            var failures: [String] = []
            for file in receipt.files {
                do {
                    if file.kind == "tools-skill", sharedSkills.contains(file.path) { continue }
                    try HarnessIO.rejectSymlink(file.path)
                    guard let current = try HarnessIO.data(file.path) else { continue }
                    if file.kind != "tools-skill", HarnessIO.hash(current) == file.beforeHash { continue }
                    var original: Data?
                    if let backup = file.backup {
                        original = try HarnessIO.data(backup)
                        guard original.map(HarnessIO.hash) == file.beforeHash else { throw HarnessError("Backup fingerprint mismatch.") }
                    }
                    if file.kind == "tools-skill" {
                        guard HarnessIO.hash(current) == file.afterHash else { throw HarnessError("Modified skill was preserved: \(file.path)") }
                        try HarnessIO.replace(file.path, expected: current, with: nil)
                        let folder = URL(fileURLWithPath: file.path).deletingLastPathComponent().path
                        if (try? FileManager.default.contentsOfDirectory(atPath: folder).isEmpty) == true {
                            try? FileManager.default.removeItem(atPath: folder)
                        }
                    } else {
                        let value = try HarnessInstallation.removingRegistrations(from: HarnessIO.object(current),
                            path: file.path, registrations: receipt.registrations)
                        try HarnessIO.replace(file.path, expected: current,
                            with: HarnessIO.hash(current) == file.afterHash ? original : HarnessIO.json(value))
                    }
                } catch { failures.append(error.localizedDescription) }
            }
            guard failures.isEmpty else { throw HarnessError("Removal is incomplete; receipt retained.\n" + failures.joined(separator: "\n")) }
            try HarnessIO.replace(root + "/tools/removed-" + UUID().uuidString + ".json", expected: nil, with: HarnessIO.encode(receipt))
            try HarnessIO.replace(path, expected: HarnessIO.data(path), with: nil)
        }
    }
}
