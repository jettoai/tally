import Darwin
import Foundation

/// A separate receipt from harness tools: installation never changes inbox hook ownership.
enum CodexSessionHooks {
    static let component = "codexSessionHooks"
    static let events = ["SessionStart", "UserPromptSubmit", "PermissionRequest"]
    static let command = "/usr/local/bin/tally codex-session-hook"

    struct Receipt: Codable {
        var command: String
        var paths: [String]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func paths(homes: [String]) -> [String] {
        Array(Set(homes.map {
            URL(fileURLWithPath: $0).appendingPathComponent("hooks.json")
                .resolvingSymlinksInPath().standardizedFileURL.path
        })).sorted()
    }

    static func receiptURL(root: URL) -> URL { root.appendingPathComponent("codex-session-hooks.json") }

    static func receipt(root: URL) throws -> Receipt? {
        let file = receiptURL(root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file))
    }

    static func document(path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
            as? [String: Any] else { throw Failure(message: "Invalid Codex hooks document.") }
        guard object["hooks"] == nil || object["hooks"] is [String: Any] else {
            throw Failure(message: "Invalid Codex hooks object.")
        }
        return object
    }

    static func group(command: String) -> [String: Any] {
        ["matcher": "", "hooks": [["type": "command", "command": command, "timeout": 5]]]
    }

    static func same(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    static func installed(homes: [String], root: URL) throws -> Bool {
        guard let receipt = try receipt(root: root), receipt.paths == paths(homes: homes) else { return false }
        return try receipt.paths.allSatisfy { path in
            let hooks = try document(path: path)["hooks"] as? [String: Any] ?? [:]
            return events.allSatisfy { event in
                (hooks[event] as? [[String: Any]] ?? []).filter { same($0, group(command: receipt.command)) }.count == 1
            }
        }
    }

    static func install(homes: [String], root: URL, command: String = command) throws {
        try locked(root: root) {
            if try receipt(root: root) != nil {
                if try installed(homes: homes, root: root) { return }
                throw Failure(message: "Remove the previous Codex session status installation before reinstalling.")
            }
            let targets = paths(homes: homes)
            guard !targets.isEmpty else { throw Failure(message: "No Codex account homes were found.") }
            var writes: [(String, Data?, Data)] = []
            for path in targets {
                let url = URL(fileURLWithPath: path)
                let before = try? Data(contentsOf: url)
                var object = try document(path: path)
                var hooks = object["hooks"] as? [String: Any] ?? [:]
                for event in events {
                    guard hooks[event] == nil || hooks[event] is [[String: Any]] else {
                        throw Failure(message: "Invalid Codex hook event.")
                    }
                    var entries = hooks[event] as? [[String: Any]] ?? []
                    let entry = group(command: command)
                    guard !entries.contains(where: { same($0, entry) }) else {
                        throw Failure(message: "A matching hook exists without a Tally ownership receipt.")
                    }
                    entries.append(entry)
                    hooks[event] = entries
                }
                object["hooks"] = hooks
                writes.append((path, before, try JSONSerialization.data(withJSONObject: object,
                                                                        options: [.prettyPrinted, .sortedKeys])))
            }
            // Record the retry list before the first mutation so a partial install is removable.
            let receipt = Receipt(command: command, paths: targets)
            try JSONEncoder().encode(receipt).write(to: receiptURL(root: root), options: .atomic)
            for (path, before, after) in writes {
                let url = URL(fileURLWithPath: path)
                guard (try? Data(contentsOf: url)) == before else {
                    throw Failure(message: "Codex hooks changed during installation. Remove and retry.")
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try after.write(to: url, options: .atomic)
            }
        }
    }

    static func remove(root: URL) throws {
        try locked(root: root) {
            guard let receipt = try receipt(root: root) else { return }
            for path in receipt.paths {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                var object = try document(path: path)
                var hooks = object["hooks"] as? [String: Any] ?? [:]
                for event in events {
                    guard hooks[event] == nil || hooks[event] is [[String: Any]] else {
                        throw Failure(message: "Invalid Codex hook event; removal remains pending.")
                    }
                    if let entries = hooks[event] as? [[String: Any]] {
                        let remaining = entries.filter { !same($0, group(command: receipt.command)) }
                        if remaining.isEmpty { hooks.removeValue(forKey: event) }
                        else { hooks[event] = remaining }
                    }
                }
                object["hooks"] = hooks
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            try FileManager.default.removeItem(at: receiptURL(root: root))
        }
    }

    private static func locked(root: URL, action: () throws -> Void) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("codex-session-hooks.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw Failure(message: "Cannot lock Codex session status installation.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure(message: "Cannot lock Codex session status installation.") }
        defer { flock(fd, LOCK_UN) }
        try action()
    }
}
