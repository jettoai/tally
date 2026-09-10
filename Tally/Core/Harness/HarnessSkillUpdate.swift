import Foundation

/// Refresh only receipt-owned product skills. Configuration and source policy stay untouched.
enum HarnessSkillUpdate {
    struct Result: Codable {
        var updated: [String] = []
        var errors: [String] = []
    }

    private struct Receipt {
        let path: String
        var bytes: Data
        var tools: HarnessToolsReceipt?
        var adapter: HarnessManifest?
        var files: [HarnessFileReceipt] { tools?.files ?? adapter!.files }
        var phase: String { tools?.phase ?? adapter!.phase }
        var skillFiles: [HarnessFileReceipt] {
            files.filter { $0.kind == (tools == nil ? "shared-skill" : "tools-skill") }
        }

        mutating func save(skill: String, oldHashes: Set<String>, newHash: String) throws {
            var next = self
            if var adapter = next.adapter {
                HarnessObservation.refreshSkill(&adapter.observations, path: skill,
                    oldHashes: oldHashes, newHash: newHash)
                for index in adapter.files.indices where adapter.files[index].kind == "shared-skill"
                    && HarnessIO.canonical(adapter.files[index].path) == skill {
                    adapter.files[index].afterHash = newHash
                }
                next.adapter = adapter
            }
            if var tools = next.tools {
                for index in tools.files.indices where tools.files[index].kind == "tools-skill"
                    && HarnessIO.canonical(tools.files[index].path) == skill {
                    tools.files[index].afterHash = newHash
                }
                next.tools = tools
            }
            let data = try next.tools.map(HarnessIO.encode) ?? HarnessIO.encode(next.adapter!)
            let previous = try tools.map(HarnessIO.encode) ?? HarnessIO.encode(adapter!)
            guard data != previous else { return }
            try HarnessIO.replace(path, expected: bytes, with: data)
            next.bytes = data
            self = next
        }
    }

    static func refresh(in root: String) -> Result {
        // A machine with no harness installation must not acquire state from app startup.
        guard HarnessIO.exists(root) else { return Result() }
        do {
            return try HarnessIO.locked(root) {
                var result = Result(), receipts: [Receipt] = []
                let names = try FileManager.default.contentsOfDirectory(atPath: root).sorted()
                for name in names where name == "tools" || (name.count == 64
                    && name.allSatisfy({ "0123456789abcdef".contains($0) })) {
                    let path = root + "/" + name + "/manifest.json"
                    guard HarnessIO.exists(path) else { continue }
                    do {
                        try HarnessIO.rejectSymlink(path)
                        guard HarnessIO.canonical(path) == path else {
                            throw HarnessError("Receipt path changed through a symbolic link: \(path)")
                        }
                        guard let bytes = try HarnessIO.data(path) else {
                            throw HarnessError("Receipt disappeared during refresh: \(path)")
                        }
                        if name == "tools" {
                            guard let tools = try HarnessTools.receipt(in: root) else {
                                throw HarnessError("Receipt disappeared during refresh: \(path)")
                            }
                            receipts.append(Receipt(path: path, bytes: bytes, tools: tools))
                        } else {
                            receipts.append(Receipt(path: path, bytes: bytes,
                                adapter: try HarnessIO.loadManifest(path)))
                        }
                    } catch { result.errors.append("\(path): \(error.localizedDescription)") }
                }
                let paths = Set(receipts.filter { $0.phase == "installed" }.flatMap(\.skillFiles)
                    .map { HarnessIO.canonical($0.path) }).sorted()
                let replacement = Data(HarnessSkill.text.utf8), newHash = HarnessIO.hash(replacement)
                // A receipt may observe another installed copy of this same product skill.
                // Retain the pre-update hashes across paths while repairing interrupted receipts.
                let knownHashes = Set(receipts.filter { $0.phase == "installed" }
                    .flatMap(\.skillFiles).map(\.afterHash))
                for path in paths {
                    do {
                        let owners = receipts.indices.filter { index in
                            receipts[index].skillFiles.contains { HarnessIO.canonical($0.path) == path }
                        }
                        guard owners.allSatisfy({ receipts[$0].phase == "installed" }) else {
                            throw HarnessError("An incomplete installation still owns this skill: \(path)")
                        }
                        let files = owners.flatMap { receipts[$0].skillFiles }.filter {
                            HarnessIO.canonical($0.path) == path
                        }
                        // Legacy receipts do not record the identity of linked parent directories.
                        // Preserve those ambiguous paths instead of following a replaced link.
                        for file in files {
                            try HarnessIO.rejectSymlink(file.path)
                            guard file.path == path else {
                                throw HarnessError("Review the symbolic link in this skill path: \(file.path)")
                            }
                        }
                        guard let current = try HarnessIO.data(path) else { continue }
                        let oldHashes = Set(files.map(\.afterHash)), currentHash = HarnessIO.hash(current)
                        guard current == replacement || oldHashes.contains(currentHash) else {
                            throw HarnessError("Modified skill was preserved: \(path)")
                        }
                        if current != replacement {
                            try HarnessIO.replace(path, expected: current, with: replacement)
                            result.updated.append(path)
                        }
                        // Save observing non-owners first. Until they succeed, an owner retains
                        // the old hash needed to repair observations after an interrupted update.
                        let observers = receipts.indices.filter { !owners.contains($0)
                            && receipts[$0].phase == "installed" && receipts[$0].adapter != nil }
                        for index in observers + owners {
                            try receipts[index].save(skill: path, oldHashes: knownHashes, newHash: newHash)
                        }
                    } catch { result.errors.append("\(path): \(error.localizedDescription)") }
                }
                return result
            }
        } catch { return Result(errors: [error.localizedDescription]) }
    }
}
