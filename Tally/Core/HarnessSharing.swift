import Foundation

/// Read-only detection of whether a provider's multi-account homes share their harness layers
/// (config, skills, transcripts, …). Tally OBSERVES sharing, it does not own it: users who wired
/// their own symlinks see them acknowledged; nothing in this type ever mutates a file.
enum HarnessSharing {
    /// The layers worth reporting, per provider. Existence in the primary home is the baseline -
    /// an item the primary doesn't have says nothing about sharing.
    static func keyItems(providerID: String) -> [String] {
        switch providerID {
        case "claude":
            return ["skills", "hooks", "agents", "memory", "projects", "CLAUDE.md", "settings.json"]
        case "codex":
            return ["config.toml", "AGENTS.md", "agents", "rules", "hooks", "plugins", "sessions", "skills"]
        default:
            return []
        }
    }

    struct Report: Equatable {
        var sharedItems: [String] = []
        var independentItems: [String] = []
        var total: Int { sharedItems.count + independentItems.count }
    }

    /// Compares every key item of `secondaryHome` against `primaryHome` by fully-resolved path -
    /// one physical copy behind both names counts as shared, however the user wired it.
    static func report(primaryHome: String, secondaryHome: String, providerID: String) -> Report {
        var report = Report()
        let fm = FileManager.default
        for item in keyItems(providerID: providerID) {
            let primary = URL(fileURLWithPath: primaryHome).appendingPathComponent(item)
            guard fm.fileExists(atPath: primary.path) else { continue }
            let secondary = URL(fileURLWithPath: secondaryHome).appendingPathComponent(item)
            // Compare .path, not URLs: resolving a symlink-to-directory yields a trailing-slash
            // URL while a plain directory does not, and URL equality treats those as different.
            if primary.resolvingSymlinksInPath().path == secondary.resolvingSymlinksInPath().path {
                report.sharedItems.append(item)
            } else {
                report.independentItems.append(item)
            }
        }
        return report
    }
}
