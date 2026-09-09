import Foundation

enum HarnessLifecycle {
    static func run(manifestPath: String, event: [String: Any]) -> HarnessHookResult {
        do {
            let manifest = try HarnessIO.loadManifest(manifestPath)
            guard manifest.phase == "installed", event["hook_event_name"] as? String == "SessionStart" else {
                throw HarnessError("Lifecycle event does not match an active installation.")
            }
            if let project = manifest.location.project {
                guard let cwd = event["cwd"] as? String,
                      HarnessIO.canonical(cwd) == project || HarnessIO.canonical(cwd).hasPrefix(project + "/") else {
                    throw HarnessError("Project harness does not match this session's directory.")
                }
            }
            let changes = try HarnessObservation.changes(manifest)
            var context = "Tally harness is registered for \(manifest.location.scope) scope. Read the applicable source instructions at "
                + manifest.location.sourceInstructions + " and the tally-harness skill. "
                + "Claude framework mechanisms are not Codex tools. Registration is not behavioral validation. "
                + "Use the tools available in this session and preserve current user authorization."
            if !changes.isEmpty {
                context += "\nDrift observed in \(changes.count) paths. Run tally harness status with this installation's explicit locations. "
                    + "Configuration was not reapplied. Changed hook definitions require review; ordinary script changes use their current contents."
            }
            return HarnessHookResult(code: 0, output: ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": context]], error: "")
        } catch { return HarnessBridge.failure("SessionStart", error.localizedDescription) }
    }
}
