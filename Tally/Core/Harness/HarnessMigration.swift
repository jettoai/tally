import Foundation

/// Selective retirement of receipt-owned entries, without reinstalling retained hooks.
enum HarnessMigration {
    private struct Change {
        let path: String
        let before: Data
        let after: Data
    }

    static func entryID(_ registration: HarnessRegistration, manifest: HarnessManifest) -> String? {
        (["lifecycle"] + manifest.hooks.map(\.id)).first {
            registration.command.hasSuffix(" --entry " + HarnessIO.quote($0))
                || registration.command.hasSuffix(" --entry " + $0)
        }
    }

    static func inventory(_ manifest: HarnessManifest) throws -> [[String: Any]] {
        try manifest.registrations.map { registration in
            let rows = try HarnessInventory.hooks(at: registration.path)
            let matching = rows.filter { $0.event == registration.event && $0.definitionHash == registration.definitionHash }
            let id = entryID(registration, manifest: manifest)
            let source = manifest.hooks.first { $0.id == id }
            return ["id": id ?? "unknown", "event": registration.event, "path": registration.path,
                    "source": source?.source ?? "", "sourceGroup": source?.group ?? -1,
                    "sourceHandler": source?.handler ?? -1,
                    "definitionMatches": matching.count,
                    "review": registration.event == "PreToolUse" ? "Review hard denials and interactive approval requirements before retirement."
                        : "Review the source behavior before retirement."]
        }
    }

    static func run(_ requested: HarnessLocation, dropHooks: [String], dropSkills: [String],
                    apply: Bool, confirmGitVisible: Bool = false) throws -> [String: Any] {
        let location = HarnessInstallation.recordedLocation(requested)
        guard HarnessIO.exists(location.manifestPath) else { throw HarnessError("No installation to migrate.") }
        if apply {
            guard !dropHooks.isEmpty || !dropSkills.isEmpty else {
                throw HarnessError("Specify individual --drop-hook or --drop-skill entries before applying a migration.")
            }
            return try HarnessIO.locked(location.stateRoot) {
                try prepare(location, dropHooks: Set(dropHooks), dropSkills: Set(dropSkills),
                            apply: true, confirmGitVisible: confirmGitVisible)
            }
        }
        return try prepare(location, dropHooks: Set(dropHooks), dropSkills: Set(dropSkills),
                           apply: false, confirmGitVisible: confirmGitVisible)
    }

    private static func prepare(_ location: HarnessLocation, dropHooks: Set<String>, dropSkills: Set<String>,
                                apply: Bool, confirmGitVisible: Bool) throws -> [String: Any] {
        guard let manifestBytes = try HarnessIO.data(location.manifestPath) else {
            throw HarnessError("Installation disappeared before migration.")
        }
        var manifest = try HarnessIO.loadManifest(location.manifestPath)
        guard manifest.phase == "installed" else { throw HarnessError("Resolve the incomplete installation before migration.") }
        guard HarnessIO.canonical(location.targetRoot + "/hooks.json") == location.targetConfig else {
            throw HarnessError("The hooks path was repointed. Review its ownership before migration.")
        }
        let knownHooks = Set(manifest.hooks.map(\.id) + ["lifecycle"])
        let knownSkills = Set(manifest.enabledSkillNames + (manifest.retiredSkillNames ?? [])
            + manifest.links.map { ($0.target as NSString).lastPathComponent })
        guard dropHooks.isSubset(of: knownHooks), dropSkills.isSubset(of: knownSkills) else {
            throw HarnessError("Unknown migration selection. Use IDs and skill names from this installation's migration inventory.")
        }
        let inventory = try inventory(manifest)
        let retired = manifest.registrations.filter {
            entryID($0, manifest: manifest).map(dropHooks.contains) ?? false
        }
        let retiredLinks = manifest.links.filter { dropSkills.contains(($0.target as NSString).lastPathComponent) }
        let otherLinks = HarnessInstallation.installations(in: location.stateRoot)
            .filter { $0.location.identifier != location.identifier }.flatMap(\.links).map(\.target)
        var changes: [Change] = [], links: [(HarnessLink, String)] = [], conflicts: [String] = []
        for path in Set(retired.map(\.path)).sorted() {
            do {
                guard path == location.targetConfig,
                      manifest.files.contains(where: { $0.path == path && $0.kind == "hooks" }) else {
                    throw HarnessError("Registration has no matching target-file receipt: \(path)")
                }
                try HarnessIO.rejectSymlink(path)
                guard let current = try HarnessIO.data(path) else { continue }
                let result = try HarnessInstallation.removingRegistrations(from: HarnessIO.object(current),
                    path: path, registrations: retired)
                if try HarnessIO.json(HarnessIO.object(current)) != HarnessIO.json(result) {
                    changes.append(Change(path: path, before: current, after: try HarnessIO.json(result)))
                }
            } catch { conflicts.append(error.localizedDescription) }
        }
        for link in retiredLinks where !otherLinks.contains(link.target) {
            if !HarnessIO.exists(link.target) { continue }
            let parent = (link.target as NSString).deletingLastPathComponent
            if HarnessIO.canonical(parent) != parent {
                conflicts.append("Skill parent was repointed; preserved \(link.target)")
                continue
            }
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.target),
               HarnessIO.canonical(link.target) == HarnessIO.canonical(link.source) {
                links.append((link, destination))
            } else { conflicts.append("Modified skill was preserved: \(link.target)") }
        }
        let nextHooks = manifest.enabledHookIDs.filter { !dropHooks.contains($0) }
        let nextSkills = manifest.enabledSkillNames.filter { !dropSkills.contains($0) }
        let changed = !retired.isEmpty || !retiredLinks.isEmpty || nextHooks != manifest.enabledHookIDs
            || nextSkills != manifest.enabledSkillNames
        let paths = Set(changes.map(\.path) + links.map { $0.0.target })
        let visible = try HarnessProjectPaths.visible(location, changedPaths: paths)
        var report: [String: Any] = ["state": conflicts.isEmpty ? (changed ? "planned" : "unchanged") : "conflict",
            "manifest": location.manifestPath, "scope": location.scope, "target": location.targetRoot,
            "hooks": inventory, "skills": manifest.enabledSkillNames,
            "dropHookIDs": dropHooks.sorted(), "dropSkillNames": dropSkills.sorted(),
            "retainedHookIDs": nextHooks, "retainedSkillNames": nextSkills,
            "changedPaths": paths.sorted(), "projectGitVisible": visible, "conflicts": conflicts,
            "receiptWillChange": changed,
            "removedLinks": links.map { ["path": $0.0.target, "destination": $0.1] },
            "meaning": "Selective retirement only. No permission changes, replacement controls, or native verification are implied."]
        guard apply else { return report }
        guard conflicts.isEmpty else { throw HarnessError(conflicts.joined(separator: "\n")) }
        guard visible.isEmpty || confirmGitVisible else {
            throw HarnessError("Review the git-visible migration paths and use --confirm-git-visible:\n" + visible.joined(separator: "\n"))
        }
        guard changed else { return report }
        let beforeObservations = try HarnessObservation.capture(location)
        let backup = location.directory + "/migrations/" + UUID().uuidString
        try HarnessIO.makeDirectory(backup)
        try HarnessIO.replace(backup + "/manifest.json", expected: nil, with: manifestBytes)
        for (index, change) in changes.enumerated() {
            try HarnessIO.replace(backup + "/file-\(index)", expected: nil, with: change.before)
        }
        try HarnessIO.replace(backup + "/plan.json", expected: nil, with: HarnessIO.json(report))
        var written: [Change] = [], removedLinks: [(HarnessLink, String)] = []
        do {
            guard try HarnessIO.data(location.manifestPath) == manifestBytes else { throw HarnessError("Receipt changed before migration.") }
            for change in changes {
                try HarnessIO.replace(change.path, expected: change.before, with: change.after)
                written.append(change)
            }
            for (link, destination) in links {
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.target)) == destination,
                      HarnessIO.canonical(link.target) == HarnessIO.canonical(link.source) else {
                    throw HarnessError("Skill link changed before migration: \(link.target)")
                }
                try FileManager.default.removeItem(atPath: link.target)
                removedLinks.append((link, destination))
            }
            let retiredCommands = Set(retired.map(\.command))
            manifest.registrations.removeAll { retiredCommands.contains($0.command) }
            manifest.links.removeAll { dropSkills.contains(($0.target as NSString).lastPathComponent) }
            manifest.selectedHookIDs = nextHooks
            manifest.selectedSkillNames = nextSkills
            manifest.retiredSkillNames = Set((manifest.retiredSkillNames ?? []) + Array(dropSkills)).sorted()
            let afterObservations = try HarnessObservation.capture(location)
            for change in changes where try HarnessIO.data(change.path) != change.after {
                throw HarnessError("Target changed during migration: \(change.path)")
            }
            for (link, _) in links where HarnessIO.exists(link.target) {
                throw HarnessError("Skill target changed during migration: \(link.target)")
            }
            for path in paths where manifest.observations[path] == beforeObservations[path] {
                manifest.observations[path] = afterObservations[path]
            }
            for index in manifest.files.indices {
                if let change = changes.first(where: { $0.path == manifest.files[index].path }),
                   manifest.files[index].afterHash == HarnessIO.hash(change.before) {
                    manifest.files[index].afterHash = HarnessIO.hash(change.after)
                }
            }
            try HarnessIO.replace(location.manifestPath, expected: manifestBytes, with: HarnessIO.encode(manifest))
        } catch {
            var failures: [String] = []
            for (link, destination) in removedLinks.reversed() {
                do {
                    guard !HarnessIO.exists(link.target) else { throw HarnessError("Changed link preserved: \(link.target)") }
                    try FileManager.default.createSymbolicLink(atPath: link.target, withDestinationPath: destination)
                } catch { failures.append(error.localizedDescription) }
            }
            for change in written.reversed() {
                do { try HarnessIO.replace(change.path, expected: change.after, with: change.before) }
                catch { failures.append(error.localizedDescription) }
            }
            throw HarnessError("Migration failed. Backup: \(backup). " + error.localizedDescription
                + (failures.isEmpty ? " Target changes were rolled back." : " Recovery needs review: " + failures.joined(separator: "; ")))
        }
        report["state"] = "migrated"
        report["backup"] = backup
        report["remainingDrift"] = try HarnessObservation.changes(manifest)
        return report
    }
}
