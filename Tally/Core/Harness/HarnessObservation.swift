import Foundation

enum HarnessObservation {
    static func refreshSkill(_ entries: inout [String: String], path: String,
                             oldHashes: Set<String>, newHash: String) {
        for key in Array(entries.keys) where HarnessIO.canonical(key) == path {
            guard let value = entries[key], let mode = value.range(of: ":mode=", options: .backwards) else { continue }
            let prefix = String(value[..<mode.lowerBound])
            let oldHash = String(prefix.suffix(64))
            guard oldHashes.contains(oldHash), prefix == oldHash || prefix.hasSuffix(":" + oldHash) else { continue }
            // Keep the recorded link and mode so unrelated drift cannot become the new baseline.
            entries[key] = String(prefix.dropLast(64)) + newHash + value[mode.lowerBound...]
        }
    }

    static func capture(_ location: HarnessLocation) throws -> [String: String] {
        var entries: [String: String] = [:], bytes = 0
        let roots = location.sourceConfigs + [location.targetConfig, location.sourceInstructions,
            location.targetInstructions, location.targetSkills]
            + ["hooks", "scripts", "skills", "rules", "agents"].map { location.sourceRoot + "/" + $0 }
        func visit(_ path: String) throws {
            guard entries.count < 20_000, bytes <= 67_108_864 else { throw HarnessError("Harness inventory exceeded its size limit.") }
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                // Directory links are observed, not recursively followed into arbitrary trees.
                entries[path] = "link:" + link + ":" + HarnessIO.canonical(path)
                let resolved = HarnessIO.canonical(path)
                if (try? URL(fileURLWithPath: resolved).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                   let data = try HarnessIO.data(resolved) {
                    bytes += data.count
                    guard bytes <= 67_108_864 else { throw HarnessError("Harness inventory exceeded its byte limit.") }
                    let mode = try FileManager.default.attributesOfItem(atPath: resolved)[.posixPermissions] as? NSNumber
                    entries[path] = entries[path]! + ":" + HarnessIO.hash(data) + ":mode=" + (mode?.stringValue ?? "unknown")
                }
                return
            }
            guard HarnessIO.exists(path) else { entries[path] = "missing"; return }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                entries[path] = "directory"
                for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted()
                    where ![".git", "__pycache__", "node_modules", ".venv", ".DS_Store"].contains(name) {
                    try visit(path + "/" + name)
                }
            } else if let data = try HarnessIO.data(path) {
                bytes += data.count
                guard bytes <= 67_108_864 else { throw HarnessError("Harness inventory exceeded its byte limit.") }
                let mode = attributes[.posixPermissions] as? NSNumber
                entries[path] = HarnessIO.hash(data) + ":mode=" + (mode?.stringValue ?? "unknown")
            }
        }
        for root in Set(roots).sorted() { try visit(root) }
        return entries
    }

    static func changes(_ manifest: HarnessManifest) throws -> [String] {
        let current = try capture(manifest.location)
        return Set(current.keys).union(manifest.observations.keys).sorted().filter {
            current[$0] != manifest.observations[$0]
        }
    }
}
