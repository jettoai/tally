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

    /// True when every one of `homes` reaches ONE `item` - e.g. all claude accounts sharing a single
    /// `projects` tree, which makes cross-account conversation moves (`tally resume`) unnecessary:
    /// the conversation is already visible everywhere.
    ///
    /// One object under several names, asked of the filesystem (PathIdentity.swift) rather than
    /// worked out from the paths. An item no home has reaches nothing and counts as shared by
    /// nobody, which is the honest reading: what is not there says nothing about how these accounts
    /// are wired.
    static func allShare(item: String, homes: [String]) -> Bool {
        guard homes.count > 1 else { return false }
        let items = homes.map { URL(fileURLWithPath: $0).appendingPathComponent(item) }
        return items.dropFirst().allSatisfy { pathsAreOne(items[0], $0) }
    }

    /// Compares every key item of `secondaryHome` against `primaryHome` as the OBJECT each reaches -
    /// one physical copy behind both names counts as shared, however the user wired it.
    static func report(primaryHome: String, secondaryHome: String, providerID: String) -> Report {
        var report = Report()
        let fm = FileManager.default
        for item in keyItems(providerID: providerID) {
            let primary = URL(fileURLWithPath: primaryHome).appendingPathComponent(item)
            guard fm.fileExists(atPath: primary.path) else { continue }
            let secondary = URL(fileURLWithPath: secondaryHome).appendingPathComponent(item)
            // The one definition every other surface asks (PathIdentity.swift): this row and the
            // Settings row are read side by side, and two spellings of "the same item" is how they
            // start saying different things about one machine.
            if pathsAreOne(primary, secondary) {
                report.sharedItems.append(item)
            } else {
                report.independentItems.append(item)
            }
        }
        return report
    }
}
