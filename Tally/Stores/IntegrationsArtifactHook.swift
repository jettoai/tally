import Foundation

// THE ARTIFACT PUBLISHING GUARD, RETIRED. Versions before 0.82.0 registered a `PreToolUse`
// hook on the `Artifact` tool in every Claude account's settings.json (`tally hook-artifact`). The
// feature is gone; what is left here is taking that registration back out, once per launch, through
// the same surgery the row's Remove used: only the hook whose command ends in our subcommand goes,
// and anything the user registered beside it, matcher included, stays exactly where it was.
//
// Delete this file, the `hook-artifact` case in TallyCLI/HookDispatch.swift, `artifact` in
// HarnessInventory's verb list and `retiredArtifactAccount` in LaunchPolicyStore together, no earlier
// than two minor releases after 0.82.0: until every machine has launched a build carrying
// this pass, some settings.json still runs that subcommand.
extension IntegrationsStore {
    /// The event and the command suffix older versions registered under. A SUFFIX, so a user's own
    /// `/opt/bin/my-hook-artifact` is never read as ours.
    private static let retiredArtifactHookEvent = "PreToolUse"
    private static let retiredArtifactHookMarker = " hook-artifact"

    /// The manifest key older versions recorded the registration under, read here as the retry list
    /// of files a previous pass could not finish.
    nonisolated static let artifactHookManifest = "claudeArtifactHook"

    private static func isOurArtifactHook(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.hasSuffix(retiredArtifactHookMarker) == true
    }

    private static func holdsOurArtifactHook(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { isOurArtifactHook($0) }
    }

    /// The settings document without our hook, or nil when there was none. It takes out the one
    /// hook, then every container left empty by its going: the entry, the event, the `hooks` block.
    /// Anything a user put beside it survives at every level, matcher included.
    static func settingsWithoutArtifactHook(_ settings: [String: Any]) -> [String: Any]? {
        guard var hooks = settings["hooks"] as? [String: Any],
              let entries = hooks[retiredArtifactHookEvent] as? [[String: Any]] else { return nil }
        var kept: [[String: Any]] = []
        var removed = false
        for entry in entries {
            guard holdsOurArtifactHook(entry) else { kept.append(entry); continue }
            removed = true
            let remaining = (entry["hooks"] as? [[String: Any]] ?? [])
                .filter { !isOurArtifactHook($0) }
            guard !remaining.isEmpty else { continue }
            var trimmed = entry
            trimmed["hooks"] = remaining
            kept.append(trimmed)
        }
        guard removed else { return nil }
        if kept.isEmpty { hooks.removeValue(forKey: retiredArtifactHookEvent) } else {
            hooks[retiredArtifactHookEvent] = kept
        }
        var merged = settings
        if hooks.isEmpty { merged.removeValue(forKey: "hooks") } else { merged["hooks"] = hooks }
        return merged
    }

    static func removeArtifactHook(in file: URL) throws {
        _ = try editSettings(file) { settingsWithoutArtifactHook($0) }
    }

    /// One removal pass, and WHAT THE MANIFEST MUST SAY AFTER IT: the paths still carrying our hook
    /// (nil when the pass finished), plus the first failure. The manifest is a RETRY LIST for the
    /// reason the notification hook's own pass states in full - it is the only record that a
    /// settings.json the discovery can no longer see was ever written to, so what was cleared leaves
    /// and what threw stays.
    static func removeArtifactHook(from files: [URL]) -> (remembered: [String]?, failure: Error?) {
        var remembered: [String] = []
        var failure: Error?
        for file in files {
            do { try removeArtifactHook(in: file) } catch {
                failure = failure ?? error
                remembered.append(file.path)
            }
        }
        return (remembered.isEmpty ? nil : remembered, failure)
    }

    /// Take the retired registration out of every settings.json it could be in, at launch.
    ///
    /// The population is the discovered homes plus the manifest's retry list, so a logged-out
    /// account's file is reached too. A file with nothing of ours is not written. A file that cannot
    /// be read stays on the retry list and is tried again next launch; it is not reported, because
    /// there is no row left to report it on, and the subcommand it still runs answers nothing.
    /// Never on a build nobody installed, and never on a launch showing fixtures.
    func retireArtifactHook() {
        guard !BuildVariant.isUnshipped, !DemoUsage.isActive else { return }
        let remembered = Self.manifestPaths(Self.artifactHookManifest)
        let pass = Self.removeArtifactHook(from: Self.notificationHookSettingsFiles(
            discovered: Self.claudeSettingsFiles(), remembered: remembered))
        if !remembered.isEmpty || pass.remembered != nil {
            recordManifest(Self.artifactHookManifest, paths: pass.remembered)
        }
        if autoFollowNotices.contains(Self.artifactHookManifest) {
            dismissAutoFollowNotice(Self.artifactHookManifest)
        }
    }
}
