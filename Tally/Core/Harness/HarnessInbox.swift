import Foundation

struct HarnessInboxAddress: Codable, Equatable {
    let provider: String
    let home: String
    let project: String

    init(provider: String, home: String, project: String) throws {
        guard ["claude", "codex"].contains(provider), home.hasPrefix("/"), project.hasPrefix("/") else {
            throw HarnessError("Inbox addressing requires a provider and absolute home and project paths.")
        }
        for path in [home, project] {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
                throw HarnessError("Inbox address directory does not exist: \(path)")
            }
        }
        self.provider = provider; self.home = HarnessIO.canonical(home)
        let result = try HarnessProcess.run(executable: "/usr/bin/git", arguments: ["rev-parse", "--show-toplevel"],
            input: Data(), cwd: project, environment: ProcessInfo.processInfo.environment, timeout: 3)
        self.project = result.code == 0 && result.failure == nil
            ? HarnessIO.canonical(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            : HarnessIO.canonical(project)
    }
    var object: [String: String] { ["provider": provider, "home": home, "project": project] }

    /// Match the existing Python v1 mailbox identity, including non-ASCII paths.
    var key: String {
        func string(_ value: String) -> String {
            var output = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 34: output += "\\\""
                case 92: output += "\\\\"
                case 8: output += "\\b"
                case 9: output += "\\t"
                case 10: output += "\\n"
                case 12: output += "\\f"
                case 13: output += "\\r"
                case 0..<32, 127...0xffff: output += String(format: "\\u%04x", scalar.value)
                case 0x10000...0x10ffff:
                    let v = scalar.value - 0x10000
                    output += String(format: "\\u%04x\\u%04x", 0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff))
                default: output.unicodeScalars.append(scalar)
                }
            }
            return output + "\""
        }
        let json = "{\"home\": " + string(home) + ", \"project\": " + string(project) + ", \"provider\": " + string(provider) + "}"
        return HarnessIO.hash(Data(json.utf8))
    }
}

enum HarnessInbox {
    static func box(_ root: String, _ address: HarnessInboxAddress) -> String { root + "/" + address.provider + "/" + address.key }

    static func message(_ root: String, address: HarnessInboxAddress, id: String) throws -> (String, Data, [String: Any]) {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw HarnessError("Invalid message UUID.") }
        let path = box(root, address) + "/" + id + ".json"
        try HarnessIO.rejectSymlink(path)
        guard let data = try HarnessIO.data(path, limit: 410_000) else { throw HarnessError("Message not found.") }
        let value = try HarnessIO.object(data)
        guard value["schema"] as? Int == 1, value["id"] as? String == id,
              value["to"] as? [String: String] == address.object,
              ["pending", "claimed", "archived"].contains(value["state"] as? String ?? "") else {
            throw HarnessError("Message identity or state does not match its address.")
        }
        if value["state"] as? String != "pending" {
            guard let claim = value["claim"] as? [String: Any],
                  !(claim["owner"] as? String ?? "").isEmpty, !(claim["nonce"] as? String ?? "").isEmpty else {
                throw HarnessError("Message claim is invalid.")
            }
        }
        return (path, data, value)
    }

    static func post(_ root: String, address: HarnessInboxAddress, body: String) throws -> [String: Any] {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 65_536 else {
            throw HarnessError("Message must contain 1 to 65536 UTF-8 bytes.")
        }
        let directory = box(root, address), id = UUID().uuidString.lowercased()
        try HarnessIO.rejectSymlink(directory)
        return try HarnessIO.locked(directory) {
            let value: [String: Any] = ["schema": 1, "id": id, "to": address.object, "state": "pending",
                "trust": "external-unverified", "body": body, "claim": NSNull(), "created_at": Date().timeIntervalSince1970]
            try HarnessIO.replace(directory + "/.address", expected: HarnessIO.data(directory + "/.address"), with: HarnessIO.json(address.object))
            try HarnessIO.replace(directory + "/" + id + ".json", expected: nil, with: HarnessIO.json(value))
            return ["id": id, "state": "pending", "received": false, "to": address.object]
        }
    }

    static func list(_ root: String, address: HarnessInboxAddress) throws -> [[String: Any]] {
        let directory = box(root, address)
        if !HarnessIO.exists(directory) { return [] }
        try HarnessIO.rejectSymlink(directory)
        return try HarnessIO.locked(directory) {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }.sorted()
            guard names.count <= 5_000 else { throw HarnessError("Mailbox exceeds the inspection limit.") }
            return names.compactMap { name in
                let id = String(name.dropLast(5))
                guard let (_, _, value) = try? message(root, address: address, id: id) else {
                    return ["id": id, "state": "unreadable", "home": address.home]
                }
                if value["state"] as? String == "archived" { return nil }
                return ["id": id, "state": value["state"]!, "home": address.home,
                        "created_at": value["created_at"] ?? NSNull(),
                        "owner": (value["claim"] as? [String: Any])?["owner"] ?? NSNull()]
            }
        }
    }

    static func addresses(_ root: String, address: HarnessInboxAddress) throws -> [HarnessInboxAddress] {
        let directory = root + "/" + address.provider
        guard HarnessIO.exists(directory) else { return [address] }
        var found = [address.home: address]
        let names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        guard names.count <= 5_000 else { throw HarnessError("Inbox address inventory exceeds its limit.") }
        for name in names {
            let folder = directory + "/" + name
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: folder)) != nil { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for candidate in [".address"] + files.filter({ $0.hasSuffix(".json") }).sorted() {
                let path = folder + "/" + candidate
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil,
                      let bytes = try? HarnessIO.data(path, limit: 410_000),
                      let value = try? HarnessIO.object(bytes),
                      let target = (candidate == ".address" ? value : value["to"]) as? [String: String],
                      target["project"] == address.project, target["provider"] == address.provider,
                      let home = target["home"],
                      let other = try? HarnessInboxAddress(provider: address.provider, home: home, project: address.project),
                      other.key == name else { continue }
                found[home] = other; break
            }
        }
        return found.values.sorted { $0.home < $1.home }
    }

    static func transition(_ root: String, address: HarnessInboxAddress, id: String,
                           action: String, owner: String, nonce: String?) throws -> [String: Any] {
        guard !owner.isEmpty, owner.count <= 200 else { throw HarnessError("An explicit session owner is required.") }
        let directory = box(root, address)
        try HarnessIO.rejectSymlink(directory)
        return try HarnessIO.locked(directory) {
            let (path, original, loaded) = try message(root, address: address, id: id)
            var value = loaded
            let claim = value["claim"] as? [String: Any]
            if action == "claim" {
                guard value["state"] as? String == "pending" else { throw HarnessError("Message is not pending.") }
                value["state"] = "claimed"
                value["claim"] = ["owner": owner, "nonce": UUID().uuidString.lowercased(), "at": Date().timeIntervalSince1970]
            } else {
                guard value["state"] as? String == "claimed", claim?["owner"] as? String == owner,
                      let nonce, !nonce.isEmpty, claim?["nonce"] as? String == nonce else {
                    throw HarnessError("Message requires its claim owner and nonce.")
                }
                switch action {
                case "read": return value
                case "ack":
                    value["state"] = "archived"
                    value["receipt"] = ["owner": owner, "nonce": nonce, "at": Date().timeIntervalSince1970]
                case "release": value["state"] = "pending"; value["claim"] = NSNull()
                default: throw HarnessError("Unknown inbox transition.")
                }
            }
            try HarnessIO.replace(path, expected: original, with: HarnessIO.json(value))
            return metadata(value)
        }
    }

    static func recover(_ root: String, address: HarnessInboxAddress, id: String, owner: String,
                        previousOwner: String, reason: String, confirmed: Bool) throws -> [String: Any] {
        guard confirmed, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reason.count <= 300, !owner.isEmpty, owner.count <= 200, !previousOwner.isEmpty else {
            throw HarnessError("Check the previous session, then provide --confirm-abandoned, --previous-owner, --owner, and --reason.")
        }
        let directory = box(root, address)
        try HarnessIO.rejectSymlink(directory)
        return try HarnessIO.locked(directory) {
            let (path, original, loaded) = try message(root, address: address, id: id)
            var value = loaded
            guard value["state"] as? String == "claimed",
                  (value["claim"] as? [String: Any])?["owner"] as? String == previousOwner else {
                throw HarnessError("Previous claim owner changed. Inspect the current claim.")
            }
            var recoveries = value["recoveries"] as? [[String: Any]] ?? []
            recoveries.append(["previous_owner": previousOwner, "owner": owner, "reason": reason, "at": Date().timeIntervalSince1970])
            value["recoveries"] = recoveries
            value["claim"] = ["owner": owner, "nonce": UUID().uuidString.lowercased(), "at": Date().timeIntervalSince1970]
            try HarnessIO.replace(path, expected: original, with: HarnessIO.json(value))
            return metadata(value)
        }
    }

    static func status(_ root: String, address: HarnessInboxAddress, id: String) throws -> [String: Any] {
        let (_, _, value) = try message(root, address: address, id: id)
        var result = value.filter { ["id", "state", "to"].contains($0.key) }
        result["owner"] = (value["claim"] as? [String: Any])?["owner"] ?? NSNull()
        result["acknowledged"] = value["receipt"] != nil
        if let receipt = value["receipt"] as? [String: Any] {
            result["receipt"] = ["owner": receipt["owner"] ?? NSNull(), "at": receipt["at"] ?? NSNull()]
        }
        return result
    }

    static func metadata(_ value: [String: Any]) -> [String: Any] {
        value.filter { ["id", "state", "to", "claim"].contains($0.key) }
    }
}
