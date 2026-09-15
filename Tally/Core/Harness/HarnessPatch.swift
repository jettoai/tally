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

}
