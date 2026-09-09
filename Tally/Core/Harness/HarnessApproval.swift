import Foundation

/// Cooperative record of prior authorization, not a source of user authority.
enum HarnessApproval {
    static func binding(event: [String: Any], entry: HarnessHook, location: HarnessLocation, generation: String) throws -> [String: Any] {
        guard let session = event["session_id"] as? String, !session.isEmpty, session.count <= 200,
              let cwd = event["cwd"] as? String, cwd.hasPrefix("/"),
              let input = event["tool_input"] as? [String: Any] else {
            throw HarnessError("Exact patch approval requires a session, cwd, and tool input.")
        }
        let files = try HarnessPatch.paths(event).map(HarnessPatch.fileState)
        guard !files.isEmpty else { throw HarnessError("Approval has no file operations.") }
        let actualHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? location.targetHome
        return ["session": session, "cwd": HarnessIO.canonical(cwd), "tool": event["tool_name"] ?? "",
                "codexHome": HarnessIO.canonical(actualHome),
                "agentID": event["agent_id"] ?? NSNull(), "agentType": event["agent_type"] ?? NSNull(),
                "inputHash": try HarnessIO.hash(HarnessIO.json(input)), "files": files,
                "entry": entry.id, "definitionHash": entry.definitionHash, "installation": location.identifier,
                "generation": generation]
    }

    static func check(event: [String: Any], entry: HarnessHook, location: HarnessLocation, generation: String,
                      now: TimeInterval = Date().timeIntervalSince1970) throws -> (allowed: Bool, request: String) {
        let binding = try binding(event: event, entry: entry, location: location, generation: generation)
        let request = try HarnessIO.hash(HarnessIO.json(binding)), root = location.directory + "/approvals/" + generation
        return try HarnessIO.locked(root) {
            let path = root + "/" + request + ".json"
            try HarnessIO.rejectSymlink(path)
            let original = try HarnessIO.data(path)
            var record = try original.map(HarnessIO.object) ?? [:]
            if record["state"] as? String == "granted",
               let existing = record["binding"] as? [String: Any],
               try HarnessIO.json(existing) == HarnessIO.json(binding),
               (record["expires"] as? Double ?? 0) > now {
                record["state"] = "consumed"; record["consumed"] = now
                try HarnessIO.replace(path, expected: original, with: HarnessIO.json(record))
                return (true, request)
            }
            if original == nil || record["state"] as? String == "granted" {
                record = ["schema": 1, "state": "pending", "binding": binding, "created": now]
                try HarnessIO.replace(path, expected: original, with: HarnessIO.json(record))
            }
            return (false, request)
        }
    }

    static func grant(_ request: String, authorization: String, manifestPath: String,
                      now: TimeInterval = Date().timeIntervalSince1970) throws -> [String: Any] {
        guard request.count == 64, request.allSatisfy({ "0123456789abcdef".contains($0) }),
              !authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, authorization.count <= 300 else {
            throw HarnessError("A request ID and an actual user authorization reference are required.")
        }
        let manifest = try HarnessIO.loadManifest(manifestPath)
        guard manifest.phase == "installed" else { throw HarnessError("Approval requires an active installation.") }
        let root = manifest.location.directory + "/approvals/" + manifest.generation
        return try HarnessIO.locked(root) {
            let path = root + "/" + request + ".json"
            try HarnessIO.rejectSymlink(path)
            guard let original = try HarnessIO.data(path) else { throw HarnessError("Approval request not found.") }
            var record = try HarnessIO.object(original)
            guard let binding = record["binding"] as? [String: Any],
                  try HarnessIO.hash(HarnessIO.json(binding)) == request,
                  binding["generation"] as? String == manifest.generation,
                  ["pending", "consumed"].contains(record["state"] as? String ?? ""),
                  let files = binding["files"] as? [[String: String]],
                  let entry = manifest.hooks.first(where: { $0.id == binding["entry"] as? String }) else {
                throw HarnessError("Approval request is invalid or already granted.")
            }
            _ = try HarnessInventory.sourceHandler(entry)
            for file in files {
                guard let path = file["path"], try HarnessPatch.fileState(path) == file else {
                    throw HarnessError("Files changed since the request. Review the new patch first.")
                }
            }
            record["state"] = "granted"; record["expires"] = now + 900; record["authorizationReference"] = authorization
            try HarnessIO.replace(path, expected: original, with: HarnessIO.json(record))
            return ["request": request, "state": "granted", "expires": now + 900,
                    "meaning": "Records prior authorization; does not prove user identity."]
        }
    }
}
