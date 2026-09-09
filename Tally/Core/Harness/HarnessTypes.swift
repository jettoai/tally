import CryptoKit
import Darwin
import Foundation

struct HarnessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// The source is user data. Only the executable and protocol adapters belong to Tally.
struct HarnessLocation: Codable, Equatable, Sendable {
    let scope: String
    let sourceHome: String
    let targetHome: String
    let project: String?
    let sharedSkills: String
    let stateRoot: String
    let identifier: String

    init(scope: String, sourceHome: String, targetHome: String, project: String? = nil,
         sharedSkills: String, stateRoot: String) throws {
        guard ["user", "project"].contains(scope),
              [sourceHome, targetHome, sharedSkills, stateRoot].allSatisfy({
                  $0.hasPrefix("/") && !$0.contains("\0") && !$0.contains("\n")
              }), scope != "project" || (project?.hasPrefix("/") == true
                  && project?.contains("\0") == false && project?.contains("\n") == false) else {
            throw HarnessError("Use an explicit user or project scope and absolute paths.")
        }
        self.scope = scope
        self.sourceHome = HarnessIO.canonical(sourceHome)
        self.targetHome = HarnessIO.canonical(targetHome)
        self.project = project.map(HarnessIO.canonical)
        self.sharedSkills = HarnessIO.canonical(sharedSkills)
        self.stateRoot = HarnessIO.canonical(stateRoot)
        let source = scope == "project" ? HarnessIO.canonical(project!) + "/.claude" : HarnessIO.canonical(sourceHome)
        let target = scope == "project" ? HarnessIO.canonical(project!) + "/.codex" : HarnessIO.canonical(targetHome)
        let skills = scope == "project" ? HarnessIO.canonical(project!) + "/.agents/skills" : HarnessIO.canonical(sharedSkills)
        identifier = HarnessIO.hash(Data([scope, source, HarnessIO.canonical(target + "/hooks.json"), skills].joined(separator: "\n").utf8))
        guard source != target else { throw HarnessError("Source and target must differ.") }
    }

    var sourceRoot: String { scope == "project" ? project! + "/.claude" : sourceHome }
    var targetRoot: String { scope == "project" ? project! + "/.codex" : targetHome }
    var sourceConfigs: [String] {
        ([sourceRoot + "/settings.json"] + (scope == "project" ? [sourceRoot + "/settings.local.json"] : [])).map(HarnessIO.canonical)
    }
    var targetConfig: String { HarnessIO.canonical(targetRoot + "/hooks.json") }
    var sourceInstructions: String { scope == "project" ? project! + "/CLAUDE.md" : sourceHome + "/CLAUDE.md" }
    var targetInstructions: String { scope == "project" ? project! + "/AGENTS.md" : targetHome + "/AGENTS.md" }
    var targetSkills: String { scope == "project" ? project! + "/.agents/skills" : sharedSkills }
    var directory: String { stateRoot + "/" + identifier }
    var manifestPath: String { directory + "/manifest.json" }
}

struct HarnessHook: Codable, Equatable, Sendable {
    let id: String
    let source: String
    let event: String
    let group: Int
    let handler: Int
    let matcher: String
    let definitionHash: String
    let timeout: Double
    let disposition: String
    let reason: String
}

struct HarnessLink: Codable, Equatable, Sendable {
    let source: String
    let target: String
}

struct HarnessPlan: Codable, Sendable {
    let location: HarnessLocation
    let hooks: [HarnessHook]
    let links: [HarnessLink]
    let conflicts: [String]
    let notices: [String]
    let projectGitVisible: [String]
    var bridgeable: [HarnessHook] { hooks.filter { $0.disposition == "protocol-candidate" } }
}

struct HarnessRegistration: Codable {
    let provider: String
    let path: String
    let event: String
    let command: String
    let definitionHash: String
}

struct HarnessFileReceipt: Codable {
    let path: String
    let kind: String
    let beforeHash: String?
    let afterHash: String
    let backup: String?
}

struct HarnessManifest: Codable {
    var schema = 1
    var generation = UUID().uuidString
    var phase: String
    let location: HarnessLocation
    let executable: String
    let hooks: [HarnessHook]
    var registrations: [HarnessRegistration]
    var files: [HarnessFileReceipt]
    var links: [HarnessLink]
    var observations: [String: String]
}

enum HarnessIO {
    static func readInput(limit: Int = 1_048_576) throws -> Data {
        var input = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, limit + 1 - input.count)), !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= limit else { throw HarnessError("Hook input exceeds its size limit.") }
        }
        return input
    }
    static func canonical(_ path: String) -> String {
        var candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        var suffix: [String] = [], followed: Set<String> = []
        // Foundation abbreviates /private on existing paths. Resolve the nearest existing
        // ancestor with realpath so creating a missing destination does not change its identity.
        while true {
            if let resolved = Darwin.realpath(candidate, nil) {
                let base = String(cString: resolved)
                free(resolved)
                return suffix.reversed().reduce(base) { ($0 as NSString).appendingPathComponent($1) }
            }
            // A shared configuration can link to a file that has not been created yet.
            // realpath alone cannot resolve that link, including a linked parent directory.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                guard followed.count < 40, followed.insert(candidate).inserted else { return path }
                let next = target.hasPrefix("/") ? target
                    : ((candidate as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
                candidate = URL(fileURLWithPath: next).standardizedFileURL.path
                continue
            }
            if candidate == "/" { return path }
            suffix.append((candidate as NSString).lastPathComponent)
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessError("Expected a JSON object.")
        }
        return value
    }
    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
    static func data(_ path: String, limit: Int = 4_194_304) throws -> Data? {
        guard exists(path) else { return nil }
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? limit + 1) <= limit else {
            throw HarnessError("Not a readable regular file within the size limit: \(path)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw HarnessError("File exceeds the size limit: \(path)") }
        return bytes
    }
    static func document(_ path: String) throws -> [String: Any] {
        try object(data(path) ?? Data("{}".utf8))
    }
    static func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    static func rejectSymlink(_ path: String) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            throw HarnessError("Review the owner of this symbolic link before changing it: \(path)")
        }
    }
    /// Compare again immediately before rename. A lock serializes cooperating Tally writers.
    static func replace(_ path: String, expected: Data?, with replacement: Data?) throws {
        try rejectSymlink(path)
        guard try data(path) == expected else { throw HarnessError("File changed since preview: \(path)") }
        guard let replacement else {
            if exists(path) { try FileManager.default.removeItem(atPath: path) }
            return
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try makeDirectory(parent)
        let temporary = parent + "/.tally-harness-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) ?? 0o600
        guard FileManager.default.createFile(atPath: temporary, contents: replacement,
                                             attributes: [.posixPermissions: mode]) else {
            throw HarnessError("Could not prepare an atomic update.")
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: temporary))
        try handle.synchronize()
        try handle.close()
        try rejectSymlink(path)
        guard try data(path) == expected else { throw HarnessError("File changed during preparation: \(path)") }
        guard Darwin.rename(temporary, path) == 0 else { throw HarnessError("Atomic update failed: \(path)") }
    }
    static func locked<T>(_ directory: String, body: () throws -> T) throws -> T {
        try makeDirectory(directory)
        let descriptor = Darwin.open(directory + "/.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HarnessError("Cannot open the harness lock.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw HarnessError("Another Tally operation is running. Retry after it finishes.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    static func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func loadManifest(_ path: String) throws -> HarnessManifest {
        try rejectSymlink(path)
        guard let data = try data(path) else { throw HarnessError("Harness installation was not found.") }
        let manifest = try JSONDecoder().decode(HarnessManifest.self, from: data)
        let value = manifest.location
        _ = try HarnessLocation(scope: value.scope, sourceHome: value.sourceHome,
            targetHome: value.targetHome, project: value.project, sharedSkills: value.sharedSkills, stateRoot: value.stateRoot)
        guard manifest.schema == 1, value.identifier.count == 64,
              value.identifier.allSatisfy({ "0123456789abcdef".contains($0) }), value.manifestPath == path else {
            throw HarnessError("Unsupported or misplaced harness manifest.")
        }
        return manifest
    }
}
