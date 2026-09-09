import CoreFoundation
import Foundation

struct HarnessHookResult {
    let code: Int32
    let output: [String: Any]?
    let error: String
}

enum HarnessBridge {
    static func failure(_ event: String, _ reason: String) -> HarnessHookResult {
        let blocking = ["PreToolUse", "Stop", "UserPromptSubmit", "SubagentStop"].contains(event)
        return HarnessHookResult(code: blocking ? 2 : 1, output: nil, error: "Tally harness: " + reason + "\n")
    }

    static func run(manifestPath: String, entryID: String, event: [String: Any]) -> HarnessHookResult {
        let eventName = event["hook_event_name"] as? String ?? "PreToolUse"
        do {
            let manifest = try HarnessIO.loadManifest(manifestPath)
            guard manifest.phase == "installed" else { throw HarnessError("Installation is incomplete. Inspect or remove it before proceeding.") }
            guard let entry = manifest.hooks.first(where: { $0.id == entryID }),
                  entry.disposition == "protocol-candidate", eventName == entry.event else {
                throw HarnessError("Hook identity or event does not match its installation.")
            }
            if eventName == "Stop", event["stop_hook_active"] as? Bool == true {
                return HarnessHookResult(code: 0, output: nil, error: "")
            }
            let knownDefinitions = Set(manifest.hooks.filter { $0.source == entry.source }.map(\.definitionHash)
                + manifest.registrations.filter { $0.path == entry.source }.map(\.definitionHash)
                + (try HarnessTools.registrations(in: manifest.location.stateRoot))
                    .filter { $0.path == entry.source }.map(\.definitionHash))
            guard let handler = try HarnessInventory.resolveHandler(entry, knownDefinitions: knownDefinitions) else {
                return combined(eventName, ["Tally harness: source hook was removed. This orphan abstained; remove or reinstall the stale registration."], [], nil)
            }
            guard let command = handler["command"] as? String, let cwd = event["cwd"] as? String,
                  cwd.hasPrefix("/") else { throw HarnessError("Hook requires an absolute cwd and a command.") }
            if manifest.location.scope == "project" {
                let resolved = HarnessIO.canonical(cwd), root = manifest.location.project!
                guard resolved == root || resolved.hasPrefix(root + "/") else {
                    throw HarnessError("Project hook was invoked outside its checkout.")
                }
            }
            var inputs = [event]
            let tool = event["tool_name"] as? String ?? ""
            let toolEvent = ["PreToolUse", "PostToolUse"].contains(eventName)
            if toolEvent && tool == "apply_patch" {
                inputs = HarnessInventory.matches(entry.matcher, tool) ? [event] : []
                let fileAliases = ["Edit", "Write"].contains { HarnessInventory.matches(entry.matcher, $0) }
                if fileAliases {
                    inputs += try HarnessPatch.events(event).filter {
                        HarnessInventory.matches(entry.matcher, $0["tool_name"] as? String ?? "")
                    }
                } else if !HarnessInventory.matches(entry.matcher, tool) {
                    return HarnessHookResult(code: 0, output: nil, error: "")
                }
            } else if toolEvent && !HarnessInventory.matches(entry.matcher, tool) {
                return HarnessHookResult(code: 0, output: nil, error: "")
            }
            var context: [String] = [], warning: [String] = [], asks: [String] = []
            var rewritten: [String: Any]?
            let deadline = ProcessInfo.processInfo.systemUptime + entry.timeout
            for var item in inputs {
                item["tally_provider"] = "codex"
                // A Codex transcript is not a Claude transcript. It remains available under
                // an explicit provider key rather than inviting a Claude parser to consume it.
                item["tally_codex_transcript_path"] = item["transcript_path"]
                item["transcript_path"] = ""
                var environment = ProcessInfo.processInfo.environment
                environment["CLAUDE_CONFIG_DIR"] = manifest.location.sourceHome
                // A shared hooks.json can serve several Codex homes. Preserve the actual
                // runtime's home instead of changing it to the installation's first account.
                if environment["CODEX_HOME"] == nil { environment["CODEX_HOME"] = manifest.location.targetHome }
                environment["TALLY_HARNESS_PROVIDER"] = "codex"
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw HarnessError("Hook exceeded its deadline.") }
                let result = try HarnessProcess.run(executable: "/bin/bash", arguments: ["-c", command],
                    input: HarnessIO.json(item), cwd: cwd, environment: environment, timeout: remaining)
                if let failure = result.failure { return self.failure(eventName, failure) }
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                if result.code == 2 {
                    return HarnessHookResult(code: 2, output: nil,
                        error: stderr.isEmpty ? "Source hook blocked this operation.\n" : stderr)
                }
                guard result.code == 0 else { return failure(eventName, "Source hook failed with exit \(result.code). " + stderr) }
                if !stderr.isEmpty { warning.append(stderr) }
                guard !result.stdout.isEmpty else { continue }
                guard let text = String(data: result.stdout, encoding: .utf8) else { throw HarnessError("Hook output is not UTF-8.") }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                // Plain text is context for startup hooks, but cannot be a valid Stop decision.
                let output: [String: Any]
                do { output = try HarnessIO.object(result.stdout).filter { !($0.value is NSNull) } }
                catch {
                    if eventName == "SessionStart" { context.append(text); continue }
                    throw HarnessError("Hook returned invalid JSON.")
                }
                guard output["hookSpecificOutput"] == nil || output["hookSpecificOutput"] is [String: Any] else {
                    throw HarnessError("Malformed hook-specific output.")
                }
                let specific = (output["hookSpecificOutput"] as? [String: Any] ?? [:]).filter { !($0.value is NSNull) }
                for key in ["decision", "reason", "stopReason", "systemMessage"] {
                    guard output[key] == nil || output[key] is String else { throw HarnessError("Malformed source output field: \(key)") }
                }
                if let value = output["continue"] {
                    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                        throw HarnessError("Source continue must be a boolean.")
                    }
                }
                guard specific["permissionDecision"] == nil || specific["permissionDecision"] is String,
                      specific["permissionDecisionReason"] == nil || specific["permissionDecisionReason"] is String,
                      specific["hookEventName"] == nil || specific["hookEventName"] is String,
                      specific["additionalContext"] == nil || specific["additionalContext"] is String,
                      specific["updatedMCPToolOutput"] == nil else {
                    throw HarnessError("Unsupported or malformed source output.")
                }
                if let name = specific["hookEventName"] as? String, name != eventName {
                    throw HarnessError("Hook output names a different event.")
                }
                let reason = specific["permissionDecisionReason"] as? String
                    ?? output["reason"] as? String ?? output["stopReason"] as? String ?? "Source hook requires review."
                let decision = specific["permissionDecision"] as? String
                if eventName != "PreToolUse", output["continue"] as? Bool == false {
                    return HarnessHookResult(code: 0, output: ["continue": false, "stopReason": reason], error: stderr)
                }
                if output["decision"] as? String == "block" || decision == "deny"
                    || (eventName == "PreToolUse" && output["continue"] as? Bool == false) {
                    return block(eventName, reason)
                }
                if decision == "ask" {
                    guard eventName == "PreToolUse" else { throw HarnessError("ask is only supported by the pre-tool adapter.") }
                    asks.append(reason)
                } else if decision != nil && decision != "allow" {
                    throw HarnessError("Unknown source permission decision.")
                }
                if let updated = specific["updatedInput"] {
                    guard decision == "allow", inputs.count == 1,
                          item["tally_original_tool"] == nil, let value = updated as? [String: Any],
                          !["Bash", "apply_patch"].contains(tool) || value["command"] is String else {
                        throw HarnessError("This source input rewrite requires a native adapter.")
                    }
                    rewritten = value
                }
                if let value = specific["additionalContext"] as? String { context.append(value) }
                if let value = output["systemMessage"] as? String { warning.append(value) }
                if let legacy = output["decision"] as? String, legacy != "block" {
                    throw HarnessError("Legacy approval output requires explicit adaptation.")
                }
            }
            if !asks.isEmpty {
                var reason = "User approval required. Codex ask was converted to deny. " + asks.joined(separator: "\n")
                if ["apply_patch", "Edit", "Write"].contains(tool) {
                    let approval = try HarnessApproval.check(event: event, entry: entry,
                        location: manifest.location, generation: manifest.generation)
                    if approval.allowed { return combined(eventName, context, warning, rewritten) }
                    reason += "\nRequest: \(approval.request). After actual user authorization, use tally harness grant --manifest "
                        + HarnessIO.quote(manifestPath) + " --request \(approval.request) --authorization <conversation-reference>."
                }
                return block(eventName, reason)
            }
            return combined(eventName, context, warning, rewritten)
        } catch {
            return failure(eventName, (error as? HarnessError)?.message ?? "Hook could not be evaluated.")
        }
    }

    static func block(_ event: String, _ reason: String) -> HarnessHookResult {
        let output: [String: Any] = event == "PreToolUse"
            ? ["hookSpecificOutput": ["hookEventName": event, "permissionDecision": "deny", "permissionDecisionReason": reason]]
            : ["decision": "block", "reason": reason]
        return HarnessHookResult(code: 0, output: output, error: "")
    }

    static func combined(_ event: String, _ context: [String], _ warnings: [String],
                         _ rewrite: [String: Any]?) -> HarnessHookResult {
        var result: [String: Any] = [:], specific: [String: Any] = ["hookEventName": event]
        if !context.isEmpty { specific["additionalContext"] = context.joined(separator: "\n") }
        if let rewrite { specific["permissionDecision"] = "allow"; specific["updatedInput"] = rewrite }
        if specific.count > 1 { result["hookSpecificOutput"] = specific }
        if !warnings.isEmpty { result["systemMessage"] = warnings.joined(separator: "\n") }
        return HarnessHookResult(code: 0, output: result.isEmpty ? nil : result, error: "")
    }
}
