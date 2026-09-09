import Foundation

enum HarnessPatch {
    static func events(_ event: [String: Any]) throws -> [[String: Any]] {
        guard event["tool_name"] as? String == "apply_patch" else { return [event] }
        guard let input = event["tool_input"] as? [String: Any], let patch = input["command"] as? String,
              let cwd = event["cwd"] as? String else { throw HarnessError("Patch input requires command and cwd.") }
        var lines = patch.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.first == "*** Begin Patch", lines.last == "*** End Patch" else {
            throw HarnessError("Unrecognized patch envelope.")
        }
        var result: [[String: Any]] = [], path: String?, operation = "", move: String?
        var old: [String] = [], new: [String] = [], emitted = false
        func absolute(_ value: String) throws -> String {
            guard !value.isEmpty, !value.contains("\0"), !value.contains("\r") else {
                throw HarnessError("Invalid patch path.")
            }
            return URL(fileURLWithPath: value.hasPrefix("/") ? value : cwd + "/" + value).standardizedFileURL.path
        }
        func append(_ file: String, tool: String, payload: [String: Any], kind: String) {
            var item = event, value = payload
            value["file_path"] = file
            item["tool_name"] = tool
            item["tool_input"] = value
            item["tally_patch_operation"] = kind
            item["tally_original_tool"] = "apply_patch"
            result.append(item)
        }
        func emit() {
            guard let path, !old.isEmpty || !new.isEmpty else { return }
            func content(_ lines: [String]) -> String { lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n") }
            if operation == "update" {
                append(path, tool: "Edit", payload: ["old_string": content(old), "new_string": content(new)], kind: operation)
            } else {
                append(path, tool: "Write", payload: ["content": content(new)], kind: operation)
            }
            emitted = true
            old = []; new = []
        }
        func finish() {
            emit()
            if let path, !emitted {
                append(path, tool: operation == "add" ? "Write" : "Edit",
                       payload: operation == "add" ? ["content": ""] : [:], kind: operation)
            }
            if let move { append(move, tool: "Write", payload: [:], kind: "move-destination") }
        }
        for line in lines.dropFirst().dropLast() {
            if let (prefix, kind) = [("*** Add File: ", "add"), ("*** Update File: ", "update"),
                                      ("*** Delete File: ", "delete")].first(where: { line.hasPrefix($0.0) }) {
                finish()
                path = try absolute(String(line.dropFirst(prefix.count)))
                operation = kind; move = nil; emitted = false
            } else if line.hasPrefix("*** Move to: ") {
                guard path != nil, operation == "update", move == nil else { throw HarnessError("Invalid move header.") }
                move = try absolute(String(line.dropFirst("*** Move to: ".count)))
            } else if line.hasPrefix("@@") {
                guard path != nil, operation == "update" else { throw HarnessError("Hunk outside update.") }
                emit()
            } else if line == "*** End of File" {
                guard operation == "update" else { throw HarnessError("End-of-file marker outside update.") }
            } else {
                guard path != nil, operation != "delete" else { throw HarnessError("Content outside a writable patch file.") }
                if line.hasPrefix("+") { new.append(String(line.dropFirst())) }
                else if operation == "update", line.hasPrefix("-") { old.append(String(line.dropFirst())) }
                else if operation == "update", line.hasPrefix(" ") || line.isEmpty {
                    let text = line.isEmpty ? "" : String(line.dropFirst())
                    old.append(text); new.append(text)
                } else { throw HarnessError("Unrecognized patch line.") }
            }
        }
        finish()
        guard !result.isEmpty else { throw HarnessError("Patch contains no file operations.") }
        return result
    }

    static func paths(_ event: [String: Any]) throws -> [String] {
        let cwd = event["cwd"] as? String ?? ""
        return try Array(Set(events(event).map { item -> String in
            guard let path = (item["tool_input"] as? [String: Any])?["file_path"] as? String,
                  !path.isEmpty else { throw HarnessError("Approval requires explicit file paths.") }
            return URL(fileURLWithPath: path.hasPrefix("/") ? path : cwd + "/" + path).standardizedFileURL.path
        })).sorted()
    }

    static func fileState(_ path: String) throws -> [String: String] {
        var state = ["path": path, "resolved": HarnessIO.canonical(path)]
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: path) { state["link"] = link }
        let before = try? FileManager.default.attributesOfItem(atPath: state["resolved"]!)
        if let data = try HarnessIO.data(state["resolved"]!, limit: 1_048_576) {
            state["sha256"] = HarnessIO.hash(data)
            let attributes = try FileManager.default.attributesOfItem(atPath: state["resolved"]!)
            state["mode"] = String(describing: attributes[.posixPermissions] ?? "unknown")
            for key in [FileAttributeKey.systemFileNumber, .size, .modificationDate, .posixPermissions] {
                guard String(describing: before?[key]) == String(describing: attributes[key]) else {
                    throw HarnessError("File changed while preparing approval. Retry with the current file.")
                }
            }
        } else {
            guard before == nil else { throw HarnessError("File disappeared while preparing approval.") }
            state["state"] = "missing"
        }
        guard state["resolved"] == HarnessIO.canonical(path),
              state["link"] == (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) else {
            throw HarnessError("File link changed while preparing approval.")
        }
        return state
    }
}
